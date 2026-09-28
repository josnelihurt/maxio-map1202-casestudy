# Scripts

Verbatim final versions of everything that ran on the target (byte-identical to what
executed; md5-verified at upload time). They are specific to this campaign's environment —
read the headers and [docs/04-root-cause.md](../docs/04-root-cause.md) before adapting.

| File | Role |
|---|---|
| `repair_device_zfix.sh` | Valve's SteamOS recovery `repair_device.sh` (3.8.14, build 20260707.10), patched for the MAP1202: `sanitize_all` skipped (warns instead), `fmt_ext4` + home mkfs get `-K -E nodiscard -b 4096`, `sfdisk --no-tell-kernel --no-reread` + incremental `partx -d/-a` (never a kernel table rescan), udev exec-queue restarted after formatting, auto poweroff/reboot suppressed, `DOPARTVERIFY` env-overridable. Diff against the pristine original: `valve-repair-device.sh.orig`. |
| `precheck-v5.sh` | The boot-time decision tree that produced the successful install: waits for the disk → verifies mitigations/cmdline → **TEST E** (isolated `mkfs -b 4096` on p6 + mount/RW probe — the discriminator that proved the block-size root cause) → formats all partitions (4 KiB blocks, udev frozen) → blkid verification → runs the installer in `system` mode (`DOPARTVERIFY=0 NOPROMPT=1`). Installed as `zfix-install.service`. |
| `persist-grub.sh` | Runs **inside** `steamos-chroot --partset A|B`: appends `nvme_core.default_ps_max_latency_us=0 nvme.max_host_mem_size_mb=0 pcie_aspm=off` to `GRUB_CMDLINE_LINUX_DEFAULT` (idempotent) and runs `update-grub`. |
| `persist-udev-mask.sh` | Runs **inside** the chroot: writes `99-nvme-nodiscard.rules` (zeroes `discard_max_bytes` on every boot — protects the installed system's fstrim) and masks `sleep/suspend/hibernate/hybrid-sleep` targets. |
| `zfix-install.service` | systemd unit that ran the decision tree at every boot of the recovery USB (`multi-user.target`, oneshot, RemainAfterExit). Disabled after success. |
| `valve-repair-device.sh.orig` | Pristine original for diffing. |

## Patch delta (original → zfix)

```diff
- DOPARTVERIFY=1
+ DOPARTVERIFY=${DOPARTVERIFY:-1}
- fmt_ext4()  { … cmd sudo mkfs.ext4 -F -L "$1" "$2"; }
+ fmt_ext4()  { … cmd sudo mkfs.ext4 -F -K -E nodiscard -b 4096 -L "$1" "$2"; }
-     cmd systemctl poweroff
-     cmd systemctl reboot
+     ewarn "zfix: systemctl poweroff suppressed (Phase 4 pending)"
+     ewarn "zfix: systemctl reboot suppressed (Phase 4 pending)"
-     echo "$PARTITION_TABLE" | sfdisk "$DISK"
+     echo "$PARTITION_TABLE" | sfdisk --no-tell-kernel --no-reread "$DISK"
+     # zfix: BLKRRPART (full kernel rescan) hangs the MAP1202; use incremental partx
+     partx -d "$DISK" 2>/dev/null
+     partx -a --nr 1-8 "$DISK" 2>/dev/null || partx -a "$DISK"
+     sleep 3
-     cmd sudo mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart $FS_HOME)"
+     cmd sudo mkfs.ext4 -F -K -E nodiscard -b 4096 -O casefold -T huge -L home "$(diskpart $FS_HOME)"
+   udevadm control --start-exec-queue 2>/dev/null || true     # after home format
-   sanitize_all
+   ewarn "zfix: sanitize_all skipped - MAP1202 SN26904 controller wedges after sanitize (needs cold power cycle)"
```
