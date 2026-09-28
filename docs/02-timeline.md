# 02 — Timeline (full bitácora)

All times are local (PDT), 2026-09-27, taken from kernel logs, systemd journals, the
Tasmota relay meter, and the orchestrating agent's session. Internal IPs/hostnames are
sanitized (`192.168.10.X` = target PC, `192.168.9.X` = relay).

## Background (before this session)

- The same SSD spent months as the OS disk of a **Rock 5B** (RK3588, Debian 12, vendor
  kernel 6.1.84). It was stabilized there in phases (Dec 2025 – Mar 2026) with:
  - Kernel cmdline: `nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off`
    (applied Feb 2026 to `/boot/extlinux/extlinux.conf`; later wiped by a kernel update that
    regenerated the file — recovered from a `.bak`).
  - `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`
    (the "suspension fix" — still active on that machine).
- On the new x86 host, repeated manual SteamOS install attempts failed. Symptoms brought to
  this session: hang at `Discarding device blocks…` (mkfs TRIM), then — after the operator
  zeroed `discard_max_bytes` — READ timeouts during formatting, controller resets, and a
  device that disappears until a full power cycle.

## Pre-session boots on the target (from the persistent journal of the recovery USB)

- **Boot −3 (14:33–14:50)** — an `all` reimage attempt:
  - 14:39:04 `I/O tag 642 opcode 0x9 (Dataset Management) QID 6 timeout, aborting req_op:DISCARD size:268435456`
  - 14:39:34 same tag → `reset controller`; 14:42–14:46 abort/reset failures;
    14:46:00 `Disabling device after reset failure: -25` → device gone.
  - The discard targeted sector 21760000 + 256 MiB = exactly **p6 (var-A)**: `mkfs.ext4`'s
    implicit whole-partition discard.
- **Boot −2 (14:52–15:03)** — READ timeouts minutes after boot, machine near idle
  (discard already disabled by then): `opcode 0x2 QID 2 size:114688` and `QID 8 size:4096`
  timeouts → reset. (Warm reboot after boot −3's wedge; controller still poisoned.)
- **Boot −1 (15:04–15:10)** — same READ-timeout pattern during user diagnostics.
- **Boot 0 (15:10)** — clean boot after a full cold power cycle by the operator. This is the
  session's starting state: disk present, zero errors.

## Session

### Phase 0 — Research (plan mode, ~15:20–15:50)

Three parallel read-only research subagents:
1. **Local artifacts** — found the Valve recovery image download, the SSH conventions
   (`deck@192.168.10.X`, key auth, passwordless sudo), and that no prior commands were
   captured locally.
2. **SSH inspection** — environment, SMART, APST status (enabled, PS4 residency),
   `discard_max_bytes` back at 2 TB, the installer script analysis
   (`/home/deck/tools/repair_device.sh`, 484 lines, `all` = sanitize + repartition + format),
   partitions p1–p8 present but unformatted.
3. **Web research** — controller class evidence, kernel semantics of every knob
   (`default_ps_max_latency_us`, HMB, APST sysfs, discard_max_bytes), SteamOS install flow.

Plan approved. Access pattern fixed for the session: `ssh deck@192.168.10.X` + `sudo -n`.

### Phase 1 — Runtime stabilization (≈15:55)

```
/sys/block/nvme0n1/queue/discard_max_bytes        → 0
/sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us → 0   (APST off, reset-surviving)
```
Verified `get-feature 0x0c`: **APSTE: Disabled**. dmesg clean.

### Phase 2 — Read-side stability battery (~16:00–16:20) — ALL PASS

- Full-surface read: `2 048 408 248 320 bytes copied, 580.656 s, 3.5 GB/s`, zero errors.
- Random direct reads (1 worker, 120 s): 25 441 ops ≈ 212 MB/s.
- 4 concurrent workers (60 s): 49 700 ops ≈ 828 MB/s aggregate.
- Idle 180 s + post-idle burst: no wake penalty.
- SMART before/after: identical (0 / 0 / 0 / 1 %).
- **Operational discovery:** the recovery env sets `KillUserProcesses=True` — background
  processes launched from SSH sessions are SIGKILLed when the session closes. Workaround:
  launch long jobs as transient units (`systemd-run --unit=…`).

### Phase 3a — Official `all` install, first agent-driven attempt (16:13) — WEDGE

- Installer launched as `systemd-run` unit with `NOPROMPT=1`; a working copy with
  `-K -E nodiscard` on mkfs and auto-reboot suppressed.
- 16:13:06–16 `sanitize_all`: crypto sanitize 0→100 % in ~5 s ("done" in 10 s — implausibly
  fast for 2 TB).
- 16:13:16 sfdisk wrote the GPT (p1–p8).
- 16:13:17 `mkfs.ext4` p6 started (`nodiscard` confirmed active in the journal).
- 16:13:48 **two 4 KiB READ timeouts** (tag 450 QID 3, tag 960 QID 6) → 16:14:18
  `reset controller` → controller never returned; mkfs stuck in D-state.
- Agent stopped the unit per its FATAL rule; PCI remove/rescan attempted by the orchestrator:
  `pci 0000:04:00.0: not ready … after 65535ms; giving up` → **only a cold power cycle can
  revive it.**

### Phase 3b — No-sanitize retry (16:34, after user cold-cycled at 16:32:38) — WEDGE

- Installer copy with `sanitize_all` replaced by a warning. Boot-time service
  (`zfix-install.service`) applied mitigations + ran the installer automatically.
- Same death ~40 s in: `opcode 0x2 (Read) QID 7 timeout` during the first mkfs; FLR failed;
  device disabled. ⇒ **Not sanitize alone.**

### Escalation — HMB off via the recovery USB's own GRUB (16:40)

Edited `/boot/efi/EFI/steamos/grub.cfg` on the USB (3 kernel lines + backup
`grub.cfg.bak-hmb`): appended `nvme.max_host_mem_size_mb=0 nvme_core.default_ps_max_latency_us=0`.

### Phase 3c — HMB-off attempt (16:46, user cold-cycled 16:45:22) — WEDGE, but with gold data

Boot-time decision-tree service v2 verified cmdline params, then:
- 64 MB read @ 3.3 GB/s ✔
- **8 GiB direct writes + fsync @ 2.6 GB/s ✔**
- 2 GiB readback @ 3.3 GB/s ✔
- **`mkfs.ext4` on the RAW 2 TB disk (4 KiB blocks, 15 262 groups, journal, superblocks
  across the whole disk) ✔ COMPLETED**
- Installer started → sfdisk + mkfs p6 → `opcode 0x2 QID 8 timeout` → dead again.

⇒ Heavy serialized I/O is fine; the *installer's specific sequence* kills it. Remaining
suspects: concurrent udev/blkid reads, end-of-disk access, or the partition-table path.

### The relay enters (17:02)

User contributed a **Tasmota Sonoff S31** plug at `http://192.168.9.X/` feeding the machine,
and configured the BIOS to **auto-power-on when energy arrives**. Recon: firmware 14.4.1,
relay ON, metering available (`Status 8 → StatusSNS.ENERGY.Power`).

### Decision-tree v3 (17:45 boot) — isolates udev concurrency

- **TEST A** (60 s concurrent 4 KiB random readers + sequential writer): **PASS**
  (16 464 random reads, 63 write passes, zero errors) ⇒ concurrent mixed I/O rejected.
- **TEST B** (end-of-disk access): reported FATAL — but with **zero NVMe errors**. Root
  cause: the orchestrator's own seek arithmetic wrote ~500 KB past the device end
  (`dd` failed instantly with ENOSPC). Bug fixed to sector-exact math. (Postmortem:
  [09-postmortem.md](09-postmortem.md).)
- **TEST C** (sfdisk + `blockdev --rereadpt` + mkfs with **udev queue frozen**): WEDGE at the
  rescan step — 4 KiB READ timeout, reset, dead. ⇒ **Not udev. The kernel's BLKRRPART path
  itself.**

### v4 — `partx` instead of BLKRRPART (18:09–18:20)

- First run: `partx -a` failed EBUSY (kernel still held the previous table; needs
  `partx -d` first). **No wedge** during this run — important negative evidence.
- Second run (`partx -d` + `partx -a`): **WEDGE inside `partx -a`** (libfdisk's table
  reads). ⇒ Runtime table re-read via libfdisk is also fatal. Boot-time kernel scan of the
  very same table: always clean.

### v5 — Zero partition-table operations (18:25) — the decisive isolation

- Existing on-disk GPT (scanned at boot, known safe) + **isolated `mkfs.ext4` on p6 with
  nothing else, udev frozen, all mitigations on**: **WEDGE.**
- The only remaining variable vs. the passing raw-disk mkfs: **block size** (256 MiB
  partition ⇒ mke2fs auto-selects **1 KiB** blocks; 2 TB raw disk ⇒ 4 KiB blocks).

### v6 — `-b 4096` everywhere (18:33 cycle → 18:34 boot) — SUCCESS

Boot-time decision tree (final, [scripts/precheck-v5.sh](../scripts/precheck-v5.sh)):
1. Mitigations + sanity read ✔
2. **TEST E**: `mkfs.ext4 -F -K -E nodiscard -b 4096 -L var /dev/nvme0n1p6` → **PASS in 3 s**
   (+ mount/read-write/sync/umount probe).
3. All partitions formatted with 4 KiB blocks (`-b 4096`) + vfat for ESP/EFI ✔ (blkid verified)
4. Installer launched in **`system` mode** (no table rewrite; `DOPARTVERIFY=0`):
   dd-imaged rootfs A/B, `btrfstune`/`btrfs check`, GRUB bootstrap per partset,
   `steamcl-install`, `Creating Boot0000 SteamOS`.
5. **18:37:02 — `SteamOS reinstall complete.` rc=0. Zero NVMe errors for the whole boot.**

### Phase 4 — Persistence into the installed system (18:38–18:45)

Via `steamos-chroot --partset A|B` (first attempt with `--no-overlay` hit the read-only
rootfs; retried with the standard overlay stack):
- `/etc/default/grub` → `GRUB_CMDLINE_LINUX_DEFAULT="… nvme_core.default_ps_max_latency_us=0 nvme.max_host_mem_size_mb=0 pcie_aspm=off"` + `update-grub` (both partsets).
- `99-nvme-nodiscard.rules` udev rule (both partsets).
- `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target` (both).
- Verified the params inside the physical `grub.cfg` on **p2 (efi-A)** and **p3 (efi-B)**.
- Disabled the boot-time installer service on the USB; `sync`.

### Phase 5 — First boot (18:46)

- **P0 notification** (action/via/reason/watts) → graceful shutdown:
  `sudo -n systemctl poweroff` at 18:46:24; SSH dropped immediately; relay meter
  **53 W → 16 W** = off confirmed (never touched the relay to shut down).
- User physically removed the recovery USB.
- Brief relay OFF(10 s)→ON to generate the power-arrival event; BIOS auto-started the
  machine; first boot from NVMe confirmed by the user ("funcionó"). OOBE handoff to the
  human (installed SteamOS ships with SSH disabled).

## Power-cycle ledger (relay + cold cuts)

| # | Time (PDT) | Mechanism | Watts before → after | Outcome |
|---|---|---|---|---|
| 1 | 16:32:38 | user, physical | — | revived for 3b |
| 2 | 16:45:22 | user, physical | — | revived for 3c |
| 3 | 17:09:57 | relay (hard, pre-protocol) | 23 → 7 | machine did NOT auto-boot (BIOS not yet set) |
| 4 | 17:44:47 | relay (hard, pre-protocol) | — → 249 | booted (USB initially missing, redone) |
| 5 | 18:01:24 | relay (hard, pre-protocol) | — | booted, but **zeroed two unsynced scripts** (ext4 writeback) |
| 6 | 18:24:45 | relay (hard, pre-protocol) | — | booted for v5 test |
| 7 | 18:33:26 | relay (hard, pre-protocol) | — | booted for v6 SUCCESS |
| 8 | 18:46:24 | **graceful SSH poweroff** | 53 → 16 | clean shutdown for USB removal |

Cycles 3–7 predate the P0–P4 power protocol (see
[06-power-automation.md](06-power-automation.md) and
[09-postmortem.md](09-postmortem.md)); the protocol was written at the user's demand after
cycle 5's data loss and an explicit earlier order the agent failed to honor.
