# 07 — The Agentic Workflow (as executed)

This campaign was run by an **AI agent, not a human operator**. This document records the
orchestration stack, the loop, the subagent topology, and the human-in-the-loop points, as
they actually happened.

## 1. Stack

| Layer | Component | Role |
|---|---|---|
| Agent harness | **ZCode** (interactive coding agent, desktop CLI) | Tooling, plan-mode approval gates, subagent spawning, background tasks, user messaging |
| LLM | **GLM-5.3** (`zai-individual-coding-plan` account) | All reasoning: diagnosis, experiment design, code/script writing, orchestration decisions |
| Tools | `Bash` (ssh/scp/curl), `Read`/`Write`/`Edit`, `WebSearch`/`WebFetch`, `Agent` (subagents), `AskUserQuestion`, background tasks | Everything the agent did on the world |
| Target "hands" | systemd transient/enabled units on the recovery USB | Unattended execution of decision trees at boot |
| Target "nerves" | `/tmp/*.log` files + `dmesg -w` captures | Verdict streams read back over SSH |
| Physical loop | Tasmota relay + BIOS auto-on + watt meter | Power cycling without a human |

## 2. The loop (control-flow level)

```
┌─────────────────────────────────────────────────────────────────┐
│ PLAN MODE (read-only)                                           │
│  └─ 3 parallel Explore subagents:                               │
│       local artifacts · SSH inspection · web research           │
│  └─ AskUserQuestion (physical access? wipe OK?)                 │
│  └─ ExitPlanMode → USER APPROVES                                │
├─────────────────────────────────────────────────────────────────┤
│ EXECUTE PHASE (repeats per hypothesis)                          │
│  ├─ prepare scripts locally → scp → md5 verify → sync           │
│  ├─ arm target-side automation (systemd unit, enabled)          │
│  ├─ POWER ACTION  ── P0 notify → graceful/relay cycle ──        │
│  │                     (BIOS auto-boots the recovery USB)       │
│  ├─ background watcher on the workstation polls SSH/meter       │
│  ├─ read verdict logs → update hypothesis matrix                │
│  └─ wedge? → cold cycle (relay) → next experiment;              │
│     clean?  → proceed to next phase                             │
├─────────────────────────────────────────────────────────────────┤
│ GATES                                                            │
│  ├─ plan approval (user)                                         │
│  ├─ destructive-action approval (AskUserQuestion: disk wipe)     │
│  ├─ physical actions only the human can do (BIOS, USB removal)   │
│  └─ P0 notification before every energy action (post-protocol)   │
└─────────────────────────────────────────────────────────────────┘
```

## 3. Subagent inventory (every agent spawned this session)

| # | Type | Mission (abridged) | Tokens | Key outcome |
|---|---|---|---|---|
| 1 | Explore | Local artifacts & SSH conventions | ~813 k | Found Valve recovery image, `deck@` + passwordless sudo, no local history of prior commands |
| 2 | Explore | Read-only SSH inspection of target | ~340 k | Environment, SMART, APST enabled/PS4, installer script analysis, boots −3/−2/−1 dmesg |
| 3 | Explore | Web research (controller + knobs + SteamOS) | ~1.49 M | Kernel-source semantics of every knob; class evidence; Mint SN26904 thread; HMB/APST traps |
| 4 | Explore | Rock 5B post-mortem read | ~148 k | Recovered the exact prior fix (`default_ps_max_latency_us=0 pcie_aspm=off` + masked suspend) |
| 5 | general-purpose | Read-side stability battery | ~585 k | Full 2 TB surface read PASS; random/idle PASS; discovered `KillUserProcesses=True` |
| 6 | general-purpose | Install attempt #1 (`all`, patched mkfs) | ~520 k | FATAL-rule stop on wedge; sanitize identified as suspect; exact journal evidence |
| 7 | general-purpose | Install monitor #2 (auto-service v1) | ~124 k | Second wedge at same point with mitigations on; stopped cleanly, no "recovery" attempts |
| 8 | Explore | Relay + machine recon (plan-mode) | ~258 k | Tasmota API mapped; watt bands; SSH-down correlation with watcher log |
| 9 | Explore | Post-power-cycle state check | ~23 k | Files, service state, md5 comparison |
| 10 | general-purpose | Power-protocol design | ~19 k | Drafted P0–P4 (user-directed), landed in AGENTS.md |

Plus non-agent automations: 5 background watchers (shutdown/boot detectors, log capturers)
and the target-side decision trees themselves.

## 4. Turn-by-turn narrative (condensed)

1. **User describes the problem** (disk that "failed on the Rock 5B, stabilized there, now
   dies on x86 during SteamOS install") and asks for diagnosis + research + a fix plan.
2. **Plan-mode fan-out:** the orchestrator resists touching the machine; three Explore
   agents gather facts in parallel (items 1–3 above). The Rock 5B is inspected later on a
   mid-turn user tip (agent 4), recovering the exact prior workaround.
3. **Approval gate:** plan presented (phases, FATAL rules, power-cycle dependence,
   AskUserQuestion for physical access + wipe consent) → user approves with full physical
   access.
4. **Stabilization + read battery** (agents 5): everything read-side passes → media healthy.
5. **Install attempt #1** (agent 6): official `all` flow → wedge → **stop rule honored**,
   evidence preserved; orchestrator attempts PCI remove/rescan revival (fails: `not ready
   after 65535 ms`).
6. **User becomes part of the loop physically** (cold cycles) twice while the orchestrator
   iterates: no-sanitize (agent 7) → HMB-off via USB GRUB patch → decision-tree v3.
7. **User contributes the relay**; orchestrator maps its API, wires BIOS auto-on, and from
   then on power cycles are agent-executed.
8. **Decision trees v3→v6:** each boot runs a gated experiment battery; each wedge costs
   only a relay cycle. The matrix converges (see [03](03-diagnosis-methodology.md)).
9. **Process incident:** user intercepts a hard cut with an explicit order; the order is
   initially not honored (postmortem), then enforced by writing the P0–P4 protocol
   (AGENTS.md) via a dedicated design agent.
10. **Success:** v6 (`-b 4096`, no table ops, `system` mode) installs SteamOS with zero NVMe
    errors; persistence phase; **graceful** shutdown under P0–P4; user removes USB; first
    boot from NVMe confirmed.
11. **Handoff:** OOBE is human work; installed SteamOS ships with SSH off. The agent
    supervises via the watt meter and stands by for post-OTA verification.

## 5. Design patterns that made this work

- **Decision-tree-as-a-service.** When every experiment costs a reboot, put the experiment
  *in the boot*: an enabled systemd unit runs the gated test battery unattended, appends
  timestamped verdicts to a log, and refuses to run the (dangerous) next stage unless
  everything passed. The agent then only needs one SSH read to learn what happened.
- **FATAL rules in every executor prompt.** "If you see X, stop; do not recover, do not
  rescan, do not reboot; report exact dmesg lines." Prevents evidence destruction and
  unbounded autonomy after a hardware fault.
- **Watts as ground truth** (see [06](06-power-automation.md)).
- **Background watchers on the workstation** for async events (SSH down/up transitions),
  so the orchestrator can idle between boots instead of polling.
- **Bundles only after delegation.** While the human powered the cycles, changes were
  one-variable-at-a-time; once the relay removed the human from the loop, orthogonal
  mitigations were bundled — with per-knob verification logged.
- **Local authoring + `scp` + md5 + `sync`.** After the zeroed-files incident, no script
  ever lived only in a quoted heredoc again; everything is a file, verified, synced.
- **Protocol escalation.** When the agent violated a user order, the fix was not a promise
  but a *written protocol* (AGENTS.md) with an unconditional prohibition list — process as
  code.

## 6. Cost & scale (for reproducibility expectations)

- Wall clock: ~15:15 → 18:50 (~3 h 35 m), of which ~45 min were human-in-the-loop
  (approvals, physical actions) and the rest autonomous or waiting on boots.
- Subagent tokens: ~4.4 M total (research-heavy by design; the three research agents are
  60 % of it).
- Power cycles consumed: 8 (2 human, 5 relay, 1 graceful).
- Controller wedges survived: 7.
