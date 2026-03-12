---
name: cobroker-admin
description: >
  Admin dashboard queries: activity logs, agent status, user budgets, and API costs.
  Use when the user asks about recent activity, which agents are running, who logged in,
  budget status across all users, or total API costs.
user-invocable: true
metadata:
  openclaw:
    emoji: "🔧"
---

# Admin Dashboard

Query system-wide admin data: activity logs, agent status, user balances, and API costs.

## 1. Recent Activity

Get recent system activity logs (messages, API calls, errors).

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/admin/logs?limit=50" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Optional params: `limit` (1-200, default 50), `type`, `tenant_id`, `session_id`

Response:
```json
{
  "success": true,
  "data": [
    {
      "id": 12345,
      "tenant_id": "cobroker-openclaw",
      "session_id": "abc123",
      "type": "assistant",
      "message": "Searching for properties...",
      "external_api": "anthropic",
      "cost_total": 0.0032,
      "entry_timestamp": "2026-03-10T14:30:00Z"
    }
  ],
  "count": 50
}
```

## 2. Agent Status

Get all registered OpenClaw agents and their status.

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/admin/agents" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "success": true,
  "data": [
    {
      "id": 1,
      "user_id": "uuid-here",
      "fly_app_name": "cobroker-openclaw",
      "fly_machine_id": "abc123",
      "bot_username": "CobrokerBot",
      "display_name": "Isaac",
      "status": "active",
      "region": "iad",
      "created_at": "2026-01-15T00:00:00Z",
      "updated_at": "2026-03-10T12:00:00Z"
    }
  ],
  "count": 2
}
```

## 3. User Balances

Get budget and spending for all users.

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/admin/balances" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "success": true,
  "totals": {
    "total_budget_usd": 150.00,
    "spent_usd": 45.67,
    "remaining_usd": 104.33,
    "percent_used": 30.4
  },
  "users": [
    {
      "user_id": "uuid-here",
      "display_name": "Isaac",
      "fly_app_name": "cobroker-openclaw",
      "bot_username": "CobrokerBot",
      "total_budget_usd": 50.00,
      "spent_usd": 16.06,
      "remaining_usd": 33.94,
      "percent_used": 32.1
    }
  ]
}
```

## 4. API Costs

Get cost breakdown by tenant over a time period.

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/admin/costs?days=30" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Optional params: `days` (1-90, default 30)

Response:
```json
{
  "success": true,
  "days": 30,
  "grand_total_usd": 67.50,
  "tenants": [
    {
      "tenant_id": "cobroker-openclaw",
      "total_calls": 1245,
      "total_cost_usd": 45.30,
      "services": [
        { "service": "Claude AI", "calls": 980, "cost_usd": 38.50 },
        { "service": "Google Places", "calls": 120, "cost_usd": 3.60 },
        { "service": "Deep Research", "calls": 15, "cost_usd": 2.10 }
      ]
    }
  ]
}
```

## Formatting Rules

Present all responses conversationally. Do NOT use markdown tables (Telegram doesn't render them). Use numbered lists and emoji indicators.

### Activity Logs
```
📋 Recent Activity (last 50 entries)

1. 14:30 — cobroker-openclaw — "Searching for properties..." (Claude AI, $0.003)
2. 14:28 — cobroker-openclaw — "User asked about Denver" (Claude AI, $0.002)
3. 14:25 — cobroker-tenant-022 — "Running demographics query" (ESRI, $0.08)
...
```

- Show timestamp (HH:MM), tenant, message snippet, and cost
- Most recent first
- Truncate long messages to ~50 chars

### Agent Status
```
🤖 Agents (2 active)

1. Isaac — @CobrokerBot — cobroker-openclaw (iad) — ✅ active
2. Demo User — @DemoBot — cobroker-tenant-022 (iad) — ✅ active
```

- Use ✅ for active, ⚠️ for degraded, ❌ for inactive/error
- Show display name, bot username, fly app, region, status

### User Balances
```
💰 Budget Overview

Total: $150.00 budget — $45.67 spent (30.4%) — $104.33 remaining

Per user:
1. Isaac (cobroker-openclaw) — $50.00 budget — $16.06 spent (32.1%) — $33.94 left
2. Demo User (cobroker-tenant-022) — $100.00 budget — $29.61 spent (29.6%) — $70.39 left
```

- Show dollar amounts with 2 decimal places
- Include percent used
- Sort by spending descending

### API Costs
```
📊 API Costs (last 30 days) — Total: $67.50

cobroker-openclaw — $45.30 (1,245 calls)
1. Claude AI — 980 calls — $38.50
2. Google Places — 120 calls — $3.60
3. Deep Research — 15 calls — $2.10

cobroker-tenant-022 — $22.20 (430 calls)
1. Claude AI — 380 calls — $18.90
2. Demographics — 50 calls — $3.30
```

- Do NOT mention the multiplier to the user
- Sort tenants by cost descending, services by cost descending
- Omit services with 0 calls

## Question-to-Endpoint Mapping

| Question | Endpoint |
|----------|----------|
| "What's the recent activity?" / "Show me logs" / "What happened today?" | logs |
| "Which agents are active?" / "Agent status" / "Who's running?" | agents |
| "What's the budget?" / "How much has everyone spent?" / "Balance check" | balances |
| "What are the API costs?" / "How much did we spend this month?" / "Cost breakdown" | costs |
| "Give me a full status report" | Call ALL four endpoints and summarize |

When asked for a "status report" or "dashboard overview", call all four endpoints and present a combined summary.
