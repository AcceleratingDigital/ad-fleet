---
name: ad-fleet-manager
description: "Use when managing AD-Fleet machines, tasks, or updates."
---

# AD-Fleet Manager

Operate the AcceleratingDigital multi-machine Hermes fleet: check roster/health, send tasks through the fleet DB bus, and distribute script/skill updates. Runs from an admin machine's user Hermes.

## Architecture

- **Fleet DB**: `hermes_fleet` on Postgres. Admins connect via Tailscale: `psql -h 10.1.128.8 -U admin -d hermes_fleet` with `$PG_ADMIN_PASS` from `source ~/ADTools/config/secrets.conf`. Members connect via the public hostname `db.acceleratingdigital.com` as user `fleet_member` (creds in that machine's `~/.ad-fleet/config.yaml`).
- These are the **same server** — before concluding two endpoints are different databases, compare `SELECT max(id), max(created_at) FROM hermes_bus;` through each; matching values prove one server behind two hostnames.
- **Member path needs no Tailscale/VPN**: members work purely over public hostnames (`db.acceleratingdigital.com:5432` for the DB, `llm.acceleratingdigital.com` for the LLM). Tailscale (`10.1.128.8`) is only the admin's direct route to the same server — never tell a joining member to install Tailscale first, and never diagnose a member's absence as a VPN problem unless its heartbeats AND public-endpoint reachability both fail.
- **Live tables**: `fleet_directives` (roster: host, role, classification, team), `fleet_status` (heartbeats: hostname, last_seen, machine_uuid), `fleet_specs` (machine specs, one row per host, FK to fleet_status.hostname — see Machine Specs below), `hermes_bus` (task queue).
- **DO NOT use `fleet_hosts` or `fleet_events_log`** — they exist in the schema but hold stale seed data and no live events; querying them makes the fleet look abandoned or machine-less.

## Quick Fleet Summary ("give me a fleet update" / "fleet summary")

When the user asks for a fleet status/summary/update, do NOT explore — run this fixed recipe and format the result:

1. Health + specs in one join:
   ```sql
   SELECT fs.hostname, fd.role, fd.classification,
          ROUND(EXTRACT(EPOCH FROM (NOW() - fs.last_seen))/60) AS mins_ago,
          sp.ram_gb, sp.disk_free_gb, sp.cpu_type, sp.os_version, sp.hermes_version, sp.user_name, sp.member_type
   FROM fleet_status fs
   JOIN fleet_directives fd ON fs.hostname = fd.host
   LEFT JOIN fleet_specs sp ON sp.hostname = fs.hostname
   ORDER BY fs.last_seen DESC;
   ```
2. Unresolved bus items (pending joins, repair reports, daemon issues):
   ```sql
   SELECT id, from_host, task_title, status, created_at FROM hermes_bus
   WHERE status = 'pending'
     AND (task_title ILIKE '%join%' OR task_title ILIKE '%repair%' OR task_title ILIKE '%issue%' OR task_title ILIKE '%specs%')
   ORDER BY id;
   ```
3. Format the reply as: **Healthy** (< 1h heartbeat) / **Stale** (1–24h) / **Offline** (> 24h or never) groupings, one line per machine (`hostname — role, Xh ago, RAM/GB, disk free, Hermes ver`), then a **Pending approvals** list (join requests awaiting the user) and **Action items** (machines needing a rerun/nudge). Include `mins_ago` as human time. Missing specs row = "specs not collected yet — send specs_update or have them rerun the installer".
4. Offer, don't auto-send: task sends (ping/specs_update/fleet_update) and approvals need the user's go-ahead, except when the user already asked for the action in the same breath.

## Fleet Health Check (do this first, in this order)

1. Roster + freshness:
   ```sql
   SELECT fs.hostname, fd.role, fd.classification,
          ROUND(EXTRACT(EPOCH FROM (NOW() - fs.last_seen))/60) AS mins_ago
   FROM fleet_status fs JOIN fleet_directives fd ON fs.hostname = fd.host
   ORDER BY fs.last_seen DESC;
   ```
2. This machine's last picked-up task: `tail -30 ~/.ad-fleet/logs/poller.log` — each line shows task id, title, received/done timestamps.
3. Task progress of a remote machine: query `hermes_bus` by `to_host` and check `status`/`result`.

## Machine Specs (`fleet_specs`)

Specs are collected in TWO paths only — NOT on every heartbeat (the user explicitly rejected per-heartbeat collection: specs barely change, and the heartbeat runs every 5 min):
1. **At registration** — the installer runs `~/.ad-fleet/scripts/ad-fleet-specs-update.sh` right after the verified first heartbeat (Phase 9.5), so any fresh install or one-liner rerun populates the row.
2. **On demand** — send a `specs_update` task (see Sending Tasks); the target's poller runs the same script and upserts within one 5-min cycle.

Columns (the user rejected a JSONB blob — spec data gets real typed columns, always):
`hostname` (PK), `ram_gb`, `disk_total_gb`, `disk_free_gb`, `cpu_type`, `os_version`, `arch`, `hermes_version`, `user_name`, `member_type`, `machine_uuid`, `collected_at`.

- Query it joined to liveness: `SELECT s.hostname, fd.role, sp.ram_gb, sp.disk_free_gb, sp.cpu_type, sp.hermes_version FROM fleet_specs sp JOIN fleet_status s USING (hostname) JOIN fleet_directives fd ON fd.host = s.hostname;`
- To add a spec column: `ALTER TABLE fleet_specs ADD COLUMN ...` (admin) → extend `ad-fleet-specs.sh` output fields (pipe-delimited: `hostname|ram|dtot|dfree|cpu|os|arch|hermes|user|mtype`) → extend the IFS read + INSERT in `ad-fleet-specs-update.sh` (NOT the heartbeat) → sync repo copy to installed copy on this machine and run `ad-fleet-specs-update.sh` once to verify the row, THEN commit/push and roll out via the one-liner or `fleet_update`. `fleet_member` has SELECT/INSERT/UPDATE on `fleet_specs` (no DELETE).
- On-demand refresh: send a `specs_update` task to the machine (`{"task":"specs_update"}`) — needed when specs changed (RAM upgrade, Hermes update) or the row is missing for a registered host. Heartbeats do NOT touch `fleet_specs`. Backfilling a whole fleet: send `specs_update` to every machine whose poller runs a version that knows the task type; machines on pre-specs pollers will report the handler missing — they need the one-liner or a `fleet_update` first.

## Approving a New Machine (join flow)

The member installer prints "Join request sent to fleet admins" regardless of whether the INSERT actually committed — verify the request in `hermes_bus` before believing any report of "awaiting approval":
```sql
SELECT id, from_host, task_title, status, created_at FROM hermes_bus
WHERE task_title ILIKE '%JOIN REQUEST%' ORDER BY created_at DESC LIMIT 10;
```
- If nothing arrived from the new machine, get the machine's hostname from the user and insert/approve on their behalf as admin — the member path (public hostname, `fleet_member` user, `kind='msg'`) accepts inserts from unregistered hosts, so a missing request means the installer's DB step failed or never ran, not a permission block. Have the user check `~/.ad-fleet/logs/install.log` for a Phase 8 warning to find the root cause.
- When inserting on a member's behalf, capture the task id with `psql -q -t -A -c "INSERT ... RETURNING id;"` and validate the output is a bare integer — the popular `-tAc` form appends a second line (`INSERT 0 1`), which breaks `grep -E '^[0-9]+$'` success checks and any `WHERE id=$ID` reuse downstream. Take `head -1` if you must parse it.
- Approve by: `INSERT INTO fleet_directives (host, role, added_by, notes, classification, team, registered_by) VALUES ('<hostname>', 'reader', '<this-host>', 'Member - <name> (approved via join_request <id>)', 'transient', 'member', '<requesting-user>');` — copy `classification`/`team` from the join request's body fields, or mirror an existing member's row — then send a `join_approved` task to the new host (`{"task":"join_approved","role":"reader"}`) so its poller flips its local config role. Mark the original join request `status='done'` with a result so it doesn't linger as pending. Match existing member roles (`reader` for typical member laptops) unless the user says otherwise. Verify the whole chain afterwards: directive row exists, approve task `pending` in the bus, and a first heartbeat from the new host arrives in `fleet_status` within a few minutes. Full worked sequence (including member-side repair commands and the v5 installer phase map) is in `references/member-join-repair.md`.
- Hostnames in join requests arrive exactly as the machine configured them; normalize to lowercase before registering.
- A successful join request does NOT mean the member's poller works. The join INSERT runs in-process during install, while the poller is a LaunchAgent — a machine whose join request landed but has **zero rows ever in `fleet_status`** and whose `join_approved`/status tasks sit `pending` through multiple 5-min cycles has daemons that load but fail on every run. The dominant cause is the daemons calling bare `psql`: `brew install libpq` does not link psql into PATH, so heartbeat/poller die with "command not found" every 5-min cycle while the installer's in-process DB steps (which resolved the binary) succeeded. Do not ask for `launchctl list` output first — the agents ARE loaded; the failure is inside the script. Have the member rerun the one-line bootstrap: `curl -fsSL https://raw.githubusercontent.com/AcceleratingDigital/ad-fleet/main/member/bootstrap.sh | bash`. The installer auto-detects the mode from local state — no install → fresh install, partial `install_state.json` → resume (retries the failed phase), complete install → update & repair — so the SAME command is the answer for first-time setup, updates, and repairs; never hand out separate repair instructions. Repair (v5+) pins psql to `~/.ad-fleet/bin/psql`, reloads the agents, fires a heartbeat, verifies it landed in `fleet_status`, and reports its findings to `fleet-admin` as a `daemon_issue`/`REPAIR REPORT` message in `hermes_bus`. Do not resend tasks — anything already queued is picked up the moment the poller works.
- Verify daemons end-to-end, not just their exit: after any install or repair, query `fleet_status` for a heartbeat younger than 5 minutes from the host. A heartbeat script that "ran" proves nothing — check the row landed. v5+ installers do this themselves (Phase 9.5 auto-runs repair when the heartbeat is not visible), but re-verify from the admin side before telling the user the machine is healthy.
- v5 daemons self-report failures: a healthy-but-broken node inserts a rate-limited (1/hour) `daemon_issue` message to `fleet-admin` in `hermes_bus`. Treat a `DAEMON ISSUE`/`REPAIR REPORT` title as the machine asking for help and triage from its `message` body; no heartbeat + no issue report means the machine cannot reach the DB at all (network/DNS), not a dead daemon.

## Sending Tasks

Insert into `hermes_bus`; pollers pick up every 5 min:
```sql
INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
VALUES ('<this-host>', 'TARGET', 'msg', '{"task":"ping"}', 'Ping', NOW() + INTERVAL '1 hour');
```

- Get `from_host` from `grep hostname: ~/.ad-fleet/config.yaml` — the trigger rejects unregistered hosts; do not assume which box you are on.
- Always `kind='msg'` (member pollers refuse `cmd`). Task types: `ping`, `doctor`, `hermes_prompt` (LLM prompt to target's fleet agent on port 8001), `status_report`, `specs_update` (collect machine specs → upsert `fleet_specs`), `fleet_update` (git pull + reload daemons + deploy skills to admins), `update`, `drop`, `fleet_alert`.
- Round-trips run 75–300s. A task still `pending` past ~6–7 min means the target's poller is down — probe the machine directly instead of waiting.

## Reaching a Machine

Try in this order; the layers fail independently:
1. Fleet agent health: `curl -s -m 10 http://<host>:8001/health` (Tailscale hostname or IP). If ok, send a `hermes_prompt` task — it is delivered via port 8001 even when the machine's main Hermes gateway is hung.
2. Main gateway: `curl http://<host>:8000/v1/models` (401 = alive but needs key).
3. SSH between fleet machines is generally NOT provisioned — do not plan around it; the DB bus is the transport.

## Distributing Skill/Script Updates

1. Edit the file in **both** places on this machine: the live copy (`~/.hermes/skills/<skill>/`) and the repo copy (`~/.ad-fleet/repo/skills/<skill>/`) — the repo copy is what other machines receive.
2. Commit in `~/.ad-fleet/repo` (remote: github.com/AcceleratingDigital/ad-fleet).
3. Push to GitHub, then send a `fleet_update` task to each machine — machines pull and the update script deploys `skills/` to `~/.hermes/skills/` on admin-role machines only.
4. If an HTTPS push fails for lack of credentials, switch the remote to SSH **before** giving up: this machine has a GitHub SSH key (`~/.ssh/id_ed25519_github`) wired up in `~/.ssh/config` as a `Host github.com` entry. `git remote set-url origin git@github.com:AcceleratingDigital/ad-fleet.git` then push. Only report 'needs credentials' if no SSH key/config entry exists at all.
5. For hand-distribution to a brand-new machine (no git pull yet): zip the repo's `member/` tree, keeping `member/` as the top-level folder name — `cd $(mktemp -d) && cp -R ~/.ad-fleet/repo/member . && zip -qry <dest>/fleet-member.zip member` — and hand the zip over; the member unzips and runs `bash member/ad-fleet-join-member.sh`. Verify the zipped installer passes `bash -n` when it carries a fresh edit. If the zip is a deliverable the user forwards to others, rebuild it from the repo after EVERY repo change — a stale zip ships stale installers and reintroduces fixed bugs. To repair an existing member without a full reinstall, the v5+ package's `member/scripts/ad-fleet-repair.sh` is the entry point (also runnable via a fresh `git clone` of the repo).

## Pitfalls

- `trg_fleet_write_permissions` on `hermes_bus` rejects only `kind='cmd'` INSERTs from hosts not registered in `fleet_directives`; `msg` inserts are open to all. Older installer builds hide DB errors and report "join request sent" regardless of whether the INSERT committed — a reported confirmation is not evidence a request exists, so verify the request row in `hermes_bus` before acting on it. The repo's member installer has been fixed (uses the Phase-1-located `psql` binary, surfaces real DB errors, confirms via `RETURNING id`); confirm that fix has reached GitHub before trusting new installs to self-report accurately.
- Hostnames are lowercase in directives/config.
- Role semantics: `admin` receives skill pushes + all tasks; `writer` can send but not receive deploys; `reader` is heartbeat/status only. Fix wrong roles with `UPDATE fleet_directives SET role=...`.
- The public DB hostname resolves to a consumer ISP IP (non-static); if member heartbeats all stop at once, check DNS resolution before debugging machines.
- `psql` may be missing from PATH entirely on libpq-only installs (brew does not link it). Locate with `command -v psql` plus the known prefixes (`/opt/homebrew/bin/psql`, `/opt/homebrew/opt/libpq/bin/psql`); v5+ scripts pin it via a `~/.ad-fleet/bin/psql` symlink so daemons never depend on PATH. Any fleet script that shells out to bare `psql` is a latent silent-failure bug — grep the repo's `member/scripts/` for `^psql\| $(psql` style calls before shipping and route them through a resolved `$PSQL` variable.
- `fleet_member` has INSERT/SELECT on `hermes_bus` but no DELETE — cleaning up probe/test rows or mistakenly-sent tasks requires the admin connection; don't burn time retrying member-path deletes.
- `fleet_status` heartbeats are NOT permission-gated: an unregistered machine's heartbeat lands fine. Presence there proves the install works, not approval. Same for self-reported healthy REPAIR REPORTs from unregistered hosts — that combination means only the approval INSERT remains, no debugging needed.
- Confirm with the user before approving a join when the request names a person you were not explicitly told to approve; a pending-approval question that times out is NOT consent to approve.
- When refreshing scripts onto a member, the freshly downloaded package (bootstrap clone or zip) is the source of truth — never let a pre-existing `~/.ad-fleet/repo/` clone overwrite it, because that clone may predate the fix and silently revert the scripts you just installed. Verify the INSTALLED copy (not the package) carries the expected marker (e.g. `grep 'ad-fleet/bin/psql' ~/.ad-fleet/scripts/ad-fleet-heartbeat.sh`) before declaring success.
- Missing error detail IS a diagnostic: v5+ fleet scripts print the real DB error after `FAILED`; output that says just `Heartbeat FAILED — <host>` with no error means the installed script is a pre-v5 copy, regardless of what the repair just claimed to refresh.
- Daemon logs self-trim (main logs to 500 lines, `-error.log` captures to 200 lines on every daemon run) — never add a separate log-cleanup cron; piggyback rotation on scripts that already run every 5 min.
- Guarded blocks in fleet scripts fail SILENTLY on an undefined variable: bash expands unset vars to empty, so `[ -x "$SPEC_SCRIPT" ]` just skips the block with no error anywhere — after editing a fleet script, run it once under `bash -x` and grep the trace for the block's marker to confirm the block actually executed.
- The INSTALLED scripts (`~/.ad-fleet/scripts/`) are what runs, not the repo copy — after editing `~/.ad-fleet/repo/member/scripts/*.sh`, copy to `~/.ad-fleet/scripts/` before testing on this machine, and copy back any fix made in the installed copy so the repo never drifts from what is verified working. Verify results in the DB/log, not from the script's exit code (0 is not evidence the specs/hb insert committed — the log line `Specs updated — <host>` or the row itself is).
