---
name: cobroker-monitor
description: >
  Track web changes for commercial real estate searches using Parallel AI Monitor.
  Create, list, check, and delete monitors. Each monitor gets a cron job that
  automatically checks for new events and reports structured results via Telegram.
user-invocable: true
metadata:
  openclaw:
    emoji: "📡"
---

# Web Change Monitoring (Parallel AI)

Track web changes for CRE searches and deliver structured updates automatically via Telegram. Monitors run on a cadence (hourly/daily/weekly) and report only NEW events — no spam.

## 1. Create Monitor

When the user wants to track something (e.g. "Track industrial spaces in El Paso", "Monitor AI startup funding news"):

### Step 1 — Choose output schema

Pick based on the query content:

- **CRE Property Schema** — if query mentions properties, listings, spaces, buildings, land, warehouses, retail, office, industrial, lease, sale
- **General Event Schema** — everything else (news, regulatory, competitive, market trends)

Store the choice as `schema_type` ("cre_property" or "general") in monitors.json.

### Step 2 — Create the Parallel monitor

```bash
curl -s -X POST "https://api.parallel.ai/v1alpha/monitors" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -d '{
    "query": "<user query>",
    "cadence": "daily",
    "metadata": { "source": "cobroker", "created_by": "agent" },
    "output_schema": <schema from Section 6>
  }'
```

Default cadence is `daily`. Use `hourly` if user says "frequently" or "ASAP". Use `weekly` or `every_two_weeks` if user says "weekly" or "occasionally".

Response contains `monitor_id`.

### Step 3 — Create matching cron job

Use `cron add` with the template from Section 7. The cron schedule is offset 30 minutes from when Parallel typically runs, so events are ready when we poll.

### Step 4 — Update monitors.json

Read `/data/workspace/monitors.json` (create if missing). Add the new monitor entry:

```json
{
  "monitors": [{
    "monitor_id": "monitor_xxx",
    "query": "industrial spaces in El Paso under 50k SF",
    "cadence": "daily",
    "schema_type": "cre_property",
    "cron_job_id": "cron_xxx",
    "created_at": "2026-02-13T...",
    "last_seen_event_ids": [],
    "last_checked_at": null
  }]
}
```

### Step 5 — Confirm to user

Reply: "📡 Now tracking: '{query}' — I'll check {cadence} and let you know when I find something."

## 2. List Monitors

When user says "list monitors", "what am I tracking", "show monitors":

1. Read `/data/workspace/monitors.json`
2. Also fetch live status from Parallel:

```bash
curl -s -X GET "https://api.parallel.ai/v1alpha/monitors" \
  -H "x-api-key: $PARALLEL_AI_API_KEY"
```

3. Display each monitor:

```
📡 Active Monitors:

1. "industrial spaces in El Paso under 50k SF"
   ⏰ Daily · Status: active · Last run: 2h ago
   📊 3 events detected so far

2. "AI startup funding news"
   ⏰ Weekly · Status: active · Last run: 3d ago
   📊 1 event detected so far
```

If no monitors exist: "No active monitors. Tell me what you'd like to track and I'll set one up."

## 3. Check Monitor Events

Used by cron (automatically) AND manually when user says "check monitors", "any updates?".

### Step 1 — Fetch events

```bash
curl -s -X GET "https://api.parallel.ai/v1alpha/monitors/{monitor_id}/events?lookback_period=2d" \
  -H "x-api-key: $PARALLEL_AI_API_KEY"
```

### Step 2 — Filter events

1. Parse response — events array contains objects with `type`, `event_group_id`, `result`, `event_date`, `source_urls`
2. Keep only entries where `type === "event"`
3. Skip events where `event_group_id` is already in `last_seen_event_ids` from monitors.json
4. If NO new events: **output nothing** (cron runs silently — no "no updates" message)

### Step 3 — Format and report new events

Use the formatting rules from Section 8 based on `schema_type`.

Structured event data from Parallel looks like:
```json
{
  "type": "event",
  "event_group_id": "mevtgrp_xxx",
  "event_date": "2026-02-13",
  "source_urls": ["https://..."],
  "result": {
    "type": "json",
    "content": {
      "property_name": "Industrial Building on Butterfield Trail",
      "address": "8200 Butterfield Trail Blvd, El Paso, TX 79907",
      "size": "32,000 SF",
      "price": "$8.50/SF/YR NNN",
      "summary": "Class B industrial near I-10, ideal for light manufacturing"
    }
  }
}
```

### Step 4 — Update tracking state

After reporting (or if no new events), update monitors.json:
- Add new `event_group_id` values to `last_seen_event_ids`
- Set `last_checked_at` to current ISO timestamp

## 4. Update Monitor

When user wants to change a monitor's query or cadence:

```bash
curl -s -X POST "https://api.parallel.ai/v1alpha/monitors/{monitor_id}" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -d '{ "query": "<new query>", "cadence": "<new cadence>" }'
```

If cadence changed, also update the cron job schedule via `cron update` with the new expression from the cadence mapping in Section 7.

Update the corresponding entry in monitors.json.

## 5. Delete Monitor

When user says "stop tracking", "delete monitor", "remove monitor":

### Step 1 — Delete from Parallel

```bash
curl -s -X DELETE "https://api.parallel.ai/v1alpha/monitors/{monitor_id}" \
  -H "x-api-key: $PARALLEL_AI_API_KEY"
```

### Step 2 — Remove cron job

```
cron remove {cron_job_id}
```

### Step 3 — Remove from monitors.json

Remove the entry from the monitors array.

### Step 4 — Confirm

Reply: "📡 Stopped tracking: '{query}'"

## 6. Output Schemas

Use `output_schema` when creating monitors to get structured JSON events. Choose schema based on query type (see Section 1, Step 1).

**Constraints** (Parallel API limitations):
- Flat schemas only — no nested objects
- 3-5 properties max
- Only `string` and `enum` types
- Clear descriptions improve extraction quality

### CRE Property Schema

For property/listing/space tracking:

```json
{
  "type": "json",
  "json_schema": {
    "type": "object",
    "properties": {
      "property_name": {
        "type": "string",
        "description": "Name or title of the property or listing"
      },
      "address": {
        "type": "string",
        "description": "Full address: street, city, state, zip. Use 'N/A' if not available"
      },
      "size": {
        "type": "string",
        "description": "Property size in square feet (e.g. '45,000 SF'). Use 'N/A' if not available"
      },
      "price": {
        "type": "string",
        "description": "Asking price or lease rate (e.g. '$12/SF/YR' or '$2.5M'). Use 'N/A' if not available"
      },
      "summary": {
        "type": "string",
        "description": "Brief 1-2 sentence description of the property and why it matches the search criteria"
      }
    }
  }
}
```

### General Event Schema

For news, regulatory, competitive, market tracking:

```json
{
  "type": "json",
  "json_schema": {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description": "Brief headline or title of the event"
      },
      "details": {
        "type": "string",
        "description": "Key details: what happened, who is involved, relevant numbers"
      },
      "source": {
        "type": "string",
        "description": "Name of the publication or website where this was found"
      },
      "significance": {
        "type": "string",
        "description": "Why this event is relevant to the tracked query"
      }
    }
  }
}
```

## 7. Cron Job Configuration

When creating a cron job for a monitor, use this template:

```
cron add {
  name: "Monitor: {short_query_summary}",
  schedule: { kind: "cron", expr: "<expr>", tz: "UTC" },
  sessionTarget: "isolated",
  wakeMode: "now",
  payload: {
    kind: "agentTurn",
    message: "Check Parallel AI monitor {monitor_id} for new events. Query: '{query}'. Read /data/workspace/monitors.json for tracking state. Use the cobroker-monitor skill Section 3 to fetch and format events. Report only NEW events not in last_seen_event_ids. Update monitors.json after reporting. If no new events, output nothing.",
    bestEffortDeliver: true
  },
  delivery: { mode: "announce", channel: "last" }
}
```

### Cadence to cron expression mapping

Offset 30 minutes from typical Parallel run times so events are ready when we poll:

| Parallel Cadence | Cron Expression | Human-Readable |
|---|---|---|
| `hourly` | `30 * * * *` | 30 min past each hour |
| `daily` | `30 12 * * *` | 7:30am ET daily |
| `weekly` | `30 12 * * 1` | Monday 7:30am ET |
| `every_two_weeks` | `30 12 1,15 * *` | 1st & 15th of month, 7:30am ET |

## 8. Event Formatting for Telegram

**NEVER use markdown tables** — they render as broken monospace in Telegram. Use numbered lists.

### CRE Property events

```
📡 Monitor Update: "industrial spaces in El Paso under 50k SF"

🆕 2 new listings detected:

1. Industrial Building on Butterfield Trail
   📍 8200 Butterfield Trail Blvd, El Paso, TX 79907
   📐 32,000 SF · 💰 $8.50/SF/YR
   Class B industrial near I-10

2. Warehouse on Rojas Dr
   📍 1420 Rojas Dr, El Paso, TX 79936
   📐 18,500 SF · 💰 $425,000
   Freestanding warehouse with dock-high loading

🔗 Sources: [source_urls as clickable links]
```

Format rules:
- Property name on first line (bold ok)
- 📍 line: address
- 📐💰 line: size and price separated by ` · ` — omit either if "N/A"
- Summary on last line (from `summary` field)
- Source URLs at the bottom as clickable links

### General events

```
📡 Monitor Update: "AI startup funding news"

🆕 1 new event detected:

1. Anthropic Raises $3B Series D
   Anthropic secured $3B in new funding led by Lightspeed Venture Partners
   Source: TechCrunch
   → Significant because: largest AI funding round of 2026

🔗 https://techcrunch.com/...
```

Format rules:
- Title on first line (bold ok)
- Details on second line
- Source name on third line
- Significance prefixed with → on fourth line
- Source URLs at the bottom

## 9. Error Handling

- **Parallel API errors**: If any API call returns an error, tell the user what happened and suggest retrying. Do NOT silently fail.
- **Missing env var**: If `$PARALLEL_AI_API_KEY` is not set, tell the user: "The Parallel AI API key isn't configured. Please set the PARALLEL_AI_API_KEY secret on Fly."
- **monitors.json missing or corrupt**: Create a fresh `{ "monitors": [] }` file.
- **Cron errors**: If cron add/remove fails, still complete the Parallel API operation and note the cron issue to the user.
