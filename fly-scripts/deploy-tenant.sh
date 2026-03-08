#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# deploy-tenant.sh — Provision & configure OpenClaw tenant instances on Fly.io
#
# Usage:
#   ./fly-scripts/deploy-tenant.sh deploy \
#     --app cobroker-USER --bot-token "7xxx:AAxxxx" \
#     --bot-username "CobrokerUserBot" --anthropic-key "sk-ant-..." \
#     [--telegram-user-id "12345"] [--cobroker-user-id "uuid"] \
#     [--cobroker-secret "secret"] [--region iad] \
#     [--source-app cobroker-openclaw]
#
#   ./fly-scripts/deploy-tenant.sh configure-user \
#     --app cobroker-USER --telegram-user-id "12345" \
#     [--cobroker-user-id "uuid"] [--cobroker-secret "secret"]
#
#   ./fly-scripts/deploy-tenant.sh update-files \
#     --app cobroker-USER [--skills-only] [--scripts-only]
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
info()  { echo -e "${CYAN}[info]${NC} $*"; }

# ── Argument parsing ─────────────────────────────────────────────────────────

MODE="${1:-}"
shift || true

APP_NAME=""
BOT_TOKEN=""
BOT_USERNAME=""
ANTHROPIC_KEY=""
TELEGRAM_USER_ID=""
COBROKER_USER_ID=""
COBROKER_SECRET=""
REGION="iad"
SOURCE_APP="cobroker-openclaw"
MODEL="anthropic/claude-opus-4-6"
SKILLS_ONLY=false
SCRIPTS_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)              APP_NAME="$2";          shift 2 ;;
    --bot-token)        BOT_TOKEN="$2";         shift 2 ;;
    --bot-username)     BOT_USERNAME="$2";      shift 2 ;;
    --anthropic-key)    ANTHROPIC_KEY="$2";     shift 2 ;;
    --telegram-user-id) TELEGRAM_USER_ID="$2";  shift 2 ;;
    --cobroker-user-id) COBROKER_USER_ID="$2";  shift 2 ;;
    --cobroker-secret)  COBROKER_SECRET="$2";   shift 2 ;;
    --region)           REGION="$2";            shift 2 ;;
    --source-app)       SOURCE_APP="$2";        shift 2 ;;
    --model)            MODEL="$2";            shift 2 ;;
    --skills-only)      SKILLS_ONLY=true;      shift ;;
    --scripts-only)     SCRIPTS_ONLY=true;     shift ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Helper: transfer a local file to /data/ on the VM via base64 ────────────

transfer_file() {
  local src="$1"
  local dest="$2"  # path relative to /data/

  if [[ ! -f "$src" ]]; then
    warn "Source file not found, skipping: $src"
    return 1
  fi

  local b64
  b64=$(base64 < "$src")
  fly ssh console -C "sh -c 'echo \"$b64\" | base64 -d > /data/$dest'" -a "$APP_NAME"
}

# ── Helper: write generated content to /data/ on the VM via base64 ──────────

write_remote() {
  local content="$1"
  local dest="$2"  # path relative to /data/

  local b64
  b64=$(echo "$content" | base64)
  fly ssh console -C "sh -c 'echo \"$b64\" | base64 -d > /data/$dest'" -a "$APP_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE: deploy
# ─────────────────────────────────────────────────────────────────────────────

do_deploy() {
  # ── Validate required inputs ──
  if [[ -z "$APP_NAME" ]]; then err "--app is required"; exit 1; fi
  if [[ -z "$BOT_TOKEN" ]]; then err "--bot-token is required"; exit 1; fi
  if [[ -z "$BOT_USERNAME" ]]; then err "--bot-username is required"; exit 1; fi
  if [[ -z "$ANTHROPIC_KEY" ]]; then err "--anthropic-key is required"; exit 1; fi

  log "Deploying new tenant: $APP_NAME (region: $REGION)"
  echo ""

  # ── Step 1: Save & swap fly.toml ──
  log "Step 1/16: Swapping fly.toml app name..."
  cp "$REPO_DIR/fly.toml" "$REPO_DIR/fly.toml.bak"
  sed -i.sedtmp "s/^app = .*/app = \"$APP_NAME\"/" "$REPO_DIR/fly.toml"
  rm -f "$REPO_DIR/fly.toml.sedtmp"
  info "fly.toml backed up → fly.toml.bak"

  # Ensure fly.toml is restored on exit (success or failure)
  trap 'log "Restoring fly.toml..."; mv "$REPO_DIR/fly.toml.bak" "$REPO_DIR/fly.toml" 2>/dev/null || true' EXIT

  # ── Step 2: Create Fly app ──
  log "Step 2/16: Creating Fly app..."
  fly apps create "$APP_NAME" || { warn "App may already exist, continuing..."; }

  # ── Step 3: Volume ──
  # Volume is auto-created by `fly deploy` via [mounts] in fly.toml.
  # Manual creation was causing zone mismatch errors ("insufficient resources")
  # because the volume would land in a zone without machine capacity.
  log "Step 3/16: Volume will be auto-created by fly deploy..."

  # ── Step 4: Set secrets (single call to avoid multiple restarts) ──
  log "Step 4/16: Setting secrets..."
  local gw_token
  gw_token=$(openssl rand -hex 32)
  local log_secret
  log_secret="${OPENCLAW_LOG_SECRET:?Set OPENCLAW_LOG_SECRET env var}"

  local secrets_args=(
    "OPENCLAW_GATEWAY_TOKEN=$gw_token"
    "ANTHROPIC_API_KEY=$ANTHROPIC_KEY"
    "TELEGRAM_BOT_TOKEN=$BOT_TOKEN"
    "OPENCLAW_LOG_SECRET=$log_secret"
    "COBROKER_BASE_URL=https://app.cobroker.ai"
  )
  if [[ -n "$COBROKER_USER_ID" ]]; then
    secrets_args+=("COBROKER_AGENT_USER_ID=$COBROKER_USER_ID")
  fi
  if [[ -n "$COBROKER_SECRET" ]]; then
    secrets_args+=("COBROKER_AGENT_SECRET=$COBROKER_SECRET")
  fi

  # Copy COBROKER_AGENT_SECRET from source app if not passed via --cobroker-secret.
  # This shared secret is required for CoBroker skill API calls.
  # COBROKER_AGENT_USER_ID is set per-user during onboarding (configure step).
  if [[ -z "$COBROKER_SECRET" ]]; then
    local agent_secret
    agent_secret=$(fly ssh console -C "sh -c 'printenv COBROKER_AGENT_SECRET'" -a "$SOURCE_APP" 2>/dev/null | head -1)
    if [[ -n "$agent_secret" ]]; then
      secrets_args+=("COBROKER_AGENT_SECRET=$agent_secret")
      info "  COBROKER_AGENT_SECRET copied from $SOURCE_APP ✓"
    else
      warn "  COBROKER_AGENT_SECRET not found on $SOURCE_APP — skills requiring it will fail"
    fi
  fi

  # Copy shared API keys from the source app (skills need these at runtime)
  info "Copying shared API keys from $SOURCE_APP..."
  local shared_keys=("GOOGLE_GEMINI_API_KEY" "PARALLEL_AI_API_KEY" "BRAVE_API_KEY" "GAMMA_API_KEY" "COMPOSIO_API_KEY" "COMPOSIO_MCP_SERVER_ID")
  for key in "${shared_keys[@]}"; do
    local val
    val=$(fly ssh console -C "sh -c 'printenv $key'" -a "$SOURCE_APP" 2>/dev/null | head -1)
    if [[ -n "$val" ]]; then
      secrets_args+=("$key=$val")
      info "  $key ✓"
    else
      warn "  $key not found on $SOURCE_APP, skipping"
    fi
  done

  fly secrets set "${secrets_args[@]}" -a "$APP_NAME"
  info "Set ${#secrets_args[@]} secrets"

  # ── Step 5: Deploy ──
  log "Step 5/16: Deploying image..."
  fly deploy -a "$APP_NAME"

  # ── Step 6: Restore fly.toml (trap handles this, but do it explicitly) ──
  log "Step 6/16: Restoring fly.toml..."
  mv "$REPO_DIR/fly.toml.bak" "$REPO_DIR/fly.toml"
  trap - EXIT  # Clear the trap since we restored manually

  # ── Step 7: Keep VM alive for file transfer ──
  # The machine's CMD is `sh /data/start.sh` which doesn't exist yet on the
  # empty volume, so it crashes immediately. Temporarily swap to `sleep 3600`
  # to keep the VM running while we transfer files.
  log "Step 7/16: Holding VM alive for file transfer..."
  local machine_id
  machine_id=$(fly machines list -a "$APP_NAME" --json 2>/dev/null | node -e "
    let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
      const m=JSON.parse(d); console.log(m[0]?.id||'');
    });"
  )
  if [[ -z "$machine_id" ]]; then
    err "Could not find machine ID"; exit 1
  fi
  info "Machine: $machine_id"

  # ── Step 7b: Register bot in Supabase ──
  local sb_url="${SUPABASE_URL:?Set SUPABASE_URL env var}"
  local sb_key="${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY env var}"

  log "Step 7b: Registering bot in Supabase openclaw_agents..."
  local upsert_payload
  upsert_payload=$(node -e "console.log(JSON.stringify({
    fly_app_name: process.argv[1],
    fly_region: process.argv[2],
    fly_machine_id: process.argv[3],
    bot_token: process.argv[4],
    bot_username: process.argv[5],
    gateway_token: process.argv[6],
    status: 'available'
  }))" "$APP_NAME" "$REGION" "$machine_id" "$BOT_TOKEN" "$BOT_USERNAME" "$gw_token")

  local upsert_status
  upsert_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${sb_url}/rest/v1/openclaw_agents" \
    -H "apikey: ${sb_key}" \
    -H "Authorization: Bearer ${sb_key}" \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates" \
    -d "$upsert_payload")

  if [[ "$upsert_status" =~ ^2 ]]; then
    info "Bot registered in Supabase ✓ (HTTP $upsert_status)"
  else
    warn "Supabase upsert returned HTTP $upsert_status — check openclaw_agents table manually"
  fi

  fly machine update "$machine_id" --command "sleep 3600" --yes -a "$APP_NAME"
  sleep 10  # let it stabilise

  # ── Step 8: Create directory structure ──
  log "Step 8/16: Creating directory structure on VM..."
  fly ssh console -C "sh -c 'mkdir -p \
    /data/skills/cobroker-projects \
    /data/skills/cobroker-search \
    /data/skills/cobroker-plan \
    /data/skills/cobroker-charts \
    /data/skills/cobroker-monitor \
    /data/skills/cobroker-client-memory \
    /data/skills/cobroker-deep-research \
    /data/skills/cobroker-presentations \
    /data/databases \
    /data/doc-extractor \
    /data/chart-renderer/fonts \
    /data/workspace \
    /data/cron \
    /data/bin'" -a "$APP_NAME"

  # ── Step 9: Generate openclaw.json ──
  log "Step 9/16: Generating and uploading openclaw.json..."

  local openclaw_json
  openclaw_json=$(cat <<JSONEOF
{
  "gateway": {
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  },
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
      "dmPolicy": "open",
      "allowFrom": ["*"],
      "groupPolicy": "disabled",
      "streamMode": "off",
      "capabilities": {
        "inlineButtons": "dm"
      }
    }
  },
  "skills": {
    "load": {
      "extraDirs": [
        "/data/skills"
      ]
    }
  },
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "workspace": "/data/workspace",
      "heartbeat": {
        "every": "0m"
      },
      "subagents": {
        "maxConcurrent": 8
      },
      "model": {
        "primary": "$MODEL"
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
  "tools": {
    "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
    "web": {
      "search": {
        "enabled": true,
        "provider": "brave"
      }
    }
  }
}
JSONEOF
)
  write_remote "$openclaw_json" "openclaw.json"

  # ── Step 10: Generate cron/jobs.json (empty — no scheduled jobs for new tenant) ──
  log "Step 10/16: Uploading cron/jobs.json..."
  write_remote '{"version":1,"jobs":[]}' "cron/jobs.json"

  # ── Step 11: Transfer files from repo ──
  log "Step 11/16: Transferring files to VM..."

  # Core scripts
  info "  start.sh"
  transfer_file "$SCRIPT_DIR/start.sh" "start.sh"
  info "  log-forwarder.js"
  transfer_file "$SCRIPT_DIR/log-forwarder.js" "log-forwarder.js"

  # Chart renderer
  info "  chart-renderer/"
  transfer_file "$SCRIPT_DIR/chart-renderer/generate-chart.mjs" "chart-renderer/generate-chart.mjs"
  transfer_file "$SCRIPT_DIR/chart-renderer/package.json" "chart-renderer/package.json"
  transfer_file "$SCRIPT_DIR/chart-renderer/fonts/Inter-Regular.ttf" "chart-renderer/fonts/Inter-Regular.ttf"
  transfer_file "$SCRIPT_DIR/chart-renderer/fonts/Inter-SemiBold.ttf" "chart-renderer/fonts/Inter-SemiBold.ttf"

  # Doc extractor
  info "  doc-extractor/"
  transfer_file "$SCRIPT_DIR/doc-extractor/extract.mjs" "doc-extractor/extract.mjs"
  transfer_file "$SCRIPT_DIR/doc-extractor/package.json" "doc-extractor/package.json"

  # Skills from fly-scripts/skills/
  for skill_dir in "$SCRIPT_DIR"/skills/cobroker-*/; do
    local skill_name
    skill_name=$(basename "$skill_dir")
    [[ "$skill_name" == "cobroker-brassica-toast" ]] && continue
    info "  skills/$skill_name/SKILL.md"
    transfer_file "$skill_dir/SKILL.md" "skills/$skill_name/SKILL.md"
  done

  # Agent personality files → /data/ (source copies) + /data/workspace/ (active)
  info "  AGENTS.md (root + workspace)"
  transfer_file "$REPO_DIR/cobroker-config-backup/AGENTS.md" "AGENTS.md"
  transfer_file "$REPO_DIR/cobroker-config-backup/AGENTS.md" "workspace/AGENTS.md"

  info "  SOUL.md (root + workspace)"
  transfer_file "$REPO_DIR/cobroker-config-backup/SOUL.md" "SOUL.md"
  transfer_file "$REPO_DIR/cobroker-config-backup/SOUL.md" "workspace/SOUL.md"

  # Blank workspace files for new user
  info "  workspace/ (blank templates)"
  write_remote "# Identity — this file is managed by the agent" "workspace/IDENTITY.md"
  write_remote "# User — this file is managed by the agent" "workspace/USER.md"
  write_remote "# Tools — this file is managed by the agent" "workspace/TOOLS.md"

  # ── Step 12: Install npm deps on VM ──
  log "Step 12/16: Installing npm dependencies on VM..."
  info "  chart-renderer"
  fly ssh console -C "sh -c 'cd /data/chart-renderer && npm install --production 2>&1'" -a "$APP_NAME"
  info "  doc-extractor"
  fly ssh console -C "sh -c 'cd /data/doc-extractor && npm install --production 2>&1'" -a "$APP_NAME"

  # ── Step 13: Fix ownership ──
  log "Step 13/16: Fixing file ownership..."
  fly ssh console -C "sh -c 'chown -R node:node /data/'" -a "$APP_NAME"

  # ── Step 14: Restore real CMD and restart ──
  log "Step 14/16: Restoring start command and restarting..."
  fly machine update "$machine_id" --command "sh /data/start.sh" --yes -a "$APP_NAME"

  # ── Step 15: Wait for gateway + verify Telegram provider ──
  log "Step 15/16: Waiting for gateway to start..."
  local retries=0
  local max_retries=12  # 12 x 10s = 2 minutes max
  local telegram_ok=false
  while [[ $retries -lt $max_retries ]]; do
    sleep 10
    retries=$((retries + 1))
    local recent_logs
    recent_logs=$(fly logs -a "$APP_NAME" --no-tail 2>/dev/null | tail -30)
    if echo "$recent_logs" | grep -q "\[telegram\].*starting provider"; then
      telegram_ok=true
      break
    fi
    info "  Waiting... ($((retries * 10))s)"
  done

  if $telegram_ok; then
    info "Telegram provider started ✓"
  else
    warn "Telegram provider not detected in logs after $((retries * 10))s"
    info "─── Recent logs ───"
    fly logs -a "$APP_NAME" --no-tail 2>/dev/null | tail -15 || true
  fi

  # ── Step 16: Agent smoke test ──
  log "Step 16/16: Running agent smoke test..."
  local test_output
  test_output=$(fly ssh console -C "sh -c 'node dist/index.js agent --local --session-id deploy-test --message \"List your skills in one sentence.\" --json 2>&1'" -a "$APP_NAME" 2>/dev/null)

  # Extract the text reply and skill count from JSON
  local reply skills_count
  reply=$(echo "$test_output" | node -e "
    let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
      try {
        const j=JSON.parse(d);
        console.log(j.payloads?.[0]?.text || 'NO_REPLY');
      } catch(e) { console.log('PARSE_ERROR'); }
    });" 2>/dev/null)
  skills_count=$(echo "$test_output" | node -e "
    let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
      try {
        const j=JSON.parse(d);
        const s=j.meta?.systemPromptReport?.skills?.entries || [];
        console.log(s.length);
      } catch(e) { console.log('0'); }
    });" 2>/dev/null)

  if [[ "$reply" != "NO_REPLY" && "$reply" != "PARSE_ERROR" && -n "$reply" ]]; then
    info "Agent responded ✓ ($skills_count skills loaded)"
    info "Agent says: ${reply:0:200}"
  else
    warn "Agent test failed — check logs"
    echo "$test_output" | tail -10
  fi

  # Clean up test session
  fly ssh console -C "sh -c 'rm -f /data/agents/main/sessions/deploy-test*.jsonl'" -a "$APP_NAME" 2>/dev/null || true

  echo ""
  info "─── App status ───"
  fly status -a "$APP_NAME"

  # ── Summary ──
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Tenant deployed successfully: $APP_NAME${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  App URL:    https://$APP_NAME.fly.dev/"
  echo "  Region:     $REGION"
  echo "  Bot:        @$BOT_USERNAME"
  echo ""
  if [[ -z "$COBROKER_USER_ID" || -z "$COBROKER_SECRET" ]]; then
    echo -e "  ${YELLOW}⚠ CoBroker API credentials not set — project/property skills won't work.${NC}"
    echo "    Run configure-user mode with --cobroker-user-id and --cobroker-secret"
    echo ""
  fi
  echo "  Next steps:"
  echo "    1. Verify: fly logs -a $APP_NAME"
  echo "    2. Check skills: fly ssh console -C \"ls /data/skills/*/SKILL.md\" -a $APP_NAME"
  echo "    3. When a user signs up, their Telegram ID will be configured automatically"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE: configure-user
# ─────────────────────────────────────────────────────────────────────────────

do_configure_user() {
  if [[ -z "$APP_NAME" ]]; then err "--app is required"; exit 1; fi
  if [[ -z "$TELEGRAM_USER_ID" ]]; then err "--telegram-user-id is required"; exit 1; fi

  log "Configuring user for tenant: $APP_NAME"
  echo ""

  # ── Step 1: Read current openclaw.json from VM ──
  log "Step 1/7: Reading current openclaw.json from VM..."
  local current_config
  current_config=$(fly ssh console -C "cat /data/openclaw.json" -a "$APP_NAME")

  # ── Step 2: Update allowFrom with the new Telegram user ID ──
  log "Step 2/7: Updating allowFrom with Telegram user ID: $TELEGRAM_USER_ID..."

  # Use node (available on the OpenClaw image) to safely merge the JSON
  local updated_config
  updated_config=$(echo "$current_config" | node -e "
    const fs = require('fs');
    let input = '';
    process.stdin.on('data', d => input += d);
    process.stdin.on('end', () => {
      const cfg = JSON.parse(input);
      const af = cfg.channels?.telegram?.allowFrom || [];
      if (!af.includes('$TELEGRAM_USER_ID')) {
        af.push('$TELEGRAM_USER_ID');
      }
      if (!cfg.channels) cfg.channels = {};
      if (!cfg.channels.telegram) cfg.channels.telegram = {};
      cfg.channels.telegram.allowFrom = af;
      console.log(JSON.stringify(cfg, null, 2));
    });
  ")

  # ── Step 3: Transfer updated openclaw.json back to VM ──
  log "Step 3/7: Uploading updated openclaw.json..."
  write_remote "$updated_config" "openclaw.json"
  fly ssh console -C "sh -c 'chown node:node /data/openclaw.json'" -a "$APP_NAME"

  # ── Step 4: Set CoBroker secrets if provided ──
  local secrets_staged=false
  if [[ -n "$COBROKER_USER_ID" || -n "$COBROKER_SECRET" ]]; then
    log "Step 4/7: Setting CoBroker secrets (staged)..."
    local secret_args=()
    if [[ -n "$COBROKER_USER_ID" ]]; then
      secret_args+=("COBROKER_AGENT_USER_ID=$COBROKER_USER_ID")
    fi
    if [[ -n "$COBROKER_SECRET" ]]; then
      secret_args+=("COBROKER_AGENT_SECRET=$COBROKER_SECRET")
    fi
    fly secrets set "${secret_args[@]}" --stage -a "$APP_NAME"
    secrets_staged=true
  else
    log "Step 4/7: No CoBroker secrets to set, skipping..."
  fi

  # ── Step 5: Update Supabase agent record ──
  if [[ -n "$COBROKER_USER_ID" ]]; then
    log "Step 5/7: Updating agent record in Supabase..."
    local sb_url="${SUPABASE_URL:?Set SUPABASE_URL env var}"
    local sb_key="${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY env var}"

    local update_payload
    update_payload=$(node -e "console.log(JSON.stringify({
      user_id: process.argv[1],
      telegram_user_id: Number(process.argv[2]),
      status: 'linked',
      linked_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    }))" "$COBROKER_USER_ID" "$TELEGRAM_USER_ID")

    local update_status
    update_status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH "${sb_url}/rest/v1/openclaw_agents?fly_app_name=eq.${APP_NAME}" \
      -H "apikey: ${sb_key}" \
      -H "Authorization: Bearer ${sb_key}" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=minimal" \
      -d "$update_payload")

    if [[ "$update_status" =~ ^2 ]]; then
      info "Agent record updated in Supabase ✓ (HTTP $update_status)"
    else
      warn "Supabase update returned HTTP $update_status — check openclaw_agents table"
    fi
  else
    log "Step 5/7: No CoBroker user ID provided, skipping Supabase update..."
  fi

  # ── Step 6: Clear sessions (force skill re-snapshot) ──
  log "Step 6/7: Clearing sessions to force skill re-snapshot..."
  fly ssh console -C "sh -c 'rm -f /data/agents/main/sessions/*.jsonl /data/agents/main/sessions/sessions.json'" -a "$APP_NAME" || true
  fly ssh console -C 'chown -R node:node /data/agents' -a "$APP_NAME" || true

  # ── Step 7: Deploy secrets and restart ──
  if [[ "$secrets_staged" == "true" ]]; then
    log "Step 7/7: Deploying staged secrets (also restarts app)..."
    fly secrets deploy -a "$APP_NAME"
  else
    log "Step 7/7: Restarting app..."
    fly apps restart "$APP_NAME"
  fi

  echo ""
  log "Waiting 15s for restart..."
  sleep 15

  info "─── Recent logs ───"
  fly logs -a "$APP_NAME" --no-tail 2>/dev/null | tail -10 || warn "Could not fetch logs"

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  User configured for: $APP_NAME${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  Telegram user ID: $TELEGRAM_USER_ID"
  if [[ -n "$COBROKER_USER_ID" ]]; then
    echo "  CoBroker user ID: $COBROKER_USER_ID"
  fi
  echo ""
  echo "  The user can now message @bot on Telegram to start chatting."
  echo "  Verify: fly logs -a $APP_NAME"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE: update-files
# ─────────────────────────────────────────────────────────────────────────────

do_update_files() {
  if [[ -z "$APP_NAME" ]]; then err "--app is required"; exit 1; fi

  log "Updating files on: $APP_NAME"
  echo ""

  # ── Check if VM is running or stopped ──
  local vm_state
  vm_state=$(fly status -a "$APP_NAME" --json 2>/dev/null | node -e "
    let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
      const s=JSON.parse(d); const m=s.Machines||s.machines||[];
      console.log(m[0]?.state||'unknown');
    });" 2>/dev/null)

  local machine_id
  machine_id=$(fly machines list -a "$APP_NAME" --json 2>/dev/null | node -e "
    let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
      const m=JSON.parse(d); console.log(m[0]?.id||'');
    });"
  )
  if [[ -z "$machine_id" ]]; then
    err "Could not find machine ID"; exit 1
  fi
  info "Machine: $machine_id (state: $vm_state)"

  local needs_cmd_swap=false
  if [[ "$vm_state" != "started" ]]; then
    log "VM is stopped — temporarily setting CMD to sleep 3600..."
    fly machine update "$machine_id" --command "sleep 3600" --yes -a "$APP_NAME"
    sleep 10
    needs_cmd_swap=true
  fi

  # ── Transfer files ──
  log "Transferring files..."

  if [[ "$SKILLS_ONLY" == "false" && "$SCRIPTS_ONLY" == "false" ]] || [[ "$SCRIPTS_ONLY" == "true" ]]; then
    info "  start.sh"
    transfer_file "$SCRIPT_DIR/start.sh" "start.sh"
    info "  log-forwarder.js"
    transfer_file "$SCRIPT_DIR/log-forwarder.js" "log-forwarder.js"
  fi

  if [[ "$SKILLS_ONLY" == "false" && "$SCRIPTS_ONLY" == "false" ]] || [[ "$SKILLS_ONLY" == "true" ]]; then
    # Create skill directories if missing (handles skills added after initial deploy)
    local skill_dirs=""
    for skill_dir in "$SCRIPT_DIR"/skills/cobroker-*/; do
      local skill_name
      skill_name=$(basename "$skill_dir")
      [[ "$skill_name" == "cobroker-brassica-toast" ]] && continue
      skill_dirs="$skill_dirs /data/skills/$skill_name"
    done
    fly ssh console -C "sh -c 'mkdir -p $skill_dirs'" -a "$APP_NAME"

    # Skills from fly-scripts/skills/
    for skill_dir in "$SCRIPT_DIR"/skills/cobroker-*/; do
      local skill_name
      skill_name=$(basename "$skill_dir")
      [[ "$skill_name" == "cobroker-brassica-toast" ]] && continue
      info "  skills/$skill_name/SKILL.md"
      transfer_file "$skill_dir/SKILL.md" "skills/$skill_name/SKILL.md"
    done
  fi

  # Transfer personality files only in full mode (not --skills-only or --scripts-only)
  if [[ "$SKILLS_ONLY" == "false" && "$SCRIPTS_ONLY" == "false" ]]; then
    info "  AGENTS.md (root + workspace)"
    transfer_file "$REPO_DIR/cobroker-config-backup/AGENTS.md" "AGENTS.md"
    transfer_file "$REPO_DIR/cobroker-config-backup/AGENTS.md" "workspace/AGENTS.md"

    info "  SOUL.md (root + workspace)"
    transfer_file "$REPO_DIR/cobroker-config-backup/SOUL.md" "SOUL.md"
    transfer_file "$REPO_DIR/cobroker-config-backup/SOUL.md" "workspace/SOUL.md"

  fi

  # ── Fix ownership ──
  log "Fixing file ownership..."
  fly ssh console -C "sh -c 'chown -R node:node /data/'" -a "$APP_NAME"

  # ── Clear sessions (force skill re-snapshot) ──
  log "Clearing sessions to force skill re-snapshot..."
  fly ssh console -C "sh -c 'rm -f /data/agents/main/sessions/*.jsonl /data/agents/main/sessions/sessions.json'" -a "$APP_NAME" || true

  # ── Restore CMD and restart ──
  if [[ "$needs_cmd_swap" == "true" ]]; then
    log "Restoring start command..."
    fly machine update "$machine_id" --command "sh /data/start.sh" --yes -a "$APP_NAME"
  else
    log "Restarting app..."
    fly apps restart "$APP_NAME"
  fi

  echo ""
  log "Waiting 15s for restart..."
  sleep 15

  info "─── Recent logs ───"
  fly logs -a "$APP_NAME" --no-tail 2>/dev/null | tail -10 || warn "Could not fetch logs"

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Files updated on: $APP_NAME${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  if [[ "$SKILLS_ONLY" == "true" ]]; then
    echo "  Updated: skills only"
  elif [[ "$SCRIPTS_ONLY" == "true" ]]; then
    echo "  Updated: scripts only (start.sh, log-forwarder.js)"
  else
    echo "  Updated: all files (scripts, skills, personality)"
  fi
  echo "  Sessions cleared — skills will re-snapshot on next message"
  echo ""
  echo "  Verify: fly logs -a $APP_NAME"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatch
# ─────────────────────────────────────────────────────────────────────────────

case "$MODE" in
  deploy)
    do_deploy
    ;;
  configure-user)
    do_configure_user
    ;;
  update-files)
    do_update_files
    ;;
  *)
    echo "Usage: $0 {deploy|configure-user|update-files} [options]"
    echo ""
    echo "Modes:"
    echo "  deploy          Full deployment of a new tenant instance"
    echo "  configure-user  Set user-specific values on existing deployment"
    echo "  update-files    Push updated files to an existing VM (skills, scripts, personality)"
    echo ""
    echo "Deploy options:"
    echo "  --app NAME              Fly app name (required)"
    echo "  --bot-token TOKEN       Telegram bot token (required)"
    echo "  --bot-username NAME     Telegram bot username (required)"
    echo "  --anthropic-key KEY     Anthropic API key (required)"
    echo "  --telegram-user-id ID   Telegram user ID (optional, set later)"
    echo "  --cobroker-user-id ID   CoBroker user ID (optional, set later)"
    echo "  --cobroker-secret SEC   CoBroker agent secret (optional, set later)"
    echo "  --region REGION         Fly region (default: iad)"
    echo "  --source-app APP        Copy shared API keys from this app (default: cobroker-openclaw)"
    echo "  --model MODEL           AI model ID (default: anthropic/claude-opus-4-6)"
    echo ""
    echo "Configure-user options:"
    echo "  --app NAME              Fly app name (required)"
    echo "  --telegram-user-id ID   Telegram user ID (required)"
    echo "  --cobroker-user-id ID   CoBroker user ID (optional)"
    echo "  --cobroker-secret SEC   CoBroker agent secret (optional)"
    echo ""
    echo "Update-files options:"
    echo "  --app NAME              Fly app name (required)"
    echo "  --skills-only           Only update skill SKILL.md files"
    echo "  --scripts-only          Only update start.sh + log-forwarder.js"
    exit 1
    ;;
esac
