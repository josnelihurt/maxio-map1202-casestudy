# 01 — The Hardware

## 1. The Drive

| Field | Value |
|---|---|
| Marketing brand | SPCC = **S**ilicon **P**ower **C**omputer **C**ommunications |
| Model string (as reported) | `SPCC M.2 PCIe SSD` |
| Capacity | 2 TB (2 048 408 248 320 bytes, 4 000 797 360 × 512 B sectors) |
| Firmware | `SN26904` |
| NVMe revision | 1.4 |
| Serial | `SN-[redacted]` |

## 2. The Controller

- **MAXIO (Hangzhou) MAP1202** — a budget **DRAM-less** NVMe controller.
  - PCI ID `1e4b:1202`, PCIe Gen3 ×4.
  - Uses **HMB** (Host Memory Buffer): the Linux driver allocated **16 MiB** of host RAM for
    its mapping tables (`nvme nvme0: allocated 16 MiB host memory buffer (4 segments)`).
  - DRAM-less + QLC-class NAND: sustained write behavior after SLC-cache exhaustion is
    known to be modest (~84 MB/s measured by third-party reviews of a sibling product).
- Power states: `npss=4`, APST-capable (`apsta=1`). The firmware's APST table (as read via
  `nvme get-feature -f 0x0c`) was: idle 100 ms → PS3, idle 2 000 ms → PS4, with PS4 at
  ~0.726 W non-operational and **45 ms exit latency**.

## 3. Measured performance on the case-study host (healthy states)

| Pattern | Result |
|---|---|
| Full-surface sequential read (2 TB, `dd bs=64M`) | **3.5 GB/s**, 580.7 s end-to-end, zero errors |
| Sustained direct writes (8 GiB, `oflag=direct conv=fsync`) | **2.6 GB/s**, zero errors |
| Random-offset direct reads (~1 MiB per op, 1 worker) | ~212 MB/s, zero errors |
| Random-offset direct reads (4 workers) | ~828 MB/s aggregate, zero errors |
| Idle 180 s + post-idle reads | No wake penalty, zero errors |

## 4. Kernel support status (mainline Linux)

The MAP1202 appears in `drivers/nvme/host/pci.c` **only** with a namespace-identifier quirk:

```c
{ PCI_DEVICE(0x1e4B, 0x1202),   /* MAXIO MAP1202 */
    .driver_data = NVME_QUIRK_BOGUS_NID, },
```

(Visible in the boot log as `nvme nvme0: Ignoring bogus Namespace Identifiers`.)

**No APST / power-state / timeout quirk exists upstream for this controller.** Everything
power-management-related must be worked around manually via module parameters (see
[05-mitigations.md](05-mitigations.md)). There is also a runtime quirk override
(`nvme.quirks=VID:DID:quirk_names`) if more is ever needed.

## 5. Community evidence collected during diagnosis (web research, 2026-09-27)

The research phase surfaced a consistent pattern for this controller family — firmware /
power-state instability with clean SMART, rather than media failure:

- **RK3588 / Rock 5B SBC threads (Armbian, Radxa forums):** NVMe drives on MAXIO controllers
  dropping off the bus; community fix = `nvme_core.default_ps_max_latency_us=0` in the boot
  args. (The case-study drive itself had run for months as the OS disk of a Rock 5B with
  `nvme_core.default_ps_max_latency_us=0 pcie_aspm=off` plus masked suspend targets —
  recovered verbatim from that machine's `/boot/extlinux/extlinux.conf.bak-*`.)
- **FreeBSD bug tracker:** "NVMe flush ack timeout on boot" with a MAP1202 — i.e. the
  controller mis-times specific command types on other operating systems too, pointing at
  firmware rather than a Linux driver bug.
- **A Linux Mint forum thread (Jan 2026)** from a user with the **same firmware `SN26904`**:
  "NVMe drive stops responding until cold boot"; the thread notes Silicon Power shipped an
  SSD firmware updater for the line around **Aug 2025** (Windows-only tool).
- **Habr / Arch / Framework / Proxmox / Level1Techs reports** of MAP1202-family drives
  producing `I/O ... timeout, reset controller` and disappearing until cold boot — several
  resolved (fully or partly) by `default_ps_max_latency_us=0`, `pcie_aspm=off`, or HMB
  adjustments.
- **Gough Lui's long-term review** of a MAP1202-based drive (Lexar NM610 PRO): documented
  modest sustained writes and a data-retention caution — background on the controller class,
  not evidence of this unit failing.

None of these reports described the two triggers this case study eventually confirmed
(sub-4 KiB-block formatting and runtime table rescans); they supported the *class* of
problem (firmware instability) and the *health* conclusion (SMART-clean, media fine).

## 6. SMART baseline (captured before any testing)

```
critical_warning      : 0
media_errors          : 0
num_err_log_entries   : 0
percentage_used       : 1%
power_on_hours        : 2515
unsafe_shutdowns      : 142
data_units_read       : 3.61 TB
data_units_written    : 3.36 TB
```

Interpretation per the standard rubric (see [03-diagnosis-methodology.md](03-diagnosis-methodology.md)):
zero media errors + 1 % endurance + clean full-surface read ⇒ **media failure ruled out**;
142 unsafe shutdowns consistent with a history of wedges/cold cuts.

## 7. The host

- Generic x86 desktop, AMD platform (recovery image boots with `amd_iommu=off`; amdgpu
  present). NVMe at PCI `0000:04:00.0`, root port `0000:00:02.1`.
- PCIe **ASPM not supported** on the slot's link capabilities (`LnkCap: ASPM not supported`) —
  ASPM was therefore a non-factor on this machine (kept `pcie_aspm=off` for parity with the
  Rock 5B recipe, but it is a no-op here).
- SteamOS recovery environment: kernel `6.16.12-valve24.4-1-neptune-616`, full KDE desktop,
  `KillUserProcesses=True` (important operationally — see
  [08-replication-guide.md](08-replication-guide.md)).
