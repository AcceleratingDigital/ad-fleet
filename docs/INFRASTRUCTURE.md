# Fleet Infrastructure Architecture

## 1. Connectivity Model (Hybrid Trust)
The fleet uses a tiered connectivity model to balance accessibility and security.

### Admin Tier (High Trust)
- **Machines:** `laptop-m1`, `USA-M4P-PP`, `USA-MM4P-PP`
- **Network:** Tailscale VPN required.
- **Access:** Direct connection to PostgreSQL (`10.1.128.8:5432`).
- **Role:** full `hermes_fleet_admin` privileges.

### Member Tier (Low Trust)
- **Machines:** `SharedMiniIntel`, `Jatins-MacBook-Air`, `Shitals-M5Pro`
- **Network:** Public Internet (no VPN needed).
- **Access:** `db.acceleratingdigital.com` via Cloudflare $\rightarrow$ Nginx $\rightarrow$ pgBouncer.
- **Role:** `fleet_member` privileges (SELECT/INSERT/UPDATE on `hermes_bus` and `fleet_status` only).

---

## 2. Endpoint Specifications

### LLM Gateway
- **URL:** `https://llm.acceleratingdigital.com`
- **Backend:** LiteLLM proxy $\rightarrow$ `10.1.2.13:4000`
- **Auth:** API Key (Bearer token)
- **Purpose:** Complex fleet reasoning and high-level coordination.

### Database Gateway
- **URL:** `db.acceleratingdigital.com`
- **Backend:** pgBouncer $\rightarrow$ `10.1.128.8:5432`
- **Auth:** DB User/Password (`fleet_member` for external)
- **Purpose:** Heartbeats, task polling, and state management.

---

## 3. Hardware & Software Baseline
- **Hermes:** CLI + Gateway installed for fleet ops.
- **Ollama:** Local instance running `qwen2.5:3b` as the baseline for diagnostics.
- **Config Folder:** `~/.fleet/` (Separate from personal `~/.hermes/`).
- **Identity:** Machine UUIDs (stored in `~/.fleet/machine_id`) used as primary keys instead of hostnames.
