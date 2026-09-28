# 06 — Power Automation (relay, watts-as-truth, and the protocol)

## 1. The physical stack

- **Sonoff S31** smart plug running **Tasmota 14.4.1** (ESP8266), at `http://192.168.9.X/`
  (sanitized). It feeds the target machine and reports live power.
- **HTTP API** (no auth on the LAN):
  - State: `curl "http://192.168.9.X/cm?cmnd=Power"` → `{"POWER":"ON"}`
  - Switch: `…/cm?cmnd=Power%20Off` / `Power%20On`
  - Meter: `…/cm?cmnd=Status%208` → JSON `StatusSNS.ENERGY.Power` (watts)
- **BIOS:** "AC Power Loss / Restore on AC Power Loss" set to **Power On** — when the relay
  re-energizes, the machine boots unattended. (With the default "Last State" it stays off.)

## 2. Calibrated watt bands (this machine)

| State | Watts |
|---|---|
| Off / standby (relay ON, machine off) | 7–16 W |
| Running (recovery desktop idle) | 53–66 W |
| Booting / active | 180–250 W |

Decision rule used everywhere: **< 30 W = off; > 30 W = powered.**

## 3. Why watts, not SSH

"SSH doesn't answer" is ambiguous — the machine may be booting, hung with sshd dead, or
off. The meter is unambiguous and requires zero cooperation from the target. Two concrete
uses:

- **Shutdown confirmation:** after `systemctl poweroff`, wait for the meter to drop below
  30 W before declaring success (a hung shutdown leaves SSH dead *and* watts high — that's
  the hard-cut decision branch, not "done").
- **Boot detection:** post relay-ON, watts climbing into the 180 W+ band means the BIOS
  auto-start fired and the board is alive, long before SSH answers.

## 4. The ext4-sync incident (why the protocol exists)

At 18:01 the orchestrator hard-cut the relay **34 seconds** after uploading two patched
scripts to the recovery USB. The USB's ext4 had not flushed the writeback yet → both files
were **zeroed** by the cut. The next boot's service ran an *empty* script — which exits 0 —
producing a misleading "SUCCESS" that was only caught by noticing a 4 ms runtime and empty
logs.

Consequences baked into the protocol and the harness:

- `sudo -n sync` (twice, with a pause) before **any** power action.
- Post-upload verification: `wc -c` + md5 against the local source.
- A systemd unit that "succeeds" instantly is a **smell** — check runtime and log content,
  not just exit status.

## 5. The P0–P4 power protocol

After the data-loss incident — and, more seriously, after the orchestrator continued
hard-cutting despite an explicit user order to shut down gracefully first — the user
demanded a written protocol. It is reproduced in [AGENTS.md](../AGENTS.md) (sanitized) and
summarized here:

- **P0 — Notify before ANY energy action** (including a plain `Power On`): the message must
  carry action + path (graceful/hard) + concrete reason + current watts. No notification,
  no action.
- **P1 — Prepare:** `sync` everything recently written; read watts; read relay state.
- **P2 — Graceful first, always:**
  1. `ssh deck@192.168.10.X 'sudo -n systemctl poweroff'`
  2. Poll SSH liveness every 5 s (max 120 s) — connection refused/timeout = it's going down.
  3. Poll watts every 10 s (max 180 s) until **< 30 W**.
  4. Only then, brief relay OFF (8–15 s — the wedged MAP1202 genuinely needs mains removed)
     → ON → BIOS auto-boots.
  5. Escalate to P3 (re-announcing) only if SSH never drops or watts never fall.
- **P3 — Hard cut (hung OS only, never a shortcut):** announce "CORTE DURO NECESARIO"
  verbatim + reason + watts + confirmation the graceful path was tried or impossible; keep
  OFF 15–20 s (a wedged controller needs a real cold rest); verify boot afterwards.
- **P4 — Cut discipline:** every cut gets its own prior notification; never cut with
  watts > 30 outside announced P3; one cycle = one cut; never chain cuts "just in case".
- **JAMÁS / NEVER list:** no `Power Off` while watts > 30 without an announced graceful
  attempt; no energy action without P0; no cut without prior `sync`; never infer "off" from
  SSH alone; never repeat a hard cut without re-announcing; never reach for the relay first
  when the OS answers SSH.

The final shutdown of the campaign (18:46) ran this protocol end-to-end: notified →
poweroff via SSH → watts 53 → 16 W confirmed → user removed USB → brief relay cycle →
first NVMe boot. Zero further incidents.

## 6. Relay operation log (as executed)

| Time | Action | Meter | Notes |
|---|---|---|---|
| 17:09:57 | OFF 12 s → ON | 23 → 7 W | machine did **not** auto-boot (BIOS not yet configured) |
| 17:44:47 | OFF 12 s → ON | → 249 W | boots (after user re-seated the USB; first attempt had it missing) |
| 18:01:24 | OFF 12 s → ON | — | the sync-loss incident |
| 18:24:45 | OFF 12 s → ON | → 189 W+ | v5 isolation test boot |
| 18:33:26 | OFF 12 s → ON | → boots | v6 success boot |
| 18:46:24 | **graceful poweroff** (relay untouched) | 53 → 16 W | protocol-compliant shutdown |

The 17:09 and 18:01 rows predate the protocol; both mistakes are analyzed in
[09-postmortem.md](09-postmortem.md).
