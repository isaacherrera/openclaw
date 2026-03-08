---
name: integrations
description: Use when the user wants to connect, disconnect, or check the status of third-party services (Gmail, Dropbox, Google Calendar, Slack, etc.) via Composio OAuth. NEVER tell users to visit composio.dev — always generate OAuth links through the CoBroker API.
metadata: { "openclaw": { "emoji": "🔌" } }
---

# Integrations — Connect & Manage Services

## Overview

You can connect 13 third-party services on behalf of the user via Composio OAuth.
All API calls use env vars already available on this VM — no extra secrets needed.

**CRITICAL: NEVER tell users to go to composio.dev or any external dashboard.
Always use the CoBroker API to generate OAuth links.**

## Auth Headers (every request)

```
X-Agent-User-Id: $COBROKER_AGENT_USER_ID
X-Agent-Secret: $COBROKER_AGENT_SECRET
```

## Supported Services

| Slug | Name | Description |
|---|---|---|
| `gmail` | Gmail | Read and send emails |
| `googlecalendar` | Google Calendar | Manage calendar events |
| `dropbox` | Dropbox | Access files and folders |
| `googledrive` | Google Drive | Store and share files |
| `googlesheets` | Google Sheets | Create and edit spreadsheets |
| `outlook` | Outlook | Email and calendar via Microsoft |
| `slack` | Slack | Team messaging and channels |
| `hubspot` | HubSpot | CRM and marketing automation |
| `salesforce` | Salesforce | CRM and sales management |
| `stripe` | Stripe | Payments and billing |
| `facebook` | Facebook | Social media and pages |
| `google_analytics` | Google Analytics | Website traffic and analytics |
| `square` | Square | Point of sale and payments |

## Step 1 — Check Connection Status

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/connections" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "connections": [
    {
      "toolkit": "gmail",
      "name": "Gmail",
      "description": "Read and send emails",
      "status": "ACTIVE",
      "connectedAccountId": "abc123",
      "connectedAt": "2025-01-15T..."
    },
    {
      "toolkit": "dropbox",
      "name": "Dropbox",
      "description": "Access files and folders",
      "status": "disconnected",
      "connectedAccountId": null,
      "connectedAt": null
    }
  ],
  "serviceAvailable": true
}
```

- `status: "ACTIVE"` → connected and ready to use
- `status: "disconnected"` → needs OAuth connection

## Step 2 — Generate OAuth Link

For each service that needs connecting, get the bot username and generate a callback URL:

```bash
# Get bot username for the callback URL
BOT_USERNAME=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe" | jq -r '.result.username')

# Generate OAuth link with Telegram callback
curl -s -X POST "$COBROKER_BASE_URL/api/agent/connections/{toolkit}/connect" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d "{\"callbackUrl\": \"$COBROKER_BASE_URL/telegram/connect-callback?toolkit={toolkit}&tg_bot=$BOT_USERNAME\"}"
```

Replace `{toolkit}` with the slug from the table above (e.g. `gmail`, `dropbox`).

Response:
```json
{
  "redirectUrl": "https://accounts.google.com/o/oauth2/...",
  "connectedAccountId": "abc123"
}
```

## Step 3 — Send OAuth Link to User

Send the `redirectUrl` value to the user as a tappable link. Example message:

> To connect Dropbox, please tap this link to authorize access:
> [Connect Dropbox](https://accounts.google.com/o/oauth2/...)
>
> After authorizing, you'll be redirected back automatically.

## Step 4 — Verify Connection

After the user says they've authorized (or after a short wait), re-check status:

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/connections" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

If the service now shows `status: "ACTIVE"`, confirm to the user and proceed with their original task.

## Disconnecting a Service

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/connections/{toolkit}/disconnect" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Replace `{toolkit}` with the slug from the table above.

Response (success):
```json
{ "success": true }
```

If the service is not connected, the API returns 404. Tell the user it was already disconnected.

## Common Scenarios

### User asks to use a disconnected service
1. Check connections (Step 1)
2. If the needed service is disconnected, generate an OAuth link (Step 2)
3. Send the link to the user (Step 3)
4. Wait for confirmation, then verify (Step 4)
5. Proceed with the original task

### User asks "what services are connected?"
1. Check connections (Step 1)
2. List all services with their status (ACTIVE vs disconnected)

### User asks to disconnect a service
1. Call the disconnect endpoint with the toolkit slug
2. Confirm to the user that the service has been disconnected

### User asks to "connect Gmail" (or any specific service)
1. Generate the OAuth link directly (Step 2) — no need to check status first
2. Send the link (Step 3)
3. Verify after authorization (Step 4)

## Rules

- **NEVER** tell users to visit composio.dev, any dashboard, or any manual setup page
- **NEVER** fabricate OAuth URLs — always use the API to generate them
- **ALWAYS** use the auth headers on every API request
- If the API returns an error, tell the user there was a problem and suggest trying again
- If `serviceAvailable` is `false` in the connections response, tell the user the integration service is temporarily unavailable
