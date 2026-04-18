---
name: cobroker-composio
description: >
  Call the user's connected third-party services — Gmail, Google Calendar,
  Drive, Sheets, Docs, Slides, Outlook, Slack, HubSpot, Salesforce, Stripe,
  Dropbox, Facebook, Zoom, WhatsApp, Google Maps, Google Analytics, Square,
  Monday.com — through the `cobroker_composio` MCP tool. Use whenever the user
  asks you to email, schedule, share a file, update CRM, check a spreadsheet,
  send a message, or otherwise act against an external account.
user-invocable: true
metadata:
  openclaw:
    emoji: "🔌"
---

# Cobroker Composio

The `cobroker_composio` tool is a single proxy that reaches every service the
user has OAuth'd through Composio. You never talk to Composio directly — all
requests flow through the `cobroker` MCP server, which forwards them with the
correct headers and the user's identity.

## The ONLY tool: `cobroker_composio`

Three actions, each with a discriminated shape:

```
cobroker_composio { action: "list_connections" }
cobroker_composio { action: "list_tools", toolkit?: <slug>, search?: <substring> }
cobroker_composio { action: "call_tool", tool: <tool_name>, args: { ... } }
```

No other tool name exists for third-party services. There is no `gmail_*` or
`hubspot_*` tool at the top level.

## Always-in-this-order flow

1. **`list_connections`** — see which toolkits this user has ACTIVE. Returns an
   array like `[{ toolkit: "gmail", status: "ACTIVE", id: "ca_..." }, ...]`. If
   the list is empty, tell the user to visit `/onboard` to connect services,
   and stop.
2. **`list_tools`** — once you know `gmail` is connected, fetch just its tool
   inventory: `{ action: "list_tools", toolkit: "gmail" }`. This keeps you
   discovering tool names rather than hard-coding them (Composio updates
   frequently). Filter further with `search` for fuzzy matches.
3. **`call_tool`** — execute a tool by name, passing its required args:
   `{ action: "call_tool", tool: "gmail_send_email", args: { ... } }`.

## Supported toolkits

Composio supports these slugs (use them as the `toolkit` filter):

| Slug | Service |
|---|---|
| `gmail` | Gmail |
| `googlecalendar` | Google Calendar |
| `googledrive` | Google Drive |
| `googlesheets` | Google Sheets |
| `googledocs` | Google Docs |
| `googleslides` | Google Slides |
| `google_maps` | Google Maps |
| `google_analytics` | Google Analytics |
| `outlook` | Outlook |
| `dropbox` | Dropbox |
| `slack` | Slack |
| `hubspot` | HubSpot |
| `salesforce` | Salesforce |
| `stripe` | Stripe |
| `facebook` | Facebook |
| `square` | Square |
| `monday` | Monday.com |

Tool names are UPPERCASE `<TOOLKIT>_<ACTION>` — e.g., `GMAIL_SEND_EMAIL`,
`GOOGLECALENDAR_CREATE_EVENT`, `HUBSPOT_CREATE_CONTACT`. The `toolkit` filter
on `list_tools` is case-insensitive, so `{ toolkit: "gmail" }` works. Never
hard-code tool names — discover them via `list_tools` each time (Composio
updates their tool catalog frequently).

## Handling disconnected services

If the user asks for Gmail and `list_connections` doesn't include Gmail, do NOT
call any `gmail_*` tool. Reply with something like:

> You haven't connected Gmail yet. Visit https://app.cobroker.ai/onboard to
> connect it, then ask again.

Never fabricate emails, events, or CRM records. If a `call_tool` comes back
with an auth error at runtime, treat it the same way: tell the user to
reconnect that toolkit and stop.

## Common flows

### Follow-up email to a lead
1. `list_connections` → confirm `gmail` is ACTIVE.
2. `list_tools { toolkit: "gmail", search: "send" }` → find `GMAIL_SEND_EMAIL`.
3. Draft the subject + body in your response, show it to the user, ask for
   confirmation.
4. After user says "send it": `call_tool { tool: "GMAIL_SEND_EMAIL", args: {
   recipient_email: "lead@example.com", subject: "...", body: "..." } }`.

### Book a property tour
1. Confirm `googlecalendar` ACTIVE.
2. `list_tools { toolkit: "googlecalendar", search: "create" }` → find the
   event-creation tool (name may vary — discover at runtime).
3. Propose the time in chat (don't book yet). Wait for approval.
4. On approval, `call_tool { tool: "<discovered_name>", args: {...} }`.

### Add a lead to HubSpot
1. Confirm `hubspot` ACTIVE.
2. `list_tools { toolkit: "hubspot", search: "contact" }` → inspect the tools
   that come back; pick the one whose description matches "create contact".
3. Ask the user which properties of the contact to set.
4. `call_tool { tool: "<discovered_name>", args: {...} }`.
5. Confirm success with the returned contact ID.

### List today's calendar events
1. Confirm `googlecalendar` ACTIVE.
2. `list_tools { toolkit: "googlecalendar", search: "list" }` → find the list
   tool in the results.
3. `call_tool { ... args: { timeMin: <today_00:00>, timeMax: <today_23:59> } }`.
4. Summarize the events in chat; don't dump raw JSON.

## Anti-patterns (do not do these)

- **Do NOT send emails, post messages, or create calendar events without an
  explicit user confirmation** in the same turn. Draft → confirm → send.
- **Do NOT overwrite existing data** (calendar events, HubSpot deal stages,
  spreadsheet cells) without reading current state and confirming with the user.
- **Do NOT print OAuth tokens, connected-account IDs, or any Composio internal
  identifiers** back to the user. They are useless to the user and leak state.
- **Do NOT call tools for disconnected toolkits** "just to see what happens" —
  check `list_connections` first every time. Each failed call burns tokens.
- **Do NOT invent tool names**. If `list_tools` doesn't return a
  `hubspot_delete_deal` tool, it doesn't exist — tell the user.
- **Do NOT cache tool results across turns** — the user may have changed
  state in another tab. Always fetch fresh state before acting.
