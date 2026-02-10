# CoBroker OpenClaw — Fly.io Deployment Wiki

> **Purpose**: Complete reference for deploying CoBroker-customized OpenClaw instances to Fly.io. Written from hands-on experience on 2026-02-10. Intended for future automation of multi-tenant VM provisioning.
>
> **Source repo**: Fork of [openclaw/openclaw](https://github.com/openclaw/openclaw) at `isaacherrera/openclaw`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step-by-Step Deployment](#3-step-by-step-deployment)
4. [Post-Deploy Configuration via SSH](#4-post-deploy-configuration-via-ssh)
5. [Configuration File Reference](#5-configuration-file-reference)
6. [Gotchas & Lessons Learned](#6-gotchas--lessons-learned)
7. [Automation Checklist](#7-automation-checklist)
8. [Management & Operations](#8-management--operations)
9. [Real-Time Log Forwarding](#9-real-time-log-forwarding)
10. [Cost Reference](#10-cost-reference)
11. [Appendix: Full File Contents](#11-appendix-full-file-contents)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────┐
│  Fly.io Machine (shared-cpu-2x, 2GB RAM)    │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │  OpenClaw Gateway (Node.js, PID 1)  │    │
│  │  - Port 3000 (LAN-bound)           │    │
│  │  - Claude Opus 4.6 via Anthropic   │    │
│  │  - Telegram bot polling            │    │
│  └──────────┬──────────────────────────┘    │
│             │ writes JSONL                  │
│  ┌──────────▼──────────────────────────┐    │
│  │  /data (1GB encrypted volume)       │    │
│  │  ├── openclaw.json                  │    │
│  │  ├── AGENTS.md / SOUL.md            │    │
│  │  ├── credentials/                   │    │
│  │  ├── skills/                        │    │
│  │  ├── cron/jobs.json                 │    │
│  │  ├── start.sh           ← startup  │    │
│  │  ├── log-forwarder.js   ← watcher  │    │
│  │  ├── log-cursor.json    ← offsets   │    │
│  │  └── agents/main/sessions/*.jsonl   │    │
│  └──────────┬──────────────────────────┘    │
│             │ reads JSONL                   │
│  ┌──────────▼──────────────────────────┐    │     ┌──────────────────────────┐
│  │  Log Forwarder (background process) │    │     │  cobroker.ai (Vercel)    │
│  │  - Polls every 3s                   │────│────▶│  POST /api/openclaw-logs │
│  │  - Tracks byte offsets per file     │    │     │  → Supabase openclaw_logs│
│  │  - Batches & POSTs all new lines    │    │     │                          │
│  └─────────────────────────────────────┘    │     │  /admin/openclaw-logs    │
│                                             │     │  (real-time dashboard)   │
└─────────────────────────────────────────────┘     └──────────────────────────┘
```

**Key design constraints:**
- Fly volumes are pinned to **one machine in one region** — no horizontal scaling or multi-region
- Each user/tenant gets their own Fly app with their own volume
- The Dockerfile builds from `node:22-bookworm`, runs as non-root `node` user (uid 1000)
- Gateway binds to LAN (`--bind lan`) for Fly proxy compatibility

---

## 2. Prerequisites

### Tools
```bash
# Install flyctl (macOS)
brew install flyctl

# Verify
fly version
# fly v0.4.8 darwin/arm64

# Authenticate (opens browser)
fly auth login
```

### Required Secrets Per Tenant
| Secret | Required | Source |
|--------|----------|--------|
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Auto-generated: `openssl rand -hex 32` |
| `ANTHROPIC_API_KEY` | Yes | https://console.anthropic.com/settings/keys |
| `TELEGRAM_BOT_TOKEN` | Yes (if Telegram) | @BotFather on Telegram |
| `COBROKER_API_URL` | For CoBroker skills | e.g., `https://app.cobroker.ai` |
| `COBROKER_API_KEY` | For CoBroker skills | CoBroker admin panel |
| `COBROKER_USER_ID` | For CoBroker skills | CoBroker user UUID |
| `OPENCLAW_LOG_SECRET` | For log forwarding | Shared secret with Vercel: `openssl rand -hex 32` |

### Per-Tenant Parameters
| Parameter | Example | Notes |
|-----------|---------|-------|
| `APP_NAME` | `cobroker-openclaw` | Must be globally unique on Fly.io |
| `REGION` | `iad` | US East; see `fly platform regions` |
| `TELEGRAM_USER_ID` | `8411700555` | Numeric Telegram user ID for allowlist |
| `BOT_USERNAME` | `@CobrokerIsaacBot` | Created via @BotFather |

---

## 3. Step-by-Step Deployment

### 3.1 Clone and Configure

```bash
git clone https://github.com/isaacherrera/openclaw.git
cd openclaw
```

**Edit `fly.toml` — only ONE line needs to change:**
```toml
app = "TENANT_APP_NAME"        # <-- Change this (must be globally unique)
primary_region = "iad"          # <-- Already correct for US East
```

Everything else in `fly.toml` is already correct:
- Process command: `sh /data/start.sh` (runs log forwarder in background, then `exec`s gateway)
- VM: `shared-cpu-2x`, `2048mb`
- Volume: `openclaw_data` → `/data`
- `auto_stop_machines = false` (keeps bot always-on)
- `NODE_OPTIONS = "--max-old-space-size=1536"`

> **IMPORTANT**: Do NOT copy `fly.private.toml` over `fly.toml`. The private config removes the `[http_service]` block which we need for the public deployment.

### 3.2 Create App and Volume

```bash
# Create the app (reads app name from fly.toml)
fly apps create TENANT_APP_NAME

# Create persistent encrypted volume (1GB is sufficient)
fly volumes create openclaw_data --size 1 --region iad -y
```

> **Note**: No `-a` flag needed when running from the project directory — flyctl reads `fly.toml` automatically.

### 3.3 Set Secrets

```bash
# Gateway token (auto-generate)
fly secrets set OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)

# Anthropic API key
fly secrets set ANTHROPIC_API_KEY=sk-ant-...

# Telegram bot token (from @BotFather)
fly secrets set TELEGRAM_BOT_TOKEN=...

# CoBroker API credentials (optional, for CoBroker skills)
fly secrets set COBROKER_API_URL=https://app.cobroker.ai
fly secrets set COBROKER_API_KEY=...
fly secrets set COBROKER_USER_ID=...
```

> **Timing**: Set ALL secrets before deploying if possible. Each `fly secrets set` after deployment triggers a machine restart.

### 3.4 Deploy

```bash
fly deploy
```

**Expected output (key milestones):**
- `Building image with Depot` — Docker build starts
- `image size: 1.3 GB` — build complete
- `Provisioning ips` — gets IPv4 (shared) and IPv6 (dedicated)
- `Machine XXXX [app] update finished: success` — machine running

**Expected warning (safe to ignore):**
```
WARNING The app is not listening on the expected address
```
This appears because the gateway takes ~30s to fully start. It resolves itself.

**First deploy takes ~3-5 minutes** (Docker build + image push). Subsequent deploys with cached layers are faster.

### 3.5 Verify

```bash
fly status                        # Machine state: "started"
fly logs --no-tail                # Check for crash loops
fly ssh console -C "ls /data"     # Volume mounted and writable
```

**Healthy log output should include:**
```
[gateway] agent model: anthropic/claude-opus-4-6
[gateway] listening on ws://0.0.0.0:3000
[telegram] [default] starting provider (@BotUsername)
```

---

## 4. Post-Deploy Configuration via SSH

After deployment, the machine is running but unconfigured. All configuration files go in `/data/` (the persistent volume).

### 4.1 SSH Command Patterns

**CRITICAL — Fly SSH Gotchas:**

| Pattern | Works? | Notes |
|---------|--------|-------|
| `fly ssh console` | Yes | Interactive shell |
| `fly ssh console -C "simple command"` | Yes | Single command |
| `fly ssh console -C "cmd > file"` | **NO** | Redirect not supported |
| `fly ssh console -C "sh -c 'cmd > file'"` | **YES** | Wrap in sh -c for redirects |
| `fly ssh console -C "cat << 'EOF' ..."` | **NO** | Heredocs not supported |
| Base64 transfer (see below) | **YES** | Best for file content |

**File transfer pattern (base64 encode/decode):**
```bash
# Write a local file to the remote machine
B64=$(base64 < /path/to/local/file)
fly ssh console -C "sh -c 'echo $B64 | base64 -d > /data/remote/path'"
```

**File ownership fix:**
Files created via SSH are owned by `root`. The app runs as `node` (uid 1000). Always fix ownership after creating files:
```bash
fly ssh console -C "sh -c 'chown -R node:node /data/AGENTS.md /data/SOUL.md /data/skills/'"
```

> Files in `/data/credentials/` and `/data/openclaw.json` are created by the gateway process itself and are already owned by `node`.

### 4.2 Create Directory Structure

```bash
fly ssh console -C "sh -c 'mkdir -p /data/skills/cobroker-site-selection /data/skills/cobroker-property-search /data/skills/cobroker-client-memory /data/skills/cobroker-alerts'"
```

### 4.3 Write Configuration Files

Write each file using the base64 transfer pattern. The files to create are:

1. `/data/openclaw.json` — Main configuration (see Section 5)
2. `/data/AGENTS.md` — Agent personality
3. `/data/SOUL.md` — Agent tone/vibe
4. `/data/skills/cobroker-site-selection/SKILL.md`
5. `/data/skills/cobroker-property-search/SKILL.md`
6. `/data/skills/cobroker-client-memory/SKILL.md`
7. `/data/skills/cobroker-alerts/SKILL.md`
8. `/data/cron/jobs.json` — Scheduled jobs

See [Appendix: Full File Contents](#10-appendix-full-file-contents) for exact content of each file.

### 4.4 Fix Ownership and Restart

```bash
# Fix ownership for files created via SSH
fly ssh console -C "sh -c 'chown -R node:node /data/AGENTS.md /data/SOUL.md /data/skills/'"

# Restart to load new config
fly apps restart
```

### 4.5 Verify Configuration

```bash
# All files present
fly ssh console -C "sh -c 'ls -la /data/AGENTS.md /data/SOUL.md /data/openclaw.json /data/cron/jobs.json && ls -la /data/skills/*/SKILL.md'"

# Config content correct
fly ssh console -C "cat /data/openclaw.json"

# Telegram connected (check logs)
fly logs --no-tail | tail -15
# Should see: [telegram] [default] starting provider (@BotUsername)
```

---

## 5. Configuration File Reference

### 5.1 openclaw.json — The Critical Details

```json
{
  "logging": {
    "level": "info",
    "redactSensitive": "tools"
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto"
  },
  "session": {
    "scope": "per-sender",
    "reset": {
      "mode": "daily",
      "atHour": 4
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "allowlist",
      "allowFrom": ["TELEGRAM_USER_ID"],
      "groupPolicy": "disabled",
      "streamMode": "partial"
    }
  },
  "skills": {
    "load": {
      "extraDirs": ["/data/skills"]
    }
  },
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      }
    }
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      }
    }
  },
  "meta": {
    "lastTouchedVersion": "2026.2.9",
    "lastTouchedAt": "2026-02-10T16:40:00.000Z"
  }
}
```

### 5.2 Key Configuration Fields

| Field | Value | Why |
|-------|-------|-----|
| `channels.telegram.dmPolicy` | `"allowlist"` | **USE THIS, NOT "pairing"** (see Gotcha #2) |
| `channels.telegram.allowFrom` | `["USER_ID"]` | Numeric Telegram user ID as string |
| `channels.telegram.streamMode` | `"partial"` | Streams responses as they generate |
| `plugins.entries.telegram.enabled` | `true` | **MUST be true** (see Gotcha #1) |
| `skills.load.extraDirs` | `["/data/skills"]` | Points to custom skill directory |
| `session.scope` | `"per-sender"` | Each user gets their own session |
| `session.reset.atHour` | `4` | Sessions reset at 4 AM |

### 5.3 How the Gateway Modifies openclaw.json

**IMPORTANT**: The OpenClaw gateway process **auto-modifies** `openclaw.json` on first boot. If you write a minimal config, the gateway will merge in defaults like:
- `commands.native`
- `agents.defaults`
- `messages.ackReactionScope`
- `plugins.entries`
- `meta.lastTouchedVersion`

This is why we saw `plugins.entries.telegram.enabled: false` appear — the gateway added it as a default. **Always include `plugins.entries.telegram.enabled: true` explicitly in your config to prevent this.**

---

## 6. Gotchas & Lessons Learned

### Gotcha #1: `plugins.entries.telegram.enabled: false` (CRITICAL)

**Symptom**: Telegram bot connects but no `[telegram]` log lines appear. Bot doesn't respond.

**Cause**: The OpenClaw gateway auto-generates default config on first boot. It adds `plugins.entries.telegram.enabled: false` by default, which **overrides** `channels.telegram.enabled: true`.

**Fix**: Always explicitly include in `openclaw.json`:
```json
"plugins": {
  "entries": {
    "telegram": {
      "enabled": true
    }
  }
}
```

**For automation**: Write the complete `openclaw.json` (with this field) BEFORE the first restart, or write it and immediately restart.

### Gotcha #2: Pairing Mode Doesn't Work Reliably

**Symptom**: `openclaw pairing approve telegram CODE` succeeds (writes to `/data/credentials/telegram-allowFrom.json`), but the next message still triggers a new pairing request.

**Cause**: The `pairing approve` command runs as a **separate Node.js process**. It writes to the file, but the **running gateway process** doesn't watch for file changes — its in-memory allowlist is stale.

**Log evidence**: After approval, logs still show `"matchKey":"none","matchSource":"none"` → `"telegram pairing request"`.

**Fix**: Use `dmPolicy: "allowlist"` instead of `"pairing"` and hardcode the user's Telegram ID in `allowFrom`:
```json
"channels": {
  "telegram": {
    "dmPolicy": "allowlist",
    "allowFrom": ["8411700555"]
  }
}
```

**For automation**: Always use `allowlist` mode. Get the user's Telegram ID upfront (they can find it via @userinfobot or similar).

### Gotcha #3: SSH File Transfer

**Symptom**: `fly ssh console -C "cat << 'EOF' > /data/file ..."` fails with `cat: '<<': No such file or directory`.

**Cause**: The `-C` flag passes arguments directly to the remote process, not through a shell. No heredocs, no redirects, no pipes.

**Fix**: Two patterns that work:
```bash
# Pattern 1: sh -c wrapper (for simple content)
fly ssh console -C "sh -c 'printf \"%s\" \"content\" > /data/file'"

# Pattern 2: base64 encode/decode (for any content, recommended)
B64=$(base64 < local-file)
fly ssh console -C "sh -c 'echo $B64 | base64 -d > /data/remote-file'"
```

### Gotcha #4: File Ownership

**Symptom**: Files created via SSH are owned by `root:root`, but the app runs as `node:node` (uid 1000).

**Cause**: SSH sessions run as root on Fly machines.

**Fix**: Always chown after creating files:
```bash
fly ssh console -C "sh -c 'chown -R node:node /data/path'"
```

**Exception**: `/data/openclaw.json` and `/data/credentials/*` are created by the gateway process itself and are already owned by `node`.

### Gotcha #5: Secrets Trigger Restarts

**Symptom**: Setting secrets one at a time causes multiple machine restarts.

**Cause**: Each `fly secrets set` triggers a machine restart to inject the new env var.

**Fix**: Set all secrets in one command:
```bash
fly secrets set \
  OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32) \
  ANTHROPIC_API_KEY=sk-ant-... \
  TELEGRAM_BOT_TOKEN=...
```

### Gotcha #6: Cron Jobs Showing 0 Jobs

**Observed**: Logs showed `cron: started` with `jobs: 0` even though `/data/cron/jobs.json` had a valid job definition.

**Likely cause**: The cron job format may require additional fields, or the gateway needs a restart after the file is written. This needs further investigation for automation.

### Gotcha #7: "Not Listening on Expected Address" Warning

**Symptom**: Deploy shows `WARNING The app is not listening on the expected address`.

**Cause**: The gateway takes ~30 seconds to fully start (loading plugins, connecting to Telegram, etc.). Fly's deploy health check runs before it's ready.

**Impact**: None — the bot works fine after startup completes. This is cosmetic.

### Gotcha #8: Don't Use `-a` Flag Unnecessarily

When running commands from the project directory (where `fly.toml` lives), flyctl reads the app name automatically. The `-a` flag is only needed when running commands from outside the directory.

### Gotcha #9: `redactSensitive` Only Accepts `"off"` or `"tools"`

**Symptom**: Gateway crashes in a restart loop immediately after boot. Logs show `Invalid config` or Zod validation errors.

**Cause**: Setting `"redactSensitive": "none"` in `openclaw.json`. The config schema (defined in `src/config/zod-schema.ts:186` and `src/logging/redact.ts:6`) only accepts two values:

| Value | Behavior |
|-------|----------|
| `"tools"` (default) | Redacts sensitive tokens in console tool summaries only |
| `"off"` | No redaction at all |

**Fix**: Use `"off"` instead of `"none"`:
```json
"logging": {
  "level": "debug",
  "redactSensitive": "off"
}
```

**For automation**: Always validate config values against the schema before writing. `"none"` is a common guess but will crash the gateway.

---

## 7. Automation Checklist

For creating a new tenant VM programmatically:

```
INPUT PARAMETERS:
  - APP_NAME          (globally unique, e.g., "cobroker-{username}")
  - REGION            (e.g., "iad")
  - ANTHROPIC_API_KEY
  - TELEGRAM_BOT_TOKEN
  - TELEGRAM_USER_ID  (numeric)
  - COBROKER_API_URL  (optional)
  - COBROKER_API_KEY  (optional)
  - COBROKER_USER_ID  (optional)
```

### Automation Script Pseudocode

```bash
#!/bin/bash
set -euo pipefail

APP_NAME=$1
REGION=$2
TELEGRAM_USER_ID=$3
# ... other params

# 1. Clone repo (or use existing checkout)
cd /path/to/openclaw

# 2. Modify fly.toml
sed -i "s/^app = .*/app = \"${APP_NAME}\"/" fly.toml
sed -i "s/^primary_region = .*/primary_region = \"${REGION}\"/" fly.toml

# 3. Create app and volume
fly apps create "$APP_NAME"
fly volumes create openclaw_data --size 1 --region "$REGION" -y

# 4. Set ALL secrets in one call (avoids multiple restarts)
fly secrets set \
  OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32) \
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  COBROKER_API_URL="$COBROKER_API_URL" \
  COBROKER_API_KEY="$COBROKER_API_KEY" \
  COBROKER_USER_ID="$COBROKER_USER_ID"

# 5. Deploy
fly deploy

# 6. Wait for machine to stabilize
sleep 30

# 7. Create directories
fly ssh console -C "sh -c 'mkdir -p /data/skills/cobroker-site-selection /data/skills/cobroker-property-search /data/skills/cobroker-client-memory /data/skills/cobroker-alerts'"

# 8. Generate openclaw.json with tenant-specific values
#    CRITICAL: Include plugins.entries.telegram.enabled: true
#    CRITICAL: Use dmPolicy: "allowlist" with user's Telegram ID
cat > /tmp/openclaw-config.json << JSONEOF
{
  "logging": {"level": "info", "redactSensitive": "tools"},
  "commands": {"native": "auto", "nativeSkills": "auto"},
  "session": {"scope": "per-sender", "reset": {"mode": "daily", "atHour": 4}},
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "allowlist",
      "allowFrom": ["${TELEGRAM_USER_ID}"],
      "groupPolicy": "disabled",
      "streamMode": "partial"
    }
  },
  "skills": {"load": {"extraDirs": ["/data/skills"]}},
  "agents": {"defaults": {"maxConcurrent": 4, "subagents": {"maxConcurrent": 8}}},
  "messages": {"ackReactionScope": "group-mentions"},
  "plugins": {"entries": {"telegram": {"enabled": true}}},
  "meta": {"lastTouchedVersion": "2026.2.9"}
}
JSONEOF

# 9. Transfer all files via base64
for file in openclaw-config.json AGENTS.md SOUL.md; do
  B64=$(base64 < /tmp/$file)
  DEST="/data/$file"
  [ "$file" = "openclaw-config.json" ] && DEST="/data/openclaw.json"
  fly ssh console -C "sh -c 'echo $B64 | base64 -d > $DEST'"
done

# Transfer skill files
for skill in cobroker-site-selection cobroker-property-search cobroker-client-memory cobroker-alerts; do
  B64=$(base64 < /path/to/skills/$skill/SKILL.md)
  fly ssh console -C "sh -c 'echo $B64 | base64 -d > /data/skills/$skill/SKILL.md'"
done

# Transfer cron jobs
B64=$(base64 < /path/to/cron/jobs.json)
fly ssh console -C "sh -c 'echo $B64 | base64 -d > /data/cron/jobs.json'"

# 10. Fix ownership
fly ssh console -C "sh -c 'chown -R node:node /data/AGENTS.md /data/SOUL.md /data/skills/'"

# 11. Restart to load everything
fly apps restart

# 12. Verify
sleep 15
fly logs --no-tail | tail -5
# Should see: [telegram] [default] starting provider (@BotUsername)

echo "✅ Deployed: https://${APP_NAME}.fly.dev/"
```

### Critical Order of Operations

1. **fly.toml** must be edited BEFORE `fly apps create`
2. **All secrets** should be set BEFORE `fly deploy` (avoids extra restarts)
3. **openclaw.json** must include `plugins.entries.telegram.enabled: true` BEFORE restart
4. **allowFrom** must include user's Telegram ID (use allowlist, not pairing)
5. **chown** must run AFTER file creation, BEFORE restart
6. **Restart** must happen AFTER all files are written

---

## 8. Management & Operations

### Daily Operations

```bash
# Check health
fly status
fly logs --no-tail | tail -20

# Interactive SSH
fly ssh console

# Run a command remotely
fly ssh console -C "sh -c 'cat /data/openclaw.json'"

# Restart (picks up config changes)
fly apps restart

# View secrets (names only, not values)
fly secrets list
```

### Viewing Conversation Logs

There are three ways to view what the bot is doing. Each shows different levels of detail.

#### Method 1: Fly CLI Logs (quick health check)

Shows gateway-level events — startup, Telegram connection, errors. No message content.

```bash
fly logs --no-tail | tail -30
```

#### Method 2: Gateway Log File (tool calls, run durations, raw Telegram updates)

JSON log file on the machine. Shows debug-level detail: run IDs, tool call start/end, session state transitions, and raw Telegram update payloads (including message text). Rolling daily files.

```bash
# Tail recent entries
fly ssh console -C "sh -c 'tail -30 /tmp/openclaw/openclaw-*.log'"

# Search for a specific message
fly ssh console -C "sh -c 'grep -i \"search term\" /tmp/openclaw/openclaw-*.log'"
```

**Note**: These logs are in `/tmp/` and do NOT persist across machine restarts.

#### Method 3: Session Transcripts (full conversation content — BEST)

JSONL files with complete conversation history: every user message, assistant response, tool calls, tool results, and token usage. This is the richest source of conversation data.

**Location**: `/data/agents/{agentId}/sessions/{sessionId}.jsonl`

```bash
# List all session files
fly ssh console -C "sh -c 'find /data/agents -name \"*.jsonl\" -type f'"

# Read a specific session transcript
fly ssh console -C "sh -c 'cat /data/agents/main/sessions/*.jsonl'"

# Pretty-print and extract just user/assistant messages (via jq)
fly ssh console -C "sh -c 'cat /data/agents/main/sessions/*.jsonl | grep \"\\\"type\\\":\\\"message\\\"\" | head -20'"
```

**Key fields in each JSONL line**:
- `type: "message"` — user or assistant message
- `message.role` — `"user"` or `"assistant"`
- `message.content` — array of text blocks, tool calls, or tool results
- `usage` — token counts and cost (on assistant messages)
- `stopReason` — `"stop"` (complete) or `"toolUse"` (mid-tool-call)

**These files persist across restarts** (stored on the `/data` volume), unlike the gateway log file.

### Volume Management

```bash
# List volumes
fly volumes list

# Check snapshots (Fly takes daily automatic snapshots)
fly volumes snapshots list

# Restore from snapshot (creates new volume)
fly volumes create openclaw_data --snapshot-id <SNAPSHOT_ID> --size 1 --region iad
```

### Updating the Bot

```bash
# Pull latest OpenClaw and redeploy
git pull upstream main
fly deploy
# Config files in /data/ persist across deploys (volume is not rebuilt)
```

### Scaling (Future)

Current architecture is **single-machine, single-region**. For multi-tenant:
- Each tenant gets their own Fly app (separate billing, isolation)
- Apps can be in different regions based on user location
- No shared state between tenants

---

## 9. Real-Time Log Forwarding

Session transcripts (JSONL) are the richest data source but live on the Fly machine. To get **real-time visibility** into what the agent is doing, we forward all JSONL entries to the CoBroker dashboard at `cobroker.ai/admin/openclaw-logs`.

### 9.1 How It Works

1. **OpenClaw writes JSONL** — every message, tool call, tool result, model change, and error is appended to `/data/agents/main/sessions/{sessionId}.jsonl`
2. **`log-forwarder.js` polls every 3s** — scans all `*.jsonl` files, reads new bytes since last offset
3. **Batches and POSTs** to `https://app.cobroker.ai/api/openclaw-logs` with Bearer token auth
4. **Vercel API route** parses each entry, extracts structured fields (role, content, thinking, tool name, tokens, cost), and bulk inserts into Supabase `openclaw_logs` table
5. **Admin dashboard** at `/admin/openclaw-logs` polls every 5s, showing a color-coded chronological feed

### 9.2 What Gets Forwarded (Everything)

| JSONL Type | What It Contains |
|------------|------------------|
| `message` role=`user` | User's message (from Telegram) |
| `message` role=`assistant` | AI response: text, thinking blocks (with signature), toolCall blocks |
| `message` role=`toolResult` | Tool execution output (success or failure) |
| `model_change` | Which LLM model was selected |
| `thinking_level_change` | AI thinking mode (low/medium/high) |
| `custom` (`model-snapshot`) | Full model config snapshot |
| `custom` (`openclaw.cache-ttl`) | Cache state between turns |

Each assistant message also includes: `usage` (input/output/cache tokens + cost breakdown), `stopReason`, `model`, `provider`.

### 9.3 Files on Fly Machine

| File | Purpose |
|------|---------|
| `/data/start.sh` | Startup wrapper — runs forwarder in background, then `exec`s gateway as PID 1 |
| `/data/log-forwarder.js` | Zero-dependency Node.js JSONL watcher (~140 lines) |
| `/data/log-cursor.json` | Auto-managed byte offsets per file (don't edit manually) |

Source files in repo: `fly-scripts/log-forwarder.js`, `fly-scripts/start.sh`

### 9.4 Files on Vercel (cobroker.ai)

| File | Purpose |
|------|---------|
| `app/api/openclaw-logs/route.ts` | POST: receives batched entries (Bearer auth). GET: serves logs to dashboard (admin auth) |
| `app/admin/openclaw-logs/page.tsx` | Server component with Clerk admin gate |
| `app/admin/openclaw-logs/components/OpenClawLogsUI.tsx` | Real-time log viewer (~810 lines) |

### 9.5 Supabase Table

```sql
CREATE TABLE openclaw_logs (
  id BIGSERIAL PRIMARY KEY,
  entry_id TEXT, parent_id TEXT, session_id TEXT,
  type TEXT NOT NULL, subtype TEXT, role TEXT,
  content TEXT, thinking TEXT,
  tool_name TEXT, tool_call_id TEXT,
  model TEXT, provider TEXT, stop_reason TEXT,
  token_input INT, token_output INT,
  token_cache_read INT, token_cache_write INT,
  tokens_total INT, cost_total NUMERIC(10,6),
  is_error BOOLEAN DEFAULT FALSE,
  raw JSONB NOT NULL,
  entry_timestamp TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- RLS disabled (matches project convention — security at app layer)
```

### 9.6 Auth

A shared secret (`OPENCLAW_LOG_SECRET`) is set as an env var on **both** Fly and Vercel:
- **Forwarder** sends: `Authorization: Bearer <secret>` header
- **API route** validates the header before inserting
- **Dashboard GET** uses Clerk admin auth (only `isaac@cobroker.ai`)
- The `/api/openclaw-logs` route is added to Clerk middleware's public routes list (POST uses Bearer, not Clerk)

### 9.7 Cursor Safety

The forwarder **only advances byte offsets after a successful HTTP 200** from the API. If the POST fails (network error, 500, auth failure), it retries from the same offset next cycle. Nothing is lost.

If a JSONL file is truncated (e.g., session reset), the forwarder detects `fileSize < storedOffset` and resets to 0.

### 9.8 Dashboard Features

- **Chronological feed** — all events in order with color-coded left borders
- **Entry types**: blue (user), purple (assistant), gray (thinking), amber (tool call), green/red (tool result), system badges (model change)
- **Auto-refresh** — polls every 5s for new entries, auto-scrolls when at bottom
- **Session filter** — dropdown to filter by session ID
- **Stats bar** — running totals for entries, tokens, and cost
- **Raw JSON toggle** — expand any entry to see the full JSONL line
- **Collapsible thinking** — AI reasoning blocks collapsed by default

### 9.9 Updating the Forwarder

To update `log-forwarder.js` after changes:

```bash
# Upload new version
fly ssh console -C "sh -c 'cat > /data/log-forwarder.js'" < fly-scripts/log-forwarder.js
fly ssh console -C "sh -c 'chown node:node /data/log-forwarder.js'"

# Restart to pick up changes (forwarder runs as background process)
fly apps restart
```

The cursor file (`/data/log-cursor.json`) persists across restarts — the forwarder resumes from where it left off.

### 9.10 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `API responded 405` | Vercel API route not deployed yet | Push Vercel project and wait for deploy |
| `API responded 401` | Secret mismatch between Fly and Vercel | Verify `OPENCLAW_LOG_SECRET` matches on both sides |
| `API responded 500` | Supabase table missing or schema mismatch | Run the SQL migration in Supabase dashboard |
| No entries in dashboard | Forwarder not running | Check `fly logs` for `[log-forwarder]` startup messages |
| Duplicate entries | Cursor file deleted/corrupted | Delete `/data/log-cursor.json` — will re-forward all entries (API should handle gracefully via `entry_id` uniqueness) |
| Dashboard shows "Unauthorized" | Not logged in as admin | Must be signed in as `isaac@cobroker.ai` |

---

## 10. Cost Reference

| Resource | Spec | Monthly Cost |
|----------|------|-------------|
| Machine | `shared-cpu-2x`, 2GB RAM, always-on | ~$11 |
| Volume | 1GB encrypted | ~$0.15 |
| Bandwidth | Included (reasonable usage) | $0 |
| IPv4 | Shared | $0 |
| IPv6 | Dedicated | $0 |
| **Total per tenant** | | **~$11.15/mo** |

Fly.io offers a free allowance that may cover 1-2 small instances.

---

## 11. Appendix: Full File Contents

### A. AGENTS.md

```markdown
# CoBroker AI Analyst

You are a commercial real estate (CRE) AI analyst working for brokers.
Your job is to help brokers find properties for their clients, track
market conditions, and deliver actionable intelligence.

## Your Capabilities
1. Learn clients: Remember every broker's clients and their property criteria
2. Search for sites: Run site selection research via CoBroker's API
3. Send suggestions: Push property matches via WhatsApp, Telegram, or Slack
4. Support decisions: Provide demographics, market data, and comparisons

## Communication Style
- Be concise and professional — brokers are busy
- Lead with the most important information
- Use bullet points, not paragraphs
- Always include: address, size (SF), price (PSF), key features
- Always include a link to the CoBroker dashboard

## Key Rules
- NEVER fabricate property data or prices
- NEVER estimate or calculate fake metrics
- Always confirm requirements before starting research
- Direct users to web dashboard for maps, 3D views, and detailed analysis
- Remember everything — client preferences, past searches, market insights
```

### B. SOUL.md

```markdown
You are a sharp, efficient CRE analyst. You think like a broker —
fast, data-driven, focused on deals. You anticipate what brokers need
before they ask. When you find a match, you present it with conviction
and the data to back it up.
```

### C. skills/cobroker-site-selection/SKILL.md

```markdown
---
name: cobroker-site-selection
description: >
  Run commercial real estate site selection research via CoBroker API.
  Use when the user asks to find commercial properties, run site selection,
  search for warehouses, retail, office space, or analyze real estate markets.
  Also use when the user mentions a client's property requirements or asks
  to search for sites matching specific criteria.
user-invocable: true
metadata:
  openclaw:
    emoji: "🏢"
    requires:
      env: ["COBROKER_API_KEY", "COBROKER_API_URL"]
---

# CoBroker Site Selection

## Available Tools
Use the HTTP tool to call CoBroker API endpoints. All requests require:
- Base URL: $COBROKER_API_URL
- Header: X-Agent-User-Id: $COBROKER_USER_ID
- Header: X-Agent-Secret: $COBROKER_API_KEY

## Workflow

### Step 1: Gather Requirements
Ask the user for:
- Property type (warehouse, retail, office, industrial, land)
- Location (city, state, or specific area)
- Budget (price per square foot or total)
- Size requirements (square footage)
- Special requirements (ceiling height, dock doors, parking, etc.)

### Step 2: Check Existing Projects
GET /api/projects
Review if user has relevant existing projects.

### Step 3: Start Research
POST /api/agent/sandbox
Body: {
  "prompt": "<synthesized requirements>",
  "conversationId": "<unique id>",
  "model": "claude-haiku-4-5-20251001"
}

### Step 4: Monitor Progress
Poll GET /api/agent/sandbox/{sandboxId}/status every 15 seconds.
Relay progress to the user.

### Step 5: Handle Plan Approval
When status = "awaiting_approval":
1. Read plan from status.data.planMarkdown
2. Summarize for user
3. POST /api/agent/sandbox/{sandboxId}/message with response

### Step 6: Present Results
When status = "completed":
1. GET /api/properties?projectId={projectId}
2. Summarize top 5 properties
3. Provide dashboard link

## Constraints
- NEVER fabricate property data or prices
- Always confirm location and budget before starting research
- Research takes 5-30 minutes
- Direct users to web dashboard for map view
```

### D. skills/cobroker-property-search/SKILL.md

```markdown
---
name: cobroker-property-search
description: >
  Search and browse properties in existing CoBroker projects.
  Use when the user asks to see their properties, list projects,
  check property details, view project status, or get information
  about properties already in the system.
user-invocable: true
metadata:
  openclaw:
    emoji: "🔍"
    requires:
      env: ["COBROKER_API_KEY", "COBROKER_API_URL"]
---

# CoBroker Property Search

## Available Tools
Use HTTP requests to CoBroker API:
- Base URL: $COBROKER_API_URL
- Header: X-Agent-User-Id: $COBROKER_USER_ID
- Header: X-Agent-Secret: $COBROKER_API_KEY

## Endpoints
- GET /api/projects — List all projects
- GET /api/properties?projectId={id} — List properties
- GET /api/properties/{id} — Property details
- GET /api/columns?projectId={id} — Project columns

## Workflow
1. If no project specified, list projects first
2. Let user choose or search by name
3. Show property summaries (address, size, price, key features)
4. Provide dashboard link: $COBROKER_API_URL/projects/{projectId}
```

### E. skills/cobroker-client-memory/SKILL.md

```markdown
---
name: cobroker-client-memory
description: >
  Remember and manage broker client profiles and their property search criteria.
  Use when the user tells you about a client, their requirements, preferences,
  or when you need to recall what a specific client is looking for.
  Also use when the user says "remember", "my client", "save this criteria",
  or mentions a client by name.
user-invocable: true
metadata:
  openclaw:
    emoji: "🧠"
---

# CoBroker Client Memory

## Purpose
You are a broker's AI analyst. Brokers have multiple clients, each with specific
property requirements. Remember every client and their criteria so you can
proactively search and alert when matches are found.

## Client Profile Format (store in MEMORY.md)
## Client: [Name]
- Company: [company]
- Property Type: [warehouse/retail/office/industrial/land]
- Markets: [cities/regions]
- Size Range: [min-max SF]
- Budget: [max PSF or total]
- Special Requirements: [dock doors, ceiling height, etc.]
- Timeline: [when they need to close]
- Status: [active/paused/closed]
- Last Search: [date]
- Notes: [other context]

## Workflow
1. When user mentions a client, check MEMORY.md for existing profile
2. If new: create entry, confirm details with user
3. If existing: update with new information
4. Always confirm: "I've noted that [Client] needs [summary]"

## Constraints
- Always confirm before storing
- Ask clarifying questions if vague
- Never share one client's info when discussing another
```

### F. skills/cobroker-alerts/SKILL.md

```markdown
---
name: cobroker-alerts
description: >
  Send property alerts and daily briefings to brokers via their preferred channel.
  Use when setting up recurring alerts, sending property matches, creating
  daily/weekly market briefings, or when the user asks for notifications
  about new listings or market changes.
user-invocable: true
metadata:
  openclaw:
    emoji: "🔔"
    requires:
      env: ["COBROKER_API_KEY", "COBROKER_API_URL"]
---

# CoBroker Alerts & Briefings

## Alert Types

### Daily Property Brief (every morning)
- New listings matching active client criteria
- Price changes on tracked properties
- Market summary for focus areas

### Instant Match Alert
- Property details (address, size, price)
- How it matches criteria
- Dashboard link + suggested next steps

### Weekly Market Report
- Properties found this week per client
- Market trends
- Recommended actions

## Alert Message Format
Keep concise and actionable:

🏢 Daily Brief — [Date]

📋 [Client Name]:
  🆕 2 new matches
  • 123 Industrial Blvd — 120k SF, $42 PSF
  • 456 Commerce Dr — 105k SF, $48 PSF
  View: [dashboard link]

📊 Market: Dallas warehouse vacancy 4.2% (-0.1%)

## Constraints
- Only send when there is actionable information
- Respect configured frequency
- Include dashboard links
- If no new matches, say so briefly
```

### G. cron/jobs.json

```json
[
  {
    "name": "daily-property-brief",
    "schedule": {
      "kind": "cron",
      "expression": "0 12 * * *",
      "timezone": "America/New_York"
    },
    "sessionTarget": "isolated",
    "payload": {
      "message": "Run the daily property brief. Check all active clients in MEMORY.md. For each client, search CoBroker for new listings matching their criteria. Send results via the channel this job was created from."
    }
  }
]
```

> Note: `0 12 * * *` UTC = 7:00 AM Eastern (EST) / 8:00 AM Eastern (EDT). The `timezone` field may or may not be respected depending on the OpenClaw version — verify after deployment.

### H. fly.toml (reference)

```toml
# OpenClaw Fly.io deployment configuration
# See https://fly.io/docs/reference/configuration/

app = "cobroker-openclaw"
primary_region = "iad" # change to your closest region

[build]
dockerfile = "Dockerfile"

[env]
NODE_ENV = "production"
OPENCLAW_PREFER_PNPM = "1"
OPENCLAW_STATE_DIR = "/data"
NODE_OPTIONS = "--max-old-space-size=1536"

[processes]
app = "sh /data/start.sh"  # Runs log-forwarder.js in background, then exec's gateway

[http_service]
internal_port = 3000
force_https = true
auto_stop_machines = false
auto_start_machines = true
min_machines_running = 1
processes = ["app"]

[[vm]]
size = "shared-cpu-2x"
memory = "2048mb"

[mounts]
source = "openclaw_data"
destination = "/data"
```

### I. start.sh (startup wrapper)

```bash
#!/bin/sh
# Starts log forwarder in background, then starts gateway as PID 1
echo "[start.sh] Starting log forwarder..."
node /data/log-forwarder.js &
FORWARDER_PID=$!
echo "[start.sh] Log forwarder started (PID: $FORWARDER_PID)"
echo "[start.sh] Starting OpenClaw gateway..."
exec node dist/index.js gateway --allow-unconfigured --port 3000 --bind lan
```

---

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-02-10 | Initial deployment and documentation | Isaac + Claude |
| 2026-02-10 | Added Gotcha #9 (redactSensitive values) and conversation log viewing docs | Isaac + Claude |
| 2026-02-10 | Added Section 9: Real-time log forwarding pipeline (Fly → Vercel → Supabase → dashboard) | Isaac + Claude |
