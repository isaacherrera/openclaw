---
name: cobroker-usage
description: >
  Check account usage, budget, and spending. Use when the user asks about
  their balance, credits, costs, spending, budget, remaining funds, or
  how much they've used.
user-invocable: true
metadata:
  openclaw:
    emoji: "💰"
---

# Account Usage

Check the user's current subscription, spending, and remaining balance.

## Get Usage

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/usage" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "success": true,
  "usage": {
    "total_budget_usd": 200.00,
    "llm_spent_usd": 12.35,
    "ext_spent_usd": 3.21,
    "app_spent_usd": 0.50,
    "total_spent_usd": 16.06,
    "remaining_usd": 183.94,
    "percent_used": 8.0
  },
  "subscription": {
    "status": "active",
    "plan": "Pro ($200/mo)",
    "current_period_start": "2026-03-01T00:00:00Z",
    "next_reset_date": "2026-04-01T00:00:00Z"
  },
  "breakdown": [
    { "service": "Claude AI", "calls": 245, "cost_usd": 12.35 },
    { "service": "Google Places", "calls": 18, "cost_usd": 1.44 }
  ],
  "subscribe_url": "https://app.cobroker.ai/subscribe"
}
```

## Formatting Rules

Present the response conversationally. Example:

```
💰 Account Usage

Plan: Pro ($200/mo)
Spent this period: $16.06 (8.0%)
Remaining: $183.94
Resets: April 1, 2026

Breakdown:
1. Claude AI — 245 calls — $12.35
2. Google Places — 18 calls — $1.44
3. Demographics — 6 calls — $0.96
4. Web Search — 12 calls — $0.48
5. Deep Research — 2 calls — $0.33

[Manage subscription](https://app.cobroker.ai/subscribe)
```

- Show dollar amounts with 2 decimal places
- Sort breakdown by cost descending
- Omit services with 0 calls
- Do NOT use markdown tables (Telegram doesn't render them)
- ALWAYS include "[Manage subscription]({subscribe_url})" as the last line of every usage response (markdown hyperlink — renders as clickable text in Telegram)
- Format `next_reset_date` as a human-readable date (e.g. "April 1, 2026")
- If `subscription.status` is not "active", warn: "⚠️ Your subscription is {status}. Resubscribe to continue using your agent."
- If `percent_used` >= 90, warn: "⚠️ You're approaching your monthly usage cap. Usage will pause when the cap is reached and resume on your next billing cycle."
