---
name: ad-fleet-manager
description: "Use when managing AD-Fleet machines, tasks, and updates."
---

# AD-Fleet Manager

Manage the AcceleratingDigital Fleet from within the admin's user Hermes. Check fleet status, send tasks to any machine, push script updates, and run remote diagnostics — all through the fleet DB bus.

## Architecture

- **Fleet DB**: `hermes_fleet` on `10.1.128.8:5432` (admin direct via Tailscale)
- **DB credentials**: `source ~/ADTools/config/secrets.conf` → use `$PG_ADMIN_PASS` with user `admin`
- **Tables**: `fleet_directives` (roster), `fleet_status` (heartbeats), `hermes_bus` (task queue)
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

## Fleet Status Report (deterministic)

Sends `status_report` task to all machines. Each machine collects locally — no LLM, pure shell. Returns JSON with:
- main Hermes version, model, provider, port 8000 status
- fleet Hermes version, model, provider, port 8001 status
- daemon status (heartbeat, poller, gateway LaunchAgents)

**Send to one machine:**
```sql
INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
VALUES ('mm4p', 'TARGET', 'msg',
  '{\"task\":\"status_report\"}'::jsonb::text,
  'Status Report', NOW() + INTERVAL '1 hour');
```

**Send to all machines** — one INSERT per host from `SELECT host FROM fleet_directives`.

**Collect results** (after ~5-10 min for poller cycles):
```sql
SELECT to_host, status,
       LEFT(result, 500) as response
FROM hermes_bus WHERE task_title = 'Status Report'
ORDER BY to_host;
```

Results are JSON strings — parse with `json.loads()` to build the status table.

## Fleet Status (heartbeat only)

```sql
SELECT fs.hostname, fd.role, fd.classification, fd.is_canary,
       ROUND(EXTRACT(EPOCH FROM (NOW() - fs.last_seen))/60) as mins_ago,
       fs.machine_uuid IS NOT NULL as has_uuid
FROM fleet_status fs
JOIN fleet_directives fd ON fs.hostname = fd.host
ORDER BY fs.last_seen DESC;
```

## Send Tasks

Insert into `hermes_bus`. `from_host` = this machine's registered hostname. Always `kind='msg'`.

**IMPORTANT**: JSON bodies must use `::jsonb::text` cast to preserve quotes:
```sql
VALUES ('mm4p', 'TARGET', 'msg', '{\"task\":\"ping\"}'::jsonb::text, 'Ping', NOW() + INTERVAL '1 hour');
```

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

## Task Types

| task | description |
|---|---|
| `ping` | Returns "pong — HOSTNAME alive at TIME" |
| `status_report` | Deterministic JSON: versions, models, providers, ports, daemons |
| `doctor` | Full diagnostics via ad-fleet-doctor.sh |
| `hermes_prompt` | LLM prompt to fleet Hermes port 8001 |
| `fleet_update` | Git pull, reload daemons, deploy skills (admin only) |

## Pitfalls

- `from_host` must be a registered host in `fleet_directives` (trigger blocks unknown hosts)
- Always `kind='msg'` — members blocked from `cmd`
- Pollers run every 5 min — round-trips typically 75-300s
- Hostnames are **lowercase** in fleet config and directives
- `psql` not in user PATH on some machines but IS in daemon PATH
- Skill deploy is **admin-only** — members never receive skill pushes

## Current Fleet (Aug 2026)

- `mm4p` — admin, always-on (coordinator, USA-MM4P-PP)
- `laptop-m1` — admin, always-on
- `algo-laptop` — admin, transient (system hostname USA-M4P-PP)
- `sharedminiintel` — writer/canary, always-on
- `shitalm5pro` — reader, transient
- `jatins-macbook-air` — reader, transient
