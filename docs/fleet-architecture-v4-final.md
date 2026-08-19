# Fleet Architecture v4 — Answers & Implications

**Piyush's Answers to 5 Decisions**

---

## Decision 1: Gateway Location (CRITICAL INSIGHT)

**Your Answer:** laptop-m1 or another admin node can be the gateway. Failover to another admin if m1 fails.

**Your Question:** "What is the gateway doing that we need one if the fleet talks via the database messaging?"

**This is the KEY question.** Let me think through what "fleet gateway" actually means in our design.

### What We Said "Fleet Gateway" Would Do (v4 Proposal)

```
Fleet Gateway (as proposed):
  ├─ HTTPS API endpoint (fleet.yourdomain.com)
  ├─ Receives heartbeats from machines
  ├─ Receives file uploads from machines
  ├─ Sends tasks to machines
  └─ Runs Ollama for simple diagnostics
```

### What Actually Happens (Reality Check)

```
If fleet talks via DATABASE:

Heartbeat:
  Machine → (INSERT to fleet_status via HTTPS DB connection)
  Database ← heartbeat

File Transfer:
  Machine → (INSERT to hermes_bus via HTTPS DB connection)
  Database ← file chunks
  Coordinator → (SELECT from hermes_bus via HTTPS DB connection)

Tasks:
  Coordinator → (INSERT to hermes_bus via HTTPS DB connection)
  Database ← task
  Machine → (SELECT from hermes_bus via HTTPS DB connection)

Diagnostics:
  Machine runs fleet-doctor.sh locally (no API call needed)
  Machine INSERTs results to hermes_bus
```

### The Honest Truth

**You don't need a "gateway" service at all.**

Here's why:

```
Current Design (Wrong):
  Machine → Fleet Gateway (HTTPS) → Database (HTTPS)
  Problem: Two hops, extra service to run

Better Design (Your Intuition):
  Machine → Database (HTTPS, via Cloudflare)
  Database ← Message bus (hermes_bus)
  Coordinator ← Database (SELECT tasks)
  Problem: None. Just use DB directly.
```

### What You Actually Need

**NOT a gateway service. Just:**

1. **HTTPS database access** (exposed via Cloudflare proxy)
   - Fleet DB (hermes_fleet) accessible at: https://acceleratingdigital.com/fleet/db
   - Machines connect directly
   - Secured via DB credentials + TLS

2. **Coordinator running on laptop-m1** (or failover to another admin)
   - Hermes instance (personal work)
   - Runs crons: monitoring, updates, health checks
   - Queries DB directly
   - Sends tasks via hermes_bus INSERT

3. **Failover logic** (if m1 is down)
   - Any other admin machine can become coordinator
   - Just needs to run the same coordinator crons
   - Queries same DB
   - Takes over automatically

---

## The "Gateway" Misconception (My Mistake)

I proposed a fleet gateway service because I was thinking:
- "Users can't reach the database directly"
- "Need an intermediary"

But your architecture already solves this:
- ✅ Database is internet-accessible (via Cloudflare)
- ✅ Credentials are secure (tokens in ~/.fleet/config.yaml)
- ✅ No intermediary needed
- ✅ Machines talk directly to DB

**So we DELETE the "fleet gateway service" concept entirely.**

---

## Revised Architecture (Simpler & Better)

```
Old (Wrong):
  Machine ─HTTPS→ Fleet Gateway Service ─→ Database
                  (extra hop, extra service)

New (Correct):
  Machine ─HTTPS→ Database (via Cloudflare)
             (direct, no extra service)
  
  Coordinator (laptop-m1 or admin failover)
    ├─ Runs on existing Hermes
    ├─ Queries DB directly
    ├─ Sends tasks via hermes_bus
    └─ Monitors fleet health

  Failover:
    If laptop-m1 down → Another admin machine runs coordinator crons
    (Same DB, same queries, automatic takeover)
```

---

## What This Means

### What Goes Away

- ❌ No separate "fleet gateway service"
- ❌ No fleet.yourdomain.com HTTPS endpoint
- ❌ No need to expose Hermes on internet
- ❌ No extra service running on m1 or other machines

### What Stays (Simpler)

- ✅ Database exposed via Cloudflare (already done)
- ✅ Coordinator Hermes on laptop-m1 (for decisions/automation)
- ✅ Fleet credentials in ~/.fleet/config.yaml
- ✅ Machines INSERT/SELECT from hermes_bus (database messaging)
- ✅ File transfer via hermes_bus (already designed)
- ✅ Failover: Any admin can become coordinator

### Simplification

**Instead of:**
```
Setup fleet gateway service on m1
Setup failover fleet gateway on USA-M4P-PP
Monitor gateway health
Handle gateway restarts
Gateway logs, gateway crons
```

**Just:**
```
Coordinator Hermes (your personal work Hermes on m1)
If m1 down: Run coordinator crons on USA-M4P-PP manually or auto-trigger
Same DB, same messaging
Done
```

---

## Decision 1 — REVISED ANSWER

**Coordinator (not "gateway"):**
- Runs on laptop-m1 as part of your existing Hermes
- If m1 is unavailable: Any admin machine can SSH into DB and run coordinator crons manually
- OR: Set up a simple watchdog cron on USA-M4P-PP that checks if m1 is down and takes over

**No separate "gateway service" needed.**

---

## Decision 2: HTTPS & Cloudflare

**Your Answer:** "We use Cloudflare proxy for all traffic. Put fleet at https://acceleratingdigital.com/fleet"

**Perfect.** This eliminates the gateway entirely.

### Setup

```
https://acceleratingdigital.com/fleet/db
  └─ Routes to: 10.1.128.8:5432 (hermes_fleet database)
  └─ Credentials: fleet tokens stored in ~/.fleet/config.yaml
  └─ TLS: Cloudflare handles it (you already have it)

machines/scripts/fleet-register.sh:
  curl -X POST https://acceleratingdigital.com/fleet/db/api/register \
    -H "Authorization: Bearer $FLEET_TOKEN" \
    -d "hostname=$(hostname -s)"
```

**Nothing new to set up.** Cloudflare already does this.

---

## Decision 3: GitHub SSH Path

**Your Answer:** "I can setup and give a GitHub SSH path for the fleet"

**Perfect.** Use for large files.

### Setup

```
GitHub repo: github.com/yourcompany/fleet-releases (private or public)

Machines clone via:
  git clone git@github.com:yourcompany/fleet-releases.git
  cd fleet-releases/v2.4.1
  ./install.sh
  cd ..
  rm -rf fleet-releases

SSH key for machines:
  ✓ Generated during setup (fleet-join.sh)
  ✓ Stored in ~/.fleet/credentials/github-deploy-key
  ✓ Added to GitHub repo as deploy key (read-only)
  ✓ Can be rotated anytime
```

---

## Decision 4: LiteLLM on Internet

**Your Answer:** "LiteLLM needs to be exposed to public internet (currently Tailscale only)"

### Setup Required

**Currently:** LiteLLM at 10.1.2.13:4000 (internal Tailscale)

**Make it HTTPS:**

```
1. Expose LiteLLM behind Cloudflare
   https://acceleratingdigital.com/litellm/v1
   
   Cloudflare routes to: 10.1.2.13:4000 (LiteLLM proxy)

2. Add API key authentication
   All machines/coordinator requests include API key
   
   Example:
   curl https://acceleratingdigital.com/litellm/v1/chat/completions \
     -H "Authorization: Bearer LITELLM_API_KEY"
     -d "model=algolia/xlarge" \
     ...

3. Rate limiting (Cloudflare worker)
   Max 100 req/min per machine
   Prevents abuse

4. Store API key in ~/.fleet/config.yaml (machines)
   And in coordinator's Hermes config (for complex queries)
```

### Security Considerations

**Exposed to internet?**
- ✅ Yes, but protected by:
  - Cloudflare DDoS protection (free)
  - API key auth (required for all requests)
  - Rate limiting (Cloudflare)
  - TLS 1.3 (encrypted)
  - Geo-blocking (optional, if needed)

**Who can access?**
- Fleet machines (have API key)
- Coordinator (has API key)
- Public internet cannot use it (wrong API key = 401)

**Cost:**
- No additional cost (Cloudflare already there)
- LiteLLM usage (already happening, just now from internet instead of Tailscale)

---

## Decision 5: Memory Requirements & Burden

**Your Specs:**
- Lowest: Apple M1 with 16 GB RAM
- Others: Highest class (likely M3/M4 with 32+ GB)
- SharedMiniIntel: Not Apple Silicon

### What Fleet Services Use

#### Per Machine

**Fleet services running on each machine:**

```
1. Hermes daemon (existing, personal work)
   Memory: ~200-300 MB (baseline)
   
2. Ollama (fleet operations)
   Memory: ~1-2 GB (mistral:7b)
   CPU: 2-4 cores when running

3. Fleet scripts (heartbeat, poller)
   Memory: ~20-30 MB each
   CPU: Minimal (mostly idle)

4. Fleet gateway (if running on m1 as coordinator)
   Memory: ~300-400 MB
   CPU: Minimal (queries DB, no heavy work)

TOTAL PER MACHINE:
  Idle: ~2.5-3 GB
  Active (running query): ~3-4 GB
  M1 with 16 GB: Plenty (12+ GB free)
```

#### On Coordinator (laptop-m1)

**If m1 is also the coordinator:**

```
1. Hermes daemon (personal work)
   Memory: ~200-300 MB

2. Ollama (fleet operations)
   Memory: ~1-2 GB (mistral:7b)
   
3. Coordinator crons (monitoring, updates)
   Memory: ~100-200 MB (mostly idle)
   CPU: Runs every 15 min (short bursts)

4. Optional: algolia/xlarge for complex fleet tasks
   Memory: ~8-12 GB (if running)
   CPU: 4-8 cores when active
   (But runs infrequently, not always)

TOTAL IF m1 IS COORDINATOR:
  Idle: ~2.5-3 GB (without algolia)
  Running coordinator cron: ~3-4 GB
  Running algolia query: ~10-15 GB
  M1 with 16 GB: OK, but tight if multiple things run together
```

### Burden on Network

**Per Heartbeat:**

```
Heartbeat size: ~500 bytes
Frequency: Every 2 minutes
Data per hour: ~15 KB
Data per day: ~360 KB per machine

6 machines:
  Per day: ~2.2 MB
  Per month: ~66 MB

Impact: Negligible (network-wise)
```

**File Transfers:**

```
If sending logs (debugging):
  Typical log file: 1-10 MB
  Base64 encoding: +33% (overhead)
  Chunked into 1 MB pieces
  Sent over hermes_bus INSERT
  
Impact: Only when debugging (not continuous)
```

**Task Polling:**

```
Machines query hermes_bus: Every 30-60 seconds
  Query size: ~100 bytes
  Result size: Depends on tasks (0-1 MB usually)
  
6 machines polling every 60 sec:
  Per day: ~50 MB query traffic
  Per month: ~1.5 GB
  
Impact: Minimal (distributed load)
```

### SharedMiniIntel Specific

**Intel mini machine (older, less RAM):**

```
Typical config: 8-16 GB RAM
Running fleet services: Still fine
  2.5-3 GB for fleet = ~5-6 GB free

Concern: If you run both Hermes + Ollama + other work
  May need active memory management
  No deal-breaker
```

### Recommendations

#### For M1 with 16 GB (Coordinator)

```
Safe Setup:
  ✓ Hermes (personal): 300 MB
  ✓ Ollama (mistral:7b): 1.5 GB
  ✓ Coordinator crons: 200 MB
  ✓ Headroom: 13 GB free
  
Active Setup (running complex fleet task):
  ✓ Hermes + Ollama + algolia/xlarge: 10-12 GB
  ✓ Headroom: 4 GB free (OK, but conscious)
  
Recommendation:
  Run algolia queries only when needed (not continuous)
  If running complex task: Close unnecessary apps
  Otherwise: Plenty of room
```

#### For Higher-Class Machines (M3/M4 with 32+ GB)

```
No concern whatsoever.
  2.5-3 GB fleet services
  28+ GB free for other work
  Run whatever you want
```

#### For SharedMiniIntel (Intel, likely 8-16 GB)

```
Concern: Tight
Recommendation:
  ✓ Don't run algolia queries on this machine
  ✓ Keep Ollama (mistral:7b) loaded
  ✓ If running complex fleet task: Use m1 or other admin machine
  ✓ Monitor memory during setup, adjust if needed
```

### Monitoring & Adjustment

```
During setup, check:
  # On each machine
  hermes fleet health-check
  
  Reports:
    ✓ RAM available
    ✓ Disk available
    ✓ Ollama model loaded
    ✓ Fleet services running
    
If tight on any machine:
  ✓ Don't load full algolia model
  ✓ Use mistral:7b locally (lighter)
  ✓ Route heavy queries to m1 coordinator
```

---

## Summary of All Decisions (Final)

### 1. Gateway (REVISED)
**No separate gateway service needed.**
- Coordinator: laptop-m1 (or any admin if m1 down)
- Runs as part of your existing Hermes
- Queries DB directly
- Failover: Another admin takes over manually or via auto-cron

### 2. HTTPS
**Already handled by Cloudflare.**
- Fleet DB: https://acceleratingdigital.com/fleet/db
- Nothing new to set up
- TLS already handled

### 3. GitHub
**Use GitHub SSH for large files.**
- Fleet releases repo (your setup)
- Machines clone → install → delete
- Deploy key (read-only) per machine

### 4. LiteLLM
**Expose to internet via Cloudflare.**
- https://acceleratingdigital.com/litellm/v1
- API key auth
- Rate limiting
- No new infrastructure

### 5. Memory
**No issues.**
- M1 with 16 GB: Plenty of room
- Higher machines: No concern
- SharedMiniIntel: Monitor but OK
- Network burden: Negligible

---

## What Actually Needs to Be Built (Revised)

### Phase 1: One-Click Installer

```
fleet-join-setup.zip contains:
  ├─ fleet-join.sh (main installer)
  ├─ scripts/
  │  ├─ fleet-register.sh (register in DB)
  │  ├─ fleet-heartbeat.sh (send heartbeat)
  │  ├─ fleet-poller.sh (receive tasks)
  │  └─ fleet-doctor.sh (diagnostics)
  │
  ├─ LaunchAgents/
  │  ├─ com.fleet.heartbeat.plist (every 2 min)
  │  └─ com.fleet.poller.plist (every 60 sec)
  │
  └─ resources/
     ├─ hermes binary
     └─ ollama binary

Setup process:
  1. Download zip from https://acceleratingdigital.com/fleet/download
  2. Unzip
  3. Double-click fleet-join.sh
  4. Answer 3 questions
  5. Done
```

### Phase 2: Coordinator Crons

```
On laptop-m1 (your Hermes):

Cron 1: Monitor fleet (every 15 min)
  ├─ Query fleet_status
  ├─ Check for stale heartbeats
  ├─ Alert if issues
  └─ Log to database

Cron 2: Research updates (daily)
  ├─ Check Hermes releases
  ├─ Decide on version
  ├─ Create update task

Cron 3: Deploy updates (on schedule)
  ├─ Test on canary (m1 first)
  ├─ Rollout to always-on
  ├─ Rollout to transient
  └─ Track success/failure

Cron 4: Failover monitor (every 5 min)
  ├─ Check if m1 is up
  ├─ If down: Alert admin
  ├─ Other admin can take over
```

### Phase 3: Database Changes

```
New tables/columns (minimal):
  ├─ fleet_config (settings, retention policy)
  ├─ fleet_events_log (long-term history)
  └─ Update fleet_directives (add classification: always-on/transient)

Cleanup jobs:
  ├─ Delete hermes_bus older than 7 days
  ├─ Archive fleet_status (keep latest per machine)
  ├─ Rotate fleet_events_log (keep 90 days)
```

### Phase 4: LiteLLM Exposure (Optional, Can Wait)

```
If complex fleet tasks need algolia:
  1. Cloudflare route to 10.1.2.13:4000
  2. Add API key auth
  3. Rate limiting
  4. Tell machines the URL + API key
```

---

## Timeline

**Week 1:**
- [ ] Build fleet-join-setup.zip (installer)
- [ ] Test on laptop-m1
- [ ] Test on 1 member machine (SharedMiniIntel)

**Week 2:**
- [ ] Deploy to all 6 machines
- [ ] Verify heartbeats + polling
- [ ] Test file transfer (DB + GitHub)

**Week 3:**
- [ ] Set up coordinator crons
- [ ] Test update workflow (canary → rollout)
- [ ] Set up failover logic

**Week 4 (Optional):**
- [ ] Expose LiteLLM to internet
- [ ] Test complex fleet tasks

---

## Next Steps

Ready to build Phase 1 (one-click installer)?

I'll create:
1. `fleet-join.sh` script (full automation)
2. Supporting scripts (register, heartbeat, poller, doctor)
3. LaunchAgent plist files (daemons)
4. ZIP assembly script

Should we start?

