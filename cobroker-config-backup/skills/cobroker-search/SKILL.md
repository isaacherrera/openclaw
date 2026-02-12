---
name: cobroker-search
description: >
  Search for commercial real estate properties using Quick Search (Gemini 3 Pro with Google grounding, ~10-60s)
  or Deep Search (FindAll AI, 2-5min). Found properties are added to an existing
  Cobroker project. Use when the user wants to find, discover, or locate commercial
  real estate properties, sites, locations, or businesses for site selection.
user-invocable: true
metadata:
  openclaw:
    emoji: "🔍"
---

# Cobroker Property Search

**⚠️ MESSAGE DELIVERY RULE — MANDATORY**
When you call ANY tool, your text output MUST be exactly `___` (three underscores) and nothing else.
The gateway filters `___` automatically — any other text gets delivered as a duplicate message.
ALL user-facing communication goes through `message` tool calls. NEVER narrate alongside tool calls.

Search for commercial real estate properties and add them to a Cobroker project. Two search paths available: Quick Search (Gemini 3 Pro with Google grounding) and Deep Search (FindAll AI research engine).

**⚠️ PROJECT LINKS — MANDATORY**: NEVER share a project URL as plain text. ALWAYS use an inline keyboard URL button:
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

## 0. Clarify Requirements (Before Search)

Before presenting search options, evaluate whether the user's request has enough detail for an effective search. A good search needs at minimum: **what** (property type or use case) and **where** (specific city/area).

### When to Ask

Ask 1-2 clarifying questions when ANY of these are missing or vague:

- **What**: No property type or business use mentioned (e.g. "find me properties")
- **Where**: No specific location — just a state or region (e.g. "somewhere in Texas")
- **Both**: Completely open-ended (e.g. "help me find a new location")

### When to Skip (proceed directly to Section 1)

Skip clarification when the request already has clear what + where:

- "Find 10 warehouses in Dallas" → clear
- "Locate retail spaces in downtown Austin for a coffee shop" → clear
- "Find industrial space over 50k SF near I-35 in San Antonio" → clear
- Running as a step in a cobroker-plan workflow → skip (plan already clarified)

### How to Ask

Ask ONE question at a time via plain text. Keep it conversational and brief. Pick the most important missing piece first.

**Good clarifying questions (pick 1-2 that apply):**

- **Property type/use**: "What type of property are you looking for? (e.g. warehouse, retail, office, industrial, land)"
- **Location**: "Which city or area should I search in?"
- **Size range** (if it would meaningfully narrow results): "Any size requirements? (e.g. 5,000-10,000 SF)"
- **Use case** (if property type is unclear): "What will this space be used for? That'll help me find the right type."

**Do NOT ask about:**
- Budget (not reliably available in listings)
- Zoning (too specific for initial search — better as enrichment later)
- More than 2 questions total — keep it moving

### Example Flows

**Vague request:**
> User: "Find me some properties"
> Agent: "What type of property are you looking for? (e.g. warehouse, retail, office, industrial)"
> User: "Warehouse"
> Agent: "Which city or area should I search in?"
> User: "Houston"
> Agent: [proceeds to Section 1 — Search Mode Selection with "warehouses in Houston"]

**Partially vague:**
> User: "Find me retail spaces"
> Agent: "Which city or area should I search in?"
> User: "Austin, near the Domain"
> Agent: [proceeds to Section 1 with "retail spaces near the Domain in Austin"]

**Clear request (no questions):**
> User: "Find 10 warehouses in Dallas"
> Agent: [proceeds directly to Section 1]

## 1. Search Mode Selection

After confirming requirements (Section 0), send a **single** message tool call with BOTH the text AND the `buttons` parameter together:

```
message tool call:
  action: send
  message: "🔍 Cobroker can search for **[what user asked for]** using:\n\n⚡ **Quick Search** — Google-powered, ~10-60 seconds, up to 50 results\n🔬 **Deep Search** — AI research engine, 2-5 minutes, sourced evidence\n❌ **Cancel** — Never mind\n\nWhich would you like?"
  buttons: [[{"text": "⚡ Quick Search", "callback_data": "search_quick"}, {"text": "🔬 Deep Search", "callback_data": "search_deep"}], [{"text": "❌ Cancel", "callback_data": "search_cancel"}]]
```

**IMPORTANT:** The `buttons` parameter MUST be included in the SAME tool call as the message text. Do NOT send the message and buttons as separate calls.

Callback handling:
- `search_quick` / text "quick" / "fast" → Execute Quick Search (Section 3)
- `search_deep` / text "deep" / "detailed" / "thorough" → Execute Deep Search (Section 4)
- `search_cancel` / text "cancel" / "nevermind" → Cancel and reply "Search cancelled."

Skip the choice (auto-select) only when:
- User explicitly says "quick search" or "gemini search" → Quick
- User explicitly says "deep search" or "findall" or "detailed search" → Deep
- Used as a step in a cobroker-plan workflow (plan specifies which type)

## 2. When to Use Each Path (Reference)

- **Quick Search (Gemini 3 Pro):** Broad CRE property discovery, up to 50 results, ~10-60s, 0 Cobroker credits (~$0.05 API cost)
  - "Find warehouses in Dallas"
  - "Locate Starbucks drive-thrus in Phoenix"
- **Deep Search (FindAll):** Specific CRE criteria, sourced evidence, uncapped results, 2-5min, paid credits
  - "Find industrial properties over 100k SF near I-35 in Austin with rail access"
  - Complex multi-criteria property searches

## 3. Quick Search (Gemini Grounded)

User-facing messaging flow:

**Step A — Searching:** `🔍 Cobroker is searching for [what user asked for]...`

**Step B — Show results + ask to save.** Display the numbered list (format below), then ask if the user wants to create a project:

```
✅ Found X warehouses in Dallas!

1. Industrial Building
   📍 2424 N Westmoreland Rd, Dallas, TX 75220
   📐 6,257 SF · 💰 $12.00 SF/YR

2. Warehouse Space
   📍 9886 Chartwell Dr, Dallas, TX 75243
   📐 35,748 SF · 💰 Call for Price

3. Distribution Warehouse
   📍 1800-1810 Kelly Blvd, Dallas, TX 75215
   📐 52,790 SF · 💰 Contact Broker

Would you like to save these to a Cobroker project?
```

Include `buttons` in the SAME message tool call (not a separate call):
```
buttons: [[{"text": "✅ Save to Project", "callback_data": "search_save"}, {"text": "❌ No Thanks", "callback_data": "search_discard"}]]
```

Callback handling:
- `search_save` / text "yes" / "save" / "create project" → Create the project (Step C)
- `search_discard` / text "no" / "no thanks" → Reply "No problem! Let me know if you need anything else."

**Step C — After project creation:**

Send a message with an inline URL button (not a text link):
```
message: "📋 X properties saved to Dallas Warehouses!"
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

**Results list format rules — ALWAYS use this numbered list. NEVER use markdown tables (they render as broken monospace in Telegram):**
- One property per numbered item, name on first line (bold ok)
- 📍 line: `full_address` from Gemini
- 📐💰 line: size and price on one line separated by ` · ` — omit either if not available
- Omit description and source_url from the summary (they're in the project)
- Keep it scannable — no extra prose between items

### Step 1 — Grounded search via Gemini 3 Pro

Single POST to Gemini 3 Pro with `googleSearch` tool and structured output. Gemini 3 is the first model family that supports `googleSearch` + `responseJsonSchema` in the same request. A low `thinkingLevel` keeps TTFT fast.

```bash
curl -s -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-preview:generateContent?key=$GOOGLE_GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{"parts": [{"text": "<SEARCH_PROMPT>"}]}],
    "tools": [{"googleSearch": {}}],
    "generationConfig": {
      "thinkingConfig": {"thinkingLevel": "low"},
      "responseMimeType": "application/json",
      "responseJsonSchema": {
        "type": "object",
        "properties": {
          "properties": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "name": {"type": "string", "description": "Property or building name"},
                "full_address": {"type": "string", "description": "Complete formatted address: street, city, state zip (e.g. 123 Main St, Dallas, TX 75201)"},
                "city": {"type": "string", "description": "City name"},
                "state": {"type": "string", "description": "2-letter state code"},
                "zip": {"type": "string", "description": "5-digit ZIP code"},
                "property_type": {"type": "string", "description": "e.g. Warehouse, Retail, Office, Industrial"},
                "square_footage": {"type": "string", "description": "Building size (e.g. 50,000 SF)"},
                "price": {"type": "string", "description": "Asking price or lease rate"},
                "description": {"type": "string", "description": "Brief property description"},
                "source_url": {"type": "string", "description": "URL where this listing was found"}
              },
              "required": ["name", "full_address", "city", "state"]
            }
          }
        },
        "required": ["properties"]
      }
    }
  }'
```

**Important constraints:**
- Model MUST be `gemini-3-pro-preview` — only Gemini 3 supports `googleSearch` + structured output together
- Use `responseJsonSchema` (not `responseSchema`) — this is the Gemini 3 field name for standard JSON Schema
- Do NOT set `--max-time` — response time varies with query complexity (~10-60s); let OpenClaw's exec polling manage the wait
- `thinkingLevel: "low"` keeps first-token latency low (Gemini 3 Pro supports `"low"` and `"high"` only — do NOT use `thinkingBudget`)

Search prompt template:
> Find [N] real [property type] properties currently for sale or lease in [location]. Search commercial real estate listings. For each property provide the name, complete street address with city/state/zip, property type, square footage, asking price or lease rate, brief description, and the source URL. Only include real verifiable listings.

Response parsing — after the exec completes, get the output with `process log` (this is an OpenClaw tool call, NOT a shell command — you cannot pipe it). Then parse the JSON in a **separate** exec:
```bash
node -e "
  const r=JSON.parse(process.argv[1]);
  console.log(r.candidates[0].content.parts[0].text);
" '<PASTE_RAW_JSON_FROM_PROCESS_LOG>'
```
If the output is too large for a CLI argument, write it to a temp file first, then:
```bash
node -e "
  const r=JSON.parse(require('fs').readFileSync('/tmp/gemini.json','utf8'));
  console.log(r.candidates[0].content.parts[0].text);
"
```
**IMPORTANT:** `process` is an OpenClaw tool, not a shell command. Never use `process log ... | node` in an exec — it will fail with "Permission denied".
- `candidates[0].content.parts[0].text` → guaranteed valid JSON (structured output enforces schema)
- Parse to get `{ properties: [...] }`
- Each property has `full_address` ready to use directly as the Cobroker address — no manual concatenation needed
- Source URLs also available at: `candidates[0].groundingMetadata.groundingChunks[].web.uri`

### Step 2 — Add to project

POST extracted properties to existing cobroker-projects endpoint.

For each property in the JSON response, format the address as `"address, city, state zip"` (3+ comma-separated parts required by Cobroker):

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/properties" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "properties": [
      {
        "address": "123 Main St, Dallas, TX 75201",
        "fields": {
          "Property Name": "Example Building",
          "Property Type": "Warehouse",
          "Square Footage": "50,000 SF",
          "Price": "$25 PSF",
          "Description": "Class A warehouse near I-35",
          "Source URL": "https://loopnet.com/listing/..."
        }
      }
    ]
  }'
```

- Vercel handles: column auto-creation, geocoding, custom_fields mapping
- Address format: use Gemini's `full_address` directly (already formatted as "street, city, state zip")
- Skip properties where Gemini returned no address (don't fabricate)

## 4. Deep Search (FindAll)

User-facing messaging at each stage:
- `🔬 Cobroker is starting a deep search for [what user asked for]...`
- `⏳ Deep search is running... Found X candidates so far.` (during polling)
- `✅ Deep search complete! Found X matching properties. Adding to project...`
- `📋 X properties added to [project name]!` with `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]`

For long-running searches (>2min), update the user every 30-60s with the candidate count from polling metrics.

### Step 1 — Ingest: Convert plan to structured spec

```bash
curl -s -X POST "https://api.parallel.ai/v1beta/findall/ingest" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -H "parallel-beta: findall-2025-09-15" \
  -d '{"objective": "<PLAN_MARKDOWN + data requirements appendix>"}'
```

- Append to plan: "For EACH result, MUST extract: full_address (complete street address with city, state, ZIP) and property_specifications (all available specs)."
- Response: `{ objective, entity_type, match_conditions: [{ name, description }] }`

### Step 2 — Create run: Start the search

```bash
curl -s -X POST "https://api.parallel.ai/v1beta/findall/runs" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -H "parallel-beta: findall-2025-09-15" \
  -d '{
    "objective": "<from ingest>",
    "entity_type": "<from ingest>",
    "match_conditions": <from ingest>,
    "match_limit": <N>,
    "generator": "base"
  }'
```

- Generator: always `base` (2-5min)
- `match_limit`: **required**, min 5 / max 1000 — use the number of results the user asked for (minimum 5 even if they asked for fewer). If unspecified, default to **10** (deep search charges per match, so keep it tight)
- All fields (`objective`, `entity_type`, `match_conditions`, `match_limit`, `generator`) go at the top level of the request body — do NOT wrap them in a nested object
- Response: `{ findall_id: "..." }`

### Step 3 — Poll status

Poll the run status in a loop. **IMPORTANT polling rules:**
- Run each poll as a **separate** curl exec — do NOT use `sleep X && curl` in one command (it blocks the process and wastes polling cycles)
- Wait ~30 seconds between polls by issuing polls at a natural pace
- **Max 8 poll attempts** — if still running after 8 polls (~4 min), stop and tell the user
- Update the user every 2-3 polls with the candidate count

```bash
curl -s "https://api.parallel.ai/v1beta/findall/runs/{findall_id}" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -H "parallel-beta: findall-2025-09-15"
```

Parse with node:
```bash
curl -s ... | node -e "
  const d=require('fs').readFileSync('/dev/stdin','utf8');
  const r=JSON.parse(d);
  const s=r.status;
  console.log(JSON.stringify({status:s.status, generated:s.metrics?.generated_candidates_count, matched:s.metrics?.matched_candidates_count}));
"
```

- `status` = `running | completed | failed | cancelled`
- When `status === "completed"`: go to Step 4
- When `status === "failed"` or `"cancelled"`: tell user and offer Quick Search fallback

### Step 4 — Get results: After completion

```bash
curl -s "https://api.parallel.ai/v1beta/findall/runs/{findall_id}/result" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -H "parallel-beta: findall-2025-09-15"
```

- Response: `{ candidates: [{ name, url, description, match_status, output: { field: { value, is_matched } }, basis: [...] }] }`
- Filter: only `match_status === "matched"`
- Extract address from `output.full_address.value`
- Extract specs from `output.property_specifications.value`

**If 0 matched results:** Automatically fall back to Quick Search. Tell the user:
> "Deep search didn't find matching results. Let me try a Quick Search instead..."
Then run Quick Search (Section 3) with the same query. Do NOT ask the user to choose again.

### Step 5 — Add to project: Same as Quick Search Step 2

- Format each candidate as `{ address, fields: { "Property Name": name, "Description": description, "Source URL": url, ... } }`
- POST to cobroker-projects add-properties endpoint

## 5. Project Handling (Integration with cobroker-projects)

**Always show results first, then ask to save.** Do NOT create a project until the user confirms.

**If user confirms save (`search_save`):**
1. If user mentioned an existing project → use GET /projects to find it, then POST properties to it
2. Otherwise → create a new project WITH the search results in a single POST /projects call — **always include `"public": true`** so the publicUrl works for Telegram users who are not logged in
3. Auto-name the project based on the search (e.g. "Dallas Warehouses", "Austin Retail Spaces")
4. Share the `publicUrl`

**If user declines (`search_discard`):**
- Reply friendly and move on. The search results are not saved.

Typical full flow (single user message like "Find me 10 warehouses in Dallas"):
1. Present Quick/Deep/Cancel buttons
2. User picks Quick → Gemini search → extract 10 properties
3. Show numbered results list + "Save to Project?" buttons
4. User taps "Save to Project" → POST /projects with `"public": true` → get publicUrl
5. Share: message "📋 10 properties saved to Dallas Warehouses!" with `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]`

**Important:** Never create a project with an empty properties array — the API requires at least 1 property. Always search first, then create the project with results.

For multi-step requests (search + demographics), cobroker-plan orchestrates and handles project creation — skip the confirmation step when running inside a plan.

## 6. Constraints & Guidelines

- **Always create projects with `"public": true`** — Telegram users are not logged in, so publicUrl only works for public projects
- Quick search: max 50 properties
- Deep search: always uses `base` generator, `match_limit` required (default 10 — charges per match)
- NEVER fabricate properties — only use real search results
- Always share the project `publicUrl` via an inline keyboard URL button — not as a text link. Use `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]` in the SAME message tool call. Never use projectUrl — Telegram users are not logged in.
- Addresses from Gemini: use `full_address` directly (already formatted as "street, city, state zip")
- FindAll candidates may not have clean addresses — extract from output fields

## 7. Cost Reference

| Path | Cost per search | Speed |
|------|----------------|-------|
| Quick (Gemini 3 Pro) | 0 Cobroker credits (~$0.05 API cost) | ~10-60 seconds |
| Deep (FindAll) | $0.03/match + 25 base credits | 2-5 minutes |
