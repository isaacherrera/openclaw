# Heartbeat — Usage Threshold Alerts

You are running a periodic heartbeat check. Your job is to check the user's budget usage and alert them ONLY if a new spending threshold has been crossed since the last check.

## OUTPUT CONTRACT — MANDATORY

**You MUST follow these rules exactly. No exceptions.**

1. **SILENT TOOL CALLS**: When you call any tool (read, write, exec), your response must contain ONLY the tool call(s). **Do NOT include any text alongside tool calls.** No status text, no narration, no explanation — just the raw tool call.

2. **ONLY allowed text output**: The ONLY text you may ever produce is the single word `HEARTBEAT_OK` as your final response — or an alert message in Step 7. No other text output is permitted at any point.

3. **NEVER use the `message` tool** except in Step 7 (a new threshold was crossed). If you are not in Step 7, you must NOT call the `message` tool for any reason.

4. **If in doubt, respond with `HEARTBEAT_OK` only.**

**CORRECT** — tool call with no text:
```
[tool call: write(...)]
```
Then final response:
```
HEARTBEAT_OK
```

**WRONG** — text alongside tool call (NEVER DO THIS):
```
Usage is 10.3%, below 50%. Updating state file.
[tool call: write(...)]
```

## Instructions

### Step 1: Read state + check usage

Call both of these in parallel with NO text:
- Read `/data/workspace/usage-alert-state.json` (if missing, assume `{"last_alerted_threshold": 0, "last_percent_used": 0, "updated_at": null}`)
- Run: `curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/usage" -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"`

If curl fails or response lacks `"success": true` → respond `HEARTBEAT_OK` (no other text).

Extract `percent_used` from `usage.percent_used` and `payment_url`.

### Step 2: Detect budget reset

If `percent_used` is more than 5 points BELOW `last_percent_used` from state, the user topped up. Write reset state to `/data/workspace/usage-alert-state.json`:
```json
{"last_alerted_threshold": 0, "last_percent_used": <current>, "updated_at": "<now ISO>"}
```
Then respond `HEARTBEAT_OK`. No other text.

### Step 3: Determine if alert is needed

Find the highest threshold (50, 75, 90, 95) that `percent_used` ≥. If none apply (below 50%) → respond `HEARTBEAT_OK`. No other text. Do NOT write to the state file.

If the highest threshold ≤ `last_alerted_threshold` from state → respond `HEARTBEAT_OK`. No other text. Do NOT write to the state file.

### Step 4: Find delivery target

A new threshold was crossed. Find the chat ID:
```bash
grep -o '"from":"telegram:[0-9]*"' /data/agents/main/sessions/sessions.json | head -1 | grep -o '[0-9]*'
```
If no chat ID found → respond `HEARTBEAT_OK`. No other text.

### Step 5: Send alert + update state

Use the `message` tool with `action: send`, `channel: telegram`, `target: <chatId>`. Include actual dollar amounts from the API.

Alert tone (include `payment_url`):
- **50%**: Heads up — you've used about half your budget ($X.XX of $Y.YY). You're on track, just keeping you in the loop. Need more credits? [Add credits here]({payment_url})
- **75%**: Hey, you've used about 75% of your budget ($X.XX of $Y.YY spent). You might want to pace your usage for the rest of the cycle. [Add credits here]({payment_url})
- **90%**: Important — you've used 90% of your budget ($X.XX of $Y.YY). Usage will be blocked when your credits run out. [Add credits here]({payment_url})
- **95%**: You're almost out of credits — $X.XX of $Y.YY used. [Add credits here]({payment_url}) to avoid interruption

After sending, write updated state:
```json
{"last_alerted_threshold": <threshold>, "last_percent_used": <percent_used>, "updated_at": "<now ISO>"}
```

## Rules

- NEVER output text alongside tool calls — tool-use responses must contain ONLY tool calls
- NEVER send markdown tables — Telegram doesn't render them
- Dollar amounts to 2 decimal places
- If anything fails, always fall back to `HEARTBEAT_OK` with no other text
- The `message` tool is ONLY for Step 5 alerts
- Do not mention "heartbeat", "threshold", or "state file" to the user
