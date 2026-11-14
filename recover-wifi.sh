#!/usr/bin/env bash
#
# Аварийное восстановление Wi-Fi на MSI MS-16Q4 без перезагрузки.
# Переключает бит аппаратного RF-kill в EC (0x2e, бит 3 по умолчанию),
# снимает soft-rfkill и перезапускает NetworkManager.
#
# Запуск:
#   sudo ./recover-wifi.sh
#
# Адрес/бит можно изменить в /etc/msi-wifi-rfkill.conf
# или переменными MSI_EC_ADDR / MSI_EC_BIT.
#
set -uo pipefail

EC_DEBUG="/sys/devices/platform/msi-ec/debug"
EC_CONF="/etc/msi-wifi-rfkill.conf"
LOG="/var/log/msi-wifi-rfkill.log"

say() { printf '%s\n' "$*"; }
die() { say "ОШИБКА: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "запустите через sudo"

[ -r "$EC_CONF" ] && . "$EC_CONF"
EC_ADDR="${MSI_EC_ADDR:-2e}"
EC_BIT="${MSI_EC_BIT:-3}"
case "$EC_ADDR" in
    [0-9a-fA-F][0-9a-fA-F]) ;;
    *) die "MSI_EC_ADDR должен быть двумя hex-цифрами" ;;
esac
case "$EC_BIT" in
    [0-7]) ;;
    *) die "MSI_EC_BIT должен быть 0..7" ;;
esac
MASK=$((1 << EC_BIT))

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

# Интерфейс и PCI-адрес
IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
if [ -z "$IFACE" ]; then
    for i in /sys/class/net/*; do
        if [ -e "$i/wireless" ]; then
            IFACE=${i##*/}
            break
        fi
    done
fi

BDF=""
if [ -n "$IFACE" ]; then
    BDF=$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null | sed 's#.*/##')
fi
if [ -z "$BDF" ]; then
    BDF=$(lspci -Dn 2>/dev/null | awk '$0 ~ /\[0280\]/{print $1; exit}')
fi
[ -n "$BDF" ] || BDF=0000:00:14.3

say "Wi-Fi: iface=${IFACE:-?}, pci=$BDF"
say "EC:    $EC_ADDR, бит $EC_BIT"

# Модуль msi_ec в debug-режиме
if [ ! -w "$EC_DEBUG/ec_set" ]; then
    say "Загружаю msi_ec debug=true..."
    modprobe msi_ec debug=true 2>/dev/null || true
    sleep 0.5
fi
[ -r "$EC_DEBUG/ec_get" ] && [ -w "$EC_DEBUG/ec_set" ] || die \
    "нет debug-интерфейса msi_ec. Установлен ли msi-ec-dkms-git?"

read_ec() {
    echo "$EC_ADDR" > "$EC_DEBUG/ec_get" 2>/dev/null || return 1
    cat "$EC_DEBUG/ec_get" 2>/dev/null | tr -d '[:space:]'
}
write_ec() {
    printf '%s=%02x\n' "$EC_ADDR" "$1" > "$EC_DEBUG/ec_set" 2>/dev/null
}

val_hex=$(read_ec) || die "не читается EC $EC_ADDR"
val=$((16#$val_hex))
on=$((val | MASK))
off=$((val & ~MASK))
say "EC $EC_ADDR до: 0x$(printf '%02x' "$val")"

if [ $(( (val >> EC_BIT) & 1 )) -eq 1 ]; then
    say "Снимаю бит $EC_BIT..."
    write_ec "$off" || die "не удалось записать EC"
    sleep 1
    say "EC $EC_ADDR: 0x$(read_ec || echo '?')"
    say "Возвращаю бит $EC_BIT..."
    write_ec "$on" || die "не удалось вернуть EC"
else
    say "Бит $EC_BIT уже снят; ставлю обратно..."
    write_ec "$on" || die "не удалось записать EC"
fi
sleep 1
say "EC $EC_ADDR после: 0x$(read_ec || echo '?')"
log "manual recovery: $EC_ADDR toggled, iface=${IFACE:-?}, pci=$BDF"

# Soft-rfkill и NetworkManager
rfkill unblock wifi 2>/dev/null || true
nmcli radio wifi on >/dev/null 2>&1 || true

say "Перезапускаю NetworkManager..."
systemctl restart NetworkManager >/dev/null 2>&1 || true
if [ -z "$IFACE" ]; then
    IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
fi

state=""
i=0
while [ "$i" -lt 40 ]; do
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v iface="$IFACE" '$1==iface{print $2}')
    [ "$state" = connected ] && break
    sleep 0.5
    i=$((i + 1))
done

say "Состояние ${IFACE:-wifi}: ${state:-missing}"
rfkill list wifi 2>/dev/null || true

if [ "$state" = connected ]; then
    say "Готово: Wi-Fi подключён."
    exit 0
fi

say "Wi-Fi не подключился автоматически."
say "Проверьте: nmcli device; nmcli connection up <имя>; rfkill list"
say "Лог: $LOG"
exit 1
