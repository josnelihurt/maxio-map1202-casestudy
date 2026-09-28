# MAXIO MAP1202 × SteamOS — An Agentic Engineering Case Study

> **TL;DR:** A 2 TB SPCC (Silicon Power) NVMe SSD built on the MAXIO MAP1202 DRAM-less
> controller (firmware `SN26904`) reliably wedged its controller — `I/O opcode 0x2 timeout →
> reset controller → device disappears until a cold power cycle — during every SteamOS
> installation attempt. After a systematic, evidence-driven elimination of eight hypotheses,
> the root causes were isolated to **two firmware trigger patterns**: (1) `mke2fs` formatting
> small partitions with auto-selected **1 KiB blocks**, and (2) **runtime partition-table
> rescans** after a table write. Forcing `-b 4096`, never rewriting the partition table at
> runtime, and skipping the crypto-sanitize step produced a **clean, zero-NVMe-error
> installation** (`rc=0`). The entire operation — research, diagnosis, testing, installation,
> and even the physical power cycling — was executed as an **autonomous agentic workflow run
> by ZCode (LLM: GLM-5.3)**, with a human in the loop only for physical actions.

---

## 1. Motivation

A SteamOS (Valve recovery image 3.8.14) installation on a generic x86 machine kept dying at
the same point — the first `mkfs.ext4` — with the NVMe controller timing out and vanishing
until mains power was removed. Manual attempts (copy-pasting commands via SSH) had failed
repeatedly. The disk had a history: the same SSD had been "stabilized" months earlier on a
Rock 5B (RK3588) with kernel-parameter workarounds related to power management.

The goals of this case study:

1. **Diagnose** whether the drive was dying or misbehaving, with reproducible evidence.
2. **Install SteamOS** on it anyway, if the failure could be engineered around.
3. **Document everything** — every hypothesis, every test, every mistake — as a reusable
   engineering record.
4. Demonstrate a **repeatable agentic pattern**: how an LLM-driven agent (ZCode + GLM-5.3)
   can run a multi-hour, hardware-level debugging campaign autonomously, including control
   of physical power.

## 2. The Hardware

| Component | Detail |
|---|---|
| SSD | SPCC (Silicon Power) M.2 NVMe, 2 TB, model string `SPCC M.2 PCIe SSD`, serial `SN-[redacted]` |
| Controller | MAXIO (Hangzhou) **MAP1202** — DRAM-less, HMB, PCIe Gen3 ×4, PCI ID `1e4b:1202` |
| Firmware | `SN26904`, NVMe 1.4 |
| Host | Generic x86 desktop (AMD platform, `amd_iommu=off` from the recovery image cmdline) |
| Boot medium | Valve SteamOS 3.8.14 recovery USB (`steamdeck-oobe-repair-20260707.10-3.8.14`), kernel `6.16.12-valve24.4-1-neptune-616` |
| SMART at start | 0 media errors, 0 critical warnings, 1 % endurance used, 2 515 power-on hours, 142 unsafe shutdowns → **the drive was NOT dying** |

Full hardware background and community evidence: [docs/01-hardware.md](docs/01-hardware.md).

## 3. Result

- ✅ **SteamOS installed successfully** — installer exited `rc=0`, `SteamOS reinstall complete.`,
  **zero NVMe errors** in the kernel log for the entire final run.
- ✅ **Mitigations persisted** into the installed system (both A/B partsets): kernel params in
  `grub.cfg`, anti-TRIM udev rule, suspend masked. Verified on the physical EFI partitions.
- ✅ **First boot from NVMe succeeded** after the user removed the recovery USB.
- ⚠️ **Long-term caveat:** this is a workaround stack, not a firmware fix. The known-good
  remedy for the underlying controller bugs is a **Silicon Power firmware update** (their
  Windows SSD updater, published for this line around Aug 2025), or a different drive.
  See [docs/04-root-cause.md](docs/04-root-cause.md#remaining-unknowns).

## 4. The Root Cause (short version)

Two independent controller-trigger patterns, both confirmed experimentally:

| # | Trigger | Evidence | Workaround |
|---|---|---|---|
| 1 | **`mke2fs` on a small partition** (≤256 MiB ⇒ auto-selects **1 KiB blocks**) | 5/5 wedges with 1 KiB-block mkfs; 0 wedges with 4 KiB-block mkfs (raw-disk 2 TB format and `-b 4096` on the same partition) | Force `-b 4096` on every ext4 format |
| 2 | **Runtime partition-table rescan** after writing a new GPT (`BLKRRPART` kernel path *and* `libfdisk`/`partx` reads) | Wedged with udev frozen, with `blockdev --rereadpt`, and inside `partx -a`; the *boot-time* scan of the very same table is always clean | Never rewrite the table at runtime — keep the on-disk GPT, use the installer's `system` target |
| 3 | **NVMe crypto-sanitize** (`nvme sanitize -a 2`, run by Valve's `all` target) | One confirmed wedge-to-death immediately after sanitize (plus suspicious 5-second "completion" on a 2 TB drive) | Skip sanitize (`sanitize_all` no-op in the patched installer) |

Everything else was **eliminated with evidence** — the full matrix is in
[docs/03-diagnosis-methodology.md](docs/03-diagnosis-methodology.md):

| Hypothesis | Test | Verdict |
|---|---|---|
| Failing media | SMART + full 2 TB surface read @ 3.5 GB/s | ❌ Rejected |
| TRIM/DSM (the original "Discarding device blocks" hang) | `discard_max_bytes=0` + `-E nodiscard` | ❌ Not sufficient (still crashed) |
| NVMe sanitize poisoning | Skip `sanitize_all` | ❌ Not sufficient (still crashed) |
| APST (autonomous power-state transitions) | `nvme_core.default_ps_max_latency_us=0` + runtime `pm_qos=0` | ❌ Not sufficient |
| HMB (host memory buffer) | `nvme.max_host_mem_size_mb=0` via GRUB | ❌ Not sufficient |
| Concurrent mixed I/O (udev/blkid readers vs. mkfs writers) | 60 s randomized 4 KiB readers + sequential writers, udev queue frozen | ❌ Rejected |
| End-of-disk instability (GPT backup area) | Sector-exact reads/writes at the last LBAs | ❌ Rejected |
| **1 KiB-block formatting** / **runtime table rescan** | see above | ✅ **Confirmed** |

## 5. The Agentic Angle — this was run by an AI agent

The whole campaign was orchestrated by **ZCode**, an interactive coding agent powered by the
**GLM-5.3** large language model. Not one command on the target machine was typed by a human
during the session. The agent:

- Ran **plan-mode research** with three parallel read-only subagents (local artifacts, SSH
  inspection of the target, web research on the controller).
- Designed a **decision-tree systemd service** that ran on the target at every boot, so each
  cold power cycle automatically executed the next experiment and logged its verdict.
- Used a **Tasmota smart relay (Sonoff S31)** — with the BIOS set to auto-power-on — to close
  the physical loop and power-cycle the wedged controller autonomously.
- Treated the relay's **watt meter as ground truth** for machine state ("SSH down" ≠ "off").
- Operated under an explicit **power protocol** (P0–P4, in [AGENTS.md](AGENTS.md)) after a
  process failure (see [docs/09-postmortem.md](docs/09-postmortem.md)).

How the loop worked and how to replicate it on another instance:
**[docs/07-agentic-workflow.md](docs/07-agentic-workflow.md)** and
**[docs/08-replication-guide.md](docs/08-replication-guide.md)**.

## 6. Document Index

| Doc | Contents |
|---|---|
| [docs/01-hardware.md](docs/01-hardware.md) | The SSD, controller, firmware, kernel quirks, community reports |
| [docs/02-timeline.md](docs/02-timeline.md) | Full chronological bitácora — every timestamp, dmesg line, power cycle, watts reading |
| [docs/03-diagnosis-methodology.md](docs/03-diagnosis-methodology.md) | Hypothesis → test → evidence elimination matrix |
| [docs/04-root-cause.md](docs/04-root-cause.md) | The two confirmed triggers, mechanism analysis, honest unknowns |
| [docs/05-mitigations.md](docs/05-mitigations.md) | Every mitigation, kernel-source semantics, what was actually necessary vs. defensive |
| [docs/06-power-automation.md](docs/06-power-automation.md) | Tasmota relay automation, watts-as-truth, the P0–P4 protocol, the ext4-sync incident |
| [docs/07-agentic-workflow.md](docs/07-agentic-workflow.md) | The orchestration as executed: stack, subagent topology, turn-by-turn narrative |
| [docs/08-replication-guide.md](docs/08-replication-guide.md) | Step-by-step guide to reproduce this agentic pattern elsewhere |
| [docs/09-postmortem.md](docs/09-postmortem.md) | Mistakes, near-misses, and lessons (including the agent's own) |

## 7. Scripts

| File | What it is |
|---|---|
| [scripts/repair_device_zfix.sh](scripts/repair_device_zfix.sh) | Valve's `repair_device.sh`, patched: skip sanitize, `-K -E nodiscard -b 4096` on ext4, no kernel partition rescan (`sfdisk --no-reread` + incremental `partx`), udev queue management, auto-reboot suppressed, `DOPARTVERIFY` env-overridable |
| [scripts/precheck-v5.sh](scripts/precheck-v5.sh) | The final boot-time decision tree: mitigations → isolated `-b 4096` mkfs test → format all partitions → launch installer in `system` mode |
| [scripts/persist-grub.sh](scripts/persist-grub.sh) | Runs inside `steamos-chroot`: appends NVMe kernel params to `/etc/default/grub`, `update-grub` |
| [scripts/persist-udev-mask.sh](scripts/persist-udev-mask.sh) | Runs inside `steamos-chroot`: anti-TRIM udev rule + masks suspend targets |
| [scripts/zfix-install.service](scripts/zfix-install.service) | systemd unit that ran the decision tree at every boot of the recovery USB |
| [scripts/valve-repair-device.sh.orig](scripts/valve-repair-device.sh.orig) | Pristine Valve original (diff target) |
| [archive/precheck-v3.sh](archive/precheck-v3.sh) | Historical decision-tree version (concurrent-I/O, end-of-disk, udev-frozen partition tests) — kept for the record |

## 8. If you hit this same wall (checklist)

1. **Confirm the drive is healthy first**: `nvme smart-log /dev/nvme0` (media_errors = 0?) and a
   full-surface read (`dd if=/dev/nvme0n1 of=/dev/null bs=64M`). A clean pass ≈ the media is fine.
2. **Disable the classic power-management suspects** (they are cheap and sometimes involved):
   `nvme_core.default_ps_max_latency_us=0 nvme.max_host_mem_size_mb=0` on the kernel cmdline,
   `echo 0 > /sys/block/nvme0n1/queue/discard_max_bytes`.
3. **Never run the installer's `all` target** on this controller — its crypto-sanitize is a
   confirmed killer. Use the patched script in `scripts/`.
4. **Pre-create the partition table once** and then only ever run install flows that do not
   rewrite it at runtime (the `system` target with `DOPARTVERIFY=0`, after manual formatting).
5. **Format every ext4 filesystem with `-b 4096`** (and `-E nodiscard`).
6. **Persist the mitigations** into the installed system (GRUB, udev rule, suspend mask) — see
   `scripts/persist-*.sh`.
7. **Update the SSD firmware** with the vendor tool at the earliest opportunity; file the
   behavior with the vendor if you can reproduce it.

## 9. Environment / Provenance

- Session date: 2026-09-27 (all timestamps in the docs are local PDT of that day).
- Orchestrator: ZCode agent harness, model GLM-5.3 (`zai-individual-coding-plan`).
- Target access: `ssh deck@192.168.10.X` (SteamOS recovery default user, passwordless sudo),
  from the operator's workstation.
- Power control: Sonoff S31 flash-ed with Tasmota 14.4.1 at `http://192.168.9.X/`.
- All internal identifiers (LAN IPs, hostnames, MQTT user, drive serial, MACs) are sanitized
  in this repository.

---

*This repository is a post-hoc, sanitized engineering record reconstructed from the full
session context of the agentic run. Scripts are verbatim final versions (byte-identical to
what executed on the target, md5-verified at upload time).*
