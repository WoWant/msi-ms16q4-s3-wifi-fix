[![RU](https://img.shields.io/badge/RU-Russian-lightgrey)](README.md)
[![EN](https://img.shields.io/badge/EN-English-blue)](README.en.md)

# MSI MS-16Q4: full S3 sleep + Wi-Fi fix after resume

A fix for MSI laptops based on the **MS-16Q4** board (P65 Creator 8SF,
GS65 Stealth 8RF/9SE, GP65/GE65 and related models) with the
**Intel Wireless-AC 9560 CNVi** Wi-Fi card (`8086:a370`, `iwlwifi` driver).

It addresses two related issues:

1. The laptop uses `s2idle` instead of full **S3 (`deep`)** sleep.
   `s2idle` does not power the platform down completely; S3 cuts power
   almost entirely and is the "real" sleep state.
2. After resuming from S3, Wi-Fi is put into **hardware RF-kill** and cannot
   be recovered by `rfkill unblock`, by reloading `iwlwifi`, or by a PCI reset.
   Only a reboot helps — or the EC workaround implemented by this fix.

> This is **not a universal fix** for any sleep or Wi-Fi problem.
> It is only for MSI MS-16Q4 (and related models) with the Intel 9560,
> when the log shows `ERFKILL` / `Failed to start RT ucode: -132` after S3
> and `rfkill` reports `Hard blocked: yes`. Other laptops have different
> causes and different fixes; `msi-ec` will not help on non-MSI hardware.

---

## Symptoms

- `cat /sys/power/mem_sleep` shows `[s2idle] deep`.
- The journal shows `PM: suspend entry (s2idle)` when going to sleep.
- After resume:

  ```text
  iwlwifi 0000:00:14.3: reporting RF_KILL (radio disabled)
  iwlwifi 0000:00:14.3: Failed to start RT ucode: -132
  ieee80211 phyX: PM: dpm_run_callback(): wiphy_resume [cfg80211] returns -132
  ieee80211 phyX: PM: failed to resume async: error -132
  ```

  `-132` is `ERFKILL`, meaning the radio is blocked by hardware.
- `rfkill list` reports `Hard blocked: yes`; `rfkill unblock all` does not help.

---

## Root cause

This is not an `iwlwifi` bug. It is a quirk of the MSI EC (Embedded Controller)
firmware. After resuming from S3, the EC wakes up with the hardware RF-kill
asserted, even though bit 3 of register `0x2e` still means "radio enabled".
The driver sees the hardware block and cannot load the firmware
(`ERFKILL -132`).

The workaround is to **clear and then set bit 3 of register `0x2e`** — this
emulates pressing Fn+F10 twice. On the MS-16Q4 the default is `0x2e`, bit 3.
After that `rfkill` is clean, and all NetworkManager needs is a nudge to bring
the interface up.

> On some MSI firmware versions, when `0x34 = 0x50`, the EC ignores the Fn+F10
> key. That is why this fix writes to the EC directly instead of relying on
> the Fn key.

---

## What the fix does

- Switches the main boot entries to `mem_sleep_default=deep`
  (S3 instead of s2idle). systemd-boot fallback entries keep `s2idle`
  as a safe recovery option.
- Adds automatic loading of the `msi_ec` module with `debug=true`
  (`/etc/modprobe.d/msi-ec.conf`, `/etc/modules-load.d/msi-ec.conf`).
  This exposes `debug/ec_get` and `debug/ec_set`.
- Installs a post-resume hook at
  `/usr/lib/systemd/system-sleep/50-msi-wifi-rfkill`:
  1. toggles the EC RF-kill bit;
  2. clears soft-rfkill;
  3. if the interface/driver did not survive resume, performs a PCI reset and
     reloads `iwlwifi`/`iwlmvm` (loading `ptp` explicitly to avoid
     `Unknown symbol ptp_clock_*`);
  4. if NetworkManager left the interface in `unmanaged`/`unavailable`,
     restarts NM immediately (no 15-second wait);
  5. waits for the connection and restarts NM once more if needed.
- Removes the old `wifi-reset` hook, which performed a PCI reset but did not
  touch the EC and therefore could not clear the hardware block.
- Removes the invalid `options iwlwifi disable_aspm=1` option
  (no such parameter exists; ASPM is already disabled via `pcie_aspm=off`).

---

## Requirements

- Linux with systemd, **NetworkManager** (`nmcli`), `iw`, `rfkill`, `kmod`,
  `util-linux`.
- `linux-firmware` for `iwlwifi`.
- The **`msi_ec` module** is mandatory. The script and the hook use
  `/sys/devices/platform/msi-ec/debug`; without the module the fix cannot work.
- With Secure Boot enabled, the DKMS module must be signed and its key trusted.

### How to install `msi_ec`

`yay -S msi-ec-dkms-git` is **only an example for Arch Linux / AUR**, not a
universal command. Choose the option for your system:

- **Arch Linux / AUR:** the `msi-ec-dkms-git` package:

  ```bash
  yay -S msi-ec-dkms-git   # or paru -S msi-ec-dkms-git
  sudo dkms status
  ```

- **Fedora:** COPR `xabi08/MSI-EC`, package `msi-ec-kmod`.
- **NixOS:** add to your configuration:

  ```nix
  boot.extraModulePackages = [ config.boot.kernelPackages.msi-ec ];
  boot.kernelModules = [ "msi-ec" ];
  ```

- **Debian/Ubuntu, Alpine, Slackware:** packages provided by the `msi-ec`
  project (Cloudsmith) or build from source.
- **From source (universal option):** requires kernel headers, `make`, `gcc`
  and `dkms`:

  ```bash
  git clone https://github.com/MControlSuite/msi-ec.git
  cd msi-ec
  sudo make dkms-install
  sudo reboot
  ```

- If the module does not support your EC firmware, the debug interface may
  still appear with `debug=true`. Check:

  ```bash
  sudo modprobe msi_ec debug=true
  ls /sys/devices/platform/msi-ec/debug/
  ```

- If `msi_ec` cannot be installed at all, `ec_sys` is theoretically an option
  (`sudo modprobe ec_sys write_support=1`), but the hook would have to be
  rewritten for `/sys/kernel/debug/ec/ec0/io`. That is less safe and is not
  supported out of the box by this project.

If the module does not load with Secure Boot enabled, enroll the DKMS key
(`dkms`/`mokutil`) or disable Secure Boot.

> `msi_ec` is only for MSI laptops. Do not install it "just in case" on other
> hardware: the causes of sleep/Wi-Fi problems there are different.

---

## Installation

Clone the project (or enter the directory you already downloaded):

```bash
git clone https://github.com/WoWant/msi-ms16q4-s3-wifi-fix.git
cd msi-ms16q4-s3-wifi-fix
```

Run the installer:

```bash
sudo ./apply-sleep-fix.sh
```

**By default** the script first verifies writes to the EC:

- reads `0x2e`;
- clears bit 3;
- sets bit 3 again;
- verifies that the register actually changed.

Wi-Fi may blink for 1–2 seconds during the check. If the check fails, the
installation is aborted and the original EC value is restored.

To install or update the fix **without the EC check** (Wi-Fi will not blink):

```bash
sudo ./apply-sleep-fix.sh --no-test
```

`--test` is kept as a synonym for the default behavior for compatibility.
The script is idempotent: it can be run again to update the hook.
It creates backups of modified files (`.bak.YYYYMMDD-HHMMSS`).

After installation, reboot so that:

- `mem_sleep_default=deep` from the bootloader takes effect;
- `msi_ec` is loaded automatically;
- the hook is tested after a real S3 cycle.

---

## Verification

Before sleeping:

```bash
cat /sys/power/mem_sleep
# expected: s2idle [deep]   (the selected state is in square brackets)

lsmod | grep msi_ec
cat /sys/devices/platform/msi-ec/debug/fw_version
```

Sleep test with automatic wake-up after 45 seconds:

```bash
sudo rtcwake -m no -s 45
systemctl suspend
```

After resume:

```bash
cat /var/log/msi-wifi-rfkill.log
nmcli device
rfkill list
```

Expected log:

```text
resume (suspend): start (iface=wlan0, pci=0000:00:14.3, ec=2e bit=3)
2e=0x4b: toggle bit 3
2e now 0x4b
iface state 'unmanaged'; restarting NetworkManager immediately
resume done: wlan0=connected
```

Expected time from resume to Wi-Fi is about **5–8 seconds**.
If the log again shows `iface state 'unmanaged'` followed by a ~15-second
pause, the old hook is still installed; update it with
`sudo ./apply-sleep-fix.sh --no-test`.

---

## Troubleshooting

### The laptop did not wake from S3

1. Hold the power button until the laptop turns off.
2. Power it on and select a `*-fallback` entry in the boot menu — it keeps
   `mem_sleep_default=s2idle`.
3. If the fallback does not help, edit the boot entry and replace
   `mem_sleep_default=deep` with `s2idle` (or remove the parameter).
4. As a plan B, configure hibernation: 16 GB of swap is enough for 15 GB of
   RAM, and hibernation resets the EC completely.

### Wi-Fi is still hard-blocked

Run the emergency recovery without rebooting:

```bash
sudo ./recover-wifi.sh
```

It toggles the EC bit, clears rfkill and restarts NetworkManager.

If that does not help:

```bash
rfkill list
sudo rfkill unblock all
sudo modprobe -r iwlmvm iwlwifi
sudo modprobe ptp
sudo modprobe iwlmvm
sudo systemctl restart NetworkManager
```

If that still does not help, reboot. After rebooting, check
`/var/log/msi-wifi-rfkill.log`: the hook may not have run, or the EC address
may be different on your firmware.

### `msi_ec` does not load

```bash
sudo modprobe msi_ec debug=true
dmesg | tail -50
sudo dkms status
```

Check:

- whether the correct package with the `msi_ec` module is installed
  (see the "Requirements" section);
- whether the module is built for the current kernel (`dkms status`);
- whether Secure Boot is blocking it;
- whether it conflicts with `msi_wmi` (usually they coexist).

### No `debug/ec_get` / `debug/ec_set`

The module was loaded without `debug=true`. Reload it:

```bash
sudo modprobe -r msi_ec
sudo modprobe msi_ec debug=true
ls /sys/devices/platform/msi-ec/debug/
```

### No `deep` in `/sys/power/mem_sleep`

This means S3 is not supported by the BIOS/ACPI. Use hibernation instead,
or keep `s2idle` (Wi-Fi may still fail after it). This fix is intended for
machines where `deep` is available.

### GRUB instead of systemd-boot

The script detects GRUB, adds `mem_sleep_default=deep` to
`/etc/default/grub`, and runs `grub-mkconfig -o /boot/grub/grub.cfg`.
Verify:

```bash
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

For other bootloaders (refind, limine, etc.), add `mem_sleep_default=deep`
to the kernel parameters manually.

---

## Rollback

Remove the hook and configuration files:

```bash
sudo rm -f /usr/lib/systemd/system-sleep/50-msi-wifi-rfkill
sudo rm -f /etc/modprobe.d/msi-ec.conf
sudo rm -f /etc/modules-load.d/msi-ec.conf
sudo rm -f /etc/msi-wifi-rfkill.conf
sudo modprobe -r msi_ec
```

Restore the bootloader configuration:

- systemd-boot: restore `*.conf` from `*.conf.bak.*` in
  `/boot/loader/entries/` (or replace `mem_sleep_default=deep` with `s2idle`).
- GRUB: restore `/etc/default/grub.bak.*` and run
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`.

The old `wifi-reset` hook is moved to `/root/` during installation
(`wifi-reset.disabled.*`). It can be restored, but it does not solve the
hardware RF-kill problem.

---

## Moving to another machine / reinstall

### Same model (MS-16Q4, Intel 9560)

1. Install the correct package with the `msi_ec` module (see "Requirements")
   and rebuild DKMS for the current kernel.
2. Copy the project directory.
3. Run (the script checks the EC by default):

   ```bash
   sudo ./apply-sleep-fix.sh
   ```

4. Reboot and test sleep.

### Another MSI model

The EC address/bit may be different. Inspect the dump:

```bash
sudo modprobe msi_ec debug=true
cat /sys/devices/platform/msi-ec/debug/ec_dump
```

Find the register that changes when toggling Fn+F10 (or the one known from
`msi-ec` issue #804). Then set the values (example: `0x2e`, bit 3):

```bash
sudo MSI_EC_ADDR=2e MSI_EC_BIT=3 ./apply-sleep-fix.sh --force-unsupported
```

By default the script refuses to run on a model other than MS-16Q4:
`--force-unsupported` is an explicit confirmation that you have verified the
EC register. The script checks the EC by default. If the check has already
been done and you only need to install/update the fix, add `--no-test`:

```bash
sudo MSI_EC_ADDR=2e MSI_EC_BIT=3 ./apply-sleep-fix.sh --no-test --force-unsupported
```

Or edit `/etc/msi-wifi-rfkill.conf` after installation:

```ini
MSI_EC_ADDR=2e
MSI_EC_BIT=3
```

> Writing to the EC is potentially dangerous. Back up the EC dump and do not
> modify unknown registers. By default the script checks the EC before
> installation; `--no-test` skips that check.

### Another Wi-Fi card

The EC workaround may still be needed if this is an MSI MS-16Q4 with a
different card, but the hook is designed for `iwlwifi`. For other drivers,
the PCI reset/module reload part must be adapted.

---

## Files and logs

| Path | Purpose |
| --- | --- |
| `/usr/lib/systemd/system-sleep/50-msi-wifi-rfkill` | post-resume hook |
| `/etc/msi-wifi-rfkill.conf` | EC address/bit |
| `/etc/modprobe.d/msi-ec.conf` | `options msi_ec debug=true` |
| `/etc/modules-load.d/msi-ec.conf` | autoload `msi_ec` |
| `/var/log/msi-wifi-rfkill.log` | hook log |
| `/var/log/msi-wifi-rfkill-install.log` | installer log |
| `/boot/loader/entries/*.bak.*` | boot entry backups |

---

## Links

- MSI EC RF-kill bug, GS65/P65: <https://github.com/MControlSuite/msi-ec/issues/804>
- `msi-ec` driver: <https://github.com/MControlSuite/msi-ec>
- Arch Wiki, power management: <https://wiki.archlinux.org/title/Power_management>
- Arch Wiki, suspend/resume: <https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate>

---

## License

MIT — see [LICENSE](LICENSE).
