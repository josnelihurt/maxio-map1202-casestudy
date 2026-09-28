# 04 — Root Cause

## 1. Summary

The MAXIO MAP1202 (firmware `SN26904`) on this host has **at least three independent
firmware-level trigger patterns**, each of which wedges the controller such that commands
time out (`opcode 0x2 Read`, 30 s), the driver resets the controller, the reset fails
(`Device not ready; aborting reset, CSTS=0x1` → `Disabling device after reset failure: -25`),
and the device does not return until **mains power is removed** (a warm reboot, or even a
PCI FLR + rescan, is insufficient — `not ready after 65535ms; giving up`).

| Trigger | First observed | Confirmed by |
|---|---|---|
| **T1 — mke2fs formatting a small partition (auto 1 KiB blocks)** | every install attempt | control pair + discriminator (below) |
| **T2 — runtime partition-table rescan after a table write** (kernel `BLKRRPART` or `libfdisk`/`partx` reads) | every install attempt (they all repartition) | isolated with udev frozen; both rescan paths wedge; boot-time scan never does |
| **T3 — NVMe crypto-sanitize** (`nvme sanitize -a 2` in Valve's `all` target) | 16:13 run | died on first I/O after sanitize; sanitize "completed" 2 TB in ~5 s (implausible) |

## 2. T1 in detail — the block-size trigger

`mke2fs` auto-selects the ext4 block size from device size. Valve's layout formats **var-A /
var-B (256 MiB)** — small enough that mke2fs picks **1 KiB blocks** (`Creating filesystem
with 262144 1k blocks`). The home stub (100 MiB) is likewise sub-4 KiB territory.

Evidence table (all with APST off, HMB off, discard off, udev frozen where applicable):

| Filesystem operation | Block size | Outcome |
|---|---|---|
| `mkfs.ext4` raw 2 TB disk (15 262 groups, journal, superblocks across the disk) | 4 KiB (auto) | ✅ completed, zero errors |
| `mkfs.ext4 -b 4096` on `/dev/nvme0n1p6` + mount + RW + sync | 4 KiB (forced) | ✅ **3 seconds**, zero errors |
| `mkfs.ext4` on `/dev/nvme0n1p6` (5 independent runs, varying environments) | 1 KiB (auto) | ❌ **5/5 wedged** — 4 KiB READ timeout ~10–30 s in, controller dead |

The wedge always manifested as a **READ** timing out during/just after metadata writing —
consistent with the controller failing on the I/O *pattern* a 1 KiB-block filesystem
produces (dense small scattered metadata writes interleaved with reads), not on any single
operation.

**Mechanism honesty:** the precise firmware defect was not characterized further. Buffered
I/O *should* coalesce to 4 KiB pages at the block layer, so the naive "sub-4 KiB commands"
story is likely incomplete — what is empirically decisive is that the *filesystem geometry*
(1 KiB vs. 4 KiB blocks) fully separates pass from wedge on this controller, holding
everything else constant. See §4 for the practical consequence and the runtime-stability
caveat.

## 3. T2 in detail — the partition-rescan trigger

- Writing a new GPT is **safe** (sfdisk completes; its writes, including the backup GPT at
  the last LBAs, land without error — verified directly in TEST B-style probes).
- **Re-reading** the table at runtime afterwards is fatal:
  - `blockdev --rereadpt` (kernel `BLKRRPART` path) — wedged with udev frozen, HMB off.
  - `partx -a` (libfdisk reads the on-disk table) — wedged identically.
- The kernel's **boot-time** scan of the *same* on-disk table is always clean (observed on
  every single boot of the session, dozens of enumerations).

**Engineering consequence:** never rewrite the partition table at runtime on this
controller. The GPT is static — write it once (any tool, any time), then only ever run
flows that *consume* the existing table. Valve's installer supports this via its `system`
target (no repartition) with `DOPARTVERIFY=0` (skip its pre-checks that expect formatted
partitions) after formatting partitions manually.

## 4. The working installation recipe (what finally ran green)

1. Boot the recovery USB **once** with the mitigations on the kernel cmdline
   (`nvme.max_host_mem_size_mb=0 nvme_core.default_ps_max_latency_us=0`) — patched into the
   USB's GRUB so no console interaction is needed.
2. Let the (already correct) GPT be scanned at boot. **Never touch the table again.**
3. Apply runtime knobs: `discard_max_bytes=0`, `pm_qos_latency_tolerance_us=0`, udev queue
   frozen during formatting.
4. Format every ext4 partition with **`-F -K -E nodiscard -b 4096`** (var-A/B, home stub),
   vfat for ESP/EFI-A/B.
5. Run the patched installer in **`system`** mode (no sanitize, no repartition):
   dd-images rootfs A/B, bootstraps GRUB per partset, installs the bootloader.
6. Persist mitigations into the installed system (GRUB cmdline, anti-TRIM udev rule,
   suspend targets masked) — see [05-mitigations.md](05-mitigations.md).
7. Graceful shutdown; remove USB; boot from NVMe.

Result: installer `rc=0`, `SteamOS reinstall complete.`, **zero NVMe errors** kernel-wide;
first boot from NVMe successful.

## 5. Remaining unknowns (documented honestly)

- **Exact firmware mechanism** of T1/T2 — not characterized below the filesystem-geometry
  level; would need vendor internals or a capture-grade reproduction.
- **Runtime stability of the installed OS:** all *proven-safe* patterns (4 KiB-block
  filesystems, no table rescans, no sanitize) are exactly what a running SteamOS does —
  but the controller has surprised this campaign three times. The udev rule additionally
  blocks fstrim/discard system-wide; suspend is masked (Rock 5B heritage). Long-term
  behavior is an open observation window.
- **Recovery/factory-reset paths:** anything that reformats var/home with default options
  (1 KiB blocks) or re-runs sanitize will wedge again — keep the patched script.
- **OTA updates:** SteamOS updates build the *other* slot; our per-partset persistence
  covers A **and** B, but a future update could rewrite `/etc/default/grub` — re-check
  `/proc/cmdline` after the first OTA.
- **Host dependence:** the drive ran for months on a Rock 5B (with the APST/suspend
  workarounds). Which aspects are host-specific (PCIe implementation, IOMMU, link
  training) was not investigated.

## 6. The actual fix (recommendation)

This stack is a **workaround**, and the right next step is the vendor's firmware update:
Silicon Power ships a Windows-only "SSD Firmware Update Software" for this line (an updater
was noted in the community around **Aug 2025** for `SN26904`-class firmware, matching this
exact "stops responding until cold boot" symptom class). After a firmware flash, re-run the
health battery (`scripts/precheck-v5.sh` logic) before trusting the drive with an OS.
