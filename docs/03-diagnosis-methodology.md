# 03 — Diagnosis Methodology

## 1. Principles applied

1. **Health first.** Before any workaround engineering, establish whether the drive is
   dying. A dying drive changes the entire decision tree (replace vs. engineer around).
   Verdict here: *healthy media* (SMART clean + full-surface read at line rate).
2. **One wedge = one cold power cycle = one experiment budget.** Every controller wedge
   costs a power cycle before the next test. That constraint drove two design decisions:
   - **Decision trees instead of single commands:** each boot ran a *sequence* of gated
     tests via a systemd service, each step logging its verdict and refusing to continue on
     failure. A wedge mid-tree still yields the exact step that died.
   - **Escalate in bundles only when orthogonal:** early attempts changed one variable at a
     time; once the per-cycle cost was delegated to the relay (no human needed), bundles of
     *independent* mitigations (HMB + APST) were applied together, with per-knob runtime
     verification in the log.
3. **Evidence over theory.** Every accepted/rejected hypothesis has a test with a binary
   outcome recorded in a log file (`/tmp/zfix-install.log` + dmesg). No hypothesis was
   rejected by argument alone.
4. **FATAL rules for executors.** Every subagent and service carried an explicit stop rule:
   *if any NVMe timeout/reset/I/O error appears, stop immediately; do not attempt recovery,
   rescans, or reboots; report the exact dmesg lines.* This prevented well-meaning
   "recovery" actions from destroying evidence (and from masking which step failed).
5. **Ground truth is the watt meter, not SSH.** "SSH doesn't answer" is ambiguous (booting,
   hung, off). The relay's power reading is unambiguous: < 30 W = off, > 30 W = running.

## 2. The elimination matrix

| # | Hypothesis | Test design | Result | Verdict |
|---|---|---|---|---|
| H1 | Failing media / bad regions | `nvme smart-log` before/after every phase; full-surface sequential read of all 2 TB (`dd bs=64M`) with dmesg watch | SMART identical throughout (0 media errors, 0 err-log, 1 % used); 2 TB read @ 3.5 GB/s, 0 errors | **Rejected** — media healthy |
| H2 | TRIM / DSM (the original `Discarding device blocks` hang) | `echo 0 > /sys/block/nvme0n1/queue/discard_max_bytes` (block layer returns EOPNOTSUPP → mkfs/fstrim skip) + `-E nodiscard` on every mkfs | Subsequent failures were READ opcodes; discard provably inactive in failing runs | **Rejected as sufficient cause** (a real earlier trigger — boot −3 — but neutralized) |
| H3 | Crypto-sanitize poisons the controller | Binary diff of behavior: `all` (with sanitize) vs. patched flow (sanitize skipped), everything else equal | Both wedged ⇒ sanitize not necessary for the wedge. Separately: the 16:13 run died immediately after a suspicious 5 s "sanitize" of 2 TB | **Rejected as the mkfs killer; confirmed as an independent trigger** (skip it) |
| H4 | APST wake bug (deep states PS3/PS4 fail to wake) | `nvme_core.default_ps_max_latency_us=0` at boot + runtime `pm_qos_latency_tolerance_us=0` (reset-surviving); `get-feature 0x0c` verified APSTE=Disabled during failures | Wedges continued with APST verifiably off | **Rejected** |
| H5 | HMB incoherence (DRAM-less map tables in host RAM) | `nvme.max_host_mem_size_mb=0` on the recovery kernel cmdline (sysfs verified: "HMB: not allocated"); prechecks passed heavy I/O, installer still wedged | Wedges continued with HMB off | **Rejected** |
| H6 | Concurrent mixed I/O (udev/blkid readers racing mkfs writers) | TEST A: 60 s of randomized 4 KiB direct readers while sequential writers hammered the disk; TEST C: identical failing sequence with `udevadm control --stop-exec-queue` | TEST A: 16 464 random reads + 63 write passes, zero errors. TEST C: wedged with udev frozen ⇒ no blkid was running | **Rejected** |
| H7 | End-of-disk instability (GPT backup area) | TEST B: sector-exact 1 MiB write, 34-sector read, and 33-sector write at the last LBAs | All passed, zero errors | **Rejected** (first run's "failure" was the harness's own off-by-end bug — see postmortem) |
| H8 | Runtime partition-table rescan after table write | TEST C variants: (a) `blockdev --rereadpt` (kernel BLKRRPART), (b) `partx -a` (libfdisk reads), both with udev frozen and HMB/APST off | (a) wedged at rescan; (b) wedged inside `partx -a`. Control: the kernel's *boot-time* scan of the identical on-disk table is always clean | **CONFIRMED — trigger #2** (avoidable without losing anything: keep the table, don't rewrite it) |
| H9 | Sub-4 KiB block I/O pattern from `mke2fs` block-size auto-selection | Control pair: raw-2 TB mkfs (auto 4 KiB) **passed** vs. 256 MiB-partition mkfs (auto **1 KiB**) **wedged 5/5** in otherwise identical conditions (udev frozen, no table ops, mitigations on). Discriminator: same partition, forced `-b 4096` → **passed in 3 s** + mount/RW probe | Clean separation | **CONFIRMED — trigger #1 / root cause of the mkfs failures** |

## 3. Why H9 was found last

The block-size variable was invisible in every failing log: `mke2fs` prints its block size
(`Creating filesystem with 262144 1k blocks`) but nothing about it looks alarming, and every
failing run *also* contained a partition-table rewrite one step earlier — a louder suspect.
Only after H2–H8 were eliminated did the raw-disk-vs-partition control pair isolate it.
The lesson is recorded in [09-postmortem.md](09-postmortem.md): **mine the constants of
passing tests against failing ones** — the passing 2 TB raw mkfs was sitting in the logs
from 16:46 onward.

## 4. Test-harness notes (what made results trustworthy)

- Every test ran from a systemd unit (transient `systemd-run --unit=…` or the enabled
  boot service) — never from an SSH session scope (`KillUserProcesses=True` on this image).
- Every test wrote its verdict to `/tmp/zfix-install.log` with timestamps; a parallel
  `dmesg -w` capture ran for the whole boot.
- The dmesg health check (`grep -cE 'nvme nvme0: .*(timeout|reset controller|I/O error)'`)
  ran after **each** step; any nonzero → FATAL → no further steps execute.
- Filesystem-level probes (mount → write → read → `sync` → umount) validated beyond raw
  device I/O.
- Uploads to the target were verified by `wc -c` + md5 against the local source after the
  sync-loss incident (see postmortem).
- Power state assertions used the relay meter (watts), never SSH liveness alone.

## 5. What was NOT tested (and why)

- **A different host for the same drive** (would separate controller-vs-host interaction);
  left as a recommendation — the user's Rock 5B history suggests host-dependence exists.
- **Firmware update** (the vendor's Windows updater) — out of scope for a Linux-only
  session; flagged as the real fix.
- **Mainline vs. Valve kernel** — the wedge reproduced under the recovery image's 6.16
  kernel only; no other kernel was tried (the Rock 5B history on 6.1 shows similar-class
  behavior, so kernel-version sensitivity was deprioritized).
