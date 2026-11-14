#!/usr/bin/env bash
#
# MSI MS-16Q4 (P65 Creator 8SF / GS65/GP65/GE65 family):
# полноценный S3 + обход аппаратного RF-kill Wi-Fi после пробуждения.
#
# Что делает:
#   1. Проверяет наличие S3 (deep), msi_ec, NetworkManager.
#   2. По умолчанию переключает бит 3 регистра EC 0x2e (Wi-Fi моргнёт на 1-2 с).
#   3. Настраивает загрузчик: основные входы -> mem_sleep_default=deep,
#      fallback-входы systemd-boot остаются с s2idle.
#   4. Добавляет автозагрузку msi_ec с debug=true.
#   5. Ставит /usr/lib/systemd/system-sleep/50-msi-wifi-rfkill:
#      EC toggle -> rfkill -> при необходимости PCI reset/iwlwifi -> NM.
#   6. Убирает старый wifi-reset и неверный iwlwifi disable_aspm.
#
# Запуск:
#   sudo ./apply-sleep-fix.sh            # проверить EC и установить (по умолчанию)
#   sudo ./apply-sleep-fix.sh --no-test  # установить без проверки EC
#   sudo ./apply-sleep-fix.sh --test     # то же, что без флага (совместимость)
#
set -uo pipefail
shopt -s nullglob

HOOK="/usr/lib/systemd/system-sleep/50-msi-wifi-rfkill"
OLD_HOOK="/usr/lib/systemd/system-sleep/wifi-reset"
EC_DEBUG="/sys/devices/platform/msi-ec/debug"
EC_CONF="/etc/msi-wifi-rfkill.conf"
LOG="/var/log/msi-wifi-rfkill-install.log"

# Адрес и бит аппаратного RF-kill в EC.
# Для MS-16Q4 это 0x2e, бит 3. Для другой модели проверьте ec_dump.
EC_ADDR="${MSI_EC_ADDR:-2e}"
EC_BIT="${MSI_EC_BIT:-3}"

say() { printf '%s\n' "$*"; }
die() { say "ОШИБКА: $*"; exit 1; }

DO_TEST=1
case "${1:-}" in
    ""|--test) DO_TEST=1 ;;
    --no-test) DO_TEST=0 ;;
    *) die "неизвестный аргумент: $1. Используйте --no-test." ;;
esac

[ "$(id -u)" -eq 0 ] || die "запустите через sudo"

case "$EC_ADDR" in
    [0-9a-fA-F][0-9a-fA-F]) ;;
    *) die "MSI_EC_ADDR должен быть двумя hex-цифрами, например 2e" ;;
esac
case "$EC_BIT" in
    [0-7]) ;;
    *) die "MSI_EC_BIT должен быть 0..7" ;;
esac
MASK=$((1 << EC_BIT))

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
say "=== install $(date -Is) ==="

# ---------------------------------------------------------------- checks
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
BOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)
say "model: $PRODUCT / $BOARD"
case "$PRODUCT $BOARD" in
    *"P65 Creator 8SF"*|*"MS-16Q4"*) ;;
    *) say "ПРЕДУПРЕЖДЕНИЕ: скрипт рассчитан на MSI MS-16Q4 (P65/GS65/GP65/GE65)." ;;
esac

command -v nmcli   >/dev/null 2>&1 || die "нужен NetworkManager (nmcli)"
command -v iw      >/dev/null 2>&1 || die "нужен пакет iw"
command -v rfkill  >/dev/null 2>&1 || die "нужен rfkill"
command -v modinfo >/dev/null 2>&1 || die "нужен kmod (modinfo)"

if ! modinfo msi_ec >/dev/null 2>&1; then
    say "ОШИБКА: модуль msi_ec не найден."
    say "Нужен пакет с драйвером MSI EC (это не универсальная команда):"
    say "  Arch/AUR: msi-ec-dkms-git"
    say "  Fedora:   COPR xabi08/MSI-EC (пакет msi-ec-kmod)"
    say "  NixOS:    boot.extraModulePackages = [ config.boot.kernelPackages.msi-ec ];"
    say "  Debian/Ubuntu/Alpine/Slackware: пакеты проекта msi-ec или сборка из исходников"
    say "  Исходники: https://github.com/MControlSuite/msi-ec"
    say "После установки проверьте:"
    say "  sudo modprobe msi_ec debug=true"
    say "  ls /sys/devices/platform/msi-ec/debug/"
    exit 1
fi

grep -qw deep /sys/power/mem_sleep 2>/dev/null || die \
    "S3 deep не поддерживается: $(cat /sys/power/mem_sleep 2>/dev/null). Фикс не нужен/невозможен."

# ---------------------------------------------------------------- helpers
backup() {
    [ -e "$1" ] || return 0
    local b="$1.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$1" "$b" || die "не удалось сделать backup $1"
    say "backup: $b"
}

EC_RESTORE=""
restore_ec() {
    if [ -n "${EC_RESTORE:-}" ] && [ -w "$EC_DEBUG/ec_set" ]; then
        printf '%s=%s\n' "$EC_ADDR" "$EC_RESTORE" > "$EC_DEBUG/ec_set" 2>/dev/null || true
        say "EC restore: $EC_ADDR=$EC_RESTORE"
    fi
    EC_RESTORE=""
}
trap restore_ec EXIT INT TERM

read_ec() {
    echo "$EC_ADDR" > "$EC_DEBUG/ec_get" 2>/dev/null || return 1
    cat "$EC_DEBUG/ec_get" 2>/dev/null | tr -d '[:space:]'
}

write_ec() {
    printf '%s=%02x\n' "$EC_ADDR" "$1" > "$EC_DEBUG/ec_set" 2>/dev/null
}

load_msi_ec() {
    modprobe msi_ec debug=true 2>/dev/null || true
    sleep 0.5
    if [ ! -e "$EC_DEBUG/ec_get" ] || [ ! -e "$EC_DEBUG/ec_set" ]; then
        modprobe -r msi_ec 2>/dev/null || true
        modprobe msi_ec debug=true 2>/dev/null || true
        sleep 0.5
    fi
    [ -e "$EC_DEBUG/ec_get" ] && [ -e "$EC_DEBUG/ec_set" ] || die \
        "msi_ec не создал debug-интерфейс $EC_DEBUG"
}

configure_bootloader() {
    local f

    if [ -d /boot/loader/entries ] && compgen -G '/boot/loader/entries/*.conf' >/dev/null; then
        say "обнаружен systemd-boot"
        for f in /boot/loader/entries/*.conf; do
            case "$f" in
                *-fallback.conf)
                    say "пропускаю fallback: $f (остаётся s2idle)"
                    continue
                    ;;
            esac
            [ -w "$f" ] || die "нет записи в $f (проверьте, что /boot смонтирован rw)"
            backup "$f"
            if grep -q 'mem_sleep_default=' "$f"; then
                sed -i 's/mem_sleep_default=[^ ]*/mem_sleep_default=deep/g' "$f"
            else
                sed -i 's/^\(options .*\)$/\1 mem_sleep_default=deep/' "$f"
            fi
            say "обновлён: $f"
        done
        return 0
    fi

    if [ -e /etc/default/grub ] && command -v grub-mkconfig >/dev/null 2>&1; then
        say "обнаружен GRUB"
        backup /etc/default/grub
        if grep -q 'mem_sleep_default=' /etc/default/grub; then
            sed -i 's/mem_sleep_default=[^ "]*/mem_sleep_default=deep/' /etc/default/grub
        else
            sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="\)\(.*\)"/\1\2 mem_sleep_default=deep"/' /etc/default/grub
        fi
        if [ -w /boot/grub/grub.cfg ]; then
            grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig завершился с ошибкой"
        else
            say "ПРЕДУПРЕЖДЕНИЕ: /boot/grub/grub.cfg недоступен для записи; выполните grub-mkconfig вручную"
        fi
        return 0
    fi

    say "ПРЕДУПРЕЖДЕНИЕ: не удалось определить загрузчик."
    say "Добавьте mem_sleep_default=deep в параметры ядра вручную."
    return 1
}

# ---------------------------------------------------------------- msi_ec
say
say "--- загрузка msi_ec debug=true ---"
load_msi_ec
say "msi_ec: $(lsmod | awk '$1=="msi_ec"{print $0}')"
say "fw_version: $(cat "$EC_DEBUG/fw_version" 2>/dev/null || echo '?')"
say "$EC_ADDR: 0x$(read_ec || echo '?')"

# ---------------------------------------------------------------- EC test
if [ "$DO_TEST" -eq 1 ]; then
    say
    say "--- тест EC: снимаю и возвращаю бит $EC_BIT регистра 0x$EC_ADDR ---"
    say "Wi-Fi может моргнуть на 1-2 секунды."
    val_hex=$(read_ec) || die "не читается 0x$EC_ADDR"
    val=$((16#$val_hex))
    on=$((val | MASK))
    off=$((val & ~MASK))
    EC_RESTORE=$val_hex

    if [ $(( (val >> EC_BIT) & 1 )) -eq 1 ]; then
        write_ec "$off" || die "не удалось записать 0x$EC_ADDR"
        sleep 1
        off_read=$(read_ec || echo '?')
        say "после снятия бита: 0x$off_read (ожидалось 0x$(printf '%02x' "$off"))"
        say "rfkill: $(rfkill list wifi 2>/dev/null | tr '\n' ' ')"
        write_ec "$on" || die "не удалось вернуть 0x$EC_ADDR"
        sleep 1
        on_read=$(read_ec || echo '?')
        say "после возврата: 0x$on_read (ожидалось 0x$(printf '%02x' "$on"))"
        say "rfkill: $(rfkill list wifi 2>/dev/null | tr '\n' ' ')"
        if [ "$off_read" != "$(printf '%02x' "$off")" ] || [ "$on_read" != "$(printf '%02x' "$on")" ]; then
            die "EC не подтвердил переключение бита $EC_BIT — установка отменена"
        fi
    else
        say "бит $EC_BIT уже снят; ставлю его обратно"
        write_ec "$on" || die "не удалось записать 0x$EC_ADDR"
        sleep 1
        say "0x$EC_ADDR: 0x$(read_ec || echo '?')"
    fi
    EC_RESTORE=""
    say "EC test: OK"
fi

# ---------------------------------------------------------------- bootloader
say
say "--- загрузчик: deep для основных входов ---"
configure_bootloader || true

# ---------------------------------------------------------------- msi_ec boot config
say
say "--- автозагрузка msi_ec ---"
backup /etc/modprobe.d/msi-ec.conf
cat > /etc/modprobe.d/msi-ec.conf <<'EOF'
options msi_ec debug=true
EOF

mkdir -p /etc/modules-load.d
backup /etc/modules-load.d/msi-ec.conf
cat > /etc/modules-load.d/msi-ec.conf <<'EOF'
msi_ec
EOF

backup "$EC_CONF"
cat > "$EC_CONF" <<EOF
# Адрес и бит аппаратного RF-kill в EC для MS-16Q4.
# Для другой модели проверьте debug/ec_dump и измените значения.
MSI_EC_ADDR=$EC_ADDR
MSI_EC_BIT=$EC_BIT
EOF
say "созданы /etc/modprobe.d/msi-ec.conf, /etc/modules-load.d/msi-ec.conf, $EC_CONF"

# ---------------------------------------------------------------- iwlwifi opts
say
say "--- чистка iwlwifi.conf ---"
if [ -e /etc/modprobe.d/iwlwifi.conf ]; then
    backup /etc/modprobe.d/iwlwifi.conf
    sed -i '/disable_aspm/d' /etc/modprobe.d/iwlwifi.conf
    say "удалён неверный параметр disable_aspm"
    sed -n '1,20p' /etc/modprobe.d/iwlwifi.conf
else
    say "/etc/modprobe.d/iwlwifi.conf отсутствует — пропускаю"
fi

# ---------------------------------------------------------------- old hook
say
say "--- отключение старого wifi-reset ---"
if [ -e "$OLD_HOOK" ]; then
    mv "$OLD_HOOK" "/root/wifi-reset.disabled.$(date +%Y%m%d-%H%M%S)"
    say "старый хук перемещён в /root/"
else
    say "старого хука нет"
fi
for f in /etc/systemd/system-sleep/*wifi-reset*; do
    mv "$f" "/root/$(basename "$f").disabled.$(date +%Y%m%d-%H%M%S)"
    say "старый хук перемещён: $f"
done

# ---------------------------------------------------------------- new hook
say
say "--- установка нового хука ---"
# systemd-sleep исполняет хуки только из /usr/lib/systemd/system-sleep/.
if [ -e "$HOOK" ]; then
    cp -p "$HOOK" "/root/$(basename "$HOOK").bak.$(date +%Y%m%d-%H%M%S)"
fi
cat > "$HOOK" <<'HOOK_EOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

LOG=/var/log/msi-wifi-rfkill.log
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

[ "$1" = post ] || exit 0
case "${2:-}" in
    suspend|hibernate|suspend-then-hibernate|hybrid-sleep) ;;
    *) exit 0 ;;
esac

EC_DEBUG=/sys/devices/platform/msi-ec/debug
EC_CONF=/etc/msi-wifi-rfkill.conf

# Настройки EC можно переопределить в /etc/msi-wifi-rfkill.conf.
[ -r "$EC_CONF" ] && . "$EC_CONF"
EC_ADDR="${MSI_EC_ADDR:-2e}"
EC_BIT="${MSI_EC_BIT:-3}"
MASK=$((1 << EC_BIT))

# Определяем Wi-Fi интерфейс: сначала через NetworkManager, потом через sysfs.
IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
if [ -z "$IFACE" ]; then
    for i in /sys/class/net/*; do
        if [ -e "$i/wireless" ]; then
            IFACE=${i##*/}
            break
        fi
    done
fi

# PCI-адрес Wi-Fi. Для CNVi 9560 это обычно 0000:00:14.3.
BDF=""
if [ -n "$IFACE" ]; then
    BDF=$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null | sed 's#.*/##')
fi
if [ -z "$BDF" ]; then
    BDF=$(lspci -Dn 2>/dev/null | awk '$0 ~ /\[0280\]/{print $1; exit}')
fi
[ -n "$BDF" ] || BDF=0000:00:14.3

log "resume ($2): start (iface=${IFACE:-?}, pci=$BDF, ec=$EC_ADDR bit=$EC_BIT)"

# 1. MSI EC: после S3 бит 3 регистра 0x2e оставляет аппаратный RF-kill.
#    Снимаем и возвращаем бит (аналог двойного Fn+F10).
if [ ! -w "$EC_DEBUG/ec_set" ]; then
    modprobe msi_ec debug=true 2>/dev/null || true
    sleep 0.5
fi

if [ -r "$EC_DEBUG/ec_get" ] && [ -w "$EC_DEBUG/ec_set" ]; then
    echo "$EC_ADDR" > "$EC_DEBUG/ec_get" 2>/dev/null || true
    val_hex=$(cat "$EC_DEBUG/ec_get" 2>/dev/null | tr -d '[:space:]')
    case "$val_hex" in
        [0-9a-fA-F][0-9a-fA-F]) ;;
        *) val_hex="" ;;
    esac
    if [ -n "$val_hex" ]; then
        val=$((16#$val_hex))
        on=$((val | MASK))
        if [ $(( (val >> EC_BIT) & 1 )) -eq 1 ]; then
            off=$((val & ~MASK))
            log "$EC_ADDR=0x$(printf '%02x' "$val"): toggle bit $EC_BIT"
            printf '%s=%02x\n' "$EC_ADDR" "$off" > "$EC_DEBUG/ec_set" 2>/dev/null || true
            sleep 1
            printf '%s=%02x\n' "$EC_ADDR" "$on" > "$EC_DEBUG/ec_set" 2>/dev/null || true
        else
            log "$EC_ADDR=0x$(printf '%02x' "$val"): set bit $EC_BIT"
            printf '%s=%02x\n' "$EC_ADDR" "$on" > "$EC_DEBUG/ec_set" 2>/dev/null || true
        fi
        sleep 1
        echo "$EC_ADDR" > "$EC_DEBUG/ec_get" 2>/dev/null || true
        log "$EC_ADDR now 0x$(cat "$EC_DEBUG/ec_get" 2>/dev/null | tr -d '[:space:]')"
    else
        log "cannot read EC register $EC_ADDR"
    fi
else
    log "msi_ec debug interface unavailable"
fi

# 2. Мягкий rfkill.
rfkill unblock wifi 2>/dev/null || true

# 3. Если wiphy не пережил resume (ERFKILL) — сброс PCI и перезагрузка драйвера.
need_reload=0
if rfkill list wifi 2>/dev/null | grep -q 'Hard blocked: yes'; then
    need_reload=1
    log "Wi-Fi still hard blocked after EC toggle"
fi

if [ -z "$IFACE" ] || ! iw dev "$IFACE" info >/dev/null 2>&1; then
    sleep 2
    if [ -z "$IFACE" ]; then
        IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
    fi
    if [ -z "$IFACE" ] || ! iw dev "$IFACE" info >/dev/null 2>&1; then
        need_reload=1
        log "Wi-Fi interface is not usable"
    fi
fi

if [ "$need_reload" -eq 1 ]; then
    log "resetting PCI $BDF and reloading iwlwifi"
    if [ -e "/sys/bus/pci/devices/$BDF" ]; then
        echo 1 > "/sys/bus/pci/devices/$BDF/remove" 2>/dev/null || true
        sleep 1
    fi
    modprobe -r iwlmvm iwlwifi 2>/dev/null || true
    modprobe ptp 2>/dev/null || true
    modprobe iwlmvm 2>/dev/null || true
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    sleep 1
    if [ -z "$IFACE" ]; then
        IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
    fi
fi

# 4. NetworkManager: после PCI reset/перезагрузки модулей он часто оставляет
#    интерфейс в unmanaged. В этом состоянии ждать бессмысленно — сразу рестарт.
nmcli radio wifi on >/dev/null 2>&1 || true

state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v iface="$IFACE" '$1==iface{print $2}')
case "$state" in
    unmanaged|unavailable|"")
        log "iface state '$state'; restarting NetworkManager immediately"
        systemctl restart NetworkManager >/dev/null 2>&1 || true
        if [ -z "$IFACE" ]; then
            IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
        fi
        ;;
esac

# Ждём подключения до 10 секунд.
state=""
i=0
while [ "$i" -lt 20 ]; do
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v iface="$IFACE" '$1==iface{print $2}')
    [ "$state" = connected ] && break
    sleep 0.5
    i=$((i + 1))
done

# Если всё ещё не подключено — один контрольный перезапуск NM.
if [ "$state" != connected ]; then
    log "iface state '$state'; restarting NetworkManager"
    systemctl restart NetworkManager >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 30 ]; do
        state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v iface="$IFACE" '$1==iface{print $2}')
        [ "$state" = connected ] && break
        sleep 0.5
        i=$((i + 1))
    done
fi

log "resume done: ${IFACE:-wifi}=${state:-missing}"
exit 0
HOOK_EOF
chmod 755 "$HOOK"
say "установлен: $HOOK"

# Сразу переключаем текущую сессию на deep; после ребута это сделает boot entry.
if grep -qw deep /sys/power/mem_sleep 2>/dev/null; then
    echo deep > /sys/power/mem_sleep 2>/dev/null || true
    say "runtime mem_sleep: $(cat /sys/power/mem_sleep)"
fi

# ---------------------------------------------------------------- summary
say
say "=== ГОТОВО ==="
say "1. Можно тестировать сразу: mem_sleep уже deep. После ребута deep придёт из boot entry,"
say "   а msi_ec загрузится автоматически."
say "2. Проверьте: cat /sys/power/mem_sleep   (должно быть [deep])"
say "3. Проверьте сон: sudo rtcwake -m no -s 45 && systemctl suspend"
say "4. После пробуждения: nmcli device, rfkill list; лог хука: /var/log/msi-wifi-rfkill.log"
say
say "Если S3 не проснётся: удерживайте кнопку питания, при загрузке выберите *-fallback"
say "(systemd-boot: там оставлен s2idle) или отредактируйте mem_sleep_default в boot entry."
say "Если Wi-Fi hard-blocked: запустите sudo ./recover-wifi.sh или нажмите Fn+F10 два раза."
say
say "Backup'ы boot entry лежат рядом: /boot/loader/entries/*.bak.*"
