# CoBroker Config Backup

Full snapshot of `/data/` from the live Fly machine (`cobroker-openclaw`). Refreshed weekly — each run **replaces all contents** with the latest state.

## What this is

This directory is a 1:1 copy of everything on the Fly volume at `/data/`. It includes:

- **Config**: `openclaw.json`, `AGENTS.md`, `SOUL.md`
- **Skills**: `skills/cobroker-client-memory/`, `skills/cobroker-projects/`, `skills/cobroker-plan/`
- **Cron**: `cron/jobs.json`
- **Startup scripts**: `start.sh`, `log-forwarder.js`
- **Sessions**: `agents/main/sessions/` (conversation transcripts + skill snapshots)
- **Credentials**: `credentials/`, `identity/`, `devices/` (Telegram auth, device keys, tokens)
- **Runtime state**: `log-cursor.json`, `telegram/`, `subagents/`, `canvas/`

## How to refresh

Run from the repo root (`~/Projects/openclaw`):

```bash
# 1. Download /data/ as a tarball
fly ssh console -C "sh -c 'cd /data && tar czf - .'" > /tmp/fly-data-snapshot.tar.gz

# 2. Wipe old backup and extract fresh snapshot (preserves this README)
cd cobroker-config-backup
find . -not -name 'README.md' -not -name '.' -not -name '..' -delete
cd ..
tar xzf /tmp/fly-data-snapshot.tar.gz -C cobroker-config-backup/

# 3. Commit
git add cobroker-config-backup/
git commit -m "backup: refresh /data/ snapshot $(date +%Y-%m-%d)"
git push
```

## Schedule

Run this roughly **once a week** or after any significant config/skill changes on the Fly machine.

## Two directories, two purposes

| Directory | Direction | Purpose |
|-----------|-----------|---------|
| `fly-scripts/` | **Push to Fly** | Source of truth for deployment. Scripts and skills that get uploaded. |
| `cobroker-config-backup/` | **Pull from Fly** | Full backup of `/data/` including runtime state. |

## Sensitive files

This backup contains credentials and private keys:

- `identity/device.json` — Ed25519 private key
- `identity/device-auth.json` — operator auth tokens
- `devices/paired.json` — operator auth tokens
- `credentials/telegram-pairing.json` — Telegram pairing code

**Keep this repo private.**
