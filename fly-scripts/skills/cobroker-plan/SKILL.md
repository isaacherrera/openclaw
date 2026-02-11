---
name: cobroker-plan
description: >
  Orchestrate multi-step Cobroker workflows. When the user requests two or more
  distinct operations (e.g. demographics + enrichment, create project + add properties + research),
  automatically enter plan mode: present a numbered plan, get approval, then execute
  all steps sequentially using the cobroker-projects skill endpoints.
user-invocable: true
metadata:
  openclaw:
    emoji: "📝"
---

# Cobroker Plan Mode

When a user requests **multiple distinct operations** in a single message, enter plan mode instead of executing immediately. Present a structured plan, wait for approval, then execute all steps sequentially.

## 0. Context Research (Pre-Plan)

Before building a plan, decide whether you need **factual context** you don't already know. Research is warranted when the user's request involves:

- **Brand / company lookups** — location counts, what the business does, parent company
- **Geographic facts** — how many locations in a region, which cities/states
- **Industry context** — market size, competitors, typical property types
- **Entity-specific data** — year founded, number of employees, recent news

**Skip research** when the request is purely operational ("add demographics to my project") or you're already confident in the facts.

### How to Research

Run a single curl to Gemini Flash with a focused research question:

```bash
curl -s -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GOOGLE_GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{"parts": [{"text": "YOUR RESEARCH QUESTION HERE"}]}],
    "systemInstruction": {"parts": [{"text": "You are a quick factual research assistant. Provide concise, accurate factual context. Focus on: current counts/numbers, locations, what the entity does, key facts. Keep response under 500 words. Do not speculate."}]},
    "generationConfig": {"temperature": 0.3, "maxOutputTokens": 1024}
  }'
```

Extract the answer from the JSON response at `.candidates[0].content.parts[0].text`.

### User-Facing Messaging

**Always tell the user that research is happening.** Before running the curl, send a message framed around Cobroker:

> 🔍 Cobroker is learning more about **[topic]**...

Examples:
- "🔍 Cobroker is learning more about **TopGolf's US locations**..."
- "🔍 Cobroker is learning more about **cold storage warehouse market trends**..."
- "🔍 Cobroker is learning more about **Starbucks drive-thru formats**..."

After research completes, weave the facts naturally into the plan — no need to say "Gemini said" or reference the research tool. Present the facts as Cobroker's own knowledge.

### Guidelines

- **One call is usually enough.** Frame the question to cover everything you need (e.g., "How many TopGolf locations are in the US? List all cities and states.").
- **Use the facts in your plan.** Cite specific numbers, locations, or context in the plan steps so the user can verify accuracy.
- **Graceful degradation.** If the curl fails (timeout, missing API key, error response), proceed without research — build the plan from your own knowledge and note that you couldn't verify the facts. Do NOT mention the failure to the user.
- **Don't block on research.** If the Gemini call takes more than a few seconds or errors out, move on.

## 0.5. Clarify Intent (Before Planning)

Before building a plan, evaluate whether the user's request has enough detail to create specific, actionable steps. A good plan needs: **what** they want to achieve, **where** (location/project), and enough specifics to choose the right operations.

### When to Ask

Ask 1-2 clarifying questions when:

- **Goal is vague**: "Research my properties" or "Help me analyze some locations" — unclear what operations they want
- **Missing location context**: No city, address, or existing project referenced
- **Missing property context**: They want to find properties but haven't said what type or for what purpose
- **Ambiguous scope**: Could mean many different operations — need to narrow down

### When to Skip

- Request already names specific operations: "Add population and income demographics to Dallas Warehouses"
- Request references a known project with clear actions: "Research zoning for my Austin Retail project"
- Request came from a callback (plan_edit feedback) — they already clarified earlier

### How to Ask

Same rules as cobroker-search: ONE question at a time, plain text, conversational. Pick the most impactful missing piece.

**Good clarifying questions (pick 1-2):**

- **Goal**: "What are you trying to accomplish? (e.g. find properties, analyze demographics, research zoning)"
- **Property type/use**: "What type of property or business is this for?"
- **Location**: "Which city or area are you focused on?"
- **Existing project**: "Do you want to work with an existing project, or start fresh?"

### Example Flow

> User: "Help me research locations for a new store"
> Agent: "What type of store? That'll help me pick the right search criteria and data."
> User: "A coffee shop"
> Agent: "Which city or area are you looking in?"
> User: "Austin, downtown area"
> Agent: [runs Context Research if needed, then builds plan for coffee shop site selection in downtown Austin]

## 1. When to Enter Plan Mode

**Enter plan mode** when the user's request contains **2 or more distinct operations**:

- "Add population and income demographics" → 2 ops (2 demographic calls) → **plan**
- "Research zoning and add median income" → 2 ops (enrichment + demographics) → **plan**
- "Create a project, add demographics, and research zoning" → 3 ops → **plan**
- "Add population, income, and home value demographics" → 3 ops → **plan**
- "Find warehouses and add demographics" → 2 ops (search + demographics) → **plan**
- "Search for properties near I-35 and research zoning" → 2 ops (search + enrichment) → **plan**

**Do NOT enter plan mode** for single operations (execute directly via cobroker-projects):

- "Add population demographics" → 1 op → **execute directly**
- "What's the zoning for my properties?" → 1 enrichment → **execute directly**
- "List my projects" → 1 op → **execute directly**
- "Create a project with 5 addresses" → 1 op (even with multiple properties)

**Rule of thumb:** Count the number of separate API calls needed. If it's 2+, plan. If it's 1, just do it.

## 2. Available Step Types

Every plan step maps to a skill endpoint:

| Step Type | Endpoint | Credits | Sync/Async |
|-----------|----------|---------|------------|
| `create-project` | POST /projects (Section 3) | 1/address (geocoding) | Sync |
| `add-properties` | POST /projects/{id}/properties (Section 5) | 1/address | Sync |
| `update-project` | PATCH /projects/{id} (Section 4) | 0 | Sync |
| `update-properties` | PATCH /projects/{id}/properties (Section 6) | 0 (re-geocode: 1/addr) | Sync |
| `delete-properties` | DELETE /projects/{id}/properties (Section 7) | 0 | Sync |
| `delete-project` | DELETE /projects/{id} (Section 8) | 0 | Sync |
| `demographics` | POST /projects/{id}/demographics (Section 9) | 4/property | Sync |
| `enrichment` | POST /projects/{id}/enrichment (Section 11) | 1-30/property | **Async** |
| `check-enrichment` | GET /projects/{id}/enrichment (Section 12) | 0 | Sync |
| `list-projects` | GET /projects (Section 1) | 0 | Sync |
| `get-details` | GET /projects/{id} (Section 2) | 0 | Sync |
| `quick-search` | Gemini Pro API (cobroker-search Section 3) | 0 Cobroker credits | Sync (~30s) |
| `deep-search` | FindAll API base (cobroker-search Section 4) | 25+ credits | Async (2-5min) |

## 3. Plan Format

Present the plan as a structured message:

```
📝 Plan: [Short Title]

[1-2 sentence description of what we'll do]

Steps:
1. [Operation description] — [type tag]
2. [Operation description] — [type tag]
3. [Operation description] — [type tag]

Estimated credits: [X] credits total
[Any notes about async operations or timing]

Reply "go" to execute, or tell me what to change.
```

Always attach inline keyboard buttons after the plan message (see Section 5).

### Credit Calculation

- Demographics: 4 credits × number of properties
- Enrichment: credits depend on processor (base=1, core=3, pro=10, ultra=30) × number of properties
- Create/add properties: 1 credit per address (geocoding)
- Updates, deletes, lists: 0 credits

## 4. Plan Examples

### Example A — Demographics + Enrichment

```
📝 Plan: Enrich Dallas Warehouses

I'll add demographic data and research zoning for your Dallas Warehouses project (12 properties).

Steps:
1. Add Population (1 mi radius) — demographics
2. Add Median Household Income (1 mi radius) — demographics
3. Research Zoning Classification (base processor) — enrichment

Estimated credits: 108 (48 demographics + 48 demographics + 12 enrichment)
Note: Enrichment results arrive async (15-100s per property).

Reply "go" to execute, or tell me what to change.
```

### Example B — Create + Enrich (full workflow)

```
📝 Plan: New Austin Retail Survey

I'll create a new project with your 8 addresses, then add demographics and research competitors.

Steps:
1. Create project "Austin Retail" with 8 properties — create-project
2. Add Population (1 mi radius) — demographics
3. Add Median Household Income (1 mi radius) — demographics
4. Add Median Home Value (1 mi radius) — demographics
5. Research "nearby competing retail stores" (base) — enrichment

Estimated credits: 168 (8 geocoding + 96 demographics + 8 enrichment)

Reply "go" to execute, or tell me what to change.
```

### Example C — Modify + Remove

```
📝 Plan: Clean Up Dallas Warehouses

I'll update the project details and remove the properties you flagged.

Steps:
1. Rename project to "Dallas Warehouses — Q2 Final" — update-project
2. Remove 3 properties (IDs: abc, def, ghi) — delete-properties
3. Update asking price on 123 Main St to $650K — update-properties

Estimated credits: 0

Reply "go" to execute, or tell me what to change.
```

### Example D — Multiple Enrichment Columns

```
📝 Plan: Deep Research — TopGolf El Paso

I'll research multiple attributes for your TopGolf El Paso project (1 property).

Steps:
1. Research Zoning Classification (base) — enrichment
2. Research Year Built & Building Size (base) — enrichment
3. Research Recent Sale History (core) — enrichment
4. Add Population (3 mi drive time) — demographics

Estimated credits: 10 (2 base enrichment + 3 core enrichment + 4 demographics)
Note: Enrichment results arrive async. Base: ~15-100s, Core: ~1-5min.

Reply "go" to execute, or tell me what to change.
```

## 5. Inline Keyboard for Approval

Include the `buttons` parameter in the SAME message tool call as the plan text (not a separate call):

```
buttons: [[{"text": "✅ Approve & Execute", "callback_data": "plan_approve"}, {"text": "✏️ Edit Plan", "callback_data": "plan_edit"}], [{"text": "❌ Cancel", "callback_data": "plan_cancel"}]]
```

**IMPORTANT:** The `buttons` parameter MUST be in the SAME tool call as the message text. Do NOT send them separately.

**How callback flow works:**
1. You send the plan message with the `buttons` parameter in one tool call
2. User clicks a button → gateway receives callback_query
3. Gateway forwards the callback_data as a new text message to you
4. You receive `"plan_approve"`, `"plan_edit"`, or `"plan_cancel"` as the next user message
5. Act accordingly (see Section 6)

## 6. Handling Callbacks

When you receive a message that matches a callback or text equivalent:

### Approve
- **Callback:** `plan_approve`
- **Text equivalents:** "go", "yes", "approved", "proceed", "execute", "do it", "run it"
- **Action:** Execute all plan steps sequentially (see Section 7)

### Edit
- **Callback:** `plan_edit`
- **Action:** Reply "What would you like to change?" and wait for feedback. After receiving feedback, revise the plan and re-present it with the same inline keyboard buttons.

### Cancel
- **Callback:** `plan_cancel`
- **Text equivalents:** "cancel", "nevermind", "stop", "nah", "no"
- **Action:** Reply "Plan cancelled. Send me a new request anytime." and stop.

### Other text
- If you're waiting for plan approval and the user sends text that isn't a clear approve/cancel, treat it as **plan edit feedback** — revise the plan based on their input and re-present with buttons.

## 7. Execution Flow

After approval:

1. Send a "⚡ Starting plan execution..." message
2. Execute each step **in order** using the cobroker-projects skill endpoints (curl commands)
3. Report progress after each step:
   ```
   ✅ Step 1/3: Population (1 mi) — done (12 properties enriched)
   ⏳ Step 2/3: Median Income (1 mi) — running...
   ```
4. For async operations (enrichment), submit and note it's processing:
   ```
   ✅ Step 3/3: Zoning enrichment submitted (12 properties, base processor)
   Results will appear in the project table shortly.
   ```
5. After all steps complete, send a summary with an inline URL button (not a text link):
   ```
   message: "✅ Plan complete!\n\n- Population (1 mi): 12/12 properties ✓\n- Median Income (1 mi): 12/12 properties ✓\n- Zoning research: submitted, processing..."
   buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
   ```

## 8. Step Ordering Rules

Always order steps logically, regardless of the order the user mentioned them:

1. **Create/update operations first** — create project, add properties, update project
2. **Search next** — quick-search or deep-search to find properties
3. **Demographics next** — synchronous, fast (~1-2s per property)
4. **Enrichment next** — async, takes longer (15s to 25min)
5. **Destructive operations last** — delete properties, delete project

This ensures:
- Properties exist before enrichment runs
- Fast operations complete before slow ones
- The user sees progress quickly

## 9. Error Handling

- **Step fails (non-credit):** Report the error and **continue** with remaining steps
- **Credit failure (402):** **Stop** execution immediately — don't waste remaining credits on steps that will also fail
- **At the end:** Summarize what succeeded and what failed

### Error Examples

Partial failure (continue):
```
✅ Step 1/3: Population (1 mi) — done (12/12)
❌ Step 2/3: Median Income (1 mi) — failed (server error)
✅ Step 3/3: Zoning enrichment submitted (12 properties)

Plan partially complete: 2/3 steps succeeded. Step 2 failed — you can retry "add median income demographics" separately.
```

Credit failure (stop):
```
✅ Step 1/3: Population (1 mi) — done (12/12)
❌ Step 2/3: Median Income — failed (insufficient credits: need 48, have 30)
⏭️ Step 3/3: Skipped (insufficient credits)

Plan stopped at step 2. Step 1 completed successfully. Add credits and retry.
```

## 10. Dependencies Between Steps

Some steps depend on outputs from earlier steps:

- **Create project → demographics/enrichment:** The create-project step returns a `projectId`. Use that ID for all subsequent demographics and enrichment calls in the same plan.
- **Add properties → enrichment:** Properties must exist (with coordinates) before demographics can run, and must have addresses before enrichment can run.
- **Enrichment → check status:** After submitting enrichment, you can optionally poll once after ~30s to report early results. But don't block the plan waiting for async completion.

When a plan includes `create-project` as step 1, capture the `projectId` from the response and pass it to all subsequent steps.
