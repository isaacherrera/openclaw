---
name: cobroker-search
description: >
  Search for commercial real estate properties using FindAll AI (~3-7min).
  Found properties are added to an existing Cobroker project. Use when the user
  wants to find, discover, or locate commercial real estate properties, sites,
  locations, or businesses for site selection.
user-invocable: true
metadata:
  openclaw:
    emoji: "🔍"
---

# Cobroker Property Search

## CRITICAL: Search = Available Space, NOT Existing Locations

This skill finds **available commercial real estate** — properties for sale or lease, vacant land, development sites, available deals.

**DO NOT use this skill to find existing businesses, chains, or stores** (e.g. "Find all Starbucks in Dallas", "Where are Topgolf locations?"). For those, use **cobroker-projects Places Search (Sections 13-15)** which uses Google Places API.

If the user's intent is ambiguous, ask: "Are you looking for available space for sale or lease, or are you trying to locate existing business locations?"

Search for commercial real estate properties using FindAll AI and add them to a Cobroker project.

**⚠️ PROJECT LINKS — MANDATORY**: NEVER share a project URL as plain text. ALWAYS use an inline keyboard URL button:
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

## 0. Clarify Requirements (Before Search)

Before searching, evaluate whether the user's request has enough detail for an effective search. A good search needs at minimum: **what** (property type or use case) and **where** (specific city/area).

### When to Ask

Ask 1-2 clarifying questions when ANY of these are missing or vague:

- **What**: No property type or business use mentioned (e.g. "find me properties")
- **Where**: No specific location — just a state or region (e.g. "somewhere in Texas")
- **Both**: Completely open-ended (e.g. "help me find a new location")
- **Existing vs available**: User wants to "find" something but unclear if they mean existing locations (chains, businesses) or available space (for sale/lease)

### When to Skip (proceed directly to Section 1)

Skip clarification when the request already has clear what + where:

- "Find 10 warehouses in Dallas" → clear
- "Locate retail spaces in downtown Austin for a coffee shop" → clear
- "Find industrial space over 50k SF near I-35 in San Antonio" → clear
- Running as a step in a cobroker-plan workflow → skip (plan already clarified)
- User explicitly mentions listings, lease, sale, available, vacant → proceed directly
- User mentions a chain/brand by name without "for lease"/"for sale" → redirect to cobroker-projects Places Search, do NOT use this skill

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
> Agent: [proceeds to Section 1 with "warehouses in Houston"]

**Partially vague:**
> User: "Find me retail spaces"
> Agent: "Which city or area should I search in?"
> User: "Austin, near the Domain"
> Agent: [proceeds to Section 1 with "retail spaces near the Domain in Austin"]

**Clear request (no questions):**
> User: "Find 10 warehouses in Dallas"
> Agent: [proceeds directly to Section 1]

## 1. Property Search (FindAll)

After confirming requirements (Section 0), proceed directly to the FindAll search. No mode selection is needed — FindAll is the only search method.

When running as a step in a cobroker-plan workflow, skip clarification (the plan already specified the search criteria).

User-facing messaging (maximum 2 messages):
- `🔍 Cobroker is searching for [what user asked for]... This usually takes 3-7 minutes.`
- Then poll SILENTLY (output `NO_REPLY`). Only message again when complete:
- `✅ Search complete! Found X matching properties.` + save/discard buttons

Do NOT send interim candidate count updates. Poll silently.

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
    "generator": "core"
  }'
```

- Generator: always `core` — better match quality for CRE property searches (~3-7min)
- `match_limit`: **required**, min 5 / max 1000 — use the number of results the user asked for (minimum 5 even if they asked for fewer). If unspecified, default to **10**
- All fields (`objective`, `entity_type`, `match_conditions`, `match_limit`, `generator`) go at the top level of the request body — do NOT wrap them in a nested object
- Response: `{ findall_id: "..." }`

### Step 3 — Poll status

Poll the run status in a loop. **IMPORTANT polling rules:**
- Run each poll as a **separate** curl exec — do NOT use `sleep X && curl` in one command
- Wait ~30 seconds between polls by issuing polls at a natural pace
- Poll SILENTLY — output `NO_REPLY` with each poll. Do NOT message the user with interim candidate counts.
- **Max 20 poll attempts** (~10 min total)
- **Partial results fallback:** After poll 20, if the run is still `running` but `matched_candidates_count > 0`, call the `/result` endpoint anyway to try fetching partial results. If it returns candidates, deliver them. If it errors or returns 0 matched, inform the user and suggest refining their search criteria.
- If `matched_candidates_count === 0` after 20 polls, inform the user that no matching properties were found and suggest refining the search criteria.

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
- When `status === "failed"` or `"cancelled"`: inform user and suggest refining search criteria

**Timeout with partial results:** After 20 polls, if the run is still `running` but `matched_candidates_count > 0` in the metrics, call the `/result` endpoint anyway to fetch partial results:

```bash
curl -s "https://api.parallel.ai/v1beta/findall/runs/{findall_id}/result" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -H "parallel-beta: findall-2025-09-15"
```

- If it returns candidates with `match_status === "matched"`, deliver them with:
  > "⏱️ Search is still running, but here are X results found so far."
  Then proceed to save/discard flow as normal.
- If it errors or returns 0 matched, inform the user no results were found and suggest refining criteria.

**Timeout with no matches:** After 20 polls with `matched_candidates_count === 0`, stop and inform the user:
> "The search didn't find matching results for those criteria. Try broadening your search — for example, a larger area, different property type, or fewer constraints."

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

**If 0 matched results:** Inform the user and suggest refining criteria:
> "The search completed but didn't find properties matching all your criteria. Try broadening your search — for example, a larger area, different property type, or fewer constraints."

### Step 5 — Add to project: Save results

For each candidate, format as `{ address, fields: { "Property Name": name, "Description": description, "Source URL": url, ... } }` and POST to cobroker-projects add-properties endpoint.

## 2. Project Handling (Integration with cobroker-projects)

**Always show results first, then ask to save.** Do NOT create a project until the user confirms.

**If user confirms save (`search_save`):**
1. If user mentioned an existing project → use GET /projects to find it, then POST properties to it
2. Otherwise → create a new project WITH the search results in a single POST /projects call — **always include `"public": true`** so the publicUrl works for Telegram users who are not logged in
3. Auto-name the project based on the search (e.g. "Dallas Warehouses", "Austin Retail Spaces")
4. Share the `publicUrl`

**If user declines (`search_discard`):**
- Reply friendly and move on. The search results are not saved.

Typical full flow (single user message like "Find me 10 warehouses in Dallas"):
1. FindAll search → ingest → run → poll → results → extract 10 properties
2. Show numbered results list + "Save to Project?" buttons
3. User taps "Save to Project" → POST /projects with `"public": true` → get publicUrl
4. Share: message "📋 10 properties saved to Dallas Warehouses!" with `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]`

**Important:** Never create a project with an empty properties array — the API requires at least 1 property. Always search first, then create the project with results.

For multi-step requests (search + demographics), cobroker-plan orchestrates and handles project creation — skip the confirmation step when running inside a plan.

## 3. Constraints & Guidelines

- **Always create projects with `"public": true`** — Telegram users are not logged in, so publicUrl only works for public projects
- FindAll: always uses `core` generator, `match_limit` required (default 10)
- NEVER fabricate properties — only use real search results
- Always share the project `publicUrl` via an inline keyboard URL button — not as a text link. Use `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]` in the SAME message tool call. Never use projectUrl — Telegram users are not logged in.
- FindAll candidates may not have clean addresses — extract from output fields
