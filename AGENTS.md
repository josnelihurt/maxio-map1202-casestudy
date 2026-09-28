# AGENTS.md — Power protocol for this case study

> Rules learned the hard way during the campaign (see
> [docs/06-power-automation.md](docs/06-power-automation.md) and
> [docs/09-postmortem.md](docs/09-postmortem.md)).
> Identifiers are sanitized: `192.168.10.X` = target PC, `192.168.9.X` = relay.

## Power protocol (relay + machine 192.168.10.X)

**Constants:** SSH `deck@192.168.10.X` (passwordless sudo, `sudo -n`) · Tasmota relay
`http://192.168.9.X` · standby band **< 30 W** · running band **> 30 W** (typically
50–250 W) · BIOS "AC Power Loss → Power On". The relay's power meter is the source of
truth for machine state.

**SSH_BASE** = `ssh -o ConnectTimeout=10 -o BatchMode=yes deck@192.168.10.X`

### P0 — Mandatory notification (BEFORE ANY energy action)
Send the user a message containing: (1) intended action (power on / off / cycle),
(2) path (graceful or hard cut), (3) concrete reason, (4) current watts. Without these
four points, DO NOT act. No energy action exists without prior notification — including a
simple `Power On`.

### P1 — Preparation (before any cut)
1. Sync everything recently written (prevents unflushed-ext4 data loss — we lost files to
   this once): `$SSH_BASE 'sudo -n sync'`
2. Read watts: `curl -s "http://192.168.9.X/cm?cmnd=Status%208"` → `StatusSNS.ENERGY.Power`
3. Read relay state: `curl -s "http://192.168.9.X/cm?cmnd=Power"`

### P2 — Graceful path (ALWAYS first; no exceptions)
1. Ordered shutdown: `$SSH_BASE 'sudo -n systemctl poweroff'`
2. Poll SSH drop every 5 s, max 120 s: `$SSH_BASE -o ConnectTimeout=5 'true'` (failing =
   it is going down).
3. Poll watts every 10 s, max 180 s, until **< 30 W** (SSH dropping is NOT enough: the OS
   can be half-alive).
4. Only with < 30 W confirmed, brief cut so the NVMe controller fully discharges:
   `curl -s "http://192.168.9.X/cm?cmnd=Power%20Off"` → `sleep 10` (8–15 s) →
   `curl -s "http://192.168.9.X/cm?cmnd=Power%20On"`. The BIOS auto-boots.
5. Verify return: watts climb into the running band and SSH answers again.
6. If SSH never drops or watts never fall below 30 W within the timeouts → escalate to P3,
   **re-announcing**.

### P3 — Hard-cut path (hung OS; the exception, never a shortcut)
Applies only if: SSH is dead/hung, `poweroff` did not complete within P2's timeouts, or
processes are in D-state.
1. Announce EXPLICITLY: **"HARD CUT REQUIRED"** + reason + current watts + confirmation
   that the graceful path was already tried (or was impossible).
2. `curl -s "http://192.168.9.X/cm?cmnd=Power%20Off"` → keep OFF **20 s** (15–20 s; a
   wedged controller needs a real cold rest) → `curl -s "http://192.168.9.X/cm?cmnd=Power%20On"`.
3. Verify boot (watts in the running band + SSH answers). If it does not boot, do NOT
   re-cut without going back to P0.

### P4 — Cut discipline
- Every cut requires its own prior notification; never re-cut without re-announcing.
- Never cut with watts > 30 W outside the announced P3 path.
- One cycle = one cut; do not chain cuts "just in case".

### NEVER
- NEVER `Power Off` while Status 8 shows > 30 W without a previously **announced**
  graceful attempt.
- NEVER an energy action (including `Power On`) without a P0 notification to the user.
- NEVER cut without a prior `sudo -n sync` of everything written.
- NEVER assume shutdown because SSH dropped: require watts < 30 W.
- NEVER repeat a hard cut without re-announcing it with the reason.
- NEVER use the relay as a first resort when the OS answers over SSH.

## Technical context of the machine (session memory)

- Drive: SPCC 2 TB, MAXIO MAP1202 controller, firmware SN26904. It wedges (4 KiB READ
  timeout → controller reset → gone until a cold cut) under specific patterns; ruled out:
  sanitize (independent trigger — skip it), APST, HMB, concurrent I/O, end-of-disk.
  Confirmed triggers: ext4 formatting with **1 KiB blocks** (always use `-b 4096`) and
  **runtime partition-table rescans** (never rewrite the table at runtime; boot-time scans
  are safe).
- Mitigations on the recovery USB's GRUB: `nvme.max_host_mem_size_mb=0
  nvme_core.default_ps_max_latency_us=0` + runtime `discard_max_bytes=0`,
  `pm_qos_latency_tolerance_us=0`.
- Patched installer: `scripts/repair_device_zfix.sh` (no sanitize, `-E nodiscard -b 4096`,
  no auto-reboot, `system` mode never touches the partition table).
  Decision tree: `scripts/precheck-v5.sh` (unit: `zfix-install.service`, disabled after
  success).
