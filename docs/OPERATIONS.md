# Fleet Management Operations

## 1. The "Brain" (Coordinator)
The coordinator role is a set of autonomous crons running on an admin node (primarily `laptop-m1`).

### Core Functions:
- **Monitoring:** Checking `fleet_status` every 15 min.
- **Update Research:** Checking GitHub releases daily for new Hermes/Ollama versions.
- **Staged Rollout:** Deploying updates to Canary $\rightarrow$ Always-on $\rightarrow$ Transient.
- **Failover:** Monitoring the coordinator's own health and triggering failover to another admin.

## 2. Task Execution Flow (The Bus)
Coordination is asynchronous via the `hermes_bus` table in the DB.

1. **Issue:** Coordinator INSERTs a task into `hermes_bus`.
2. **Poll:** Machine SELECTs pending tasks for its UUID.
3. **Execute:** Machine runs the script/command locally.
4. **Report:** Machine UPDATEs the task to `done` with the result.

## 3. File Transfer (The Git CDN)
Large files are never sent through the DB.
- **Global Releases:** `/releases/{version}/` $\rightarrow$ All machines pull.
- **Targeted Drops:** `/drops/{uuid}/` $\rightarrow$ Specific machine pulls.
- **Integrity:** All transfers must be verified with SHA-256 checksums.

## 4. Diagnostics (The Doctor)
The `fleet-doctor.sh` script provides a deterministic health check of:
- Hermes process status
- Ollama process status
- DB connectivity
- Resource usage (RAM/Disk)
