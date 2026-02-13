# CoBroker OpenClaw — Fly.io Deployment Wiki

> **Purpose**: Complete reference for deploying CoBroker-customized OpenClaw instances to Fly.io. Written from hands-on experience on 2026-02-10. Multi-tenant provisioning is fully automated via `fly-scripts/deploy-tenant.sh` — see [Section 7](#7-multi-tenant-provisioning).

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
7. `/data/skills/cobroker-search/SKILL.md` — Property search (Quick + Deep)
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

A single script — `fly-scripts/deploy-tenant.sh` — handles full provisioning of new CoBroker OpenClaw tenant instances on Fly.io. It has two modes: **deploy** (creates everything from scratch) and **configure-user** (adds a user to an existing deployment). Fully tested and battle-proven as of 2026-02-13.

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
- Creates the Fly app and a 1GB encrypted volume
- Sets all secrets in a single call (auto-generates `OPENCLAW_GATEWAY_TOKEN` and `OPENCLAW_LOG_SECRET`)
- Copies shared API keys (`GOOGLE_GEMINI_API_KEY`, `PARALLEL_AI_API_KEY`, `BRAVE_API_KEY`) from the source app
- Deploys the Docker image
- Restores `fly.toml` to the original app name
- Temporarily sets machine CMD to `sleep 3600` (workaround for empty volume — `sh /data/start.sh` doesn't exist yet)
- Creates full directory structure on the volume (`/data/skills/`, `/data/workspace/`, `/data/chart-renderer/`, etc.)
- Generates and uploads `openclaw.json` with tenant-specific config (Telegram allowlist, workspace path, model, Brave web search)
- Uploads empty `cron/jobs.json` (no scheduled jobs for new tenants)
- Transfers all files via base64: startup scripts, log forwarder, 8 skill SKILL.md files, chart-renderer + doc-extractor (with npm deps), AGENTS.md + SOUL.md (to both `/data/` and `/data/workspace/`), blank workspace templates
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

### 7.3 Configure User Mode

Adds a Telegram user to an existing deployment and optionally sets CoBroker API credentials.

```bash
./fly-scripts/deploy-tenant.sh configure-user \
  --app cobroker-USER \
  --telegram-user-id "12345" \
  [--cobroker-user-id "uuid"] \
  [--cobroker-secret "secret"]
```

**What it does (6 steps):**

1. Reads the current `openclaw.json` from the VM
2. Merges the Telegram user ID into `channels.telegram.allowFrom` (additive — won't duplicate)
3. Uploads the updated `openclaw.json` back to the VM
4. Sets CoBroker secrets (`COBROKER_AGENT_USER_ID`, `COBROKER_AGENT_SECRET`) if provided
5. Clears session files (`/data/agents/main/sessions/*`) to force skill re-snapshot on next message
6. Restarts the app and tails recent logs for verification

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
| `OPENCLAW_LOG_SECRET` | Auto-generated | `openssl rand -hex 16` | Used by log forwarder |
| `ANTHROPIC_API_KEY` | From `--anthropic-key` | User-provided | Claude API access |
| `TELEGRAM_BOT_TOKEN` | From `--bot-token` | User-provided | Telegram bot auth |
| `COBROKER_BASE_URL` | Hardcoded | `https://app.cobroker.ai` | CoBroker Vercel app |
| `COBROKER_AGENT_USER_ID` | From `--cobroker-user-id` | User-provided (optional) | For project/property skills |
| `COBROKER_AGENT_SECRET` | From `--cobroker-secret` | User-provided (optional) | For project/property skills |
| `GOOGLE_GEMINI_API_KEY` | Copied from source app | `--source-app` SSH | Shared — used by search skill |
| `PARALLEL_AI_API_KEY` | Copied from source app | `--source-app` SSH | Shared — used by monitor skill |
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

### 7.8 Active Tenants

| App Name | URL | Bot | Region | Telegram User | Status |
|----------|-----|-----|--------|---------------|--------|
| `cobroker-openclaw` | [cobroker-openclaw.fly.dev](https://cobroker-openclaw.fly.dev/) | @CobrokerIsaacBot | iad | Isaac | Primary (production) |
| `cobroker-openclaw-001` | [cobroker-openclaw-001.fly.dev](https://cobroker-openclaw-001.fly.dev/) | @Cobroker001Bot | iad | *(not configured)* | Test tenant, needs `configure-user` |

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
| Quick Search (Gemini) | Yes | Google-grounded search via Gemini 3 Pro, structured JSON output, results displayed with Save/No Thanks buttons |
| Deep Search (FindAll) | Yes | Parallel AI FindAll engine, async polling, auto-fallback to Quick Search on 0 results |
| Inline URL buttons | Yes | Project links render as tappable Telegram buttons (not text hyperlinks) |
| Places search → properties | Yes | Google Places Text Search, auto-project creation, 4 custom columns |
| Places search → logo layer | Yes | `map_layers` with `dataset_json`, brand logos via `/api/logo` |
| Places nearby (nearest) | Yes | Per-property nearest place search with distance calculation |
| Places nearby (count) | Yes | Per-property Area Insights COUNT for place type density |
| Search routing (brand → Places) | Yes | "Find Starbucks in Dallas" correctly routes to Places Search, not Quick/Deep Search |
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

The `cobroker-search` skill at `/data/skills/cobroker-search/SKILL.md` provides two search paths for finding commercial real estate properties:

**Quick Search** — Google-powered via Gemini 3 Pro with grounding:
- Uses Gemini's `generateContent` API with `google_search` tool and structured JSON output
- Returns property name, address, type, size, price, description, source URL
- ~10-60 seconds, max 50 results, 0 Cobroker credits (Google API costs only)
- Agent formats results as numbered list with inline keyboard buttons (Save to Project / No Thanks)

**Deep Search** — AI research engine via Parallel AI FindAll:
- Submits an async research job with objective, entity type, match conditions
- Generator: always `base` (2-5 min runtime)
- `match_limit` required (min 5, max 1000, default 10 — charges per match, 25+ credits)
- Agent polls status every ~30s (max 8 attempts), reports progress to user
- On 0 matched results: auto-falls back to Quick Search without re-asking user
- Results parsed from `output.full_address.value` and `output.property_specifications.value`

**Search flow:**
1. User asks to find properties → agent asks clarifying questions if needed (type, location, count)
2. Agent presents search mode selection via inline keyboard (Quick Search / Deep Search / Cancel)
3. User picks mode → agent runs search → displays results with Save to Project button
4. User taps Save → agent creates project via `cobroker-projects` POST `/projects` with `"public": true`
5. Agent shares project link as inline URL button: `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]`

**Key behaviors:**
- Response parsing uses `process log` (OpenClaw tool) then a separate `node -e` exec — never piped `curl | node`
- Deep Search polling uses separate curl execs per poll — no `sleep X && curl` combos
- Addresses from Gemini use `full_address` directly (already formatted as "street, city, state zip")
- FindAll candidates may not have clean addresses — agent extracts from output fields

See [Appendix L](#l-skillscobroker-searchskillmd) for the full SKILL.md contents.

### 10.9 Message Delivery Rule (`___` Convention)

The OpenClaw gateway delivers **all text output** from the agent as visible Telegram messages — including text alongside tool calls. This causes duplicate messages when the agent narrates (e.g., "Let me search..." followed by a `message` tool call with the actual response).

**Solution:** Every skill includes a mandatory rule at the top:

```
⚠️ MESSAGE DELIVERY RULE — MANDATORY
When you call ANY tool, your text output MUST be exactly `___` (three underscores) and nothing else.
The gateway filters `___` automatically — any other text gets delivered as a duplicate message.
ALL user-facing communication goes through `message` tool calls. NEVER narrate alongside tool calls.
```

The `___` is filtered by the gateway's text post-processing. This rule is added to:
- `AGENTS.md` (global, at the very top)
- Every skill SKILL.md (per-skill reinforcement)

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
| `cobroker-search` | After saving Quick Search results to project (Step C) |
| `cobroker-search` | After Deep Search completion and project creation |
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

> **Note**: The search skill uses two external APIs — Google Gemini (Quick Search) and Parallel AI FindAll (Deep Search). Gemini API key is set as `GOOGLE_GEMINI_API_KEY` on Fly. FindAll API key is set as `PARALLEL_AI_API_KEY`.

The full skill is ~400 lines. Key sections:

| Section | Content |
|---------|---------|
| 0. Clarify Requirements | Asks 1-2 questions before searching (type, location, count) |
| 1. Search Mode Selection | Inline buttons: Quick Search / Deep Search / Cancel |
| 2. Callback Handling | Maps button clicks to search modes |
| 3. Quick Search (Gemini) | Google-grounded search with structured JSON output |
| 4. Deep Search (FindAll) | Async research engine, 5-step flow (submit → poll → get results → create project → share) |
| 5. Full Flow | End-to-end example: "Find me 10 warehouses in Dallas" |
| 6. Constraints | Max 50 (Quick), match_limit min 5 (Deep), no fabrication |

See `fly-scripts/skills/cobroker-search/SKILL.md` in the repo for full contents.

### 10.12 Search Routing Logic

The agent has two distinct search tools that serve different purposes. Without explicit routing guidance, the agent sometimes misroutes brand/chain lookups to Quick Search (Gemini) instead of Google Places.

**Routing rules (added to all 3 skill files):**

| User wants | Correct tool | Skill |
|------------|-------------|-------|
| Existing locations (chains, brands, businesses) | Google Places Search | `cobroker-projects` Sections 13-15 |
| Available space for sale/lease | Quick/Deep Search | `cobroker-search` |
| Ambiguous ("find locations") | Ask clarifying question | — |

**Key signals:**
- Brand/chain name without "for lease"/"for sale" → Places Search
- Keywords: listings, lease, sale, available, vacant → Quick/Deep Search
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
| 2026-02-11 | Added property search skill (`cobroker-search`) — Quick Search (Gemini 3 Pro) + Deep Search (Parallel AI FindAll). Inline URL buttons for project links (replaces text hyperlinks). Message delivery rule (`___` convention) to prevent duplicate Telegram messages. Deep Search fixes: response parsing, polling improvements, match_limit min 5, 0-result fallback. New Sections 10.8-10.10, Appendix L. | Isaac + Claude |
| 2026-02-11 | Added Google Places integration — 3 operations: search→properties, search→logo layer, nearby analysis (nearest/count). New `places-service.ts`, 2 route files. Skill Sections 13-15 in `cobroker-projects`, `places-*` step types in `cobroker-plan`. New Section 10.11. | Isaac + Claude |
| 2026-02-11 | Added search routing logic across 3 skill files — Places Search for existing locations, Quick/Deep Search for available space. Fixed misleading Starbucks example in cobroker-search. Verified via Telegram: "Find Starbucks in Dallas" correctly routes to Places Search. New Section 10.12. | Isaac + Claude |
| 2026-02-13 | Added 5 new skills: Brassica POS analytics (10.13), chart generation (10.14), email document import (10.15), web change monitoring (10.16), Google Workspace/gog (10.17). Updated AGENTS.md appendix with Telegram message rules, immediate acknowledgment, email import + charts capabilities, Chart Offer Rule. Updated client-memory appendix with message delivery rule, exec-based file handling, workspace storage path. Added Appendices N–R. Updated architecture diagram, directory structure, openclaw.json (workspace config), verified operations table, automation script. | Isaac + Claude |
