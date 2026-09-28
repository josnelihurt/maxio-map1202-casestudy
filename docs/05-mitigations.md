# 05 — Mitigations & Kernel Knobs (semantics, sources, what was actually needed)

Every knob used in this case study, with its exact semantics (verified against kernel
source / official docs during the research phase), how it was applied, and — importantly —
whether the evidence ultimately showed it was *necessary* or merely *defensive*.

## 1. NVMe APST — `nvme_core.default_ps_max_latency_us`

- **Semantics** (from `drivers/nvme/host/core.c`): module parameter, default **100 000 µs**.
  APST is the drive-internal autonomous power-state table (this drive: idle 100 ms → PS3,
  2 s → PS4 with 45 ms exit latency). Setting the parameter to **0 disables APST entirely**
  ("Users can set ps_max_latency_us to zero to turn off APST" — kernel comment).
- **Boot-time:** appended to the recovery USB's GRUB kernel lines (and later to the
  installed system's `GRUB_CMDLINE_LINUX_DEFAULT`).
- **Runtime (no reboot):** `echo 0 > /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us`
  — the kernel-blessed per-device path; re-runs `nvme_configure_apst()` and **survives
  controller resets** (the value lives in the controller's PM-QoS state, not the device).
- **Trap:** `nvme set-feature -f 0x0c -v 0` does *not* stick — the kernel re-programs its own
  APST table on every controller initialization (documented in nvme-cli issue #878).
- **Verdict:** ❌ *not the fix here* (wedges continued with APST verifiably off), kept as
  defensive hardening — it is the classic fix for this controller family on RK3588 boards
  and costs nothing measurable on a desktop.

## 2. HMB — `nvme.max_host_mem_size_mb=0`

- **Semantics** (from `drivers/nvme/host/pci.c`): module parameter, default 128 MiB;
  controls the Host Memory Buffer the driver offers to DRAM-less controllers. `0` prevents
  HMB from being enabled at controller initialization. **Read-only at runtime** (`0444`) —
  boot-time only.
- **Applied** by editing the recovery USB's GRUB config (see
  [06-power-automation.md](06-power-automation.md) for the mechanics). Verified in-boot by
  the *absence* of the "allocated 16 MiB host memory buffer" dmesg line.
- **Verdict:** ❌ *not the fix here* (heavy-I/O prechecks passed and the installer still
  wedged with HMB off), kept as defensive hardening on a DRAM-less controller with a
  documented history of flakiness. Cost: some performance on mapping-table-heavy workloads
  (imperceptible in this campaign: 2.6 GB/s sustained writes with HMB off).

## 3. TRIM/DSM — `discard_max_bytes=0` + `-E nodiscard`

- **Semantics:** `/sys/block/nvme0n1/queue/discard_max_bytes` is what the block layer uses
  to advertise discard support. `0` ⇒ discards are rejected (`EOPNOTSUPP`) ⇒ `mkfs.ext4`'s
  implicit "discard device blocks" phase and `fstrim` become no-ops. `mke2fs` man page:
  `-E discard` is the **default**; `-E nodiscard` (plus legacy `-K`) disables it.
- **Runtime:** sysfs write (whole-disk queue, not partitions); **resets on reboot/rescan** —
  re-applied at every boot by the decision-tree service, and **persisted into the installed
  system as a udev rule**:
  ```
  ACTION=="add|change", KERNEL=="nvme*n1", ATTR{queue/discard_max_bytes}="0"
  ```
- **Verdict:** ✅ **necessary** — the original boot −3 wedge was a 256 MiB DSM (opcode `0x9`)
  on the var partition; and SteamOS runs periodic fstrim, which without this rule would
  eventually re-trigger it on the installed system.

## 4. Sub-4 KiB block formatting — `-b 4096`

- **Semantics:** `mke2fs` picks the ext4 block size from device size; ≤256 MiB ⇒ 1 KiB
  blocks. Forcing `-b 4096` on small partitions keeps every filesystem the OS uses in the
  geometry that empirically passes on this controller.
- **Applied** in the decision tree (manual formatting) and in the patched installer
  (`fmt_ext4` and the home mkfs both carry `-b 4096`).
- **Verdict:** ✅ **the fix** for trigger T1. See [04-root-cause.md](04-root-cause.md) §2.

## 5. No runtime partition-table operations

- **Semantics:** the trigger is *re-reading* a modified table at runtime (`BLKRRPART`,
  libfdisk via `partx`). Boot-time scans are safe.
- **Applied** by using Valve's `system` target (`writePartitionTable=0`) over a
  pre-existing, correct GPT; the patched `all` path additionally demonstrates the safe
  primitives (`sfdisk --no-tell-kernel --no-reread` + `partx -d/-a`), though the final
  install never needed them.
- **Verdict:** ✅ **necessary** for trigger T2 (any flow that repartitions at runtime dies).

## 6. No crypto-sanitize

- Valve's `all` target runs `nvme sanitize -a 2` before reinstalling. On this controller it
  "completed" 2 TB in ~5 s and the controller wedged on the first subsequent I/O.
- **Applied:** `sanitize_all` call replaced with a warning line in the patched installer.
- **Verdict:** ✅ **necessary** (T3). Note the data-hygiene trade-off: skipping sanitize
  means stale flash is not crypto-erased — acceptable when the previous contents are
  disposable; otherwise wipe the drive on another host first.

## 7. Suspend masking (Rock 5B heritage)

- `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target` inside
  each installed partset. This drive's history on the Rock 5B included resume-time
  disappearances; masking suspend is the durable half of that machine's fix (it survives
  kernel updates, unlike a hand-edited generated boot file).
- **Verdict:** defensive; reversible (`systemctl unmask …`) if suspend is wanted and the
  firmware update lands.

## 8. `pcie_aspm=off` (+ `pcie_port_pm=off`)

- ASPM is link-level PCIe power management (distinct from APST). Included for parity with
  the Rock 5B recipe. On this host the NVMe link advertised **ASPM not supported**, so it is
  a no-op; kept because it costs nothing on a desktop and closes the class on hosts where
  the slot does support it.

## 9. GRUB persistence mechanics (SteamOS-specific)

- The installed system uses A/B partsets: `efi-A/B` hold each slot's `grub.cfg`; `/etc` is
  writable only through the **overlay** stack (`steamos-chroot --partset X` without
  `--no-overlay`; `--no-overlay` mounts the read-only rootfs and even `/etc` edits fail —
  learned the hard way).
- Durable change: edit `/etc/default/grub` (`GRUB_CMDLINE_LINUX_DEFAULT`) inside each
  partset, then `update-grub` — the regenerated config lands on that slot's EFI partition.
  Verified post-hoc by grepping the physical `grub.cfg` on p2 and p3.
- **Lesson from the Rock 5B:** never hand-edit generated boot files (`extlinux.conf` there)
  — a kernel update regenerated it and silently erased the fix. `/etc/default/grub` is the
  durable location; re-verify `/proc/cmdline` after every OTA.

## 10. Necessity summary

| Knob | Necessity on this controller |
|---|---|
| `-b 4096` on all ext4 mkfs | **Required** (T1) |
| No runtime table rescan / no repartition | **Required** (T2) |
| Skip sanitize | **Required** (T3) |
| `discard_max_bytes=0` (+ udev rule persistence) | **Required** (T0: the original DSM hang; also protects installed system's fstrim) |
| APST off (`default_ps_max_latency_us=0` / pm_qos) | Defensive — class-recommended |
| HMB off (`max_host_mem_size_mb=0`) | Defensive — class-recommended |
| Suspend masked | Defensive — history-recommended |
| `pcie_aspm=off` | No-op here, class-parity |
