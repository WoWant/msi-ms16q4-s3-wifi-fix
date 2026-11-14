[![RU](https://img.shields.io/badge/RU-Russian-blue)](README.md)
[![EN](https://img.shields.io/badge/EN-English-lightgrey)](README.en.md)

# MSI MS-16Q4: полноценный S3 + исправление Wi-Fi после сна

Фикс для ноутбуков MSI на плате **MS-16Q4** (P65 Creator 8SF, GS65 Stealth 8RF/9SE,
GP65/GE65 и родственные модели) с Wi-Fi **Intel Wireless-AC 9560 CNVi**
(`8086:a370`, драйвер `iwlwifi`).

Решает две связанные проблемы:

1. Ноутбук использует `s2idle` вместо полноценного **S3 (`deep`)**.
   `s2idle` не выключает платформу полностью; S3 выключает питание почти
   полностью и является «настоящим» сном.
2. После пробуждения из S3 Wi-Fi уходит в **аппаратный RF-kill** и не
   восстанавливается ни `rfkill unblock`, ни перезагрузкой `iwlwifi`, ни PCI reset.
   Помогает только перезагрузка — или обход EC, который делает этот фикс.

> Это **не универсальный фикс** для любых проблем со сном или Wi-Fi.
> Он нужен только для MSI MS-16Q4 (и родственных моделей) с Intel 9560,
> когда после S3 в логе видно `ERFKILL` / `Failed to start RT ucode: -132`,
> а `rfkill` показывает `Hard blocked: yes`. На других ноутбуках причины
> и решения будут другими; `msi-ec` на не-MSI железе не поможет.

---

## Симптомы

- `cat /sys/power/mem_sleep` показывает `[s2idle] deep`.
- В журнале при засыпании: `PM: suspend entry (s2idle)`.
- После пробуждения:

  ```text
  iwlwifi 0000:00:14.3: reporting RF_KILL (radio disabled)
  iwlwifi 0000:00:14.3: Failed to start RT ucode: -132
  ieee80211 phyX: PM: dpm_run_callback(): wiphy_resume [cfg80211] returns -132
  ieee80211 phyX: PM: failed to resume async: error -132
  ```

  `-132` — это `ERFKILL`, то есть радио заблокировано аппаратно.
- `rfkill list` показывает `Hard blocked: yes`; `rfkill unblock all` не помогает.

---

## Причина

Это не баг `iwlwifi`, а особенность прошивки EC (Embedded Controller) MSI.
После выхода из S3 EC просыпается с выставленным аппаратным RF-kill, хотя
в регистре `0x2e` бит 3 всё ещё означает «радио включено». Драйвер видит
аппаратную блокировку и не может загрузить firmware (`ERFKILL -132`).

Обход: **снять и вернуть бит 3 регистра `0x2e`** — это эмуляция двойного
нажатия Fn+F10. На MS-16Q4 по умолчанию используется `0x2e`, бит 3.
После этого `rfkill` чистый, и достаточно дать NetworkManager поднять интерфейс.

> На некоторых прошивках MSI при `0x34 = 0x50` клавиша Fn+F10 игнорируется EC.
> Поэтому фикс пишет в EC напрямую, не полагаясь на Fn-клавишу.

---

## Что делает фикс

- Переключает основные записи загрузчика на `mem_sleep_default=deep`
  (S3 вместо s2idle). Fallback-записи systemd-boot остаются с `s2idle`
  как безопасный вариант для восстановления.
- Добавляет автозагрузку модуля `msi_ec` с `debug=true`
  (`/etc/modprobe.d/msi-ec.conf`, `/etc/modules-load.d/msi-ec.conf`).
  Это даёт доступ к `debug/ec_get` и `debug/ec_set`.
- Ставит post-resume хук
  `/usr/lib/systemd/system-sleep/50-msi-wifi-rfkill`:
  1. переключает бит RF-kill в EC;
  2. снимает soft-rfkill;
  3. если интерфейс/драйвер не пережил resume — делает PCI reset и
     перезагружает `iwlwifi`/`iwlmvm` (с явной загрузкой `ptp`, чтобы
     не ловить `Unknown symbol ptp_clock_*`);
  4. если NetworkManager оставил интерфейс в `unmanaged`/`unavailable`,
     сразу перезапускает NM (без 15-секундного ожидания);
  5. ждёт подключения, при необходимости перезапускает NM ещё раз.
- Убирает старый `wifi-reset`, который делал PCI reset, но не трогал EC,
  и поэтому не мог снять аппаратную блокировку.
- Удаляет неверный параметр `options iwlwifi disable_aspm=1`
  (такого параметра нет; ASPM уже выключен через `pcie_aspm=off`).

---

## Требования

- Linux с systemd, **NetworkManager** (`nmcli`), `iw`, `rfkill`, `kmod`, `util-linux`.
- `linux-firmware` для `iwlwifi`.
- **Модуль `msi_ec`** — обязательное условие. Скрипт и хук используют
  `/sys/devices/platform/msi-ec/debug`; без модуля фикс не работает.
- Если включён Secure Boot, модуль DKMS должен быть подписан и ключ
  должен быть доверенным.

### Как установить `msi_ec`

`yay -S msi-ec-dkms-git` — это **только пример для Arch Linux / AUR**,
а не универсальная команда. Выберите вариант под свою систему:

- **Arch Linux / AUR:** пакет `msi-ec-dkms-git`:

  ```bash
  yay -S msi-ec-dkms-git   # или paru -S msi-ec-dkms-git
  sudo dkms status
  ```

- **Fedora:** COPR `xabi08/MSI-EC`, пакет `msi-ec-kmod`.
- **NixOS:** добавьте в конфигурацию:

  ```nix
  boot.extraModulePackages = [ config.boot.kernelPackages.msi-ec ];
  boot.kernelModules = [ "msi-ec" ];
  ```

- **Debian/Ubuntu, Alpine, Slackware:** готовые пакеты проекта `msi-ec`
  (Cloudsmith) или сборка из исходников.
- **Из исходников (универсальный вариант):** нужны kernel headers, `make`,
  `gcc` и `dkms`:

  ```bash
  git clone https://github.com/MControlSuite/msi-ec.git
  cd msi-ec
  sudo make dkms-install
  sudo reboot
  ```

- Если модуль не поддерживает вашу EC-прошивку, debug-интерфейс всё равно
  может появиться при `debug=true`. Проверка:

  ```bash
  sudo modprobe msi_ec debug=true
  ls /sys/devices/platform/msi-ec/debug/
  ```

- Если `msi_ec` установить нельзя, теоретически остаётся `ec_sys`
  (`sudo modprobe ec_sys write_support=1`), но тогда хук нужно переписать
  под `/sys/kernel/debug/ec/ec0/io`. Это менее безопасно и в проекте
  «из коробки» не поддерживается.

Если модуль не загружается при Secure Boot — зарегистрируйте ключ DKMS
(`dkms`/`mokutil`) или отключите Secure Boot.

> `msi_ec` нужен только для MSI. На других ноутбуках не устанавливайте его
> «на всякий случай»: причины проблем со сном/Wi-Fi там другие.

---

## Установка

Склонируйте проект (или перейдите в уже скачанную папку):

```bash
git clone https://github.com/WoWant/msi-ms16q4-s3-wifi-fix.git
cd msi-ms16q4-s3-wifi-fix
```

Запустите установщик:

```bash
sudo ./apply-sleep-fix.sh
```

**По умолчанию** скрипт сначала проверяет запись в EC:

- читает `0x2e`;
- снимает бит 3;
- возвращает бит 3;
- проверяет, что регистр действительно изменился.

Во время проверки Wi-Fi может моргнуть на 1–2 секунды. Если проверка не прошла,
установка отменяется, а исходное значение EC восстанавливается.

Если нужно установить или обновить фикс **без проверки EC** (Wi-Fi не моргнёт):

```bash
sudo ./apply-sleep-fix.sh --no-test
```

`--test` оставлен как синоним поведения по умолчанию для совместимости.
Скрипт идемпотентен: его можно запускать повторно для обновления хука.
Он делает backup'ы изменяемых файлов (`.bak.YYYYMMDD-HHMMSS`).

После установки перезагрузитесь, чтобы:

- применился `mem_sleep_default=deep` из загрузчика;
- `msi_ec` загрузился автоматически;
- проверилась работа хука после реального S3.

---

## Проверка

До сна:

```bash
cat /sys/power/mem_sleep
# ожидается: s2idle [deep]   (квадратные скобки вокруг deep)

lsmod | grep msi_ec
cat /sys/devices/platform/msi-ec/debug/fw_version
```

Тест сна с автоматическим пробуждением через 45 секунд:

```bash
sudo rtcwake -m no -s 45
systemctl suspend
```

После пробуждения:

```bash
cat /var/log/msi-wifi-rfkill.log
nmcli device
rfkill list
```

Ожидаемый лог:

```text
resume (suspend): start (iface=wlan0, pci=0000:00:14.3, ec=2e bit=3)
2e=0x4b: toggle bit 3
2e now 0x4b
iface state 'unmanaged'; restarting NetworkManager immediately
resume done: wlan0=connected
```

Ожидаемое время от пробуждения до Wi-Fi — примерно **5–8 секунд**.
Если в логе снова `iface state 'unmanaged'` и пауза ~15 секунд, значит
установлен старый хук; обновите его: `sudo ./apply-sleep-fix.sh --no-test`.

---

## Если что-то пошло не так

### Ноутбук не проснулся из S3

1. Удерживайте кнопку питания до выключения.
2. Включите и выберите в меню загрузчика `*-fallback` — там оставлен
   `mem_sleep_default=s2idle`.
3. Если fallback не помогает, отредактируйте boot entry и замените
   `mem_sleep_default=deep` на `s2idle` (или уберите параметр).
4. Как план B можно настроить гибернацию: 16 ГБ swap при 15 ГБ RAM хватает,
   а после гибернации EC сбрасывается полностью.

### Wi-Fi остался hard-blocked

Запустите аварийное восстановление без перезагрузки:

```bash
sudo ./recover-wifi.sh
```

Оно переключит EC-бит, снимет rfkill и перезапустит NetworkManager.

Если не помогло:

```bash
rfkill list
sudo rfkill unblock all
sudo modprobe -r iwlmvm iwlwifi
sudo modprobe ptp
sudo modprobe iwlmvm
sudo systemctl restart NetworkManager
```

Если и это не помогло — перезагрузка. После перезагрузки проверьте
`/var/log/msi-wifi-rfkill.log`: возможно, хук не запускался или EC-адрес
на этой прошивке другой.

### `msi_ec` не загружается

```bash
sudo modprobe msi_ec debug=true
dmesg | tail -50
sudo dkms status
```

Проверьте:

- установлен ли подходящий пакет с модулем `msi_ec` (см. раздел «Требования»);
- собран ли модуль для текущего ядра (`dkms status`);
- не блокирует ли Secure Boot;
- нет ли конфликта с `msi_wmi` (обычно они сосуществуют).

### Нет `debug/ec_get` / `debug/ec_set`

Модуль загружен без `debug=true`. Перезагрузите его:

```bash
sudo modprobe -r msi_ec
sudo modprobe msi_ec debug=true
ls /sys/devices/platform/msi-ec/debug/
```

### Нет `deep` в `/sys/power/mem_sleep`

Значит, S3 не поддерживается BIOS/ACPI. Тогда используйте гибернацию
или оставьте `s2idle` (но Wi-Fi после него всё равно может отваливаться).
Фикс рассчитан на машины, где `deep` доступен.

### GRUB вместо systemd-boot

Скрипт определяет GRUB и добавляет `mem_sleep_default=deep` в
`/etc/default/grub`, затем выполняет `grub-mkconfig -o /boot/grub/grub.cfg`.
Проверьте:

```bash
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Для других загрузчиков (refind, limine и т.п.) добавьте
`mem_sleep_default=deep` в параметры ядра вручную.

---

## Откат

Удалить хук и конфиги:

```bash
sudo rm -f /usr/lib/systemd/system-sleep/50-msi-wifi-rfkill
sudo rm -f /etc/modprobe.d/msi-ec.conf
sudo rm -f /etc/modules-load.d/msi-ec.conf
sudo rm -f /etc/msi-wifi-rfkill.conf
sudo modprobe -r msi_ec
```

Вернуть загрузчик:

- systemd-boot: восстановите `*.conf` из `*.conf.bak.*` в
  `/boot/loader/entries/` (или замените `mem_sleep_default=deep` на `s2idle`).
- GRUB: восстановите `/etc/default/grub.bak.*` и выполните
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`.

Старый хук `wifi-reset` при установке перемещается в `/root/`
(`wifi-reset.disabled.*`). Его можно вернуть, но он не решает проблему
аппаратного RF-kill.

---

## Перенос на другую машину / переустановка

### Та же модель (MS-16Q4, Intel 9560)

1. Установите подходящий пакет с модулем `msi_ec` (см. раздел «Требования»)
   и пересоберите DKMS для текущего ядра.
2. Скопируйте папку проекта.
3. Запустите (по умолчанию скрипт проверит EC):

   ```bash
   sudo ./apply-sleep-fix.sh
   ```

4. Перезагрузитесь и проверьте сон.

### Другая модель MSI

Адрес/бит EC может отличаться. Проверьте дамп:

```bash
sudo modprobe msi_ec debug=true
cat /sys/devices/platform/msi-ec/debug/ec_dump
```

Найдите регистр, который меняется при переключении Fn+F10 (или
известный по `msi-ec` issue #804). Затем задайте значения (пример: `0x2e`, бит 3):

```bash
sudo MSI_EC_ADDR=2e MSI_EC_BIT=3 ./apply-sleep-fix.sh --force-unsupported
```

Скрипт по умолчанию откажется работать на модели, отличной от MS-16Q4:
`--force-unsupported` — это явное подтверждение, что вы проверили EC-регистр.
По умолчанию скрипт выполнит проверку EC. Если проверка уже сделана и нужно
просто установить/обновить фикс, добавьте `--no-test`:

```bash
sudo MSI_EC_ADDR=2e MSI_EC_BIT=3 ./apply-sleep-fix.sh --no-test --force-unsupported
```

Или отредактируйте `/etc/msi-wifi-rfkill.conf` после установки:

```ini
MSI_EC_ADDR=2e
MSI_EC_BIT=3
```

> Запись в EC — потенциально опасная операция. Делайте backup EC-дампа
> и не меняйте незнакомые регистры. По умолчанию скрипт проверяет EC
> перед установкой; `--no-test` пропускает эту проверку.

### Другая Wi-Fi карта

EC-обход всё равно может понадобиться, если это MSI MS-16Q4 с другой
картой, но хук рассчитан на `iwlwifi`. Для других драйверов
PCI reset/перезагрузка модулей нужно адаптировать.

---

## Файлы и логи

| Путь | Назначение |
| --- | --- |
| `/usr/lib/systemd/system-sleep/50-msi-wifi-rfkill` | post-resume хук |
| `/etc/msi-wifi-rfkill.conf` | адрес/бит EC |
| `/etc/modprobe.d/msi-ec.conf` | `options msi_ec debug=true` |
| `/etc/modules-load.d/msi-ec.conf` | автозагрузка `msi_ec` |
| `/var/log/msi-wifi-rfkill.log` | лог хука |
| `/var/log/msi-wifi-rfkill-install.log` | лог установки |
| `/boot/loader/entries/*.bak.*` | backup'ы boot entries |

---

## Ссылки

- MSI EC RF-kill bug, GS65/P65: <https://github.com/MControlSuite/msi-ec/issues/804>
- `msi-ec` driver: <https://github.com/MControlSuite/msi-ec>
- Arch Wiki, power management: <https://wiki.archlinux.org/title/Power_management>
- Arch Wiki, suspend/resume: <https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate>

---

## Лицензия

MIT — см. [LICENSE](LICENSE).
