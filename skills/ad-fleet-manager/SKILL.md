---
name: ad-fleet-manager
description: "Use when managing AD-Fleet machines, tasks, and updates."
---

# AD-Fleet Manager

Manage the AcceleratingDigital Fleet from within the admin's user Hermes. Check fleet status, send tasks to any machine, push script updates, and run remote diagnostics — all through the fleet DB bus.

## Architecture

- **Fleet DB**: `hermes_fleet` on `10.1.128.8:5432` (admin direct via Tailscale)
- **DB credentials**: `source ~/ADTools/config/secrets.conf` → use `$PG_ADMIN_PASS` with user `admin`
- **Tables**: `fleet_directives` (roster), `fleet_status` (heartbeats), `hermes_bus` (task queue). **Do NOT use `fleet_hosts` / `fleet_events_log`** — they exist in the schema but hold stale Aug-2026 seed data and no live events; querying them makes the fleet look abandoned. Roster truth = `fleet_directives` JOIN `fleet_status`.
- **Member path**: `db.acceleratingdigital.com:5432` as user `fleet_member` (creds in `~/.ad-fleet/config.yaml`) — **same Postgres server** as the Tailscale endpoint (hermes_bus max(id) matches on both). Admin installers point at `10.1.128.8`, member installers at the public hostname — both intentional, not a misconfiguration.
- **Task flow**: Insert into `hermes_bus` → target poller picks up (every 5 min) → result written to `result` column, `status='done'`
- **This machine hostname**: `grep hostname: ~/.ad-fleet/config.yaml` — use as `from_host`
- **GitHub repo**: `https://github.com/AcceleratingDigital/ad-fleet.git`
- **Repo checkout**: `~/code/fleet-management-tools/`

## DB Access Pattern

```bash
source ~/ADTools/config/secrets.conf
export PGPASSWORD="$PG_ADMIN_PASS"
psql -h 10.1.128.8 -p 5432 -U admin -d hermes_fleet
```

## Fleet Status

```sql
SELECT fs.hostname, fd.role, fd.classification, fd.is_canary,
       ROUND(EXTRACT(EPOCH FROM (NOW() - fs.last_seen))) as secs_ago,
       fs.machine_uuid IS NOT NULL as has_uuid
FROM fleet_status fs
JOIN fleet_directives fd ON fs.hostname = fd.host
ORDER BY fs.last_seen DESC;
```

## Send Tasks

Insert into `hermes_bus`. `from_host` = this machine's registered hostname. Always `kind='msg'`.

**Ping:**
```sql
INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
VALUES ('mm4p', 'TARGET', 'msg', '{"task":"ping"}', 'Ping', NOW() + INTERVAL '1 hour');
```

**Doctor (full diagnostics):**
```sql
VALUES ('mm4p', 'TARGET', 'msg', '{"task":"doctor"}', 'Doctor', NOW() + INTERVAL '1 hour');
```

**Hermes prompt (LLM task on target machine):**
```sql
VALUES ('mm4p', 'TARGET', 'msg', '{"task":"hermes_prompt","prompt":"YOUR PROMPT"}', 'Task', NOW() + INTERVAL '1 hour');
```

**Fleet update (git pull + reload daemons + deploy skills on admins):**
```sql
VALUES ('mm4p', 'TARGET', 'msg', '{"task":"fleet_update"}', 'Update', NOW() + INTERVAL '1 hour');
```

**Broadcast to all** — one INSERT per host from `SELECT host FROM fleet_directives`.

## Check Results

```sql
SELECT to_host, status,
       ROUND(EXTRACT(EPOCH FROM (done_at - created_at))) as secs,
       LEFT(result, 300) as response
FROM hermes_bus WHERE task_title = 'YOUR_TITLE' ORDER BY to_host;
```

## Push Code Updates to Fleet

1. Edit files in `~/code/fleet-management-tools/`
2. `git add -A && git commit -m "..." && git push`
3. Send `fleet_update` task to each machine
4. Machines pull from GitHub, copy scripts, reload daemons
5. Skills deploy to `~/.hermes/skills/` on **admin machines only** (role=admin guard)

## Pushing to shared repos (adtools-sanitized etc.)

- The working tree on the shared checkout often carries UNRELATED dirty files from another session (finance skills, schema files) — never `git add -A`; stage only the exact files you touched. To push when those dirty files block a `pull --rebase`, use `git pull --rebase --autostash` (stashes, rebases, restores in one step) rather than a manual stash dance that can drop someone else's work.
- Fetch first and expect the remote to have moved (`git rev-list origin/main..main --count` for local-only commits); a bare `git push` rejection means rebase, not force.

## Task Types

| task | description |
|---|---|
| `ping` | Returns "pong — HOSTNAME alive at TIME" |
| `doctor` | Full diagnostics via ad-fleet-doctor.sh |
| `hermes_prompt` | LLM prompt to fleet Hermes port 8001 |
| `fleet_update` | Git pull, reload daemons, deploy skills (admin only) |

## Reaching a machine whose MAIN Hermes is down

Each fleet machine can run TWO Hermes layers: the user's main gateway (user crons, chat) and the AD-Fleet agent on **port 8001** (separate daemon, installed by fleet setup). They fail independently — diagnose which layer is dead before choosing a channel:

1. **Health-check the fleet agent directly:** `curl -s -m 10 http://<host>:8001/health` (Tailscale-resolvable hostname). If it answers ok, the fleet agent is alive even when the main gateway is hung or dead.
2. **Route work through the fleet agent:** send a `hermes_prompt` task (not a plain `msg`) — the fleet poller delivers prompts to port 8001, which does not depend on the main gateway. A plain `msg` to a box whose main gateway is down may sit `pending` forever, because on some boxes the bus poller runs through that gateway.
3. **`hermesbus.sh` may not exist on this box** — that is not a blocker. Insert directly into `hermes_bus` via psql (DB Access Pattern above); for `kind='msg'` the DB trigger allows any registered host. The script is a convenience wrapper, not a requirement.
4. **Check `~/.ad-fleet/config.yaml` for THIS machine's hostname before every send** — do not assume from memory which box you are on; `from_host` must match a registered `fleet_directives` host or the trigger rejects the insert.

## Pitfalls

- `from_host` must be a registered host in `fleet_directives` (trigger blocks unknown hosts) — use THIS machine's hostname per `~/.ad-fleet/config.yaml`, not another admin's, and not the hostname you remember the machine by
- Always `kind='msg'` — members blocked from `cmd`
- Pollers run every 5 min — round-trips typically 75-300s. If a task is still `pending` past ~6-7 min, treat the target's poller as down and SSH/probe the machine directly instead of waiting longer — the pending task itself is the diagnostic signal
- Hostnames are **lowercase** in fleet config and directives
- `psql` not in user PATH on some machines but IS in daemon PATH
- `db.acceleratingdigital.com` resolves to a residential ISP IP (AT&T lightspeed Houston, non-static) — works today but breaks silently if the IP changes; if members stop heartbeating, check DNS first
- Skill deploy is **admin-only** — members never receive skill pushes
- Role semantics: `admin` = receives skill pushes + fleet_update + all tasks; `writer` = can SEND bus tasks but receives no skill deploys; `reader` = status/heartbeat only. A machine running a full Hermes gateway + crons should be `admin`, not `writer`. Fix wrong roles with `UPDATE fleet_directives SET role=...` (check constraint allows writer/reader/admin only).

## Current Fleet

Pull the live roster from `fleet_directives` rather than trusting this list — roles change. Known members: `mm4p`, `laptop-m1`, `algo-laptop`, `sharedminiintel` (admin, always-on, canary), `shitalm5pro` and `jatins-macbook-air` (readers, transient). As of 2026-10-19: all 6 hosts alive, no new joins since Aug 2026. Shital's machine is **`shitalm5pro`** — there is no `shital-laptop`.
