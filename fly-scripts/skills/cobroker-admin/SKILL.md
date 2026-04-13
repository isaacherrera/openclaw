---
name: cobroker-admin
description: Monitor and manage CoBroker OpenClaw fleet — view tenant balances, logs, costs, agents, and last activity. Use for admin dashboards, nightly reports, and fleet health checks.
metadata: { "openclaw": { "emoji": "📊", "requires": { "bins": ["curl"], "env": ["COBROKER_BASE_URL", "COBROKER_AGENT_USER_ID", "COBROKER_AGENT_SECRET"] }, "primaryEnv": "COBROKER_AGENT_SECRET" } }
---

# CoBroker Admin

Use this skill for fleet monitoring, usage reports, and admin operations on the CoBroker OpenClaw platform.

## Authentication

All admin endpoints require these HTTP headers, populated from environment variables:

```bash
-H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
-H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Base URL is `$COBROKER_BASE_URL` (e.g. `https://app.cobroker.ai`).

Every curl command below uses these headers. If you get 401, verify the env vars are set. If 403, the user is not an admin.

## 1. Balances

Get per-tenant budget, spend, and remaining balance.

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/balances" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Response:**
```json
{
  "success": true,
  "totals": { "total_budget_usd": 200.0, "spent_usd": 12.34, "remaining_usd": 187.66, "percent_used": 6.2 },
  "users": [
    { "user_id": "...", "display_name": "Tenant Name", "fly_app_name": "cobroker-tenant-010", "bot_username": "TenantBot", "total_budget_usd": 200.0, "spent_usd": 1.23, "remaining_usd": 198.77, "percent_used": 0.6 }
  ]
}
```

## 2. Logs

Get recent activity logs. Supports filtering.

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/logs?limit=50" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Query params:** `limit` (1-200, default 50), `type`, `tenant_id`, `session_id`

**Response:**
```json
{
  "success": true,
  "data": [
    { "id": 123, "tenant_id": "cobroker-tenant-010", "session_id": "abc", "type": "message", "message": "Hello", "external_api": null, "cost_total": 0.003, "entry_timestamp": "2026-03-11T00:59:03Z" }
  ],
  "count": 50
}
```

## 3. Agents

List all registered agent VMs.

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/agents" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Response:**
```json
{
  "success": true,
  "data": [
    { "id": 1, "user_id": "...", "fly_app_name": "cobroker-tenant-010", "fly_machine_id": "abc123", "bot_username": "TenantBot", "display_name": "Tenant Name", "status": "active", "region": "iad", "created_at": "...", "updated_at": "..." }
  ],
  "count": 10
}
```

## 4. Costs

Get cost breakdown by tenant and service over a time period.

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/costs?days=30" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Query params:** `days` (1-90, default 30)

**Response:**
```json
{
  "success": true,
  "days": 30,
  "multiplier": 2.5,
  "grand_total_usd": 45.67,
  "tenants": [
    { "tenant_id": "cobroker-tenant-010", "total_calls": 150, "total_cost_usd": 4.56, "services": [{ "service": "Anthropic Claude", "calls": 100, "cost_usd": 3.45 }] }
  ]
}
```

## 5. Last Activity Per Tenant

Get last activity for every active tenant in a single call. Much faster than querying logs per tenant.

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/activity" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Response:**
```json
{
  "success": true,
  "data": [
    { "tenant_id": "cobroker-tenant-010", "last_message": "Searching for properties...", "last_type": "message", "last_timestamp": "2026-03-11T00:59:03Z", "last_cost": 0.003 }
  ],
  "count": 10
}
```

## 6. Dashboard (All-in-One)

Returns ALL admin data in a single API call. Use this for cron jobs, comprehensive reports, and any task that needs multiple data types. Eliminates the need for multiple sequential calls.

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/dashboard" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Query params:**
- `sections` — comma-separated list of sections to include (default: all). Valid: `balances`, `agents`, `costs`, `activity`, `logs`
- `days` — cost lookback period (1-90, default 30)
- `log_limit` — number of recent logs (1-200, default 50)

**Examples:**
```bash
# Everything (default)
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/dashboard" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"

# Just balances and activity (for nightly report)
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/dashboard?sections=balances,activity" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"

# Costs for last 7 days with recent logs
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/dashboard?sections=costs,logs&days=7&log_limit=20" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Response** (all sections):
```json
{
  "success": true,
  "sections": ["balances", "agents", "costs", "activity", "logs"],
  "balances": {
    "totals": { "total_budget_usd": 200.0, "spent_usd": 12.34, "remaining_usd": 187.66, "percent_used": 6.2 },
    "users": [{ "user_id": "...", "display_name": "Tenant Name", "fly_app_name": "cobroker-tenant-010", "bot_username": "TenantBot", "total_budget_usd": 200.0, "spent_usd": 1.23, "remaining_usd": 198.77, "percent_used": 0.6 }]
  },
  "agents": {
    "data": [{ "id": 1, "fly_app_name": "cobroker-tenant-010", "display_name": "Tenant Name", "status": "active", "region": "iad" }],
    "count": 10
  },
  "costs": {
    "days": 30, "multiplier": 2.5, "grand_total_usd": 45.67,
    "tenants": [{ "tenant_id": "cobroker-tenant-010", "total_calls": 150, "total_cost_usd": 4.56, "services": [{ "service": "Claude AI", "calls": 100, "cost_usd": 3.45 }] }]
  },
  "activity": {
    "data": [{ "tenant_id": "cobroker-tenant-010", "last_message": "Searching...", "last_type": "message", "last_timestamp": "2026-03-11T00:59:03Z", "last_cost": 0.003 }],
    "count": 10
  },
  "logs": {
    "data": [{ "id": 123, "tenant_id": "cobroker-tenant-010", "type": "message", "message": "Hello", "cost_total": 0.003, "entry_timestamp": "2026-03-11T00:59:03Z" }],
    "count": 50
  }
}
```

All sections are fetched in parallel. If a section fails, it returns `{ "error": "..." }` for that section while other sections still succeed.

## 7. Nightly Usage Report

To generate the daily usage report, make **1 API call** using the usage-report endpoint (Section 9):

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/usage-report?days=14" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Then format the response as a table with columns: **User, Prompts, Active Days, Cost**. Use `active_days`/`total_days` for the Active Days column (e.g., "7/12"). Include fleet totals at the bottom. Sort by active days descending (the endpoint already returns sorted data).

All metrics are pre-calculated server-side:
- **Prompts** = user messages only, heartbeats excluded
- **Active Days** = distinct dates with at least one user message
- **Total Days** = min(report period, days since user activation)
- **Cost** = same multiplier-based cost calculation as the costs endpoint

## 8. Creating Cron Jobs

**IMPORTANT: Follow these rules for EVERY cron job you create.** These are mandatory flags — do not skip any of them.

### Required flags (always use ALL of these)

```bash
openclaw cron add \
  --name "<descriptive name>" \
  --cron "<cron expression>" \
  --tz "America/Denver" \
  --session isolated \
  --timeout 120 \
  --message "<task description — always reference this skill and the dashboard endpoint>" \
  --announce \
  --channel telegram \
  --to 8411700555 \
  --best-effort-deliver
```

### Rules for the `--message` flag

The message MUST include:
1. What report/task to generate
2. A reference to this skill: "Use the cobroker-admin skill"
3. The exact dashboard endpoint URL with `?sections=` param specifying only the data needed
4. Instructions to format and send the result

**Template:**
```
Generate the <report name>. Use the cobroker-admin skill Section 6: call /api/agent/openclaw/admin/dashboard?sections=<needed sections>, then format and send the report here.
```

### Choosing the right `sections` param

| Report type | Sections to request | Example |
|-------------|-------------------|---------|
| Usage/budget report | `balances,activity` | Daily spend + last activity per tenant |
| Cost breakdown | `costs` | Per-tenant cost by service (add `&days=7` for weekly) |
| Fleet status | `agents,activity` | VM status + last activity |
| Full dashboard | (omit param — gets all) | Everything: balances, agents, costs, activity, logs |
| Activity + logs | `activity,logs` | Last activity + recent log entries |

### Examples

**Daily usage report at 10 AM MT:**
```bash
openclaw cron add \
  --name "Daily Usage Report — 10 AM MT" \
  --cron "0 10 * * *" \
  --tz "America/Denver" \
  --session isolated \
  --timeout 120 \
  --message "Generate the daily usage report. Use the cobroker-admin skill Section 6: call /api/agent/openclaw/admin/dashboard?sections=balances,activity in a single curl request, then format and send the report here." \
  --announce \
  --channel telegram \
  --to 8411700555 \
  --best-effort-deliver
```

**Weekly cost report every Monday at 9 AM MT:**
```bash
openclaw cron add \
  --name "Weekly Cost Report" \
  --cron "0 9 * * 1" \
  --tz "America/Denver" \
  --session isolated \
  --timeout 120 \
  --message "Generate the weekly cost report. Use the cobroker-admin skill Section 6: call /api/agent/openclaw/admin/dashboard?sections=costs&days=7 in a single curl request, then format and send the report here." \
  --announce \
  --channel telegram \
  --to 8411700555 \
  --best-effort-deliver
```

**Fleet health check every 6 hours:**
```bash
openclaw cron add \
  --name "Fleet Health Check" \
  --cron "0 */6 * * *" \
  --tz "America/Denver" \
  --session isolated \
  --timeout 120 \
  --message "Run a fleet health check. Use the cobroker-admin skill Section 6: call /api/agent/openclaw/admin/dashboard?sections=agents,activity in a single curl request. Report any agents with status != active or tenants with no activity in the last 24 hours." \
  --announce \
  --channel telegram \
  --to 8411700555 \
  --best-effort-deliver
```

### Why these flags matter

| Flag | Why it's mandatory |
|------|-------------------|
| `--session isolated` | Fires reliably every time. `--session main` has a one-shot guard that silently skips repeat runs. |
| `--best-effort-deliver` | Prevents delivery failures from marking the job as errored. The report still generates — only delivery is skipped. |
| `--announce --channel telegram --to <id>` | Delivers the report to Telegram. Without these, the report generates but nobody sees it. |
| `--timeout 120` | Prevents runaway sessions. 2 minutes is plenty for any admin report. |
| `--message` with skill reference | Without a skill reference, the agent wastes time discovering endpoints and auth. |
| `--message` with dashboard URL | One API call returns all data. Without the URL, the agent may make multiple slow calls. |

### Managing cron jobs

```bash
# List all cron jobs
openclaw cron list

# View recent runs
openclaw cron runs --id <job-id> --limit 5

# Remove a job
openclaw cron remove <job-id>
```

### Verifying a new cron job

1. After creating: `openclaw cron list` — verify schedule and next run time
2. After first run: `openclaw cron runs --id <job-id> --limit 1` — verify status `ok`
3. Check Telegram Logs channel for the report output

## 9. Usage Report

Pre-calculated per-tenant usage metrics for the daily report. Returns prompts (user messages only, heartbeats excluded), active days, and cost — no derivation needed.

```bash
curl -sS "$COBROKER_BASE_URL/api/agent/openclaw/admin/usage-report?days=14" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

**Query params:** `days` (1-90, default 14)

**Response:**
```json
{
  "success": true,
  "days": 14,
  "cost_basis": "raw_no_markup",
  "period": { "start": "2026-03-31", "end": "2026-04-13" },
  "fleet": {
    "anthropic_cost_usd": 0.99,
    "api_cost_usd": 5.05,
    "total_cost_usd": 6.04,
    "total_prompts": 162,
    "active_users": 10,
    "total_users": 10
  },
  "users": [
    {
      "tenant_id": "cobroker-tenant-010",
      "display_name": "mf@emerging.com",
      "prompts": 18,
      "active_days": 14,
      "total_days": 14,
      "anthropic_cost_usd": 0.18,
      "api_cost_usd": 0.00,
      "total_cost_usd": 0.18,
      "cost_usd": 0.18
    }
  ]
}
```

**Key fields:**
- `prompts` — count of user messages with `role='user'`, excluding heartbeats (`"Read HEARTBEAT.md if it exists"`)
- `active_days` — distinct calendar dates with at least one user prompt (guaranteed `≤ total_days`)
- `total_days` — `min(report_period, days_since_user_activation)`. A user who activated 5 days ago shows "2/5" not "2/14"
- `anthropic_cost_usd` — **raw Anthropic billed cost** from `tenant_usage_snapshots` (sourced from Anthropic Admin API) for the period window. **No markup.**
- `api_cost_usd` — **raw** non-Anthropic external-API cost (Esri, Brave web search, Lightcast, Parallel.ai, Perplexity, etc.) from `pricing_config × openclaw_logs` scan. **No markup.**
- `total_cost_usd` — `anthropic_cost_usd + api_cost_usd` per row
- `cost_usd` — backwards-compat alias of `total_cost_usd`
- `cost_basis: "raw_no_markup"` — top-level flag confirming no customer markup has been applied anywhere in the response. The formatter should defensively check this and refuse to send the report if it ever reads something else.

**Cron message for daily usage report:**
```
Generate the daily usage report. Use the cobroker-admin skill Section 9: call /api/agent/openclaw/admin/usage-report?days=14, then format as a Markdown table with columns: User, Prompts, Active Days (X/Y), Anthropic, APIs, Total. Sort by active_days descending. Include fleet totals on a final line: "Anthropic $A · APIs $B · Total $C".

IMPORTANT: the report header MUST include the phrase "(raw cost, no markup)" so the reader knows these are real operational costs, not the 4×-marked-up customer price. All three cost columns come from the endpoint raw — do not apply any multiplier or discount. If the response has `cost_basis != "raw_no_markup"`, refuse to send the message and report the anomaly instead.
```

## Error Handling

- **401**: Check `COBROKER_AGENT_USER_ID` and `COBROKER_AGENT_SECRET` env vars.
- **403**: The authenticated user is not an admin.
- **500**: Retry once, then report the error code and message.
