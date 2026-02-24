# CoBroker OpenClaw — Fly.io Deployment Wiki

> **Purpose**: Complete reference for deploying CoBroker-customized OpenClaw instances to Fly.io. Written from hands-on experience on 2026-02-10. Multi-tenant provisioning is fully automated via `fly-scripts/deploy-tenant.sh` — see [Section 7](#7-multi-tenant-provisioning).

> [!IMPORTANT]
> **Three repos work together.** This system spans three separate repositories that interact with each other. You need access to all three to make changes:
>
> | Repo | Local Path | GitHub | What It Does |
> |------|-----------|--------|-------------|
> | **OpenClaw** (this repo) | `~/Projects/openclaw` | `isaacherrera/openclaw` | Fly.io deployment config, skill definitions (`fly-scripts/skills/`), startup scripts, this wiki. Fork of [openclaw/openclaw](https://github.com/openclaw/openclaw). |
> | **CoBroker App** | `~/Projects/openai-assistants-quickstart` | `flyerio/openai_assistant` | Next.js app at `app.cobroker.ai`. API routes (`app/api/agent/openclaw/`), business logic (`lib/agentkit/`, `lib/server/`), webhooks, credit system, Supabase integration. Auto-deploys to Vercel on push. |
> | **ClawBroker.ai** | `~/Projects/clawbroker` | — | Self-service onboarding platform at `clawbroker.ai`. Signup, bot assignment, dashboard, admin panel, billing (Stripe), auto-suspend/reactivation. Shares Supabase + Clerk with CoBroker App. Auto-deploys to Vercel on push. |
>
> **How they connect:** The OpenClaw agent (Fly) calls the CoBroker App API routes via `curl` using credentials (`COBROKER_BASE_URL`, `COBROKER_AGENT_SECRET`). Skill files (SKILL.md) in the OpenClaw repo define _what_ the agent can do; the CoBroker App implements _how_ it works. ClawBroker.ai is the self-service onboarding hub — it provisions tenants (bot + VM assignment), manages billing, and controls VM lifecycle (start/stop) via the Fly Machines API. All three apps share the same Supabase database.
>
> **To onboard a new agent/session:** Give it this wiki file plus access to all three repo paths above.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step-by-Step Deployment](#3-step-by-step-deployment)
4. [Post-Deploy Configuration via SSH](#4-post-deploy-configuration-via-ssh)
5. [Configuration File Reference](#5-configuration-file-reference)
6. [Gotchas & Lessons Learned](#6-gotchas--lessons-learned)
7. [Multi-Tenant Provisioning](#7-multi-tenant-provisioning)
8. [Management & Operations](#8-management--operations)
9. [Real-Time Log Forwarding](#9-real-time-log-forwarding)
10. [CoBroker Agent Skills & API](#10-cobroker-projects-api-unified-crud)
    - [10.1–10.5 Projects API (Unified CRUD)](#101-endpoint-overview)
    - [10.6 Plan Mode](#106-plan-mode-multi-step-orchestration)
    - [10.7 Verified Operations](#107-verified-operations)
    - [10.8 Property Search (cobroker-search)](#108-property-search-cobroker-search-skill)
    - [10.9 Message Delivery Rule](#109-message-delivery-rule--convention)
    - [10.10 Inline URL Buttons](#1010-inline-url-buttons-for-project-links)
    - [10.11 Google Places Integration](#1011-google-places-integration)
    - [10.12 Search Routing Logic](#1012-search-routing-logic)
    - [10.13 Brassica POS Analytics](#1013-brassica-pos-analytics)
    - [10.14 Chart Generation](#1014-chart-generation)
    - [10.15 Email Document Import](#1015-email-document-import)
    - [10.16 Web Change Monitoring](#1016-web-change-monitoring)
    - [10.17 Google Workspace CLI (gog)](#1017-google-workspace-cli-gog)
11. [Cost Reference](#11-cost-reference)
12. [Appendix: Full File Contents](#12-appendix-full-file-contents)
13. [CoBroker Vercel App — Telegram & Agent Pool](#13-cobroker-vercel-app--telegram--agent-pool)
    - [13.1 Architecture Overview](#131-architecture-overview)
    - [13.2 Telegram Bot (grammY)](#132-telegram-bot-grammy)
    - [13.3 User Linking Flow](#133-user-linking-flow)
    - [13.4 Agent Pool Management](#134-agent-pool-management)
    - [13.5 Message Handlers](#135-message-handlers)
    - [13.6 Session Management](#136-session-management)
    - [13.7 Progress Relay](#137-progress-relay)
    - [13.8 Agent Authentication](#138-agent-authentication)
    - [13.9 Database Schema](#139-database-schema)
    - [13.10 Environment Variables (Vercel)](#1310-environment-variables-vercel)
    - [13.11 UI Component](#1311-ui-component)
    - [13.12 File Reference](#1312-file-reference)
14. [ClawBroker.ai — Self-Service Onboarding](#14-clawbrokerai--self-service-onboarding)
    - [14.1 Architecture Overview](#141-architecture-overview)
    - [14.2 Tech Stack](#142-tech-stack)
    - [14.3 Database Schema](#143-database-schema)
    - [14.4 Onboarding Flow](#144-onboarding-flow)
    - [14.5 API Routes](#145-api-routes)
    - [14.6 Dashboard & Admin Pages](#146-dashboard--admin-pages)
    - [14.7 Auto-Suspend & Reactivation](#147-auto-suspend--reactivation)
    - [14.8 Environment Variables (Vercel)](#148-environment-variables-vercel)
    - [14.9 File Reference](#149-file-reference)
    - [14.10 Current Status](#1410-current-status)

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
│  │  ├── workspace/         ← persist   │    │
│  │  ├── skills/                        │    │
│  │  ├── databases/brassica_pos.db      │    │
│  │  ├── doc-extractor/extract.mjs      │    │
│  │  ├── chart-renderer/generate-chart  │    │
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
fly ssh console -C "sh -c 'mkdir -p /data/skills/cobroker-client-memory /data/skills/cobroker-projects /data/skills/cobroker-plan /data/skills/cobroker-search /data/skills/cobroker-brassica-analytics /data/skills/cobroker-charts /data/skills/cobroker-email-import /data/skills/cobroker-monitor /data/skills/gog /data/databases /data/doc-extractor /data/chart-renderer /data/workspace'"
```

### 4.3 Write Configuration Files

Write each file using the base64 transfer pattern. The files to create are:

1. `/data/openclaw.json` — Main configuration (see Section 5)
2. `/data/AGENTS.md` — Agent personality
3. `/data/SOUL.md` — Agent tone/vibe
4. `/data/skills/cobroker-client-memory/SKILL.md`
5. `/data/skills/cobroker-projects/SKILL.md` — Unified CRUD for projects & properties
6. `/data/skills/cobroker-plan/SKILL.md` — Multi-step plan mode orchestration
7. `/data/skills/cobroker-search/SKILL.md` — Property search (FindAll)
8. `/data/skills/cobroker-brassica-analytics/SKILL.md` — Brassica POS analytics
9. `/data/skills/cobroker-charts/SKILL.md` — Chart generation
10. `/data/skills/cobroker-email-import/SKILL.md` — Email document import
11. `/data/skills/cobroker-monitor/SKILL.md` — Web change monitoring
12. `/data/skills/gog/SKILL.md` — Google Workspace CLI
13. `/data/cron/jobs.json` — Scheduled jobs
14. `/data/databases/brassica_pos.db` — Brassica POS SQLite database (binary, transferred separately)
15. `/data/doc-extractor/extract.mjs` — Document extraction script (PDF, images, CSV, XLSX, DOCX)
16. `/data/chart-renderer/generate-chart.mjs` — Chart.js PNG renderer

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
      "workspace": "/data/workspace",
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
| `agents.defaults.workspace` | `"/data/workspace"` | **CRITICAL** — persistent workspace on volume (default is ephemeral `/home/node/.openclaw/workspace/`) |
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

### Gotcha #13: API Cost During Testing — Minimize Usage

**Problem**: Google Places API, ESRI GeoEnrichment, and Parallel AI calls cost real money. Testing with broad queries ("all Starbucks in Texas") can burn through credits and incur high API costs.

**Rules for testing:**
- **Always use the smallest possible query** — test with queries that return 1-3 results, not 50+
- Good: "Topgolf in El Paso" (1 result), "Apple Store in El Paso" (1 result)
- Bad: "Starbucks in Texas" (50+ results), "all restaurants in Dallas" (400+ results)
- **Use `maxResults: 1`** when testing Places Search to cap API calls
- **Use small radius** for nearby analysis — `radiusMiles: 0.1` is enough to verify it works
- **Use `preview: true`** first — preview is free (no credits charged)
- **Don't repeat tests unnecessarily** — if a test passes once, move on
- **Count API calls**: each Places Text Search page = 1 API call ($0.032), Nearby Search = $0.032, Place Details = $0.017, Area Insights = $0.01
- **Test with existing projects** that already have data rather than creating new ones each time

---

## 7. Multi-Tenant Provisioning

A single script — `fly-scripts/deploy-tenant.sh` — handles full provisioning of new CoBroker OpenClaw tenant instances on Fly.io. It has three modes: **deploy** (creates everything from scratch), **configure-user** (adds a user to an existing deployment), and **update-files** (pushes updated scripts, skills, and personality files to an existing VM without touching config). Fully tested and battle-proven as of 2026-02-13, with `update-files` mode added 2026-02-23.

### 7.1 Prerequisites

Before running the script, you need:

| Requirement | How to Get It |
|-------------|---------------|
| **Telegram bot token** | Create a new bot via [@BotFather](https://t.me/BotFather). You'll get a token like `7xxx:AAxxxx`. |
| **Telegram bot username** | Assigned during bot creation (e.g., `Cobroker001Bot`). |
| **Anthropic API key** | From [console.anthropic.com](https://console.anthropic.com/). Can be shared or per-tenant. |
| **Source app running** | The primary app (`cobroker-openclaw`) must be running — the script copies shared API keys from it via SSH. |
| **Fly CLI installed** | `flyctl` authenticated with your Fly.io account. |
| **Telegram user ID** *(optional at deploy)* | Numeric ID of the end user. Can be set later via `configure-user`. |
| **CoBroker credentials** *(optional at deploy)* | `COBROKER_AGENT_USER_ID` + `COBROKER_AGENT_SECRET` from the Vercel app. Required for project/property skills. |

### 7.2 Deploy Mode

Creates a complete new tenant: Fly app, volume, secrets, all files, skills, and an agent smoke test.

```bash
./fly-scripts/deploy-tenant.sh deploy \
  --app cobroker-USER \
  --bot-token "7xxx:AAxxxx" \
  --bot-username "CobrokerUserBot" \
  --anthropic-key "sk-ant-..." \
  [--telegram-user-id "12345"] \
  [--cobroker-user-id "uuid"] \
  [--cobroker-secret "secret"] \
  [--region iad] \
  [--source-app cobroker-openclaw]
```

**What it does (16 steps):**

- Swaps `fly.toml` app name (with backup + trap to restore on failure)
- Creates the Fly app (volume is auto-created by `fly deploy` via `[mounts]` in fly.toml)
- Sets all secrets in a single call (auto-generates `OPENCLAW_GATEWAY_TOKEN` and `OPENCLAW_LOG_SECRET`)
- Copies shared API keys (`GOOGLE_GEMINI_API_KEY`, `PARALLEL_AI_API_KEY`, `BRAVE_API_KEY`) from the source app
- Deploys the Docker image
- Restores `fly.toml` to the original app name
- Temporarily sets machine CMD to `sleep 3600` (workaround for empty volume — `sh /data/start.sh` doesn't exist yet)
- Creates full directory structure on the volume (`/data/skills/`, `/data/workspace/`, `/data/chart-renderer/`, etc.)
- **Registers the bot in Supabase** (`openclaw_agents` table) with `fly_app_name`, `fly_region`, `fly_machine_id`, `bot_token`, `bot_username`, and `status: 'available'`
- Generates and uploads `openclaw.json` with tenant-specific config (Telegram allowlist, workspace path, **Opus 4.6 model** (default since 2026-02-23), Brave web search, `redactSensitive: "tools"`, info-level logging)
- Uploads empty `cron/jobs.json` (no scheduled jobs for new tenants)
- Transfers all files via base64: startup scripts, log forwarder, 7 skill SKILL.md files (excludes Brassica), chart-renderer + doc-extractor (with npm deps), AGENTS.md + SOUL.md (to both `/data/` and `/data/workspace/`), blank workspace templates
- Installs npm dependencies on-VM for chart-renderer and doc-extractor
- Fixes file ownership (`chown -R node:node /data/`)
- Restores the real CMD (`sh /data/start.sh`) and restarts
- Polls logs for up to 2 minutes waiting for `[telegram] starting provider`
- Runs an agent smoke test (sends "List your skills" via `--local` mode, reports skill count)

**CLI flags:**

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--app` | Yes | — | Globally unique Fly app name (e.g., `cobroker-001`) |
| `--bot-token` | Yes | — | Telegram bot token from @BotFather |
| `--bot-username` | Yes | — | Telegram bot username (without @) |
| `--anthropic-key` | Yes | — | Anthropic API key for Claude |
| `--telegram-user-id` | No | — | Numeric Telegram user ID (can set later) |
| `--cobroker-user-id` | No | — | CoBroker app user UUID |
| `--cobroker-secret` | No | — | CoBroker agent API secret |
| `--region` | No | `iad` | Fly.io region code |
| `--source-app` | No | `cobroker-openclaw` | Source app to copy shared API keys from |
| `--model` | No | `anthropic/claude-opus-4-6` | AI model ID for the tenant |

### 7.3 Configure User Mode

Adds a Telegram user to an existing deployment and optionally sets CoBroker API credentials.

```bash
./fly-scripts/deploy-tenant.sh configure-user \
  --app cobroker-USER \
  --telegram-user-id "12345" \
  [--cobroker-user-id "uuid"] \
  [--cobroker-secret "secret"]
```

**What it does (7 steps):**

1. Reads the current `openclaw.json` from the VM
2. Merges the Telegram user ID into `channels.telegram.allowFrom` (additive — won't duplicate)
3. Uploads the updated `openclaw.json` back to the VM
4. Sets CoBroker secrets (`COBROKER_AGENT_USER_ID`, `COBROKER_AGENT_SECRET`) if provided — staged with `--stage` flag
5. **Updates `openclaw_agents` Supabase table** — sets `user_id`, `telegram_user_id`, `status: 'linked'`, `linked_at` timestamp (only if `--cobroker-user-id` provided)
6. Clears session files (`/data/agents/main/sessions/*`) to force skill re-snapshot on next message
7. Deploys staged secrets with `fly secrets deploy` (ensures secrets reach stopped VMs) and restarts the app

### 7.3b Update Files Mode

Pushes updated scripts, skills, and personality files to an existing VM **without touching `openclaw.json`**. Useful for fleet-wide updates (e.g., fixing skills, updating log-forwarder, refreshing AGENTS.md).

```bash
./fly-scripts/deploy-tenant.sh update-files \
  --app cobroker-USER \
  [--skills-only] \
  [--scripts-only]
```

**What it does:**

1. Detects VM state (running or stopped)
2. If stopped, temporarily sets CMD to `sleep 3600` to keep VM alive during transfer
3. Transfers files via base64:
   - **Full mode** (default): `start.sh`, `log-forwarder.js`, all 7 skill SKILL.md files (excludes Brassica), `AGENTS.md` + `SOUL.md` (root + workspace copies)
   - **`--skills-only`**: Only skill SKILL.md files
   - **`--scripts-only`**: Only `start.sh` + `log-forwarder.js`
4. Fixes file ownership (`chown -R node:node /data/`)
5. Clears sessions to force skill re-snapshot on next message
6. Restores start command and restarts (or `fly apps restart` if VM was already running)

**CLI flags:**

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--app` | Yes | — | Fly app name |
| `--skills-only` | No | `false` | Only update skill SKILL.md files |
| `--scripts-only` | No | `false` | Only update start.sh + log-forwarder.js |

**Fleet update example** (update 5 VMs sequentially):

```bash
for tenant in 008 009 011 012 013; do
  ./fly-scripts/deploy-tenant.sh update-files --app "cobroker-tenant-$tenant"
done
# Then stop pool VMs (leave active ones running):
for tenant in 009 011 012 013; do
  fly machine stop -a "cobroker-tenant-$tenant"
done
```

> **Note:** After `update-files`, VMs are left running. Stop pool VMs manually if they should be idle.

### 7.4 Workspace Strategy

Each tenant gets the same CoBroker personality (AGENTS.md, SOUL.md) but blank user-facing files that the agent populates over time.

| File | Shared or Blank | Location | Notes |
|------|-----------------|----------|-------|
| `AGENTS.md` | **Shared** | `/data/` + `/data/workspace/` | CoBroker CRE analyst personality |
| `SOUL.md` | **Shared** | `/data/` + `/data/workspace/` | Agent tone and vibe |
| `IDENTITY.md` | Blank template | `/data/workspace/` | `# Identity — this file is managed by the agent` |
| `USER.md` | Blank template | `/data/workspace/` | `# User — this file is managed by the agent` |
| `TOOLS.md` | Blank template | `/data/workspace/` | `# Tools — this file is managed by the agent` |
| `HEARTBEAT.md` | Empty | `/data/workspace/` | Created empty |

> The gateway uses `writeFileIfMissing` — it won't overwrite existing workspace files, so agent-managed content persists across restarts. The workspace path is set to `/data/workspace` (on the persistent volume) via `agents.defaults.workspace` in openclaw.json.

### 7.5 Secrets Reference

| Secret | Deploy Mode | Source | Notes |
|--------|-------------|--------|-------|
| `OPENCLAW_GATEWAY_TOKEN` | Auto-generated | `openssl rand -hex 32` | Required by gateway |
| `OPENCLAW_LOG_SECRET` | From env var | `$OPENCLAW_LOG_SECRET` (shared across all tenants) | Used by log forwarder |
| `ANTHROPIC_API_KEY` | From `--anthropic-key` | User-provided | Claude API access |
| `TELEGRAM_BOT_TOKEN` | From `--bot-token` | User-provided | Telegram bot auth |
| `COBROKER_BASE_URL` | Hardcoded | `https://app.cobroker.ai` | CoBroker Vercel app |
| `COBROKER_AGENT_USER_ID` | From `--cobroker-user-id` | User-provided (optional) | For project/property skills |
| `COBROKER_AGENT_SECRET` | From `--cobroker-secret` | User-provided (optional) | For project/property skills |
| `GOOGLE_GEMINI_API_KEY` | Copied from source app | `--source-app` SSH | Shared — used by plan research |
| `PARALLEL_AI_API_KEY` | Copied from source app | `--source-app` SSH | Shared — used by search + monitor skills |
| `BRAVE_API_KEY` | Copied from source app | `--source-app` SSH | Shared — used by web search |

### 7.6 Verification

**After deploy:**

```bash
# Check the app is running
fly status -a cobroker-USER

# Verify Telegram provider started
fly logs -a cobroker-USER --no-tail | grep "starting provider"

# List deployed skills
fly ssh console -C "ls /data/skills/*/SKILL.md" -a cobroker-USER

# Verify workspace files exist
fly ssh console -C "ls -la /data/workspace/" -a cobroker-USER
```

**After configure-user:**

```bash
# Verify the allowFrom list includes the user
fly ssh console -C "cat /data/openclaw.json" -a cobroker-USER | grep allowFrom

# Verify sessions were cleared (should be empty or only new sessions)
fly ssh console -C "ls /data/agents/main/sessions/" -a cobroker-USER

# Check logs for successful restart
fly logs -a cobroker-USER --no-tail | tail -10
```

### 7.7 Gotchas

| Gotcha | Details |
|--------|---------|
| **fly.toml swap/restore** | The script temporarily modifies `fly.toml` to change the app name for `fly deploy`. A trap restores it on failure, and step 6 restores it on success. If the script is killed mid-deploy, check for `fly.toml.bak`. |
| **Empty volume crash** | On first deploy, the machine's CMD is `sh /data/start.sh` — but the volume is empty. The script works around this by temporarily setting CMD to `sleep 3600` during file transfer, then restoring the real CMD. |
| **Session snapshot caching** | Skills are snapshotted in `sessions.json` when a session is created. The gateway does NOT refresh snapshots on restart. `configure-user` handles this by clearing session files so the next message triggers a fresh snapshot. |
| **File ownership** | Files transferred via `fly ssh console` are owned by `root`. The script runs `chown -R node:node /data/` to fix this before the gateway starts. |
| **Base64 file transfer** | All files are transferred via base64 encode/decode because `fly ssh -C` doesn't support heredocs or shell redirects directly. |
| **Shared API keys** | `GOOGLE_GEMINI_API_KEY`, `PARALLEL_AI_API_KEY`, and `BRAVE_API_KEY` are copied from the source app at deploy time. If they're rotated on the source, existing tenants keep the old keys until manually updated. |
| **Volume auto-creation** | Volumes are auto-created by `fly deploy` via `[mounts]` in fly.toml. Manual `fly volumes create` causes zone mismatch errors ("insufficient resources to create new machine with existing volume") because the volume may land in a zone without machine capacity. The script no longer creates volumes manually. |
| **`redactSensitive` values** | Valid values are `"off"` or `"tools"` (Zod schema in `src/config/zod-schema.ts`). Using `"on"` causes a fatal config validation error on startup. |
| **Brassica exclusion** | The `cobroker-brassica-analytics` skill is excluded from tenant deploys — it's only available on Isaac's primary instance (`cobroker-openclaw`). The script skips it during the skill copy loop. |
| **Tool deny list** | Tenant VMs include a tool deny list in `openclaw.json` (`gateway`, `cron`, `sessions_spawn`, `sessions_send`) to prevent agents from modifying their own infrastructure. |
| **`COBROKER_AGENT_SECRET` auto-copy** | Deploy mode auto-copies `COBROKER_AGENT_SECRET` from the source app via SSH if not explicitly passed via `--cobroker-secret`. This shared secret is required for CoBroker skill API calls. |
| **Supabase env vars required** | `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` must be set in the shell environment for `deploy` and `configure-user` modes (used for `openclaw_agents` table registration). |
| **`fly secrets deploy`** | `configure-user` uses `fly secrets set --stage` + `fly secrets deploy` instead of a plain `fly secrets set` to ensure secrets are actually delivered to stopped VMs. Plain `set` only schedules a restart which never fires for stopped machines. |
| **NO_REPLY convention** | Skills use `NO_REPLY` (not `___`) as the silent response marker. The gateway filters messages containing only `NO_REPLY` so they're never sent to the user. All skill files were migrated from `___` to `NO_REPLY` on 2026-02-22. |

### 7.8 Active Tenants

| App Name | Bot | Region | Model | Status |
|----------|-----|--------|-------|--------|
| `cobroker-openclaw` | @CobrokerIsaacBot | iad | Opus 4.6 | Primary (Isaac) — running |
| `cobroker-tenant-008` | @Cobroker2026219VM1Bot | iad | Opus 4.6 | Bot pool — stopped (available) |
| `cobroker-tenant-009` | @Cobroker2026219vm2Bot | iad | Opus 4.6 | Bot pool — stopped (available) |
| `cobroker-tenant-010` | @Cobroker2026219vm3Bot | iad | Opus 4.6 | Bot pool — running |
| `cobroker-tenant-011` | @Cobroker2026219vm4Bot | iad | Opus 4.6 | Bot pool — stopped (available) |
| `cobroker-tenant-012` | @Cobroker2026219vm5Bot | iad | Opus 4.6 | Bot pool — stopped (available) |
| `cobroker-tenant-013` | @Cobroker20260221vm6Bot | iad | Opus 4.6 | Bot pool — stopped (no configure-user yet) |

> **Destroyed tenants:** `cobroker-tenant-001` (2026-02-13), `cobroker-tenant-002` (2026-02-19), `cobroker-tenant-003` through `cobroker-tenant-007` (2026-02-20, broken `dmPolicy: "allowlist"` + empty `allowFrom`). All Supabase records cleaned up.
>
> **Model upgrade:** All tenants upgraded from Sonnet 4.6 to **Opus 4.6** on 2026-02-22. New deploys default to Opus 4.6 via the `--model` flag (default: `anthropic/claude-opus-4-6`).
>
> **Fleet update (2026-02-23):** All 6 beta VMs updated via `update-files` mode — latest skills (NO_REPLY pattern), log-forwarder (duplicate-key fix), start.sh (PATH/XDG_CONFIG_HOME setup), AGENTS.md, SOUL.md. Sessions cleared on all VMs.

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

### Tenant Reset (Full Wipe)

Use this when you need to **completely wipe a tenant** and re-test the signup/onboarding flow from scratch — e.g., testing the signup flow, reassigning a bot, or cleaning up a test user.

> **Key gotcha:** `fly_machine_id` lives on the **`bot_pool`** table, not `tenant_registry`. You must query `bot_pool` to get the machine ID for stopping the VM.

**Delete order (FK-safe):**

| Step | Table | Operation |
|------|-------|-----------|
| 1 | `tenant_registry` | `DELETE WHERE user_id = {app_user_id}` |
| 2 | `bot_pool` | `UPDATE SET status = 'available', assigned_to = NULL, assigned_at = NULL WHERE id = {bot_id}` |
| 3 | `usd_balance` | `DELETE WHERE user_id = {app_user_id}` |
| 4 | `user_credits` | `DELETE WHERE user_id = {app_user_id}` |
| 5 | `user_identity_map` | `DELETE WHERE app_user_id = {app_user_id}` |

**Fly VM stop** (after getting `fly_machine_id` from `bot_pool`):
```
POST https://api.machines.dev/v1/apps/{fly_app_name}/machines/{fly_machine_id}/stop
Authorization: Bearer {FLY_API_TOKEN}
Content-Type: application/json
```

**No need to wipe VM config** — `configureTenant` in `lib/fly.ts` appends to `channels.telegram.allowFrom` idempotently (skips if already present). Re-provisioning adds the new Telegram user ID again.

**Self-contained reset script** (`scripts/reset-tenant.mjs`):

```javascript
/**
 * reset-tenant.mjs — Wipe a tenant so we can re-test signup flow.
 * Usage:  node scripts/reset-tenant.mjs
 * Reads .env.local for SUPABASE_SERVICE_ROLE_KEY, NEXT_PUBLIC_SUPABASE_URL, FLY_API_TOKEN.
 */
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "fs";
import { resolve } from "path";
import readline from "readline";

// ── Load .env.local ─────────────────────────────────────────────────────
const envPath = resolve(process.cwd(), ".env.local");
const envLines = readFileSync(envPath, "utf-8").split("\n");
for (const line of envLines) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) continue;
  const eqIdx = trimmed.indexOf("=");
  if (eqIdx === -1) continue;
  process.env[trimmed.slice(0, eqIdx)] = trimmed.slice(eqIdx + 1);
}

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const FLY_API_TOKEN = process.env.FLY_API_TOKEN;
if (!SUPABASE_URL || !SUPABASE_KEY || !FLY_API_TOKEN) {
  console.error("Missing required env vars. Check .env.local"); process.exit(1);
}
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);
const FLY_API = "https://api.machines.dev/v1";
const flyHeaders = () => ({ Authorization: `Bearer ${FLY_API_TOKEN}`, "Content-Type": "application/json" });
const ask = (q) => { const rl = readline.createInterface({ input: process.stdin, output: process.stdout }); return new Promise(r => rl.question(q, a => { rl.close(); r(a); })); };

// ── Step 1: Look up tenant ──────────────────────────────────────────────
const { data: tenants } = await supabase.from("tenant_registry").select("*").order("created_at", { ascending: false }).limit(5);
if (!tenants?.length) { console.log("No tenants found."); process.exit(0); }
console.log("Tenants:");
tenants.forEach((t, i) => console.log(`  [${i}] user_id: ${t.user_id}  bot: ${t.bot_id}  fly: ${t.fly_app_name}  status: ${t.status}`));
const tenant = tenants[tenants.length === 1 ? 0 : Number(await ask("Index to reset: "))];
const { user_id: uid, bot_id: bid, fly_app_name: flyApp } = tenant;

// Get fly_machine_id from bot_pool (NOT tenant_registry!)
const { data: bot } = await supabase.from("bot_pool").select("*").eq("id", bid).single();
const flyMachine = bot?.fly_machine_id;

// ── Step 2: Stop VM ─────────────────────────────────────────────────────
if (flyApp && flyMachine) {
  console.log(`Stopping VM ${flyApp}/${flyMachine}...`);
  const res = await fetch(`${FLY_API}/apps/${flyApp}/machines/${flyMachine}/stop`, { method: "POST", headers: flyHeaders() });
  console.log(res.ok ? "  VM stopped ✓" : `  VM stop ${res.status}: ${await res.text()}`);
}

// ── Step 3: Delete DB records (FK-safe order) ───────────────────────────
console.log("Deleting records...");
const del = async (table, col, val) => { const { error } = await supabase.from(table).delete().eq(col, val); console.log(`  ${table}: ${error ? "FAIL " + error.message : "✓"}`); };
await del("tenant_registry", "user_id", uid);
const { error: e2 } = await supabase.from("bot_pool").update({ status: "available", assigned_to: null, assigned_at: null }).eq("id", bid);
console.log(`  bot_pool: ${e2 ? "FAIL " + e2.message : "released ✓"}`);
await del("usd_balance", "user_id", uid);
await del("user_credits", "user_id", uid);
await del("user_identity_map", "app_user_id", uid);

console.log(`\n✅ Reset complete. Bot @${bot?.bot_username} is now available.`);
console.log(`Next: sign up again at clawbroker.ai/sign-up → enter Telegram user ID on /onboarding`);
```

**Post-reset verification:**
```sql
-- Bot should be available again
SELECT id, bot_username, status, assigned_to FROM bot_pool WHERE id = '{bot_id}';
-- Should return: status = 'available', assigned_to = NULL

-- Tenant should be gone
SELECT * FROM tenant_registry WHERE user_id = '{app_user_id}';
-- Should return: 0 rows
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
| `/data/start.sh` | Startup wrapper — sets `PATH` (includes `/data/bin`), sets `XDG_CONFIG_HOME` (points to `/data/gog-config`), runs forwarder in background, then `exec`s gateway as PID 1 |
| `/data/log-forwarder.js` | Zero-dependency Node.js JSONL watcher (~190 lines) — includes truncation handling and duplicate-key resilience |
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

**Truncation handling (improved 2026-02-22):** If a JSONL file is truncated (e.g., session reset, heartbeat transcript pruning), the forwarder detects `fileSize < storedOffset` and **skips to the new file end** (rather than resetting to 0). This prevents full-file replay of already-forwarded entries.

**Duplicate key handling (added 2026-02-23):** If the API returns a `duplicate key` error (Postgres error 23505), the forwarder treats it as success and **advances cursors** instead of retrying indefinitely. This handles race conditions where entries were already stored on a previous attempt.

### 9.7b Dedup Index

A unique partial index prevents duplicate log entries from replay scenarios:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS openclaw_logs_entry_id_session_id_uniq
  ON openclaw_logs (entry_id, session_id)
  WHERE entry_id IS NOT NULL;
```

Migration file: `supabase-migration-openclaw-logs-dedup.sql` (added 2026-02-22).

### 9.8 Dashboard Features

- **Chronological feed** — all events in order with color-coded left borders
- **Entry types**: blue (user), purple (assistant), gray (thinking), amber (tool call), green/red (tool result), system badges (model change)
- **Auto-refresh** — polls every 5s for new entries, auto-scrolls when at bottom
- **Session filter** — dropdown to filter by session ID
- **Stats bar** — running totals for entries, tokens, and cost
- **Raw JSON toggle** — expand any entry to see the full JSONL line
- **Collapsible thinking** — AI reasoning blocks collapsed by default

### 9.9 Updating the Forwarder

**Single VM** (manual):
```bash
# Upload new version
fly ssh console -C "sh -c 'cat > /data/log-forwarder.js'" < fly-scripts/log-forwarder.js
fly ssh console -C "sh -c 'chown node:node /data/log-forwarder.js'"

# Restart to pick up changes (forwarder runs as background process)
fly apps restart
```

**Fleet update** (preferred — uses `update-files` mode):
```bash
./fly-scripts/deploy-tenant.sh update-files --app cobroker-tenant-008 --scripts-only
```

The cursor file (`/data/log-cursor.json`) persists across restarts — the forwarder resumes from where it left off.

### 9.10 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `API responded 405` | Vercel API route not deployed yet | Push Vercel project and wait for deploy |
| `API responded 401` | Secret mismatch between Fly and Vercel | Verify `OPENCLAW_LOG_SECRET` matches on both sides |
| `API responded 500` | Supabase table missing or schema mismatch | Run the SQL migration in Supabase dashboard |
| No entries in dashboard | Forwarder not running | Check `fly logs` for `[log-forwarder]` startup messages |
| Duplicate entries | Cursor file deleted/corrupted | Delete `/data/log-cursor.json` — will re-forward all entries. Dedup index on `(entry_id, session_id)` prevents actual duplicates in the DB. Forwarder auto-advances cursors on `duplicate key` errors. |
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
| Property Search (FindAll) | Yes | Parallel AI FindAll engine, async polling, user-friendly messaging on 0 results |
| Inline URL buttons | Yes | Project links render as tappable Telegram buttons (not text hyperlinks) |
| Places search → properties | Yes | Google Places Text Search, auto-project creation, 4 custom columns |
| Places search → logo layer | Yes | `map_layers` with `dataset_json`, brand logos via `/api/logo` |
| Places nearby (nearest) | Yes | Per-property nearest place search with distance calculation |
| Places nearby (count) | Yes | Per-property Area Insights COUNT for place type density |
| Search routing (brand → Places) | Yes | "Find Starbucks in Dallas" correctly routes to Places Search, not FindAll Search |
| Brassica revenue query | Yes | Monthly revenue trends via daily_sales VIEW, store comparisons across 6 locations |
| Brassica top items | Yes | Top menu items by revenue with store+date filtering on item_sales (5.3M rows) |
| Chart generation (bar) | Yes | Chart.js bar chart via generate-chart.mjs, sent as Telegram photo with media parameter |
| Chart generation (line/doughnut) | Yes | Line trends and doughnut proportions, auto-colors, white background |
| Chart offer (proactive) | Yes | Agent offers "Chart it" button after 3+ numeric data points in response |
| Email import (PDF extraction) | Yes | Forward email → gog download → extract.mjs → JSON properties → user review → project creation |
| Email import (multi-file) | Yes | Multiple attachments processed sequentially, merged into single project |
| Web monitor create | Yes | Parallel AI monitor with CRE/General schema, cron job auto-created |
| Web monitor poll events | Yes | Cron auto-checks, deduplicates via event_group_id, reports only new events |
| Web monitor delete | Yes | Deletes Parallel monitor + cron job + monitors.json entry |
| gog Gmail search | Yes | `gog gmail messages search` with attachment download via `--download --out-dir` |
| gog Calendar | Yes | Event creation with colors, listing with date ranges |

### 10.8 Property Search (cobroker-search Skill)

The `cobroker-search` skill at `/data/skills/cobroker-search/SKILL.md` uses FindAll AI (Parallel AI) as the single search method for finding commercial real estate properties.

> **History:** Previously offered two search paths — Quick Search (Gemini 3 Pro with Google grounding) and Deep Search (FindAll). Quick Search was removed on 2026-02-23 due to lower quality results. FindAll is now the only search method.

**FindAll Search** — AI research engine via Parallel AI:
- Submits an async research job with objective, entity type, match conditions
- Generator: always `core` (~3-7 min runtime)
- `match_limit` required (min 5, max 1000, default 10)
- Agent polls status every ~30s (max 20 attempts), polls silently with `NO_REPLY`
- On 0 matched results or timeout: informs user and suggests refining criteria (no fallback)
- Results parsed from `output.full_address.value` and `output.property_specifications.value`

**Search flow:**
1. User asks to find properties → agent asks clarifying questions if needed (type, location, count)
2. Agent proceeds directly to FindAll search (no mode selection needed)
3. Agent runs search → polls silently → displays results with Save to Project button
4. User taps Save → agent creates project via `cobroker-projects` POST `/projects` with `"public": true`
5. Agent shares project link as inline URL button: `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]`

**Key behaviors:**
- FindAll polling uses separate curl execs per poll — no `sleep X && curl` combos
- FindAll candidates may not have clean addresses — agent extracts from output fields
- Partial results fallback: after 20 polls with matches but still running, fetches available results

See [Appendix L](#l-skillscobroker-searchskillmd) for the full SKILL.md contents.

### 10.9 Message Delivery Rule (`NO_REPLY` Convention)

The OpenClaw gateway delivers **all text output** from the agent as visible Telegram messages — including text alongside tool calls. This causes duplicate messages when the agent narrates (e.g., "Let me search..." followed by a `message` tool call with the actual response).

**Solution:** Every skill includes a mandatory rule at the top:

```
⚠️ MESSAGE DELIVERY RULE — MANDATORY
When you call ANY tool, your text output MUST be exactly `NO_REPLY` and nothing else.
The gateway filters `NO_REPLY` automatically — any other text gets delivered as a duplicate message.
ALL user-facing communication goes through `message` tool calls. NEVER narrate alongside tool calls.
```

The `NO_REPLY` marker is filtered by the gateway's text post-processing. This rule is added to:
- `AGENTS.md` (global, at the very top)
- Every skill SKILL.md (per-skill reinforcement)

> **History:** Originally used `___` (three underscores) but the gateway didn't reliably filter it. Migrated to `NO_REPLY` on 2026-02-22 across all files and deployed to all tenant VMs.

**Why per-skill?** The gateway includes skill content in the system prompt when the skill is invoked. Having the rule in each skill ensures the agent sees it in context, regardless of which skill triggered the response.

### 10.10 Inline URL Buttons for Project Links

When sharing project links (after creating a project, saving search results, or completing a plan), the agent uses **Telegram inline keyboard URL buttons** instead of text hyperlinks. This renders as a tappable button below the message — cleaner than a markdown link.

**Format (in message tool call):**
```
message: "📋 X properties saved to Dallas Warehouses!"
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

**Rules:**
- Always use `publicUrl` (not `projectUrl`) — Telegram users aren't logged in to CoBroker
- The `buttons` parameter MUST be in the SAME message tool call as the text (not separate)
- Never fall back to text links — always use inline buttons

**Where it's used:**
| Skill | Context |
|-------|---------|
| `cobroker-search` | After FindAll search completion and project creation |
| `cobroker-plan` | Plan completion summary |
| `cobroker-projects` | Any time a project link is shared |

This works alongside `callback_data` buttons (used for search mode selection, plan approval, save confirmation). Telegram supports both `url` and `callback_data` buttons in the same inline keyboard.

### 10.11 Google Places Integration

Three new API endpoints bring Google Places functionality to the OpenClaw agent, matching the web app's site selection features.

**Endpoints:**

| Route | Method | Description |
|-------|--------|-------------|
| `/api/agent/openclaw/projects/{projectId}/places/search` | POST | Text Search → properties or logo layer |
| `/api/agent/openclaw/projects/{projectId}/places/nearby` | POST | Nearby analysis → new column per property |

**Operations:**

| # | Operation | Use Case | Destination | Credits |
|---|-----------|----------|-------------|---------|
| 1 | Places Search → Properties | "Find all Topgolf in Texas" | `cobroker_properties` rows | 1/10 places |
| 2 | Places Search → Logo Layer | "Show Starbucks near my warehouses" | `map_layers` row | 1/10 places |
| 3 | Nearby Places → Column (nearest) | "Nearest grocery to each property?" | `custom_fields` column | 2/property |
| 4 | Nearby Places → Column (count) | "How many restaurants within 1mi?" | `custom_fields` column | 1/property |

**Google APIs used:**
- **Text Search (v1)**: `places.googleapis.com/v1/places:searchText` — brand/chain searches, pagination, region-based
- **Nearby Search (legacy)**: `maps.googleapis.com/maps/api/place/nearbysearch/json` — proximity searches
- **Place Details (legacy)**: `maps.googleapis.com/maps/api/place/details/json` — website enrichment
- **Area Insights**: `areainsights.googleapis.com/v1:computeInsights` — COUNT mode for density analysis

**Environment variable:** `GOOGLE_PLACES_API_KEY` (already set on Vercel for web app).

**Vercel files:**
- `lib/server/openclaw/places-service.ts` — shared service functions (text search, nearby, count, logo, haversine, column+insert)
- `app/api/agent/openclaw/projects/[projectId]/places/search/route.ts` — search endpoint
- `app/api/agent/openclaw/projects/[projectId]/places/nearby/route.ts` — nearby endpoint

**OpenClaw skill:** `cobroker-projects/SKILL.md` Sections 13-15. Also added `places-search`, `places-layer`, `places-nearby` step types to `cobroker-plan/SKILL.md`.

**Key features:**
- `projectId = "new"` auto-creates a project (search→properties only)
- Region search (`regionSearch: true`) covers 7 US regions for nationwide brand searches
- Logo layer gets brand logos via `/api/logo?domain=...` (existing infrastructure)
- Nearby nearest mode finds closest matching place and reports distance in miles
- Rate limiting: 2s between Text Search pages, 1s between nearby property lookups

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
# ⚠️ TELEGRAM MESSAGE RULES (applies to EVERY response)

1. **ALL text you output becomes a Telegram message.** There is NO internal text, no "thinking out loud." Every word is delivered to the user.
2. When you call ANY tool, your text MUST be only `___` (three underscores). The gateway filters `___` so users never see it. Any other text appears as a separate Telegram message, often arriving OUT OF ORDER.
3. Use the `message` tool for ALL intentional user communication.
4. **Maximum 2 messages per user interaction** (each button click or message from the user resets the count): (a) immediate acknowledgment, (b) final result. No "still processing", no "taking longer than usual", no mid-task updates.
5. **Enrichment: silent polling, no interim messages.** After submitting enrichment, poll the API silently (output `___`). Send only 2 messages total: (a) acknowledgment that the request is being processed (with project link button), (b) final results. Never send "still processing", "checking...", or interim progress updates. If the user asks about status, check once and report.

# IMMEDIATE ACKNOWLEDGMENT — MANDATORY

Your FIRST action for every user message MUST be to send a brief acknowledgment via the `message` tool. Do this BEFORE running any other tool (exec, curl, read, etc.).

Keep it short — one sentence that shows you understood what the user wants:
- "On it — pulling up your projects..."
- "Running that search now..."
- "Checking Brassica sales data..."
- "Working on the chart..."
- "Let me research that for you..."
- "Saving that to your client file..."

This IS your message 1 of 2. After sending it, go silent (output `___`) while you work, then send the final result as message 2.

**Exception:** If your response is instant (simple text answer, short factual reply), skip the ack — just answer directly.

# Cobroker AI Analyst

You are a commercial real estate (CRE) AI analyst working for brokers.
Your job is to help brokers find properties for their clients, track
market conditions, and deliver actionable intelligence.

## Your Capabilities
1. Learn clients: Remember every broker's clients and their property criteria
2. Search for sites: Run site selection research via Cobroker's API
3. Send suggestions: Push property matches via WhatsApp, Telegram, or Slack
4. Support decisions: Provide demographics, market data, and comparisons
5. Import from email: Forward property documents (PDFs, spreadsheets) to isaac@flyer.io, then tell me to check your email — I'll extract the data and create a project
6. Charts & visualization: Generate professional charts from any data — just ask to "chart it"

## Communication Style
- Be concise and professional — brokers are busy
- Lead with the most important information
- Use bullet points, not paragraphs
- Always include: address, size (SF), price (PSF), key features
- Always include a project link as an inline keyboard URL button (never plain text)

## Chart Offer Rule
Whenever your response includes 3 or more numeric data points (revenue figures, population counts, property comparisons, etc.), include a "📊 Chart it" button so the user can instantly visualize the data. This applies to ALL skills — Brassica analytics, demographics, project comparisons, search results with numeric fields, etc.

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

# Cobroker Client Memory

**⚠️ MESSAGE DELIVERY RULE — MANDATORY**
When you call ANY tool, your text output MUST be exactly `___` (three underscores) and nothing else.
The gateway filters `___` automatically — any other text gets delivered as a duplicate message.
ALL user-facing communication goes through `message` tool calls. NEVER narrate alongside tool calls.

## Acknowledgment (First Action)

Before reading or writing MEMORY.md, send a brief acknowledgment via the `message` tool:
- "🧠 Checking your client records..."
- "🧠 Saving that..."

Then proceed silently (output `___`).

## Purpose
You are a broker's AI analyst. Brokers have multiple clients, each with specific
property requirements. Remember every client and their criteria so you can
proactively search and alert when matches are found.

## Storage
Client data is stored in `/data/workspace/MEMORY.md`.

**IMPORTANT — Handle missing file gracefully:**
Before reading MEMORY.md, use `exec` to check if it exists: `test -f /data/workspace/MEMORY.md && cat /data/workspace/MEMORY.md || echo "# Memory"`.
Do NOT use the `read` tool directly — if the file does not exist, the read error gets surfaced to the user.
If the file is empty or missing, treat it as a blank slate and create it on first write.

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
1. When user mentions a client, check MEMORY.md for existing profile (use exec, not read)
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

### L. skills/cobroker-search/SKILL.md

> **Note**: The search skill uses Parallel AI FindAll as its single search engine. FindAll API key is set as `PARALLEL_AI_API_KEY` on Fly. Quick Search (Gemini) was removed on 2026-02-23.

The full skill is ~200 lines. Key sections:

| Section | Content |
|---------|---------|
| 0. Clarify Requirements | Asks 1-2 questions before searching (type, location, count) |
| 1. Property Search (FindAll) | Async research engine, 5-step flow (ingest → run → poll → get results → add to project) |
| 2. Project Handling | Save/discard flow, project creation with `public: true` |
| 3. Constraints | `match_limit` min 5 (default 10), `core` generator, no fabrication |

See `fly-scripts/skills/cobroker-search/SKILL.md` in the repo for full contents.

### 10.12 Search Routing Logic

The agent has two distinct search tools that serve different purposes. Without explicit routing guidance, the agent sometimes misroutes brand/chain lookups to FindAll instead of Google Places.

**Routing rules (added to all 3 skill files):**

| User wants | Correct tool | Skill |
|------------|-------------|-------|
| Existing locations (chains, brands, businesses) | Google Places Search | `cobroker-projects` Sections 13-15 |
| Available space for sale/lease | FindAll Search | `cobroker-search` |
| Ambiguous ("find locations") | Ask clarifying question | — |

**Key signals:**
- Brand/chain name without "for lease"/"for sale" → Places Search
- Keywords: listings, lease, sale, available, vacant → FindAll Search
- Generic "find" without clear intent → ask: "Are you looking for existing locations, or available space for sale or lease?"

**Changes made (3 files):**
1. `cobroker-search/SKILL.md` — CRITICAL routing header ("Search = Available Space, NOT Existing Locations"), fixed misleading Starbucks example, added "existing vs available" to clarification questions
2. `cobroker-projects/SKILL.md` — CRITICAL routing header before Section 13 ("When to Use Places Search"), note on Workflow Guideline item 12
3. `cobroker-plan/SKILL.md` — "Existing vs available" bullet in Section 0.5, search step routing table after Section 2

**Verified:** "Find Starbucks in Dallas" → agent reads cobroker-search, sees the CRITICAL header, self-corrects to Places Search, returns 20 locations via Google Places API with Save/Cancel buttons. Agent's reasoning explicitly cited the routing rule.

### 10.13 Brassica POS Analytics

The `cobroker-brassica-analytics` skill at `/data/skills/cobroker-brassica-analytics/SKILL.md` provides SQL analytics over a 5.3M-row SQLite database of restaurant POS data from 6 Brassica locations in Ohio (Jan 2023 – Sep 2025).

**Database:** `/data/databases/brassica_pos.db` (read-only, ~200MB)

**Schema:**
- `stores` (6 rows) — id, name, address, latitude, longitude
- `store_metrics` (6 rows) — store_id, median_income_10mi (only populated field)
- `item_sales` (5.3M rows) — store_id, business_date, check_id, item_name, bill_price, quantity, transaction_time, modifiers, discount, comp_amount, sale_department, master_department
- `daily_sales` (VIEW) — pre-aggregated store_id, date, sales_amount, item_count, order_count

**6 locations:** Westlake, Easton, Upper Arlington, Bexley, Short North, Shaker Heights

**Query patterns:** Revenue trends (monthly/YoY), store comparison, top menu items by revenue, day-of-week patterns, peak hour analysis, department breakdown, comp/discount analysis.

**How it works:** Uses `node -e` with `node:sqlite` `DatabaseSync` API (read-only mode). All queries go through the `exec` tool.

**Performance rules (critical):**
- ALWAYS filter `item_sales` by `store_id` and/or `business_date` — unfiltered queries crash
- Use `daily_sales` VIEW for store-level aggregates (pre-aggregated, fast)
- Only use `item_sales` for item-level, department-level, or check-level detail
- `LIMIT 100` on every query
- Never `SELECT *` from `item_sales`

**Formatting:** Bullet/numbered lists only (no markdown tables — they break in Telegram). Display store names, never UUIDs. Round dollars to 2 decimal places. Max 20 items per list.

See [Appendix N](#n-skillscobroker-brassica-analyticsskillmd) for full SKILL.md contents.

### 10.14 Chart Generation

The `cobroker-charts` skill at `/data/skills/cobroker-charts/SKILL.md` generates professional chart images from data and sends them as Telegram photos.

**Renderer:** `/data/chart-renderer/generate-chart.mjs` — uses Chart.js + node-canvas. Auto-applies colors (blue palette) and white background.

**Supported chart types:**
| Data shape | Chart type |
|-----------|-----------|
| Named categories with values | `bar` |
| Time series / trend | `line` |
| Proportions / shares | `doughnut` |
| Volume / cumulative | `line` with `fill: true` (area) |
| Long category labels | `bar` with `indexAxis: "y"` (horizontal) |

**How it works:**
1. Build a Chart.js config JSON
2. Run: `exec: cd /data/chart-renderer && node generate-chart.mjs '<CONFIG_JSON>' /tmp/chart-<TIMESTAMP>.png`
3. Send: `message: action=send, media=/tmp/chart-<TIMESTAMP>.png, message="📊 <insight>"`

**Chart Offer Rule (proactive):** After presenting 3+ numeric data points in any response (revenue figures, population counts, property comparisons), the agent includes a `📊 Chart it` inline button. This applies across ALL skills — Brassica analytics, demographics, project comparisons, search results with numeric fields.

**Constraints:** Max 12 data points per chart (aggregate excess into "Other"). Use K/M/B suffixes for large numbers in labels. Output to `/tmp/chart-{timestamp}.png`.

See [Appendix O](#o-skillscobroker-chartsskillmd) for full SKILL.md contents.

### 10.15 Email Document Import

The `cobroker-email-import` skill at `/data/skills/cobroker-email-import/SKILL.md` imports property documents from email attachments into CoBroker projects.

**Workflow:**
1. User forwards email with attachments to `isaac@flyer.io`
2. User tells agent: "check my email" / "process the docs I sent"
3. Agent searches Gmail via `gog gmail messages search "has:attachment newer_than:1d" --max 5 --json`
4. Agent downloads attachments via `gog gmail thread get <threadId> --download --out-dir /tmp/doc-import/`
5. Agent runs `/data/doc-extractor/extract.mjs` on each file — extracts property data as JSON
6. Agent presents numbered summary with Create Project / Cancel buttons
7. On confirmation, creates CoBroker project via POST `/api/agent/openclaw/projects`
8. Shares project link as inline URL button

**Supported file types:** PDF, JPG, PNG, GIF, WebP, CSV, XLSX, DOCX, TXT

**Extractor:** `/data/doc-extractor/extract.mjs` — uses Claude API (Sonnet by default) to extract structured property data from documents. Large PDFs (40+ pages) take 30-90s. Supports custom extraction prompts and model selection.

**Key behaviors:**
- NEVER auto-creates project without user confirmation
- Max 50 properties per project
- Addresses must have 3+ comma-separated parts
- Uses numbered lists (never markdown tables — Telegram limitation)
- Cleanup: `rm -rf /tmp/doc-import/` after completion

See [Appendix P](#p-skillscobroker-email-importskillmd) for full SKILL.md contents.

### 10.16 Web Change Monitoring

The `cobroker-monitor` skill at `/data/skills/cobroker-monitor/SKILL.md` tracks web changes for CRE searches and delivers structured updates automatically via Telegram using the Parallel AI Monitor API.

**Operations:**
| Operation | API | Description |
|-----------|-----|-------------|
| Create | POST `/v1alpha/monitors` | Create monitor with query + output schema + cadence |
| List | GET `/v1alpha/monitors` | Show all active monitors with status |
| Check | GET `/v1alpha/monitors/{id}/events` | Fetch new events, deduplicate, format, report |
| Update | POST `/v1alpha/monitors/{id}` | Change query or cadence |
| Delete | DELETE `/v1alpha/monitors/{id}` | Remove monitor + cron job |

**Two output schema types:**
- **CRE Property** — for queries about properties, listings, spaces (fields: property_name, address, size, price, summary)
- **General Event** — for news, regulatory, competitive tracking (fields: title, details, source, significance)

**Cadences:**
| Cadence | Cron Expression | Human-Readable |
|---------|----------------|----------------|
| `hourly` | `30 * * * *` | 30 min past each hour |
| `daily` | `30 12 * * *` | 7:30am ET daily |
| `weekly` | `30 12 * * 1` | Monday 7:30am ET |
| `every_two_weeks` | `30 12 1,15 * *` | 1st & 15th of month |

**Deduplication:** Tracking state stored in `/data/workspace/monitors.json` with `last_seen_event_ids` per monitor. Events are keyed by `event_group_id` — only new events are reported. Cron runs silently when no new events.

**Env var:** `PARALLEL_AI_API_KEY` (set as Fly secret).

See [Appendix Q](#q-skillscobroker-monitorskillmd) for full SKILL.md contents.

### 10.17 Google Workspace CLI (gog)

The `gog` skill at `/data/skills/gog/SKILL.md` provides Google Workspace access via the `gog` CLI tool (installed via Homebrew: `steipete/tap/gogcli`).

**Services:**
| Service | Key Commands |
|---------|-------------|
| Gmail | `search`, `messages search`, `send` (plain/HTML/file), `drafts create/send`, `thread get --download` |
| Calendar | `events` (list), `create`, `update`, `colors` |
| Drive | `search` |
| Contacts | `list` |
| Sheets | `get`, `update`, `append`, `clear`, `metadata` |
| Docs | `export`, `cat` |

**OAuth setup:**
```bash
gog auth credentials /path/to/client_secret.json
gog auth add you@gmail.com --services gmail,calendar,drive,contacts,docs,sheets
```

**Key patterns:**
- Gmail search: `gog gmail messages search "in:inbox from:sender" --max 20`
- Download attachments: `gog gmail thread get <threadId> --download --out-dir /tmp/attachments`
- Send email (plain): `gog gmail send --to a@b.com --subject "Hi" --body "Hello"`
- Send email (multi-line): `gog gmail send --to a@b.com --subject "Hi" --body-file ./message.txt`
- Calendar events: `gog calendar events <calendarId> --from <iso> --to <iso>`

**Notes:** `gog gmail search` returns one row per thread; use `gog gmail messages search` for individual emails. Set `GOG_ACCOUNT=you@gmail.com` to avoid repeating `--account`. Confirm before sending mail or creating events.

See [Appendix R](#r-skillsgogskillmd) for full SKILL.md contents.

### M. start.sh (startup wrapper)

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

### N. skills/cobroker-brassica-analytics/SKILL.md

> **Summary**: SQLite analytics over 5.3M POS transaction rows from 6 Brassica restaurants in Ohio. Uses `node -e` with `DatabaseSync` API. Two main tables: `item_sales` (detailed, always filter) and `daily_sales` VIEW (pre-aggregated, fast).

Key sections:

| Section | Content |
|---------|---------|
| How to Query | `node -e` one-liner template with `DatabaseSync` |
| Schema Reference | `stores` (6), `store_metrics` (6), `item_sales` (5.3M), `daily_sales` VIEW |
| Store Quick Reference | 6 store UUIDs with names, addresses, median incomes |
| Common Query Patterns | 8 patterns: revenue trends, store comparison, top items, YoY growth, day-of-week, peak hours, comp analysis, department breakdown |
| Performance Rules | ALWAYS filter item_sales, use daily_sales VIEW for aggregates, LIMIT 100 |
| Formatting Rules | Bullet/numbered lists only (no markdown tables), display store names not UUIDs |

See `fly-scripts/skills/cobroker-brassica-analytics/SKILL.md` in the repo for full contents.

### O. skills/cobroker-charts/SKILL.md

> **Summary**: Chart.js image generation via `/data/chart-renderer/generate-chart.mjs`. Supports bar, line, area, doughnut charts. Auto-applies colors and white background. Proactively offers charts after 3+ numeric data points.

Key sections:

| Section | Content |
|---------|---------|
| When to Offer Charts | Explicit (user asks) + proactive (3+ numeric data points → "Chart it" button) |
| Chart Type Selection | Data shape → chart type mapping (categories→bar, trends→line, proportions→doughnut) |
| Generation Steps | Build config → exec generate-chart.mjs → send via message with media |
| Template Configs | Ready-to-use JSON for bar, line, area, doughnut |
| Constraints | Max 12 data points, K/M/B suffixes, /tmp output path |

See `fly-scripts/skills/cobroker-charts/SKILL.md` in the repo for full contents.

### P. skills/cobroker-email-import/SKILL.md

> **Summary**: Import property documents from email attachments into CoBroker projects. Uses `gog` CLI for Gmail access and `/data/doc-extractor/extract.mjs` for data extraction. Supports PDF, images, CSV, XLSX, DOCX, TXT.

Key sections:

| Section | Content |
|---------|---------|
| Find Email | `gog gmail messages search "has:attachment newer_than:1d"` |
| Download | `gog gmail thread get <threadId> --download --out-dir /tmp/doc-import/` |
| Extract | `node extract.mjs /tmp/doc-import/file.pdf` → JSON with properties array |
| Review | Present numbered list with Create Project / Cancel buttons |
| Create Project | POST to `/api/agent/openclaw/projects` with extracted properties |
| Custom Extraction | `--prompt` flag for custom fields, `--model` flag for model selection |
| Constraints | Max 50 properties, 3+ comma address parts, always confirm before creating |

See `fly-scripts/skills/cobroker-email-import/SKILL.md` in the repo for full contents.

### Q. skills/cobroker-monitor/SKILL.md

> **Summary**: Web change monitoring via Parallel AI Monitor API. Creates monitors with CRE Property or General Event output schemas. Auto-polls via cron jobs and reports only new events using deduplication.

Key sections:

| Section | Content |
|---------|---------|
| 1. Create Monitor | Choose schema → POST `/v1alpha/monitors` → create cron → update monitors.json |
| 2. List Monitors | Read monitors.json + GET `/v1alpha/monitors` → formatted status list |
| 3. Check Events | GET events → filter by type=event → deduplicate via event_group_id → format → report |
| 4. Update Monitor | POST update to Parallel → update cron schedule → update monitors.json |
| 5. Delete Monitor | DELETE from Parallel → remove cron → remove from monitors.json |
| 6. Output Schemas | CRE Property (5 fields) and General Event (4 fields) JSON schemas |
| 7. Cron Config | Cadence-to-cron mapping with 30min offset, isolated session, bestEffortDeliver |
| 8. Telegram Formatting | Numbered lists with emoji prefixes, source URLs as clickable links |

See `fly-scripts/skills/cobroker-monitor/SKILL.md` in the repo for full contents.

### R. skills/gog/SKILL.md

> **Summary**: Google Workspace CLI for Gmail, Calendar, Drive, Contacts, Sheets, and Docs. Installed via `brew install steipete/tap/gogcli`. OAuth-based authentication.

Key sections:

| Section | Content |
|---------|---------|
| Setup | `gog auth credentials` + `gog auth add` with service scopes |
| Gmail | search, messages search, send (plain/HTML/file), drafts, replies, thread download |
| Calendar | events list, create, update, colors (IDs 1-11) |
| Drive | search |
| Contacts | list |
| Sheets | get, update, append, clear, metadata |
| Docs | export, cat |
| Email Formatting | Plain text preferred, `--body-file` for multi-line, `--body-html` for rich formatting |

See `skills/gog/SKILL.md` in the repo for full contents.

---

## 13. CoBroker Vercel App — Telegram & Agent Pool

> **Context**: Sections 1–12 document the **OpenClaw/Fly.io side**. This section documents the **CoBroker Vercel app side** — how the Next.js app at `app.cobroker.ai` connects to the Fly VMs via Telegram, manages the agent pool, handles user linking, and relays progress. All files referenced below are in the **Vercel App** repo (`~/Projects/openai-assistants-quickstart`).

### 13.1 Architecture Overview

Two communication paths connect users to their Fly-hosted agent:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  CoBroker Vercel App (app.cobroker.ai)                                  │
│                                                                          │
│  ┌─ Inbound (Telegram → App) ────────────────────────────────────────┐  │
│  │                                                                    │  │
│  │  Telegram Bot API                                                  │  │
│  │    → POST /api/telegram/webhook                                    │  │
│  │      → grammY bot.handleUpdate()  [waitUntil — returns 200 fast]   │  │
│  │        → commands handler    (/start, /link, /new, /plan, /help)   │  │
│  │        → callbacks handler   (inline buttons: pa/pe/pc/qa/pj)      │  │
│  │        → file-upload handler (documents, photos)                   │  │
│  │        → agent-mode handler  (free text — catch-all)               │  │
│  │          ↓                                                         │  │
│  │        POST /api/agent/sandbox  → Vercel Sandbox (agent runs)      │  │
│  │          ↓                                                         │  │
│  │        INSERT agent_sandbox_progress (Supabase)                    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─ Outbound (App → Telegram) ───────────────────────────────────────┐  │
│  │                                                                    │  │
│  │  agent_sandbox_progress INSERT                                     │  │
│  │    → Supabase DB Webhook                                           │  │
│  │      → Edge Function: telegram-relay                               │  │
│  │        → lookup telegram_sandbox_sessions by sandbox_id            │  │
│  │        → find telegram_chat_id                                     │  │
│  │        → Telegram Bot API: sendMessage (+ inline keyboards)        │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─ Web UI (Dashboard) ─────────────────────────────────────────────┐   │
│  │  TelegramLinkDropdown (Popover in top bar)                        │   │
│  │    → GET /api/openclaw/status  (check agent assignment)           │   │
│  │    → POST /api/openclaw/link   (assign agent from pool)           │   │
│  │    → DELETE /api/openclaw/link (return agent to pool)             │   │
│  └───────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

### 13.2 Telegram Bot (grammY)

**Bot singleton**: `lib/telegram/bot.ts`

```typescript
import { Bot } from "grammy";
export const bot = new Bot(token, { botInfo: getBotInfo() });

// Handler registration order matters — last handler is catch-all
registerCommands(bot);    // /start, /link, /new, /plan, /cancel, /projects, /project, /help
registerCallbacks(bot);   // Inline button clicks (pa/pe/pc/qa/pj/sl/sc/sp prefixes)
registerFileUpload(bot);  // Document and photo messages
registerAgentMode(bot);   // Free text — must be last (catch-all)
```

**Webhook endpoint**: `POST /api/telegram/webhook` (`app/api/telegram/webhook/route.ts`)

- Validates `X-Telegram-Bot-Api-Secret-Token` header with constant-time comparison
- Uses `waitUntil()` from `@vercel/functions` for background processing — returns `200 OK` immediately
- `maxDuration = 60` (Vercel serverless function timeout)
- `GET /api/telegram/webhook` is a simple health check returning `{ status: "ok" }`

**Pre-cached bot info**: `lib/telegram/config.ts` exports `getBotInfo()` which reads env vars (`TELEGRAM_BOT_ID`, `TELEGRAM_BOT_NAME`, `TELEGRAM_BOT_USERNAME`) to skip the `getMe()` API call on cold starts.

### 13.3 User Linking Flow

There are **two complementary linking systems** that work together:

#### A. Telegram Account Linking (identity)

Links a Telegram user to a CoBroker `app_user_id` so the bot knows which CoBroker user is messaging.

1. **Web UI**: User navigates to dashboard → Clicks "Link Telegram" → (this path is now bypassed in favor of direct agent assignment, but code route still exists)
2. **API**: `POST /api/telegram/link` generates a random 6-char alphanumeric code (chars: `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, omits confusing `0/O/1/I`). TTL: 10 minutes. Stored in `telegram_link_codes` table.
3. **Telegram Bot**: User sends `/link ABC123` → `handleLink` in `handlers/commands.ts` → calls `linkAccount()` in `lib/telegram/auth.ts`
4. **Atomic claim**: `linkAccount()` does `UPDATE telegram_link_codes SET used=true WHERE code=X AND used=false AND expires_at > now()` → prevents race conditions
5. **Upsert**: Creates/updates `telegram_user_links` row (keyed on `telegram_user_id`)

#### B. Agent Assignment (pool)

Assigns a pre-provisioned Fly VM + Telegram bot from the `openclaw_agents` pool.

1. **Web UI**: `TelegramLinkDropdown` → User enters their numeric Telegram ID
2. **API**: `POST /api/openclaw/link` → finds first agent with `status = 'available'` → assigns it to the user with optimistic locking (`WHERE status = 'available'`)
3. **Agent secret**: Generated via `crypto.randomUUID()`, stored in `openclaw_agents.agent_secret`
4. **Status transition**: `available` → `linked`
5. **Unlinking**: `DELETE /api/openclaw/link` → resets agent fields to null, status back to `available`

### 13.4 Agent Pool Management

**Table**: `openclaw_agents` — Each row represents a complete agent (Fly VM + Telegram bot).

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Primary key |
| `fly_app_name` | text | Fly.io app name (unique) |
| `fly_region` | text | Fly region (default: `iad`) |
| `fly_machine_id` | text | Fly machine ID (nullable) |
| `bot_token` | text | Telegram bot token (unique) |
| `bot_username` | text | Telegram bot @handle (unique) |
| `user_id` | uuid | Assigned CoBroker user (nullable, unique) |
| `telegram_user_id` | bigint | Assigned Telegram user (nullable) |
| `agent_secret` | text | Auth secret for API calls (nullable) |
| `status` | text | Lifecycle state (CHECK constraint) |
| `status_message` | text | Human-readable status detail |
| `notes` | text | Admin notes |
| `linked_at` | timestamptz | When user was assigned |
| `activated_at` | timestamptz | When agent became fully active |
| `created_at` | timestamptz | Row creation time |
| `updated_at` | timestamptz | Last modification time |

**Lifecycle**: `available` → `linked` → `configuring` → `active` → `stopped`/`error`

**Admin routes** (restricted to `isaac@cobroker.ai` via `verifyAdminAccess()`):

| Method | Route | Action |
|--------|-------|--------|
| GET | `/api/admin/openclaw/agents` | List all agents |
| POST | `/api/admin/openclaw/agents` | Add agent to pool |
| PATCH | `/api/admin/openclaw/agents/[id]` | Update agent fields |
| DELETE | `/api/admin/openclaw/agents/[id]` | Remove agent from pool |

**User-facing routes**:

| Method | Route | Action |
|--------|-------|--------|
| GET | `/api/openclaw/status` | Check if current user has a linked agent |
| POST | `/api/openclaw/link` | Assign available agent to current user |
| DELETE | `/api/openclaw/link` | Unlink and return agent to pool |

### 13.5 Message Handlers

| Handler | Registration | Trigger | File | What It Does |
|---------|-------------|---------|------|-------------|
| Commands | `bot.command()` | `/start`, `/link`, `/new`, `/plan`, `/cancel`, `/projects`, `/project`, `/help` | `handlers/commands.ts` | Account linking, new conversations, project listing |
| Callbacks | `bot.on("callback_query:data")` | Inline button clicks | `handlers/callbacks.ts` | Plan approval (`pa`), plan edit (`pe`), plan cancel (`pc`), question answer (`qa`), project select (`pj`), selection toggle/confirm/page (`sl`/`sc`/`sp`) |
| File Upload | Documents / photos | Document or photo message | `handlers/file-upload.ts` | Downloads file → uploads to Supabase Storage |
| Plan Mode | Called from `/plan` command | `/plan <prompt>` | `handlers/plan-mode.ts` | Convenience wrapper — starts sandbox agent in plan mode |
| Agent Mode | `bot.on("message:text")` | Free text (catch-all) | `handlers/agent-mode.ts` | Starts or resumes sandbox agent with the user's message |

**Registration order is critical** — agent mode (catch-all) must be registered last.

**Callback data format**: Telegram limits callback data to 64 bytes. We use short prefixes (`pa:`, `pe:`, `pc:`, `qa:`, `pj:`) and truncate IDs to last 20 characters. Full format: `action:shortSandboxId:shortQuestionId[:extra]`.

### 13.6 Session Management

**Session lock** prevents concurrent handler execution for the same Telegram user:

- Lock stored in `telegram_user_links.session_locked_at` + `session_lock_id`
- Timeout: **120 seconds** (configurable in `TELEGRAM_CONFIG.sessionLockTimeoutMs`)
- `acquireSessionLock(telegramUserId, lockId)` → returns `true` if acquired, `false` if another handler is active
- `releaseSessionLock(telegramUserId, lockId)` → only releases if lock ID matches (prevents releasing someone else's lock)
- `withSessionGuard(handler)` → higher-order function that auto-acquires/releases
- Stale locks (older than 120s) are forcibly released on next acquisition attempt

**Chat state machine** (stored in `telegram_user_links.chat_state`):

| State | Description |
|-------|-------------|
| `idle` | No active interaction |
| `project_select` | User is picking a project from inline buttons |
| `agent_running` | Sandbox agent is active |
| `plan_review` | Sandbox started in plan mode, awaiting plan approval |
| `awaiting_plan_feedback` | User clicked "Edit Plan", bot is waiting for feedback text |

**Active session tracking**:
- `telegram_user_links.active_sandbox_id` — current sandbox ID
- `telegram_user_links.active_conversation_id` — current conversation ID
- `telegram_user_links.chat_state_data` — JSONB for arbitrary state (e.g., selected project ID)
- Updated via `updateChatState()` in `lib/telegram/auth.ts`

### 13.7 Progress Relay

The relay pipeline delivers agent progress updates from the sandbox back to Telegram:

1. **Agent writes**: Sandbox agent inserts rows into `agent_sandbox_progress` table (columns: `sandbox_id`, `step`, `status`, `detail`, `data` as JSONB)
2. **DB webhook fires**: Supabase DB webhook triggers on INSERT to `agent_sandbox_progress`
3. **Edge Function**: `telegram-relay` Edge Function receives the webhook payload
4. **Lookup**: Queries `telegram_sandbox_sessions` by `sandbox_id` → retrieves `telegram_chat_id`
5. **Format**: Uses step/status to pick an icon (searching→🔍, importing→📥, enriching→✨, completed→✅, error→❌)
6. **Send**: Posts formatted message to Telegram Bot API. For `plan_review` events, includes inline keyboard with Approve/Edit/Cancel buttons

**Formatting utilities** (`lib/telegram/formatters.ts`):
- `markdownToTelegramHtml()` — converts Markdown to Telegram's HTML subset (`<b>`, `<i>`, `<code>`, `<pre>`, `<a>`)
- `splitMessage()` — chunks long messages at paragraph/line/space boundaries to fit 4096-char Telegram limit
- `formatPlanReview()` — wraps plan markdown in header/footer for review display
- `formatProgressUpdate()` — adds emoji icon prefix based on step type

**Keyboard builders** (`lib/telegram/keyboards.ts`):
- `planReviewKeyboard(sandboxId, questionId)` — Approve & Build / Edit Plan / Cancel
- `questionKeyboard(sandboxId, questionId, options)` — Display answer options as buttons
- `projectSelectKeyboard(projects)` — List projects with "New Project" at bottom
- `propertySelectionKeyboard(...)` — Checkboxes with pagination
- `modelSelectKeyboard()` — Haiku (Fast) / Sonnet (Balanced) / Opus (Powerful)

### 13.8 Agent Authentication

The Telegram bot makes internal API calls to the CoBroker app (e.g., `POST /api/agent/sandbox`) using agent bypass headers instead of Clerk JWT:

| Header | Value | Purpose |
|--------|-------|---------|
| `X-Agent-User-Id` | Supabase UUID (`app_user_id`) | Identifies which user the agent acts on behalf of |
| `X-Agent-Secret` | Shared secret (`AGENT_AUTH_SECRET`) | Proves the request is from a trusted agent |

**Why**: Clerk `__session` JWT expires after ~60 seconds. Agent operations (sandbox creation, sandbox messaging) run for minutes. The bypass headers provide stable authentication for long-running flows.

**Implementation**:
- `lib/telegram/conversation.ts` → `agentFetch(path, appUserId, options)` — wraps `fetch()` with agent headers
- `middleware.ts` — checks for agent headers on `/api/agent/*` paths, validates with `constantTimeEqual()` (not `crypto.timingSafeEqual` — unavailable in Edge/webpack runtime)
- `lib/server/identity.ts` → `getAppUserId()` — checks agent headers as fallback when Clerk auth is unavailable

### 13.9 Database Schema

**Migration 1**: `20260209_telegram_tables.sql` (4 tables)

```sql
-- 1. telegram_user_links: Links Telegram users to Cobroker accounts
CREATE TABLE IF NOT EXISTS telegram_user_links (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  telegram_user_id bigint NOT NULL UNIQUE,
  app_user_id uuid NOT NULL,
  telegram_username text,
  telegram_first_name text,
  linked_at timestamptz DEFAULT now() NOT NULL,
  session_locked_at timestamptz,        -- Session guard lock
  session_lock_id text,                  -- Lock owner ID
  chat_state text DEFAULT 'idle',        -- State machine: idle/project_select/agent_running
  chat_state_data jsonb,                 -- Arbitrary state for multi-step interactions
  active_sandbox_id text,                -- Currently active sandbox
  active_conversation_id text,           -- Currently active conversation
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- 2. telegram_sandbox_sessions: Tracks active sandbox → Telegram chat mapping for relay
CREATE TABLE IF NOT EXISTS telegram_sandbox_sessions (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  sandbox_id text NOT NULL,
  telegram_chat_id bigint NOT NULL,
  telegram_user_id bigint NOT NULL,
  app_user_id uuid NOT NULL,
  conversation_id text,
  status text DEFAULT 'active' NOT NULL,
  last_progress_id uuid,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- 3. telegram_interaction_state: Server-side state for multi-step interactions (TTL-based)
CREATE TABLE IF NOT EXISTS telegram_interaction_state (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  telegram_chat_id bigint NOT NULL,
  telegram_user_id bigint NOT NULL,
  interaction_type text NOT NULL,  -- 'project_select', 'plan_review', 'question_answer'
  state_data jsonb NOT NULL DEFAULT '{}',
  expires_at timestamptz NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- 4. telegram_link_codes: Temporary 6-char codes for account linking (10-min TTL)
CREATE TABLE IF NOT EXISTS telegram_link_codes (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  code text NOT NULL UNIQUE,
  app_user_id uuid NOT NULL,
  expires_at timestamptz NOT NULL,
  used boolean DEFAULT false,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- Realtime enabled on telegram_sandbox_sessions for the relay function
ALTER PUBLICATION supabase_realtime ADD TABLE telegram_sandbox_sessions;
```

**Migration 2**: `20260213_openclaw_agents.sql`

```sql
-- OpenClaw Agent Pool — each row is a complete agent (Fly VM + Telegram bot)
CREATE TABLE IF NOT EXISTS openclaw_agents (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  fly_app_name text NOT NULL UNIQUE,
  fly_region text DEFAULT 'iad' NOT NULL,
  fly_machine_id text,
  bot_token text NOT NULL,
  bot_username text NOT NULL,
  user_id uuid UNIQUE,              -- null = available in pool
  telegram_user_id bigint,
  agent_secret text,
  status text DEFAULT 'available' NOT NULL,
  status_message text,
  notes text,
  linked_at timestamptz,
  activated_at timestamptz,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);
```

**Migration 3**: `20260213_openclaw_agents_constraints.sql`

```sql
ALTER TABLE openclaw_agents
  ADD CONSTRAINT openclaw_agents_bot_token_unique UNIQUE (bot_token),
  ADD CONSTRAINT openclaw_agents_bot_username_unique UNIQUE (bot_username),
  ADD CONSTRAINT openclaw_agents_status_check
    CHECK (status IN ('available', 'linked', 'configuring', 'active', 'stopped', 'error'));
```

### 13.10 Environment Variables (Vercel)

| Variable | Purpose | Example |
|----------|---------|---------|
| `TELEGRAM_BOT_TOKEN` | grammY bot authentication | `7843210:AAF...` |
| `TELEGRAM_WEBHOOK_SECRET` | Webhook `X-Telegram-Bot-Api-Secret-Token` validation | Random string |
| `TELEGRAM_BOT_ID` | Bot numeric ID (pre-cached, skips `getMe()`) | `7843210` |
| `TELEGRAM_BOT_NAME` | Bot display name | `Cobroker` |
| `TELEGRAM_BOT_USERNAME` | Bot @handle (without @) | `cobroker_bot` |
| `AGENT_AUTH_SECRET` | Shared secret for agent bypass headers. Must match Fly's `COBROKER_AGENT_SECRET` | UUID string |

### 13.11 UI Component

**`TelegramLinkDropdown`** at `components/settings/TelegramLinkDropdown.tsx`

Rendered in the dashboard top bar as a `Popover`:

**Unlinked state**:
- Black button with Send icon: "Link Telegram"
- Popover: Instructions to get Telegram ID via @userinfobot, numeric input field, "Link" button
- Calls `POST /api/openclaw/link` with `{ telegramUserId: number }`

**Linked state**:
- Icon button with status dot:
  - Green (animated ping): `active` or `linked`/`configuring`
  - Red: `error`
- Popover: Shows `@bot_username` + status badge, "Open in Telegram" link, "Unlink" button
- Error state shows `status_message` and "Contact Isaac for help"

**Data flow**:
1. `useEffect` → `GET /api/openclaw/status` on mount
2. Link → `POST /api/openclaw/link` → re-fetch status
3. Unlink → `DELETE /api/openclaw/link` → clear state + close popover

### 13.12 File Reference

All paths relative to the Vercel App repo (`~/Projects/openai-assistants-quickstart`).

**Migrations** (3 files):

| File | Tables Created |
|------|---------------|
| `supabase/migrations/20260209_telegram_tables.sql` | `telegram_user_links`, `telegram_sandbox_sessions`, `telegram_interaction_state`, `telegram_link_codes` |
| `supabase/migrations/20260213_openclaw_agents.sql` | `openclaw_agents` |
| `supabase/migrations/20260213_openclaw_agents_constraints.sql` | Constraints on `openclaw_agents` |

**API Routes — Telegram** (2 files):

| File | Endpoints |
|------|----------|
| `app/api/telegram/webhook/route.ts` | `POST` (handle update), `GET` (health check) |
| `app/api/telegram/link/route.ts` | `POST` (generate link code), `GET` (check link status) |

**API Routes — OpenClaw** (2 files):

| File | Endpoints |
|------|----------|
| `app/api/openclaw/link/route.ts` | `POST` (assign agent), `DELETE` (unlink agent) |
| `app/api/openclaw/status/route.ts` | `GET` (agent status for current user) |

**API Routes — Admin** (2 files):

| File | Endpoints |
|------|----------|
| `app/api/admin/openclaw/agents/route.ts` | `GET` (list agents), `POST` (add agent) |
| `app/api/admin/openclaw/agents/[id]/route.ts` | `PATCH` (update), `DELETE` (remove) |

**Types** (1 file):

| File | Exports |
|------|---------|
| `types/openclaw.ts` | `OpenClawAgentStatus`, `OpenClawAgent`, `OpenClawAgentUserView` |

**UI Components** (1 file):

| File | Component |
|------|-----------|
| `components/settings/TelegramLinkDropdown.tsx` | `TelegramLinkDropdown` |

**Telegram Library — Core** (8 files in `lib/telegram/`):

| File | Purpose |
|------|---------|
| `bot.ts` | Bot singleton, handler registration |
| `config.ts` | Constants (limits, TTLs, header names), `getBotInfo()`, `getAppUrl()` |
| `auth.ts` | `resolveAppUser()`, `linkAccount()`, `updateChatState()` |
| `session-guard.ts` | `acquireSessionLock()`, `releaseSessionLock()`, `withSessionGuard()` |
| `conversation.ts` | `agentFetch()`, `createConversation()`, `startSandbox()`, `sendSandboxMessage()`, `listConversations()` |
| `formatters.ts` | `markdownToTelegramHtml()`, `splitMessage()`, `formatProgressUpdate()`, `formatPlanReview()`, `escapeHtml()` |
| `error-handler.ts` | `notifyError()` — user-friendly error messages + lock cleanup |
| `keyboards.ts` | `planReviewKeyboard()`, `questionKeyboard()`, `projectSelectKeyboard()`, `propertySelectionKeyboard()`, `confirmKeyboard()`, `modelSelectKeyboard()` |

**Telegram Library — Handlers** (5 files in `lib/telegram/handlers/`):

| File | Registers | Trigger |
|------|----------|---------|
| `commands.ts` | `bot.command()` for 8 commands | `/start`, `/link`, `/new`, `/plan`, `/cancel`, `/projects`, `/project`, `/help` |
| `callbacks.ts` | `bot.on("callback_query:data")` | Inline button clicks |
| `file-upload.ts` | Document/photo messages | File attachments |
| `plan-mode.ts` | Called from `/plan` command | Plan-mode convenience wrapper |
| `agent-mode.ts` | `bot.on("message:text")` (catch-all) | Free text → starts/resumes sandbox |

**Total: 24 files** (3 migrations + 6 API routes + 1 type file + 1 UI component + 13 library files)

---

## 14. ClawBroker.ai — Self-Service Onboarding

> **Repo:** `~/Projects/clawbroker` · **URL:** [clawbroker.ai](https://clawbroker.ai) · **Deployed:** Vercel (auto-deploy on push)

ClawBroker.ai is the self-service onboarding platform that lets new users sign up, get assigned a pre-deployed bot + VM, and manage their account — without touching SSH, Fly.io, or any config files. It was built as a separate Next.js app that shares the same Supabase database and Clerk auth instance as the CoBroker App.

### 14.1 Architecture Overview

```
┌────────────────────────────────────────────────┐
│  clawbroker.ai (Vercel)                        │
│  Next.js 16 + Clerk + Stripe                   │
│                                                │
│  ┌──────────────┐  ┌──────────────────────┐    │
│  │ Landing Page  │  │ /onboarding          │    │
│  │ / (public)    │  │ Telegram username    │    │
│  └──────┬───────┘  └──────────┬───────────┘    │
│         │ sign-up              │ POST /api/onboard
│         ▼                      ▼               │
│  ┌──────────────┐  ┌──────────────────────┐    │
│  │ Clerk Auth    │  │ Bot Assignment       │    │
│  │ sign-in/up    │  │ bot_pool → tenant    │    │
│  └──────────────┘  └──────────┬───────────┘    │
│                               ▼               │
│  ┌──────────────┐  ┌──────────────────────┐    │
│  │ /dashboard    │  │ /admin/tenants       │    │
│  │ status+balance│  │ activate / suspend   │    │
│  └──────────────┘  └──────────────────────┘    │
│                                                │
│  Cron (*/5 min): check-balances                │
│  Webhook: Stripe → top-up + reactivate         │
└──────────────────┬─────────────────────────────┘
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
┌──────────┐ ┌──────────┐ ┌───────────────────────────┐
│ Supabase │ │  Clerk   │ │ Fly Machines API          │
│ (shared) │ │ (shared) │ │ start/stop/exec/restart   │
└──────────┘ └──────────┘ └───────────────────────────┘
```

**Key design principle:** ClawBroker.ai makes **zero changes** to the CoBroker App or OpenClaw repos. It only reads/writes to shared Supabase tables and controls Fly VMs via the Machines API.

### 14.2 Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Framework | Next.js | 16.1.6 |
| UI | React + Tailwind CSS v4 | 19.2.3 |
| Auth | Clerk (`@clerk/nextjs`) | ^6.37.4 |
| Database | Supabase (`@supabase/supabase-js`) | ^2.95.3 |
| Payments | Stripe | ^14.25.0 |
| Email | Resend | ^3.5.0 |
| VM Control | Fly Machines REST API | v1 |
| Hosting | Vercel | — |

### 14.3 Database Schema

Three new tables + one view, all in the shared CoBroker Supabase instance. Migration: `supabase-migration-onboarding.sql` (in the OpenClaw repo).

**`bot_pool`** — Pre-created Telegram bots paired with pre-deployed Fly VMs:

```sql
CREATE TABLE bot_pool (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bot_token TEXT NOT NULL,
  bot_username TEXT NOT NULL,
  fly_app_name TEXT NOT NULL,
  fly_machine_id TEXT,
  assigned_to UUID REFERENCES user_identity_map(app_user_id),
  status TEXT DEFAULT 'available'
    CHECK (status IN ('available', 'assigned', 'retired')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  assigned_at TIMESTAMPTZ
);
```

**`tenant_registry`** — Links users to their bot + VM:

```sql
CREATE TABLE tenant_registry (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES user_identity_map(app_user_id),
  bot_id UUID REFERENCES bot_pool(id),
  fly_app_name TEXT,
  telegram_user_id TEXT,
  telegram_username TEXT,
  status TEXT DEFAULT 'pending'
    CHECK (status IN ('pending', 'provisioning', 'active', 'suspended', 'terminated')),
  provisioned_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

**`usd_balance`** — User's total dollar budget:

```sql
CREATE TABLE usd_balance (
  user_id UUID PRIMARY KEY REFERENCES user_identity_map(app_user_id),
  total_budget_usd NUMERIC(10,2) DEFAULT 10.00,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

**`v_user_usd_balance`** — View joining budget with actual LLM + app feature spend:

```sql
CREATE OR REPLACE VIEW v_user_usd_balance AS
SELECT
  ub.user_id,
  ub.total_budget_usd,
  COALESCE(llm.spent, 0)::NUMERIC(10,6) AS llm_spent_usd,
  COALESCE(app.spent, 0)::NUMERIC(10,6) AS app_spent_usd,
  (ub.total_budget_usd - COALESCE(llm.spent, 0) - COALESCE(app.spent, 0))::NUMERIC(10,6)
    AS remaining_usd
FROM usd_balance ub
LEFT JOIN (
  SELECT tr.user_id, SUM(ol.cost_total) AS spent
  FROM tenant_registry tr
  JOIN openclaw_logs ol ON ol.tenant_id = tr.fly_app_name
  WHERE ol.role = 'assistant' AND ol.cost_total > 0
  GROUP BY tr.user_id
) llm ON llm.user_id = ub.user_id
LEFT JOIN (
  SELECT user_id, SUM(credits_charged * 0.005) AS spent
  FROM credit_usage_log WHERE success = true
  GROUP BY user_id
) app ON app.user_id = ub.user_id;
```

### 14.4 Onboarding Flow

```
User visits clawbroker.ai
  │
  ├─ Landing page: pick model + channel → "Get Started — Free $10 Credit"
  │
  ▼
Clerk sign-up (/sign-up)
  │
  ▼
Onboarding form (/onboarding)
  │  User enters Telegram user ID
  │
  ▼
POST /api/onboard (~5 seconds)
  │  1. Create/find user_identity_map row (Clerk → app_user_id)
  │  2. Assign next available bot from bot_pool (optimistic lock)
  │  3. Create tenant_registry row (status: "pending")
  │  4. Create usd_balance ($10.00 budget)
  │  5. Create user_credits (2,000 app credits)
  │  6. Auto-activate via Fly Machines exec API:
  │     a. Start VM (if stopped)
  │     b. Read /data/openclaw.json from VM
  │     c. Add Telegram user ID to channels.telegram.allowFrom (idempotent)
  │     d. Write updated config back via base64
  │     e. Clear sessions (force skill re-snapshot)
  │     f. Restart machine to pick up new config
  │     g. Set tenant status → "active", record provisioned_at
  │  7. Send activation email with Telegram deep link (Resend)
  │  8. Telegram notification to admin ("Auto-activated!")
  │
  ▼
Redirect to /dashboard (status: "Active" — agent ready immediately)
```

**Auto-activation fallback:** If the Fly exec API fails (e.g., VM unreachable), the tenant stays in `pending` status and the admin is notified. The admin can manually activate from `/admin/tenants` — the Activate button performs the same VM configuration steps.

**Initial balances:** Each new user gets $10.00 USD budget + 2,000 CoBroker app credits. The $10 covers LLM costs tracked in `openclaw_logs`; the 2,000 credits cover app features (Places, demographics, etc.) at $0.005/credit.

### 14.5 API Routes

| Method | Route | Auth | Description |
|--------|-------|------|-------------|
| POST | `/api/onboard` | Clerk | Sign up: create user, assign bot, create balances, auto-activate VM, send email, notify admin |
| GET | `/api/balance` | Clerk | Returns user's USD balance from `v_user_usd_balance` view |
| GET | `/api/status` | Clerk | Returns tenant status, bot username, Fly app name |
| GET | `/api/admin/bot-pool` | Admin | List all bots in pool with assignment status |
| POST | `/api/admin/bot-pool` | Admin | Add new bot to pool (username, token, fly app, machine ID) |
| GET | `/api/admin/tenants` | Admin | List all tenants with balances (joins bot_pool + identity + balance) |
| POST | `/api/admin/activate-tenant` | Admin | Configure VM via Fly exec API + set active (fallback for auto-activation failures) |
| POST | `/api/admin/suspend-tenant` | Admin | Stop Fly VM + set status → suspended |
| GET | `/api/cron/check-balances` | Cron secret | Auto-suspend depleted users (see §14.7) |
| POST | `/api/checkout` | Clerk | Create Stripe checkout session → return payment URL |
| POST | `/api/webhooks/stripe` | Stripe sig | Payment received → top-up balance + reactivate if suspended |

**Admin auth:** Clerk user + `ADMIN_EMAIL` environment variable check (default: `isaac@cobroker.ai`).

### 14.6 Dashboard & Admin Pages

**User-facing:**

| Page | Route | Description |
|------|-------|-------------|
| Landing | `/` | Model + channel selection, comparison table, use-case marquee, CTA |
| Sign Up | `/sign-up` | Clerk sign-up component |
| Sign In | `/sign-in` | Clerk sign-in component |
| Onboarding | `/onboarding` | Telegram username form → POST /api/onboard |
| Dashboard | `/dashboard` | Status badge (active/pending/suspended), bot Telegram link, balance bar |
| Usage | `/dashboard/usage` | Budget breakdown: LLM spend vs app feature spend, visual bars |

**Admin-facing:**

| Page | Route | Description |
|------|-------|-------------|
| Bot Pool | `/admin/bot-pool` | Table of all bots (username, Fly app, status, assigned user). Add Bot form. |
| Tenants | `/admin/tenants` | Table of all tenants (email, Telegram, bot, status, balance). Activate/Suspend buttons. |

### 14.7 Auto-Suspend & Reactivation

**Auto-Suspend (Vercel Cron — every 5 minutes):**

```
vercel.json: { "crons": [{ "path": "/api/cron/check-balances", "schedule": "*/5 * * * *" }] }
```

1. Query `v_user_usd_balance` for `remaining_usd ≤ 0`
2. Join with `tenant_registry` for active tenants only
3. For each depleted tenant:
   - **Notification 1:** Telegram DM to user via their bot (with Stripe payment link)
   - **Action:** Stop Fly.io machine via Machines API (`POST /apps/{app}/machines/{id}/stop`)
   - **Update:** Set `tenant_registry.status` → `"suspended"`
   - **Notification 2:** Suspension email via Resend (with Stripe payment link)
   - **Notification 3:** Telegram message to admin

**Reactivation (Stripe Webhook):**

1. `POST /api/webhooks/stripe` receives `checkout.session.completed`
2. Extract `app_user_id` from session metadata + `amount_total` from payment
3. Top up `usd_balance.total_budget_usd` (add dollar amount)
4. Top up `user_credits` (at $0.005/credit rate)
5. If tenant is suspended:
   - Start Fly.io machine via Machines API (`POST /apps/{app}/machines/{id}/start`)
   - Set `tenant_registry.status` → `"active"`

### 14.8 Environment Variables (Vercel)

| Variable | Status | Description |
|----------|--------|-------------|
| `NEXT_PUBLIC_SUPABASE_URL` | Set | Supabase project URL (shared with CoBroker App) |
| `SUPABASE_SERVICE_ROLE_KEY` | Set | Supabase service role key (bypasses RLS) |
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | Set | Clerk frontend key (shared instance) |
| `CLERK_SECRET_KEY` | Set | Clerk backend key |
| `NEXT_PUBLIC_CLERK_SIGN_IN_URL` | Set | `/sign-in` |
| `NEXT_PUBLIC_CLERK_SIGN_UP_URL` | Set | `/sign-up` |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL` | Set | `/dashboard` |
| `FLY_API_TOKEN` | Set | Fly.io API token for Machines API (start/stop VMs) |
| `ADMIN_EMAIL` | Set | Admin email for access control (`isaac@cobroker.ai`) |
| `ADMIN_TELEGRAM_BOT_TOKEN` | Set | Bot token for admin notifications |
| `ADMIN_TELEGRAM_CHAT_ID` | Set | Admin's Telegram chat ID |
| `CRON_SECRET` | Set | Vercel Cron authentication secret |
| `STRIPE_SECRET_KEY` | Set | Stripe restricted key (`rk_live_...`) — Checkout Sessions write-only |
| `STRIPE_CREDIT_PRICE_ID` | Set | Stripe Price ID for $50 credit top-up (`price_1T2fAg...`) |
| `STRIPE_WEBHOOK_SECRET` | Set | Stripe webhook signing secret (`whsec_...`) — endpoint: `charming-victory` |
| `RESEND_API_KEY` | Set | Resend API key for suspension emails (key: `clawbroker-prod`) |
| `EMAIL_FROM` | Set | Sender address (`isaac@cobroker.ai`) — domain `cobroker.ai` verified in Resend |

### 14.9 File Reference

**Pages (7 files):**

| File | Route | Purpose |
|------|-------|---------|
| `app/page.tsx` | `/` | Landing page — model/channel selection, comparison table, marquee |
| `app/layout.tsx` | — | Root layout with Clerk `<ClerkProvider>` |
| `app/sign-in/[[...sign-in]]/page.tsx` | `/sign-in` | Clerk sign-in |
| `app/sign-up/[[...sign-up]]/page.tsx` | `/sign-up` | Clerk sign-up |
| `app/onboarding/page.tsx` | `/onboarding` | Telegram username form → POST /api/onboard |
| `app/dashboard/page.tsx` | `/dashboard` | Status badge, bot card, balance bar |
| `app/dashboard/usage/page.tsx` | `/dashboard/usage` | LLM vs app spend breakdown |

**Admin Pages (2 files):**

| File | Route | Purpose |
|------|-------|---------|
| `app/admin/bot-pool/page.tsx` | `/admin/bot-pool` | Bot pool table + add form |
| `app/admin/tenants/page.tsx` | `/admin/tenants` | Tenant list, activate/suspend buttons |

**API Routes (11 files):**

| File | Method | Purpose |
|------|--------|---------|
| `app/api/onboard/route.ts` | POST | Signup + bot assign + create balances |
| `app/api/balance/route.ts` | GET | User's USD balance (from view) |
| `app/api/status/route.ts` | GET | Tenant status + bot info |
| `app/api/checkout/route.ts` | POST | Create Stripe checkout session → return URL |
| `app/api/admin/bot-pool/route.ts` | GET/POST | List/add bots |
| `app/api/admin/tenants/route.ts` | GET | List tenants with balances |
| `app/api/admin/activate-tenant/route.ts` | POST | Activate tenant |
| `app/api/admin/suspend-tenant/route.ts` | POST | Suspend + stop VM |
| `app/api/cron/check-balances/route.ts` | GET | Auto-suspend depleted users |
| `app/api/webhooks/stripe/route.ts` | POST | Stripe payment → top-up + reactivate |

**Library Files (6 files):**

| File | Purpose |
|------|---------|
| `lib/supabase.ts` | Supabase client (service role, lazy singleton) |
| `lib/admin-auth.ts` | Clerk + ADMIN_EMAIL verification |
| `lib/fly.ts` | Fly Machines API — `startMachine()`, `stopMachine()`, `getMachineStatus()`, `execCommand()`, `restartMachine()`, `configureTenant()` |
| `lib/stripe.ts` | Stripe checkout session creation for credit top-ups |
| `lib/email.ts` | Resend — `sendActivationEmail()` (Telegram deep link) + `sendSuspensionEmail()` (Stripe payment link) |
| `lib/telegram.ts` | `sendTelegramMessage()` + `notifyAdmin()` |

**Config Files (4 files):**

| File | Purpose |
|------|---------|
| `proxy.ts` | Clerk middleware (auth guard, public route matcher) |
| `next.config.ts` | Next.js configuration |
| `vercel.json` | Cron schedule: `check-balances` every 5 minutes |
| `tsconfig.json` | TypeScript configuration |

**Total: 30 files** (7 pages + 2 admin pages + 11 API routes + 6 library files + 4 config files)

### 14.10 Current Status

> **Beta-ready as of 2026-02-19.** 5 bot+VM pairs provisioned and available in the bot pool. All tenant VMs hardened for production (Sonnet 4.6, info logging, secret-guard plugin, tool deny list). Test tenant-002 destroyed and cleaned up. Platform accepts signups immediately.

**Beta Launch Prep (2026-02-19):**
- [x] Primary instance updated to OpenClaw v2026.2.19
- [x] Primary bot switched from Opus 4.6 → Sonnet 4.6 (cost savings)
- [x] `deploy-tenant.sh` updated with production defaults (Sonnet 4.6, `logging.level: "info"`, `redactSensitive: "tools"`, Brassica skill excluded)
- [x] Secret-guard plugin added to tenant deploys (redacts API keys from outbound messages)
- [x] Tool deny list added (`gateway`, `cron`, `sessions_spawn`, `sessions_send`)
- [x] Volume auto-creation fix (removed manual `fly volumes create` — `fly deploy` auto-creates via `[mounts]`)
- [x] 5 tenant VMs deployed: `cobroker-tenant-003` through `cobroker-tenant-007` (all stopped, awaiting assignment)
- [x] 5 bots added to Supabase `bot_pool` with status `available`
- [x] Test tenant-002 destroyed — Fly app deleted, all 5 Supabase tables cleaned (FK-safe order)
- [x] Stripe deferred — $10 seed balance for beta, manual top-ups via admin if needed

**Verified Working (E2E tested 2026-02-16):**
- [x] Landing page at clawbroker.ai
- [x] Clerk auth — sign-up, sign-in, session management
- [x] Onboarding flow — Telegram user ID → bot assignment → auto-activate → dashboard redirect
- [x] `POST /api/onboard` — creates user_identity_map, assigns bot (optimistic lock), creates tenant, seeds balances ($10 USD + 2,000 credits), **auto-activates VM** (exec API → write config → restart), sends activation email, notifies admin
- [x] **Auto-activation via Fly Machines exec API** — tested locally and in production:
  - Reads `/data/openclaw.json` from VM via exec
  - Adds Telegram user ID to `channels.telegram.allowFrom` (idempotent — skips if already present)
  - Writes updated config back via base64 encoding
  - Clears sessions (`/data/agents/main/sessions/`) to force skill re-snapshot
  - Restarts machine to pick up new config
  - Total time: ~5 seconds from click to active bot
  - Fly exec API field: `command` (array), not `cmd` (discovered during testing)
- [x] **Admin activate as fallback** — `POST /api/admin/activate-tenant` performs the same VM configuration steps. Used when auto-activation fails (e.g., VM unreachable).
- [x] 23505 conflict handling — re-fetches real `app_user_id` after duplicate key (bug fixed 2026-02-16, commit `2414b34`)
- [x] Database records — all 5 tables verified correct (user_identity_map, bot_pool, tenant_registry, usd_balance, user_credits)
- [x] User dashboard — "Hi, {name}", status badge (pending/active/suspended), bot username, balance bar
- [x] Usage breakdown page — budget, LLM costs, app costs, remaining
- [x] Landing page redirect — logged-in users with a tenant auto-redirect to `/dashboard` (commit `9f0aa53`)
- [x] Sign-out button on dashboard — redirects to landing page (commit `9f0aa53`)
- [x] Admin bot pool page — list bots, status, assigned user, "Add Bot" button
- [x] Admin tenants page — list tenants with email, Telegram, bot, status, balance
- [x] Admin activate — pending → active (configures VM + sets `provisioned_at`)
- [x] Admin suspend — active → suspended (stops Fly VM if `fly_machine_id` set)
- [x] Admin re-activate — suspended → active
- [x] Auto-suspend cron — running every 5 min, returning 200 (verified in Vercel logs)
- [x] Fly Machines API integration (start/stop/exec/restart VMs)
- [x] Admin Telegram notifications on signup (auto-activated or fallback message)
- [x] Activation email — Telegram deep link sent via Resend on successful activation
- [x] **Tenant reset + re-onboard verified** (2026-02-16) — full wipe (5 tables + VM stop) → re-signup → auto-activate in ~4s. Confirmed `fly_machine_id` lives on `bot_pool`, not `tenant_registry`. Reset script documented in Section 8.

**Bugs Fixed During E2E Test:**
1. **Stale Supabase key** — `SUPABASE_SERVICE_ROLE_KEY` on Vercel was from before JWT secret rotation. Updated on Vercel + all local `.env` files.
2. **`const finalUserId` bug in `/api/onboard`** — When `user_identity_map` INSERT fails with 23505 (duplicate), code continued with random UUID that was never stored, causing FK violation on `bot_pool.assigned_to`. Fix: changed to `let`, added re-fetch after 23505.
3. **Stale test row** — Manual `user_identity_map` row with `clerk_user_id='test_clerk_id_001'` conflicted on email unique constraint. Deleted via SQL.
4. **Fly exec API field name** — Machines exec API expects `command` (string array), not `cmd`. Discovered during local testing (400 error). Fixed in `lib/fly.ts`.
5. **Missing `sendActivationEmail` on Vercel** — `lib/email.ts` had the function locally but it wasn't committed. Vercel build failed with Turbopack error. Fixed by committing `lib/email.ts` (commit `6f8eb3f`).

- [x] Resend email integration — domain `cobroker.ai` verified, test emails delivered successfully (commit `490f4cf`)
  - DNS records added in Namecheap (Advanced DNS → Custom MX):
    - `send` subdomain MX → `feedback-smtp.us-east-1.amazonses.com` priority 10 (Resend outbound)
    - `@` root MX → 5 Gmail MX records preserved (ASPMX.L.GOOGLE.COM etc.)
  - DKIM (TXT), SPF (TXT), MX all verified in Resend dashboard
  - Sender: `isaac@cobroker.ai` via `lib/email.ts`

**Stripe Integration (configured 2026-02-19):**
- [x] Stripe product: "ClawBroker - $50 Credit" (`prod_U0gXZ9yyrT6mRa`, `price_1T2fAgGI6BgwVAaKiY3SykMr`)
- [x] Restricted API key: Checkout Sessions write-only permission
- [x] Webhook endpoint: `https://clawbroker.ai/api/webhooks/stripe` → listens for `checkout.session.completed`
- [x] All 3 env vars set on Vercel (`STRIPE_SECRET_KEY`, `STRIPE_CREDIT_PRICE_ID`, `STRIPE_WEBHOOK_SECRET`)
- [x] Dashboard "Add Credits" button wired to `POST /api/checkout` → creates Stripe Checkout Session → redirects user to Stripe hosted payment page
- [x] Full reactivation flow: payment received → webhook fires → balance topped up ($50 + 10,000 credits at $0.005/credit) → VM restarted → tenant status → active

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
| 2026-02-16 | Section 14: Resend email integration verified — `cobroker.ai` domain added in Resend, DNS records (DKIM/SPF/MX) configured in Namecheap, test emails confirmed delivered. Updated env var status and checklist. | Isaac + Claude |
| 2026-02-11 | Added property search skill (`cobroker-search`) — Quick Search (Gemini 3 Pro) + Deep Search (Parallel AI FindAll). Inline URL buttons for project links (replaces text hyperlinks). Message delivery rule (`___` convention) to prevent duplicate Telegram messages. Deep Search fixes: response parsing, polling improvements, match_limit min 5, 0-result fallback. New Sections 10.8-10.10, Appendix L. | Isaac + Claude |
| 2026-02-11 | Added Google Places integration — 3 operations: search→properties, search→logo layer, nearby analysis (nearest/count). New `places-service.ts`, 2 route files. Skill Sections 13-15 in `cobroker-projects`, `places-*` step types in `cobroker-plan`. New Section 10.11. | Isaac + Claude |
| 2026-02-11 | Added search routing logic across 3 skill files — Places Search for existing locations, Quick/Deep Search for available space. Fixed misleading Starbucks example in cobroker-search. Verified via Telegram: "Find Starbucks in Dallas" correctly routes to Places Search. New Section 10.12. | Isaac + Claude |
| 2026-02-13 | Added 5 new skills: Brassica POS analytics (10.13), chart generation (10.14), email document import (10.15), web change monitoring (10.16), Google Workspace/gog (10.17). Updated AGENTS.md appendix with Telegram message rules, immediate acknowledgment, email import + charts capabilities, Chart Offer Rule. Updated client-memory appendix with message delivery rule, exec-based file handling, workspace storage path. Added Appendices N–R. Updated architecture diagram, directory structure, openclaw.json (workspace config), verified operations table, automation script. | Isaac + Claude |
| 2026-02-13 | Added Section 13: CoBroker Vercel App — Telegram & Agent Pool. Documents the Vercel-side integration: grammY bot (webhook, handlers, keyboards), two-path user linking (Telegram identity + agent pool assignment), session guard (120s lock), progress relay pipeline (Supabase → Edge Function → Telegram), agent auth bypass headers, database schema (5 tables across 3 migrations), TelegramLinkDropdown UI component, environment variables. Full 24-file reference. | Isaac + Claude |
| 2026-02-15 | Added Section 14: ClawBroker.ai — Self-Service Onboarding. Documents the third repo (clawbroker.ai): Clerk + Stripe + Resend onboarding platform, bot pool assignment, user dashboard (status/balance/usage), admin pages (bot-pool/tenants), auto-suspend cron (every 5 min, 3 notifications), Stripe webhook reactivation, Fly Machines API (start/stop), 3 new Supabase tables (bot_pool, tenant_registry, usd_balance) + v_user_usd_balance view. Updated intro callout from 2 repos → 3 repos. 29-file reference. | Isaac + Claude |
| 2026-02-16 | E2E test of ClawBroker.ai: 24/26 checks passing. Fixed 3 bugs (stale Supabase key, `const finalUserId` 23505 handling, stale test row). Added landing→dashboard redirect for logged-in users with tenants + sign-out button on dashboard. Updated Section 14.10 with full verified test results. | Isaac + Claude |
| 2026-02-16 | **Auto-activation:** Automated `configure-user` into onboard + activate-tenant routes via Fly Machines exec API. Zero-touch signup: user enters Telegram ID → VM configured + restarted → status active in ~5s. Admin dashboard remains as fallback. Added `execCommand()`, `restartMachine()`, `configureTenant()` to `lib/fly.ts`, `sendActivationEmail()` to `lib/email.ts`. Updated deploy-tenant.sh summary. Fixed Fly exec API field name (`command` not `cmd`) and missing `lib/email.ts` commit. 26/26 checks passing. | Isaac + Claude |
| 2026-02-16 | **Tenant reset procedure:** Added "Tenant Reset (Full Wipe)" subsection to Section 8 with FK-safe delete order, self-contained reset script, Fly VM stop, and post-reset verification queries. Documented key gotcha: `fly_machine_id` lives on `bot_pool`, not `tenant_registry`. Verified full reset → re-onboard → active in ~4s. Updated Section 14.10 with reset test results. | Isaac + Claude |
| 2026-02-19 | **Beta launch prep:** Provisioned 5 tenant VMs (003–007) with production-hardened config: Sonnet 4.6 model, info-level logging, `redactSensitive: "tools"`, secret-guard plugin, tool deny list, Brassica skill excluded. Fixed deploy script volume creation (auto-create via `[mounts]` instead of manual). Destroyed test tenant-002 + cleaned Supabase. Primary bot switched to Sonnet 4.6. Updated Sections 7.2, 7.7, 7.8, 14.10. | Isaac + Claude |
| 2026-02-19 | **Stripe integration:** Configured Stripe product ($50 credit), restricted API key (Checkout Sessions write-only), webhook endpoint (`checkout.session.completed`). Set 3 env vars on Vercel. Added `POST /api/checkout` route for dashboard "Add Credits" button → Stripe hosted checkout. Full payment → reactivation flow is now live. Updated Sections 14.5, 14.7, 14.8, 14.9, 14.10. | Isaac + Claude |
| 2026-02-20 | **Tenant fleet rebuild:** Destroyed tenants 003–007 (broken `dmPolicy: "allowlist"` + empty `allowFrom`). Fixed DM policy to `dmPolicy: "open"` + `allowFrom: ["*"]`. Removed invalid `plugins.load.extraDirs` and `secret-guard` plugin references from deploy script. | Isaac + Claude |
| 2026-02-21 | **New fleet deployed:** Provisioned 6 new tenant VMs (008–013) with corrected DM policy. Added `fly-agent` skill for Fly.io tenant VM management (primary-only). | Isaac + Claude |
| 2026-02-22 | **NO_REPLY migration:** Replaced `___` with `NO_REPLY` in AGENTS.md and all 7 skill files — gateway now correctly filters silent tool-call messages. Added `cobroker-client-memory` SKILL.md to repo. Upgraded all 6 beta VMs + primary from Sonnet 4.6 to **Opus 4.6**. | Isaac + Claude |
| 2026-02-22 | **Log forwarder hardening:** (1) Truncation handling — skip to file end instead of resetting to 0, preventing full-file replay after session pruning. (2) Supabase dedup index on `(entry_id, session_id)` to prevent duplicate entries. (3) `cobroker-plan` skill: force Google Places for location lookups, block Gemini address research. | Isaac + Claude |
| 2026-02-23 | **Log forwarder duplicate-key fix:** Forwarder now treats `duplicate key` errors from the API as success and advances cursors instead of retrying forever. | Isaac + Claude |
| 2026-02-23 | **Deploy script enhancements:** (1) `configure-user` now updates `openclaw_agents` Supabase table to `status: 'linked'` with `user_id`, `telegram_user_id`, `linked_at`. (2) Uses `fly secrets deploy` for stopped VMs (fixes staged secrets not deploying). (3) `deploy` mode auto-copies `COBROKER_AGENT_SECRET` from source app. (4) `deploy` mode registers bot in `openclaw_agents` Supabase table. | Isaac + Claude |
| 2026-02-23 | **`update-files` mode added:** New third mode for `deploy-tenant.sh` — pushes updated scripts, skills, and personality files to existing VMs without touching `openclaw.json`. Supports `--skills-only` and `--scripts-only` flags. Handles stopped VMs automatically (sleep→transfer→restore). Default model changed to Opus 4.6. Updated Sections 7.1–7.8, 9.3, 9.7, 9.9, 9.10. Fleet-updated all 6 beta VMs. | Isaac + Claude |
| 2026-02-23 | **Search simplification:** Removed Quick Search (Gemini 3 Pro) from `cobroker-search` skill — FindAll AI is now the only search method. Removed mode selection buttons, deleted ~190 lines of Gemini code/prompts/parsing. Updated `cobroker-plan` step types (`quick-search`/`deep-search` → `search`). Deployed to all 7 VMs via `update-files --skills-only`. Updated Sections 10.7, 10.8, 10.10, 10.12, Appendix L. | Isaac + Claude |
