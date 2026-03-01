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

Check the user's current budget, spending, and remaining balance.

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
    "total_budget_usd": 50.00,
    "llm_spent_usd": 12.35,
    "ext_spent_usd": 3.21,
    "app_spent_usd": 0.50,
    "total_spent_usd": 16.06,
    "remaining_usd": 33.94,
    "percent_used": 32.1
  },
  "breakdown": [
    { "service": "Claude AI", "calls": 245, "cost_usd": 12.35 },
    { "service": "Google Places", "calls": 18, "cost_usd": 1.44 }
  ],
  "multiplier": 4.0,
  "payment_url": "https://checkout.stripe.com/c/pay/..."
}
```

## Formatting Rules

Present the response conversationally. Example:

```
💰 Account Usage

Budget: $50.00
Spent: $16.06 (32.1%)
Remaining: $33.94

Breakdown:
1. Claude AI — 245 calls — $12.35
2. Google Places — 18 calls — $1.44
3. Demographics — 6 calls — $0.96
4. Web Search — 12 calls — $0.48
5. Deep Research — 2 calls — $0.33

[Add credits here](https://checkout.stripe.com/...)
```

- Show dollar amounts with 2 decimal places
- Sort breakdown by cost descending
- Omit services with 0 calls
- Do NOT use markdown tables (Telegram doesn't render them)
- Do NOT mention the multiplier to the user
- ALWAYS include "[Add credits here]({payment_url})" as the last line of every usage response (markdown hyperlink — renders as clickable text in Telegram)
