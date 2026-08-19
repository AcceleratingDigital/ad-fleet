---
name: ad-fleet-manager
description: "Use when managing the AD-Fleet: check fleet status, send tasks to machines, push updates, run diagnostics. Fleet = multi-machine Hermes coordination via shared Postgres DB."
---

# AD-Fleet Manager

Manage the AcceleratingDigital Fleet from within the admin's user Hermes (port 8000). This skill lets you check fleet status, send tasks to any machine, push script updates, and run remote diagnostics — all through the fleet DB bus.

## Architecture

- **Fleet DB**: `hermes_fleet` on `10.1.128.8:5432` (admin direct via Tailscale) or `db.acceleratingdigital.com:5432` (members via pgBouncer)
- **DB user**: `admin` (table owner, full access) — credentials in `~/ADTools/config/secrets.conf` as `PG_ADMIN_PASS`
- **Tables**: `fleet_directives` (roster), `fleet_status` (heartbeats), `hermes_bus` (task queue)
- **Task flow**: Insert task into `hermes_bus` → target machine's poller picks it up (every 5 min) → result written back to `result` column with `status='done'`
- **This machine**: admin role, can send tasks from its registered hostname
- **GitHub repo**: `git@github.com:AcceleratingDigital/ad-fleet.git` (HTTPS: `https://github.com/AcceleratingDigital/ad-fleet.git`)
- **Repo checkout**: `~/code/fleet-management-tools/` on the coordinator machine

## DB Access

Admin DB credentials are in `~/ADTools/config/secrets.conf`:
```
source ~/ADTools/config/secrets.conf
export PGPASSWORD="$PG_ADMIN_PASS"
```
Use `psql -h 10.1.128.8 -p 5432 -U admin -d hermes_fleet` for all queries.

## Commands

### 1. Fleet Status — see all machines and heartbeat health

```sql
SELECT fs.hostname, fd.role, fd.classification, fd.is_canary,
       fs.last_seen,
       ROUND(EXTRACT(EPOCH FROM (NOW() - fs.last_seen))) as secs_ago,
       fs.machine_uuid IS NOT NULL as has_uuid
FROM fleet_status fs
JOIN fleet_directives fd ON fs.hostname = fd.host
ORDER BY fs.last_seen DESC;
```

Also check the roster (registered machines):
```sql
SELECT host, role, classification, team, is_canary, registered_by, registered_at
FROM fleet_directives ORDER BY host;
```

### 2. Send a Task to a Machine

Insert a task into `hermes_bus`. Always use `from_host` = this machine's registered hostname (check `~/.ad-fleet/config.yaml` for the `hostname:` value). Use `kind='msg'` (members can't use `cmd`).

**Ping** (quick health check):
```sql
INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
VALUES ('mm4p', 'TARGET_HOST', 'msg',
  '{"task":"ping"}',
  'Ping', NOW() + INTERVAL '1 hour');
```

**Run doctor** (full diagnostics):
```sql
INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
VALUES ('mm4p', 'TARGET_HOST', 'msg',
  '{"task":"doctor"}',
  'Doctor Check', NOW() + INTERVAL '1 hour');
```

**Send a prompt to fleet Hermes** (LLM-powered task on target machine's port 8001):
```sql
INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
VALUES ('mm4p', 'TARGET_HOST', 'msg',
  '{"task":"hermes_prompt","prompt":"YOUR PROMPT HERE"}',
  'Hermes Task', NOW() + INTERVAL '1 hour');
```

**Push fleet_update** (pull latest scripts from GitHub, reload daemons, deploy skills):
```sql
INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
VALUES ('mm4p', 'TARGET_HOST', 'msg',
  '{"task":"fleet_update"}',
  'Fleet Update', NOW() + INTERVAL '1 hour');
```

### 3. Check Task Results

```sql
SELECT id, to_host, task_title, status,
       ROUND(EXTRACT(EPOCH FROM (done_at - created_at))) as round_trip_secs,
       LEFT(result, 200) as response
FROM hermes_bus
WHERE task_title = 'YOUR_TASK_TITLE'
ORDER BY created_at DESC;
```

Or check all recent activity:
```sql
SELECT id, from_host, to_host, task_title, status, created_at, done_at,
       LEFT(result, 100) as response
FROM hermes_bus
ORDER BY created_at DESC LIMIT 15;
```

### 4. Broadcast to All Machines

To send the same task to every machine, insert one row per machine:
```sql
-- Get all active hosts
SELECT host FROM fleet_directives;
-- Then insert a task for each (use a loop in Python/psql)
```

### 5. Clean Up Old Bus Messages

```sql
DELETE FROM hermes_bus WHERE created_at < NOW() - INTERVAL '7 days';
```

### 6. Push Code Updates to All Machines

1. Make changes in `~/code/fleet-management-tools/`
2. `git add -A && git commit -m "description" && git push`
3. Send `fleet_update` task to each machine via bus (see above)
4. Machines pull from GitHub, copy scripts, reload daemons, deploy skills
5. Check results via the bus

### 7. Deploy Skills to Admin Machines' User Hermes

The `fleet_update` task handler automatically deploys skills from the repo's `skills/` directory to `~/.hermes/skills/` on admin machines. To deploy a new skill:

1. Create the skill in `~/code/fleet-management-tools/skills/<skill-name>/SKILL.md`
2. `git add -A && git commit && git push`
3. Send `fleet_update` to admin machines
4. Skills land at `~/.hermes/skills/<skill-name>/SKILL.md` on each admin machine

## Task Types Reference

| task | body JSON | what it does |
|---|---|---|
| `ping` | `{"task":"ping"}` | Returns "pong — HOSTNAME alive at TIME" |
| `doctor` | `{"task":"doctor"}` | Runs ad-fleet-doctor.sh, returns full diagnostics |
| `hermes_prompt` | `{"task":"hermes_prompt","prompt":"..."}` | Sends prompt to fleet Hermes (port 8001), returns LLM response |
| `fleet_update` | `{"task":"fleet_update"}` | Git pull, copy scripts, reload daemons, deploy skills |
| `join_approved` | `{"task":"join_approved","role":"writer\|admin"}` | Updates local config role after admin approval |

## Poller Timing

Pollers run every 5 minutes. Tasks are picked up on the next poller cycle. Round-trip times are typically 75-290 seconds depending on when the poller fires relative to task insertion.

## Current Fleet Machines

Check with the fleet status query above. As of Aug 2026:
- `mm4p` — admin, always-on (coordinator)
- `laptop-m1` — admin, always-on
- `algo-laptop` — admin, transient
- `sharedminiintel` — writer (canary), always-on

## SSH Access

SSH is available to some machines for direct debugging (not a fleet dependency):
- `ssh -i ~/.ssh/id_ed25519_hermes patelpk@laptop-m1.local`
- `ssh -i ~/.ssh/id_ed25519_hermes patelpk@sharedminiintel.local`

## Pitfalls

- **Trigger blocks non-registered hosts**: `from_host` must match a `host` in `fleet_directives`. Use the coordinator's registered hostname.
- **Members can't use `cmd` kind**: DB trigger blocks it. Always use `kind='msg'`.
- **Result column**: long results are truncated to 4000 chars by the poller.
- **Poller log**: `~/.ad-fleet/logs/poller.log` on each machine — empty log means no pending tasks (normal).
- **psql not in PATH**: On some machines `psql` isn't in the user's PATH but IS in the daemon's PATH (plist has `/opt/homebrew/bin:/usr/local/bin`). Doctor script handles this.
- **Hostnames are lowercase**: fleet config uses lowercase hostnames. DB directives must match.
