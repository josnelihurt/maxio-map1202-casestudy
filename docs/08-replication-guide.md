# 08 — Replication Guide: running this agentic pattern on another instance

This is a recipe for reproducing the *workflow pattern* — an LLM agent (ZCode + GLM-5.3)
debugging hostile hardware over SSH with unattended boots and automated power control — on
another machine/instance. The hardware specifics live in the other docs; this one is about
the method.

## 1. Prerequisites

- **Agent harness:** ZCode (or an equivalent tool with: subagents, background tasks,
  plan-mode approval gates, AskUserQuestion-style clarifications, and file/shell tools).
- **Target access:** SSH with **key auth** to a user with **passwordless sudo**
  (`sudo -n` works). Nothing else on the target may require interactive secrets.
- **Unattended boot:** the target must boot by itself into a recovery/live environment
  (USB auto-boot in BIOS) — you will reboot it many times.
- **Power control (optional but transformative):** a smart plug with a local API and a
  **power meter** (Tasmota-flashed Sonoff S31 here). Configure BIOS **AC Power Loss →
  Power On**. Without it, a human must perform every cold cycle.
- **A writable live environment on the target** (the recovery USB's root was rw) so scripts
  and systemd units can persist across the campaign's reboots.
- **Local workspace** for authoring scripts (never inline-heredoc anything nontrivial).

## 2. The loop, step by step

1. **Plan-mode research — do not touch the target.** Spawn 2–3 read-only Explore agents in
   parallel:
   - one for local context (artifacts, SSH conventions, history),
   - one for a read-only SSH inspection of the target (state, logs, the failing component),
   - one for web research (the hardware's known pathologies + the semantics of every knob
     you might touch — verify against kernel/docs sources, not blog posts).
2. **Clarify with the human** (AskUserQuestion): physical access level, destructive-action
   consent (e.g., "disk will be wiped — confirm"), and anything only they can decide.
3. **Present the plan** (phases, stop rules, power-cycle dependence) and get approval.
4. **Establish health before workarounds** (SMART, full-surface read). A dying component
   changes every downstream decision.
5. **Author target-side automation as files:**
   - a *decision tree* script: gated steps, each logging a timestamped verdict; a health
     check after every step; hard `exit` on first fault; the expensive/dangerous operation
     only runs if everything before it passed;
   - a systemd unit (enabled, `After=multi-user.target`) that runs it at every boot;
   - deploy with `scp` → `wc -c` + `md5` verify → `sudo -n sync` (twice) — see pitfall P4.
6. **Power actions under the protocol** ([06](06-power-automation.md)): P0 notification →
   graceful SSH shutdown → watts-confirmed off → brief relay cut → auto-boot.
7. **Observe via logs, not assumptions:** read the decision tree's log + `dmesg` capture;
   append each result to a running hypothesis matrix; design the next single (or bundled-
   orthogonal) experiment.
8. **Converge → execute the real goal → persist mitigations into the installed system →
   verify on the physical artifacts (e.g., grep the real grub.cfg), not just the chroot
   view.**
9. **Hand off human-only steps explicitly** (BIOS, USB removal, OOBE) and supervise with
   the meter.

## 3. Prompt patterns that worked (skeletons)

**Read-only inspector (Explore agent):**
> Read-only inspection of HOST over SSH. Every command must be strictly read-only. Gather:
> [state, logs, component info, exact error lines verbatim]. Do NOT write/set/reboot. If
> you cannot connect non-interactively, report what you tried and stop.

**Executor with stop rules (general-purpose agent):**
> You are doing X on HOST over SSH (`ssh -o BatchMode=yes user@host`, `sudo -n` for
> privileged). CRITICAL SAFETY RULE: after every step check `dmesg | grep -E '<fault
> pattern>'`; if ANY match appears, STOP all further work immediately — do not attempt
> recovery/rescan/reboot — and report the exact lines with timestamps. Long jobs must run
> as systemd transient units (this host kills session-scoped background processes).
> Report: per-step verdicts, final state, exact error text if stopped.

**Decision-tree prompt discipline (for the script itself):**
> Each step: echo a header with `$(date)`; run; `|| fatal "<step> failed"`; then a
> whole-boot fault counter must still be zero before the next step. The dangerous final
> step runs only if all gates passed.

**Power action (only after P0 notification):**
> Action / via (graceful|hard) / concrete reason / current watts — then and only then:
> `ssh 'sudo -n systemctl poweroff'`; poll SSH (5 s, ≤120 s); poll watts (10 s, ≤180 s)
> until < 30 W; only then relay OFF 10 s → ON.

## 4. Pitfalls encountered (each cost real time — avoid them)

| # | Pitfall | Countermeasure |
|---|---|---|
| P1 | **`KillUserProcesses=True`** on the live env silently kills SSH-session background jobs | Launch anything long-lived via `systemd-run --unit=<name>`; never `nohup … &` from a session |
| P2 | **Quoting through 3 shell layers** (local zsh → ssh → remote bash) mangled sed patterns | Author a script file locally, `scp` it, execute the file; never inline-escape nontrivial code |
| P3 | **Off-by-end arithmetic in test harnesses** (wrote past the device end → instant ENOSPC mistaken for a hardware failure) | Compute boundaries from sysfs values in-sector units; sanity-check with a tiny dry run; treat "failed with zero hardware errors" as a harness bug first |
| P4 | **ext4 writeback vs. hard power cut** → uploaded scripts zeroed | `sync` (twice, with a pause) after uploads and before any cut; md5-verify; treat instant-success units (4 ms, empty log) as a smell |
| P5 | **`partx -a` EBUSY** when the kernel already holds a table | `partx -d` (all) then `partx -a` |
| P6 | **`steamos-chroot --no-overlay`** mounts read-only rootfs — `/etc` edits fail | Use the overlay stack (no `--no-overlay`) for persistence work |
| P7 | **Empty script exits 0** — systemd reports success for nothing | Verify log content and unit runtime, not just exit status |
| P8 | **Inferring power state from SSH liveness** | Watts are ground truth (see protocol) |
| P9 | **Kernel-generated boot files get regenerated** (the Rock 5B lost its fix this way) | Persist params in `/etc/default/grub`-style durable sources; re-verify after updates |
| P10 | **`nvme set-feature -f 0x0c` doesn't stick** (kernel re-programs APST) | Use `pm_qos_latency_tolerance_us` sysfs or the kernel cmdline |

## 5. What to do differently from the start

1. Write the power protocol **before** the first energy action (ours was written after
   incidents — see [09-postmortem.md](09-postmortem.md)).
2. Get the relay + BIOS auto-on wired **before** the first wedge, not after two human
   power cycles.
3. Diff the constants of passing tests against failing ones **early** (the passing 2 TB
   raw-disk mkfs that exposed the block-size variable sat in a log for ~90 minutes before
   anyone compared block sizes).
4. Bundle orthogonal mitigations earlier when cycles are cheap (relay), one-at-a-time when
   they are expensive (human).

## 6. Minimal file set to replicate this campaign

```
scripts/precheck-v5.sh          # decision tree (final)
scripts/repair_device_zfix.sh   # patched installer
scripts/persist-grub.sh         # chroot persistence
scripts/persist-udev-mask.sh    # chroot persistence
scripts/zfix-install.service    # boot-time automation unit
AGENTS.md                       # power protocol
```

Adapt the decision tree's fault patterns (`nvme nvme0: .*timeout|reset controller|I/O
error`) and watt bands to your hardware, and the installer patches to your OS flow.
