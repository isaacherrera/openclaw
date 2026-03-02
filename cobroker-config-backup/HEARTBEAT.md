# Heartbeat — Usage Threshold Alerts

You are running a periodic heartbeat check. Your job is to check the user's budget usage and alert them ONLY if a new spending threshold has been crossed since the last check.

## OUTPUT CONTRACT — MANDATORY

**You MUST follow these rules exactly. No exceptions.**

1. **For ALL non-alert cases**: Your ENTIRE response must be the single word `HEARTBEAT_OK`. Nothing else. No explanation, no narration, no status updates, no description of what you checked or found.

2. **NEVER use the `message` tool** except in Step 7 (a new threshold was crossed). If you are not in Step 7, you must NOT call the `message` tool for any reason.

3. **All internal operations are invisible.** Reading files, calling APIs, writing state — the user must never see any of this. Do not describe, summarize, or narrate any step.

4. **If in doubt, respond with `HEARTBEAT_OK` only.** Errors, missing data, edge cases — always fall back to `HEARTBEAT_OK`.

Correct non-alert response (your ENTIRE output):
```
HEARTBEAT_OK
```

Wrong (DO NOT do any of these):
```
Usage is at 30%, below the 50% threshold. Updating state file. HEARTBEAT_OK
```
```
Checked usage: 0% used. No thresholds crossed. HEARTBEAT_OK
```
```
Everything looks good, no alerts needed. HEARTBEAT_OK
```

## Instructions

### Step 1: Read state file

Read `/data/workspace/usage-alert-state.json`. If it doesn't exist, use these defaults:
```json
{"last_alerted_threshold": 0, "last_percent_used": 0, "updated_at": null}
```

### Step 2: Check usage via API

Run this curl command:
```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/usage" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

If the command fails, any env var is missing, or the response doesn't contain `"success": true`, respond with `HEARTBEAT_OK` and stop. No other text.

Extract `percent_used` from `usage.percent_used` and `payment_url` from the response.

### Step 3: Detect budget reset

If `percent_used` is more than 5 points BELOW the `last_percent_used` from the state file, the user has topped up their budget. Reset the state:
```json
{"last_alerted_threshold": 0, "last_percent_used": <current percent_used>, "updated_at": "<now ISO>"}
```
Write this to `/data/workspace/usage-alert-state.json`. Respond with `HEARTBEAT_OK` only — no other text.

### Step 4: Check thresholds

The thresholds are: 50, 75, 90, 95

Find the highest threshold that `percent_used` is greater than or equal to. If none apply (usage below 50%), update the state file with the current `percent_used` and respond with `HEARTBEAT_OK` only — no other text.

### Step 5: Compare with last alert

If the highest applicable threshold is LESS THAN OR EQUAL TO `last_alerted_threshold` from the state file, the user was already alerted for this level. Update `last_percent_used` in the state file and respond with `HEARTBEAT_OK` only — no other text.

### Step 6: Find the delivery target

Before sending the alert, find the user's Telegram chat ID:
```bash
grep -o '"from":"telegram:[0-9]*"' /data/agents/main/sessions/sessions.json | head -1 | grep -o '[0-9]*'
```
If no chat ID is found, respond with `HEARTBEAT_OK` only and stop.

### Step 7: Send alert

The highest threshold is NEW (higher than the last alert). Use the `message` tool with `action: send`, `channel: telegram`, and `target: <chatId>` (the numeric ID from Step 6). Include the actual dollar amounts from the API response.

Alert tone by threshold (include `payment_url` from the API response):

- **50%**: Heads up — you've used about half your budget ($X.XX of $Y.YY). You're on track, just keeping you in the loop. Need more credits? [Add credits here]({payment_url})
- **75%**: Hey, you've used about 75% of your budget ($X.XX of $Y.YY spent). You might want to pace your usage for the rest of the cycle. [Add credits here]({payment_url})
- **90%**: Important — you've used 90% of your budget ($X.XX of $Y.YY). Usage will be blocked when your credits run out. [Add credits here]({payment_url})
- **95%**: You're almost out of credits — $X.XX of $Y.YY used. [Add credits here]({payment_url}) to avoid interruption

After sending the alert successfully, update the state file:
```json
{"last_alerted_threshold": <threshold>, "last_percent_used": <percent_used>, "updated_at": "<now ISO>"}
```

Write the updated state to `/data/workspace/usage-alert-state.json`.

## Rules

- NEVER send markdown tables — Telegram doesn't render them
- Dollar amounts to 2 decimal places
- If anything fails (missing env vars, API error, curl timeout), always fall back to `HEARTBEAT_OK` with no other text
- Keep alert messages short and conversational
- Do not mention technical details like "heartbeat", "threshold", or "state file" to the user
- The `message` tool is ONLY for Step 7 alerts. Never use it for status updates or non-alert cases.
