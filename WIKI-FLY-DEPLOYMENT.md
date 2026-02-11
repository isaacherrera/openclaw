# CoBroker OpenClaw — Fly.io Deployment Wiki

> **Purpose**: Complete reference for deploying CoBroker-customized OpenClaw instances to Fly.io. Written from hands-on experience on 2026-02-10. Intended for future automation of multi-tenant VM provisioning.

> [!IMPORTANT]
> **Two repos work together.** This system spans two separate repositories that interact with each other. You need access to both to make changes:
>
> | Repo | Local Path | GitHub | What It Does |
> |------|-----------|--------|-------------|
> | **OpenClaw** (this repo) | `~/Projects/openclaw` | `isaacherrera/openclaw` | Fly.io deployment config, skill definitions (`fly-scripts/skills/`), startup scripts, this wiki. Fork of [openclaw/openclaw](https://github.com/openclaw/openclaw). |
> | **Vercel App** | `~/Projects/openai-assistants-quickstart` | `flyerio/openai_assistant` | Next.js app at `app.cobroker.ai`. API routes (`app/api/agent/openclaw/`), business logic (`lib/agentkit/`, `lib/server/`), webhooks, credit system, Supabase integration. Auto-deploys to Vercel on push. |
>
> **How they connect:** The OpenClaw agent (Fly) calls the Vercel API routes via `curl` using credentials (`COBROKER_BASE_URL`, `COBROKER_AGENT_SECRET`). Skill files (SKILL.md) in the OpenClaw repo define _what_ the agent can do; the Vercel app implements _how_ it works. Changes often touch both repos — e.g., adding a new capability requires a new API route in the Vercel app AND a new skill section in OpenClaw.
>
> **To onboard a new agent/session:** Give it this wiki file plus access to both repo paths above.

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
10. [CoBroker Projects API (Unified CRUD)](#10-cobroker-projects-api-unified-crud)
11. [Cost Reference](#11-cost-reference)
12. [Appendix: Full File Contents](#12-appendix-full-file-contents)

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
| `COBROKER_BASE_URL` | For CoBroker skills | e.g., `https://app.cobroker.ai` |
| `COBROKER_AGENT_SECRET` | For CoBroker skills | Must match `AGENT_AUTH_SECRET` on Vercel (see Gotcha #12) |
| `COBROKER_AGENT_USER_ID` | For CoBroker skills | CoBroker app user UUID |
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

# CoBroker API credentials (for import-properties skill)
# IMPORTANT: COBROKER_AGENT_SECRET must match AGENT_AUTH_SECRET on Vercel
fly secrets set COBROKER_BASE_URL=https://app.cobroker.ai
fly secrets set COBROKER_AGENT_SECRET=...
fly secrets set COBROKER_AGENT_USER_ID=...
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
fly ssh console -C "sh -c 'mkdir -p /data/skills/cobroker-client-memory /data/skills/cobroker-projects /data/skills/cobroker-plan'"
```

### 4.3 Write Configuration Files

Write each file using the base64 transfer pattern. The files to create are:

1. `/data/openclaw.json` — Main configuration (see Section 5)
2. `/data/AGENTS.md` — Agent personality
3. `/data/SOUL.md` — Agent tone/vibe
4. `/data/skills/cobroker-client-memory/SKILL.md`
5. `/data/skills/cobroker-projects/SKILL.md` — Unified CRUD for projects & properties
6. `/data/skills/cobroker-plan/SKILL.md` — Multi-step plan mode orchestration
7. `/data/cron/jobs.json` — Scheduled jobs

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
      "streamMode": "partial",
      "capabilities": {
        "inlineButtons": "dm"
      }
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
| `channels.telegram.capabilities.inlineButtons` | `"dm"` | Enables inline keyboard buttons in DMs (needed for plan mode approval) |
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

### Gotcha #10: `getAppUserEmail()` Returns Wrong Email (Admin Auth Fails)

**Symptom**: Dashboard page loads fine (server component), but client-side `fetch()` to the API route returns `401 Admin access denied` with `reason: "not-admin"`.

**Cause**: `getAppUserEmail()` in `lib/server/identity.ts` was using `user.emailAddresses[0]` — the first email in the array — which is NOT necessarily the primary email. If the Clerk user has multiple email addresses (e.g., `isaac@flyer.io` + `isaac@cobroker.ai`), the array order is arbitrary. The admin check compares against `ADMIN_EMAIL` and fails.

Meanwhile, the page server component used the correct pattern:
```typescript
// CORRECT — finds primary email by ID
user.emailAddresses?.find(e => e.id === user.primaryEmailAddressId)?.emailAddress

// WRONG — first in array may not be primary
user.emailAddresses?.[0]?.emailAddress
```

**Fix**: Updated `getAppUserEmail()` to use `primaryEmailAddressId`:
```typescript
const primary = user.emailAddresses?.find(
  (e: any) => e.id === user.primaryEmailAddressId
);
return primary?.emailAddress || user.emailAddresses?.[0]?.emailAddress || null;
```

**Debugging approach**: Added temporary diagnostic fields (`reason`, `debug_email`) to the API 401 response to expose which email Clerk was returning. The error banner showed `[HTTP 401] Admin access denied | not-admin | isaac@flyer.io`, immediately revealing the email mismatch.

**For automation**: Always use `primaryEmailAddressId` when looking up a Clerk user's email. Never rely on `emailAddresses[0]`.

### Gotcha #11: Skill Snapshot Caching (Skills Don't Appear After Adding)

**Symptom**: A new skill directory exists in `/data/skills/`, env vars are set, gateway has been restarted multiple times, but the agent still doesn't list or use the new skill.

**Cause**: OpenClaw snapshots the resolved skill list into `sessions.json` → `skillsSnapshot` when a session is **first created**. The gateway does NOT refresh this snapshot on restart — it reuses the cached version for existing sessions. New skills added to `/data/skills/` are invisible to the agent until the session is recreated.

**Diagnosis**: Check the `skillsSnapshot.resolvedSkills` array in `sessions.json`:
```bash
fly ssh console -C "cat /data/agents/main/sessions/sessions.json" | python3 -m json.tool | grep -A2 '"name"'
```
If the new skill isn't listed, the snapshot is stale.

**Fix**: Delete the session files to force a fresh session (and skill re-resolution):
```bash
fly ssh console -C "sh -c 'rm -f /data/agents/main/sessions/*.jsonl /data/agents/main/sessions/sessions.json'"
fly apps restart
```
The agent loses its conversation history, but sessions reset daily at 4am anyway.

**Also beware `requires.env`**: If a skill's YAML frontmatter has `requires.env: ["SOME_VAR"]` and that var is missing, the gateway silently skips the skill during resolution. Even after the env var is later set, the stale `skillsSnapshot` still won't include it — you must clear the session. **Recommendation**: Avoid `requires.env` in SKILL.md unless absolutely needed.

**For automation**: After deploying skills to a new tenant, always restart the gateway. For existing tenants, clear sessions before restart if skills have been added or changed.

### Gotcha #12: Agent Auth Secret Mismatch (Import Returns 401)

**Symptom**: The OpenClaw agent's `curl` to `/api/agent/openclaw/import-properties` returns `{"error":"Unauthorized","message":"Authentication required to access this endpoint"}`.

**Cause**: The Vercel middleware (`middleware.ts`) has an **agent auth bypass** for `/api/agent/*` routes. It checks:
1. `process.env.AGENT_AUTH_SECRET` must be set on Vercel
2. `X-Agent-Secret` header (from the agent) must match `AGENT_AUTH_SECRET` exactly
3. `X-Agent-User-Id` header must be present

The OpenClaw skill sends `$COBROKER_AGENT_SECRET` as `X-Agent-Secret`. If this value doesn't match `AGENT_AUTH_SECRET` on Vercel, the bypass is skipped and Clerk middleware returns 401.

**The two secrets that must match:**
| Where | Env Var Name | Sent As |
|-------|-------------|---------|
| Fly.io | `COBROKER_AGENT_SECRET` | `X-Agent-Secret` header |
| Vercel | `AGENT_AUTH_SECRET` | Compared in middleware |

**Fix**: Ensure both contain the same value:
```bash
# Get the value from Vercel dashboard (Settings → Environment Variables → AGENT_AUTH_SECRET)
# Then set Fly to match:
fly secrets set COBROKER_AGENT_SECRET="<same value as AGENT_AUTH_SECRET>"
```

**For automation**: Generate one secret (`openssl rand -hex 32`) and set it as **both** `AGENT_AUTH_SECRET` on Vercel and `COBROKER_AGENT_SECRET` on Fly.

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
  - COBROKER_BASE_URL       (for import skill)
  - COBROKER_AGENT_SECRET   (must match AGENT_AUTH_SECRET on Vercel)
  - COBROKER_AGENT_USER_ID  (CoBroker app user UUID)
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
  COBROKER_BASE_URL="$COBROKER_BASE_URL" \
  COBROKER_AGENT_SECRET="$COBROKER_AGENT_SECRET" \
  COBROKER_AGENT_USER_ID="$COBROKER_AGENT_USER_ID"

# 5. Deploy
fly deploy

# 6. Wait for machine to stabilize
sleep 30

# 7. Create directories
fly ssh console -C "sh -c 'mkdir -p /data/skills/cobroker-client-memory /data/skills/cobroker-projects /data/skills/cobroker-plan'"

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
      "streamMode": "partial",
      "capabilities": { "inlineButtons": "dm" }
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
for skill in cobroker-client-memory cobroker-projects cobroker-plan; do
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

### Config Backup (`cobroker-config-backup/`)

The repo contains a full snapshot of `/data/` from the live Fly machine at `cobroker-config-backup/`. This includes config, skills, agent personality, sessions, credentials, and runtime state.

**Two directories, two purposes:**
- `fly-scripts/` — **PUSH to Fly.** Source of truth for deploying customizations (scripts, skills).
- `cobroker-config-backup/` — **PULL from Fly.** Full backup of `/data/` including runtime state.

**To refresh the backup** (roughly once a week or after config changes):
```bash
fly ssh console -C "sh -c 'cd /data && tar czf - .'" > /tmp/fly-data-snapshot.tar.gz
cd cobroker-config-backup && find . -not -name 'README.md' -not -name '.' -not -name '..' -delete && cd ..
tar xzf /tmp/fly-data-snapshot.tar.gz -C cobroker-config-backup/
git add cobroker-config-backup/ && git commit -m "backup: refresh /data/ snapshot $(date +%Y-%m-%d)"
```

See `cobroker-config-backup/README.md` for full instructions.

**Contents:** `openclaw.json`, `AGENTS.md`, `SOUL.md`, `start.sh`, `log-forwarder.js`, `skills/`, `cron/`, `credentials/`, `agents/main/sessions/`, `identity/`, `devices/`, and other runtime files.

> **Note:** The backup contains sensitive files (private keys in `identity/`, auth tokens in `credentials/` and `devices/`). Keep this repo private.

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
| `app/api/openclaw-logs/route.ts` | POST: receives batched entries from Fly forwarder (Bearer token auth, public route in middleware) |
| `app/api/admin/openclaw-logs/route.ts` | GET: serves logs to admin dashboard (Clerk admin auth via `verifyAdminAccess()`) |
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
| Dashboard shows "Unauthorized" (middleware) | Not logged in, or Clerk session expired | Sign in as admin; check `x-clerk-auth-status` header |
| Dashboard shows "Admin access denied" (route handler) | `getAppUserEmail()` returning wrong email | See Gotcha #10 — use `primaryEmailAddressId`, not `emailAddresses[0]` |

---

## 10. CoBroker Projects API (Unified CRUD)

The OpenClaw agent uses a **single unified skill** (`cobroker-projects`) to manage all project and property operations via the CoBroker Vercel API. This replaced the earlier single-purpose `cobroker-import-properties` skill.

### 10.1 Endpoint Overview

All routes live under `/api/agent/openclaw/projects` on the Vercel app (`app.cobroker.ai`).

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/projects` | Create project with properties |
| GET | `/projects` | List user's projects (limit 50) |
| GET | `/projects/[projectId]` | Get project details + properties (human-readable fields) |
| PATCH | `/projects/[projectId]` | Update project name/description/public |
| DELETE | `/projects/[projectId]` | Delete project (full cascade) |
| POST | `/projects/[projectId]/properties` | Add properties to existing project |
| PATCH | `/projects/[projectId]/properties` | Update existing properties |
| DELETE | `/projects/[projectId]/properties` | Delete specific properties |
| POST | `/projects/[projectId]/demographics` | Add demographic column (ESRI GeoEnrichment) |
| GET | `/projects/[projectId]/demographics` | List available demographic data types |
| POST | `/projects/[projectId]/enrichment` | Create AI research enrichment column (Parallel AI, async) |
| GET | `/projects/[projectId]/enrichment?columnId=x` | Poll enrichment status + results |

### 10.2 Auth

All requests use agent auth bypass headers (no Clerk session needed):

```
X-Agent-User-Id: $COBROKER_AGENT_USER_ID
X-Agent-Secret: $COBROKER_AGENT_SECRET
```

The Vercel middleware at `/api/agent/*` checks `X-Agent-Secret` against `AGENT_AUTH_SECRET` env var (see Gotcha #12).

### 10.3 Key Behaviors

- **Geocoding**: Addresses without lat/long are auto-geocoded via Mapbox (1 credit per address). If credits are exhausted, properties still import without map pins.
- **Column auto-creation**: Both POST and PATCH on properties auto-create `table_columns` for unknown field names. Field names are normalized (trimmed, capped at 100 chars).
- **Demographics enrichment**: POST to `/demographics` creates a `type: 'api'` column, calls ESRI GeoEnrichment API for every property with coordinates, and writes values into `custom_fields` keyed by column UUID. Supports 58 data types across 6 categories (population, income, age, employment, housing, race/ethnicity). Costs 4 credits per property per column. Properties without lat/long are skipped.
- **Research enrichment (async)**: POST to `/enrichment` creates a `type: 'enrichment'` column, batch-submits Parallel AI tasks for every property with an address, and returns immediately (202 Accepted). Results arrive via webhook (`/api/webhooks/parallel-ai`) which writes to `custom_fields[columnId]` atomically. GET `/enrichment?columnId=x` polls status (completed/pending/failed per property). Processor tiers: `base` (1 credit, ~15-100s), `core` (3 credits, ~1-5min), `pro` (10 credits, ~3-9min), `ultra` (30 credits, ~5-25min). Properties need addresses (not coordinates) — unlike demographics.
- **Cascade delete (project)**: Deletes all properties → property_images → cobroker_documents (storage + records) → table_columns → table_projects.
- **Cascade delete (property)**: Deletes property_images → cobroker_documents (storage + records) → cobroker_properties record.
- **Field mapping**: Properties store custom fields as `{ columnUUID: value }`. The GET detail endpoint reverse-maps UUIDs → human-readable column names.
- **Address changes**: PATCH with a new address triggers re-geocoding. Field updates merge into existing `custom_fields` (additive, not replace).

### 10.4 Vercel Files

```
openai-assistants-quickstart/
  app/api/agent/openclaw/
    import-properties/route.ts              ← KEPT for backward compat (no changes)
    projects/
      route.ts                               ← POST create + GET list
      [projectId]/
        route.ts                             ← GET detail + PATCH update + DELETE
        properties/
          route.ts                           ← POST add + PATCH update + DELETE
        demographics/
          route.ts                           ← POST enrich + GET list types
        enrichment/
          route.ts                           ← POST create + GET poll status
  lib/agentkit/
    enrichment-service.ts                    ← Batch task submission + credit mgmt
  lib/server/openclaw/
    import-properties-service.ts             ← Refactored to use shared helpers
    project-service.ts                       ← Ownership check + cascade delete
    property-helpers.ts                      ← Normalization, geocoding, cleanup
```

### 10.5 OpenClaw Skill

The unified skill is at `/data/skills/cobroker-projects/SKILL.md` on the Fly machine. It covers all 12 sections (CRUD, demographics, and research enrichment) with curl examples and workflow guidelines. See [Appendix H](#h-skillscobroker-projectsskillmd) for full contents.

The old `cobroker-import-properties` skill has been removed. The old `/api/agent/openclaw/import-properties` API endpoint still works for backward compatibility but is no longer referenced by any skill.

### 10.6 Plan Mode (Multi-Step Orchestration)

The `cobroker-plan` skill at `/data/skills/cobroker-plan/SKILL.md` teaches the agent to **auto-detect when a user requests 2+ distinct operations** and orchestrate them as a structured plan. No backend API changes are needed — plan mode is purely an agent behavior pattern defined in the skill's SKILL.md.

**How it works:**
1. User sends a message with multiple operations (e.g., "add population and income demographics, and research zoning")
2. Agent detects 2+ operations → enters plan mode
3. Agent presents a numbered plan with credit estimates and Telegram inline keyboard buttons (Approve / Edit / Cancel)
4. User clicks "Approve & Execute" → agent executes all steps sequentially via `cobroker-projects` endpoints
5. Agent reports progress after each step and a summary at the end

**Inline buttons:** Requires `channels.telegram.capabilities.inlineButtons: "dm"` in `openclaw.json`. The gateway renders inline keyboard buttons below the plan message. When the user clicks a button, the gateway forwards the `callback_data` as a synthetic text message to the agent (e.g., `"plan_approve"`, `"plan_edit"`, `"plan_cancel"`). Text fallbacks ("go", "yes", "cancel") also work.

**Step ordering:** The skill instructs the agent to order steps logically — create/update ops first, demographics next (sync/fast), enrichment last (async/slow), destructive ops at the end.

**Error handling:** Non-credit failures are reported and skipped; credit failures (402) stop execution immediately.

See [Appendix I](#i-skillscobroker-planskillmd) for the full SKILL.md contents.

### 10.7 Verified Operations

All operations tested end-to-end via Telegram and direct curl:

| Operation | Verified | Notes |
|-----------|----------|-------|
| Create project | Yes | With properties, geocoding, and column creation |
| List projects | Yes | Returned 50 projects with property counts |
| Get project details | Yes | Human-readable field names (reverse UUID mapping) |
| Update project name | Yes | Via Telegram |
| Update project public flag | Yes | `updated: ["public"]` |
| Delete project (cascade) | Yes | Tested via curl and Telegram |
| Add properties | Yes | With new column auto-creation |
| Update property fields | Yes | With auto-column creation for new field names |
| Update property addresses | Yes | 10 properties re-geocoded (`geocodedCount: 10`) |
| Delete properties | Yes | With cascade cleanup |
| Add demographics (POST) | Yes | Population (1mi)=9,257 and Income (5mi)=$56,440 verified on TopGolf El Paso |
| List demographic types (GET) | Yes | Returns 58 types across 6 categories |
| Create enrichment column (POST) | Yes | Zoning code "SCZ" returned for 365 Vin Rambla Dr, El Paso via Parallel AI base processor |
| Poll enrichment status (GET) | Yes | Status polling works: pending → completed with content + confidence |
| Plan mode (multi-step) | Yes | Agent presents plan with inline buttons, executes steps sequentially after approval |

---

## 11. Cost Reference

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

## 12. Appendix: Full File Contents

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

### C–D. (Removed)

> Skills `cobroker-site-selection`, `cobroker-property-search`, and `cobroker-alerts` were removed on 2026-02-10. They were placeholder skills that required API endpoints not yet built. Active skills are `cobroker-client-memory`, `cobroker-projects`, and `cobroker-plan`.

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

### F. (Removed — see C–D note above)

### G. (Removed — replaced by cobroker-projects)

> The `cobroker-import-properties` skill was replaced on 2026-02-10 by the unified `cobroker-projects` skill (see Appendix H). The old `/api/agent/openclaw/import-properties` endpoint still works for backward compatibility.

### H. skills/cobroker-projects/SKILL.md

> **Note**: This skill intentionally omits `requires.env` to avoid silent loading failures due to skill snapshot caching (see Gotcha #11). The env vars (`COBROKER_BASE_URL`, `COBROKER_AGENT_USER_ID`, `COBROKER_AGENT_SECRET`) must be set as Fly secrets.

```markdown
---
name: cobroker-projects
description: >
  Manage CoBroker projects and properties. Create, list, view, update, and delete
  projects. Add, update, and remove properties. Enrich properties with demographic
  data (population, income, jobs, housing) or AI-powered research enrichment
  (zoning, building details, market data, etc.). Use whenever the user wants to
  work with CoBroker project data.
user-invocable: true
metadata:
  openclaw:
    emoji: "📋"
---

# CoBroker Projects

Full CRUD for projects and properties — create, list, view, update, delete.

## Auth Headers (all requests)

\```
-H "Content-Type: application/json" \
-H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
-H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
\```

## 1–8. Projects & Properties CRUD

(Same as before — List, Get, Create, Update, Delete projects; Add, Update, Delete properties.)

## 9. Add Demographics to Project

Enrich properties with ESRI demographic data. Creates a new column and populates values for all properties with coordinates.

\```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/demographics" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "dataType": "population",
    "radius": 1,
    "mode": "radius"
  }'
\```

Parameters:
- `dataType` (required) — one of 58 ESRI types (see Section 10)
- `radius` (required) — 0.1 to 100 (miles for radius, minutes for drive/walk)
- `mode` (optional, default `"radius"`) — `"radius"` | `"drive"` | `"walk"`
- `columnName` (optional) — auto-generated if omitted (e.g. "Population (1 mi)")

Response:
\```json
{
  "success": true,
  "projectId": "uuid",
  "columnId": "uuid",
  "columnName": "Population (1 mi)",
  "dataType": "population",
  "radius": 1,
  "mode": "radius",
  "propertiesProcessed": 5,
  "propertiesTotal": 5,
  "propertiesFailed": 0
}
\```

Common data types: `population`, `income`, `median_age`, `households`, `median_home_value`, `median_rent`, `retail_jobs`, `healthcare_jobs`.

Cost: 4 credits per property per demographic column.

## 10. List Demographic Types

\```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/demographics" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
\```

Returns all 58 supported data types grouped by category: Core Demographics, Income Brackets, Race/Ethnicity, Age Groups, Employment, Housing & Additional.

## 11. Research Enrichment (AI-Powered)

Use Parallel AI to research a question about each property. Creates a new column and submits async research tasks. Results arrive via webhook (15s to 25min depending on processor).

\```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/enrichment" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "prompt": "What is the zoning classification for this property?",
    "columnName": "Zoning",
    "processor": "base"
  }'
\```

Parameters:
- `prompt` (required) — question to research for each property address
- `columnName` (optional) — auto-generated from prompt if omitted
- `processor` (optional, default `"base"`) — research depth:
  - `"base"` — 1 credit/property, ~15-100s
  - `"core"` — 3 credits/property, ~1-5min
  - `"pro"` — 10 credits/property, ~3-9min
  - `"ultra"` — 30 credits/property, ~5-25min

Response (202 Accepted):
\```json
{
  "success": true,
  "projectId": "uuid",
  "columnId": "uuid",
  "columnName": "Zoning",
  "prompt": "What is the zoning classification for this property?",
  "processor": "base",
  "propertiesSubmitted": 5,
  "propertiesTotal": 5,
  "propertiesSkipped": 0,
  "creditsCharged": 5,
  "status": "processing",
  "estimatedTime": "15-100 seconds per property (base processor)"
}
\```

## 12. Check Enrichment Status

Poll to check if enrichment tasks have completed.

\```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/enrichment?columnId={columnId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
\```

Response:
\```json
{
  "success": true,
  "columnId": "uuid",
  "columnName": "Zoning",
  "status": "processing",
  "completed": 3,
  "pending": 1,
  "failed": 1,
  "total": 5,
  "results": [
    {
      "propertyId": "uuid",
      "address": "123 Main St, Dallas, TX 75201",
      "status": "completed",
      "content": "C-2 Commercial",
      "confidence": "high"
    }
  ]
}
\```

## Address Formatting — CRITICAL

Addresses MUST have >=3 comma-separated parts:
- GOOD: `"123 Main St, Dallas, TX 75201"`
- BAD: `"123 Main St, Dallas TX 75201"` (only 2 parts, rejected)

## Constraints
- Max 50 properties per request
- NEVER fabricate addresses
- Always `"public": true`
- Each geocoded address costs 1 credit
- Always share the publicUrl (not projectUrl)
- Demographics require properties with coordinates — add properties first, then enrich
- Each demographic column costs 4 credits per property (ESRI GeoEnrichment API)
- Properties without lat/long are skipped during demographic enrichment
- Each enrichment costs 1-30 credits per property depending on processor (base=1, core=3, pro=10, ultra=30)
- Enrichment is **async** — submit first, then poll for results
- Properties need addresses (not coordinates) for enrichment — unlike demographics
- Default to `"base"` processor unless user asks for deeper research
- After enrichment completes, results appear as a new column in the project table
```

### I. skills/cobroker-plan/SKILL.md

> **Note**: This skill requires `user-invocable: true` to be included in the session skill snapshot (see Gotcha #11). It also requires `channels.telegram.capabilities.inlineButtons: "dm"` in `openclaw.json` for the inline approval buttons to render.

```markdown
---
name: cobroker-plan
description: >
  Orchestrate multi-step CoBroker workflows. When the user requests two or more
  distinct operations (e.g. demographics + enrichment, create project + add properties + research),
  automatically enter plan mode: present a numbered plan, get approval, then execute
  all steps sequentially using the cobroker-projects skill endpoints.
user-invocable: true
metadata:
  openclaw:
    emoji: "📝"
---

# CoBroker Plan Mode

When a user requests **multiple distinct operations** in a single message, enter plan mode instead of executing immediately. Present a structured plan, wait for approval, then execute all steps sequentially.

## 1. When to Enter Plan Mode

**Enter plan mode** when the user's request contains **2 or more distinct operations**:

- "Add population and income demographics" → 2 ops (2 demographic calls) → **plan**
- "Research zoning and add median income" → 2 ops (enrichment + demographics) → **plan**
- "Create a project, add demographics, and research zoning" → 3 ops → **plan**

**Do NOT enter plan mode** for single operations:

- "Add population demographics" → 1 op → **execute directly**
- "What's the zoning for my properties?" → 1 enrichment → **execute directly**
- "List my projects" → 1 op → **execute directly**
- "Create a project with 5 addresses" → 1 op (even with multiple properties)

## 2. Available Step Types

Every plan step maps to a cobroker-projects endpoint:

| Step Type | Endpoint | Credits | Sync/Async |
|-----------|----------|---------|------------|
| `create-project` | POST /projects | 1/address (geocoding) | Sync |
| `add-properties` | POST /projects/{id}/properties | 1/address | Sync |
| `update-project` | PATCH /projects/{id} | 0 | Sync |
| `demographics` | POST /projects/{id}/demographics | 4/property | Sync |
| `enrichment` | POST /projects/{id}/enrichment | 1-30/property | **Async** |
| `delete-properties` | DELETE /projects/{id}/properties | 0 | Sync |
| `delete-project` | DELETE /projects/{id} | 0 | Sync |

## 3-4. Plan Format & Examples

Plan is presented as a numbered list with credit estimates and inline keyboard buttons.

## 5. Inline Keyboard for Approval

buttons: [
  [
    { text: "✅ Approve & Execute", callback_data: "plan_approve" },
    { text: "✏️ Edit Plan", callback_data: "plan_edit" }
  ],
  [
    { text: "❌ Cancel", callback_data: "plan_cancel" }
  ]
]

## 6-10. Callback Handling, Execution Flow, Step Ordering, Error Handling, Dependencies

See full file at `fly-scripts/skills/cobroker-plan/SKILL.md` in the repo.
```

### J. cron/jobs.json

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

### K. fly.toml (reference)

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

### L. start.sh (startup wrapper)

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
| 2026-02-10 | Added Gotcha #10: `getAppUserEmail()` wrong email bug; updated Section 9 troubleshooting + file table | Isaac + Claude |
| 2026-02-10 | Added `cobroker-import-properties` skill (Appendix G) + updated mkdir and file list | Isaac + Claude |
| 2026-02-10 | Fixed env var names (`COBROKER_BASE_URL`/`AGENT_SECRET`/`AGENT_USER_ID`), added Gotcha #11 (skill snapshot caching) + #12 (agent auth secret mismatch), removed deprecated skills (C/D/F) | Isaac + Claude |
| 2026-02-10 | Added Section 10: Unified Projects CRUD API (8 endpoints). Replaced `cobroker-import-properties` skill with `cobroker-projects` (Appendix G→H). Updated all directory/file references. Full e2e verification table. | Isaac + Claude |
| 2026-02-10 | Added demographics endpoints (POST enrich + GET list types) to Section 10. Updated skill (Appendix H) with Sections 9-10. 58 ESRI data types, 4 credits/property. Fixed ESRI API integration (studyAreasOptions, buffer units, attribute mappings). | Isaac + Claude |
| 2026-02-10 | Added research enrichment (Parallel AI) — POST `/enrichment` (async task submission) + GET `/enrichment?columnId=x` (status polling). New `enrichment-service.ts`. Skill Sections 11-12. Verified e2e: zoning code SCZ for TopGolf El Paso. | Isaac + Claude |
| 2026-02-10 | Added plan mode (`cobroker-plan` skill) — auto-detects 2+ operations, presents numbered plan with inline Telegram buttons (Approve/Edit/Cancel), executes steps sequentially. Added `inlineButtons: "dm"` to openclaw.json config. New Section 10.6, Appendix I. | Isaac + Claude |
| 2026-02-11 | Added `cobroker-config-backup/` — full `/data/` snapshot from live Fly machine. Added backup docs to Section 8. | Isaac + Claude |
