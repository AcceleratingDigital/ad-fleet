# AD-Fleet

AcceleratingDigital Fleet — multi-machine Hermes fleet management system.

## Structure
- `admin/` — Admin installer + scripts (admin machines only)
- `member/` — Member installer + scripts (member machines only)
- `shared/` — Scripts and LaunchAgents used by both admin and member
- `skills/ad-fleet-manager/` — Hermes skill for fleet management (admin machines)
- `docs/` — Architecture and operations docs

## Install
- Admin: download `ad-fleet-admin-v4.zip`, unzip, run `bash admin/ad-fleet-join-admin.sh`
- Member: download `ad-fleet-member-v4.zip`, unzip, run `bash member/ad-fleet-join-member.sh`

## Updates
Push updates to this repo. Fleet machines pull via `git pull` triggered by poller tasks.
