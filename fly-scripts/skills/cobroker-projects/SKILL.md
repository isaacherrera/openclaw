---
name: cobroker-projects
description: >
  Manage Cobroker projects and properties. Create, list, view, update, and delete
  projects. Add, update, and remove properties. Enrich properties with demographic
  data (population, income, jobs, housing) or AI-powered research enrichment
  (zoning, building details, market data, etc.). Use whenever the user wants to
  work with Cobroker project data.
user-invocable: true
metadata:
  openclaw:
    emoji: "📋"
---

# Cobroker Projects

Full CRUD for projects and properties — create, list, view, update, delete.

## CRITICAL: Project Links Must Use Buttons

NEVER share a project URL as plain text. ALWAYS use an inline keyboard URL button:
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```
Use `publicUrl` (not `projectUrl`) — Telegram users are not logged in. This applies to EVERY response that includes a project link — create, save, places search, enrichment, etc.

## CRITICAL: Message Discipline for Async Operations

- **Enrichment (Section 11):** Submit the research, send ONE acknowledgment with the project link button, then poll silently (output `___`). When results arrive, send ONE final message. Total: 2 messages max. See Section 12 for polling details.
- **Never** send "still processing", "checking...", or interim progress messages.
- **Never use `sleep` in exec commands.**

## CRITICAL: Preview Data in Chat — MANDATORY

**NEVER** confirm a data operation with just counts like "6/6 properties enriched." The user MUST see actual values.

After EVERY data-adding operation (demographics, enrichment, nearby analysis, places):
1. **GET project details** (Section 2) to read the new column values
2. **Include a numbered preview** of the actual per-property values in your confirmation message
3. Show 3-5 properties max. If there are more, end with "...and X more in your project."
4. **Never use markdown tables** — use a simple numbered list
5. **Never skip this step** — even if the API response only returns counts, you MUST make the extra GET call to fetch real values

## Auth Headers (all requests)

```
-H "Content-Type: application/json" \
-H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
-H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

## 1. List Projects

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "success": true,
  "projects": [
    {
      "id": "uuid",
      "name": "Dallas Warehouses",
      "description": "Q1 survey",
      "public": true,
      "propertyCount": 12,
      "createdAt": "2026-01-15T...",
      "projectUrl": "https://app.cobroker.ai/project/{id}?view=table",
      "publicUrl": "https://app.cobroker.ai/public/{id}"
    }
  ],
  "count": 5
}
```

## 2. Get Project Details

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response includes human-readable field names (not UUIDs):
```json
{
  "success": true,
  "project": { "id": "uuid", "name": "...", "description": "...", "public": true },
  "columns": [{ "id": "uuid", "name": "Price" }],
  "properties": [
    {
      "id": "uuid",
      "address": "123 Main St, Dallas, TX 75201",
      "latitude": 32.78,
      "longitude": -96.80,
      "fields": { "Price": "$500K", "Size": "10,000 SF" }
    }
  ],
  "propertyCount": 12
}
```

## 3. Create Project

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "name": "Dallas Warehouses",
    "description": "Q1 survey",
    "source": "openclaw",
    "public": true,
    "properties": [
      {
        "address": "123 Main St, Dallas, TX 75201",
        "fields": {
          "Price": "$500,000",
          "Size": "10,000 SF",
          "Type": "Warehouse"
        }
      }
    ]
  }'
```

Response:
```json
{
  "success": true,
  "projectId": "uuid",
  "projectUrl": "https://app.cobroker.ai/project/{id}?view=table",
  "publicUrl": "https://app.cobroker.ai/public/{id}",
  "propertyCount": 5,
  "columnCount": 3,
  "geocodedCount": 5,
  "columns": [{ "id": "uuid", "name": "Price" }]
}
```

After creating a project, share the link using an inline URL button (never as a plain text link):
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

## 4. Update Project

```bash
curl -s -X PATCH "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "name": "Updated Name",
    "description": "New description",
    "public": true
  }'
```

All fields optional. Only provided fields are updated.

## 5. Add Properties to Existing Project

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/properties" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "properties": [
      {
        "address": "456 Oak Ave, Dallas, TX 75202",
        "fields": { "Price": "$750K", "Size": "15,000 SF" }
      }
    ]
  }'
```

New field names automatically create new columns. Existing field names map to existing columns.

## 6. Update Properties

```bash
curl -s -X PATCH "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/properties" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "updates": [
      {
        "id": "property-uuid",
        "address": "789 New St, Dallas, TX 75203",
        "fields": { "Price": "$600K" }
      }
    ]
  }'
```

- Property `id` is required (get from project details)
- Address changes trigger re-geocoding
- Field updates merge into existing fields

## 7. Delete Properties

```bash
curl -s -X DELETE "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/properties" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "propertyIds": ["uuid-1", "uuid-2"]
  }'
```

## 8. Delete Project

```bash
curl -s -X DELETE "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Deletes project and ALL associated data (properties, images, documents).

## 9. Add Demographics to Project

Enrich properties with ESRI demographic data.

**IMPORTANT**: Use this SINGLE combined command — it adds the demographics AND outputs a formatted preview of the actual values. Do NOT split into separate commands.

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/demographics" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{"dataType":"population","radius":1,"mode":"radius"}' \
  > /tmp/_post.json && \
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  > /tmp/_get.json && \
node -e "
const post=JSON.parse(require('fs').readFileSync('/tmp/_post.json','utf8'));
const proj=JSON.parse(require('fs').readFileSync('/tmp/_get.json','utf8'));
const col=post.columnName;
console.log(JSON.stringify(post));
console.log('---PREVIEW---');
console.log('Column: '+col);
proj.properties.forEach((p,i)=>{
  const val=p.fields&&p.fields[col]||'N/A';
  console.log((i+1)+'. '+p.address+' — '+val);
});
console.log('Total: '+proj.propertyCount+' properties');
"
```

Parameters (in the `-d` JSON):
- `dataType` (required) — demographic metric (see Section 10 for full list)
- `radius` (required) — 0.1 to 100 (miles for radius, minutes for drive/walk)
- `mode` (optional, default `"radius"`) — `"radius"` | `"drive"` | `"walk"`
- `columnName` (optional) — auto-generated if omitted (e.g. "Population (1 mi)")

The command output has two parts separated by `---PREVIEW---`:
1. The POST response JSON (counts, column name)
2. A formatted preview showing each property's address and the actual demographic value

Use the preview section directly in your confirmation message:

```
✅ Population (1 mi) added to 5 properties
1. 3500 Maple Ave, Dallas, TX — 12,450
2. 7920 Belt Line Rd, Dallas, TX — 8,230
3. 950 W Bethany Dr, Allen, TX — 15,100
...and 2 more in your project.
```

Common data types:
| Type | Description |
|------|-------------|
| `population` | Total population |
| `income` | Median household income |
| `median_age` | Median age |
| `households` | Total households |
| `median_home_value` | Median home value |
| `median_rent` | Median rent |
| `retail_jobs` | Retail employment |
| `healthcare_jobs` | Healthcare employment |

Uses ESRI GeoEnrichment API. Properties must have coordinates.

## 10. List Demographic Types

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/demographics" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Returns all 58 supported data types grouped by category: Core Demographics, Income Brackets, Race/Ethnicity, Age Groups, Employment, Housing & Additional.

## 11. Research Enrichment (AI-Powered)

Use Parallel AI to research a question about each property. Creates a new column and submits async research tasks. Results arrive via webhook (15s to 25min depending on processor).

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/enrichment" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "prompt": "What is the zoning classification for this property?",
    "columnName": "Zoning",
    "processor": "core"
  }'
```

Parameters:
- `prompt` (required) — question to research for each property address
- `columnName` (optional) — auto-generated from prompt if omitted
- `processor` (optional, default `"core"`) — research depth:
  - `"base"` — fast, ~15-100s per property
  - `"core"` (default) — balanced depth + speed, ~1-5min per property
  - `"pro"` — thorough, ~3-9min per property
  - `"ultra"` — exhaustive, ~5-25min per property

Response (202 Accepted):
```json
{
  "success": true,
  "projectId": "uuid",
  "columnId": "uuid",
  "columnName": "Zoning",
  "prompt": "What is the zoning classification for this property?",
  "processor": "core",
  "propertiesSubmitted": 5,
  "propertiesTotal": 5,
  "propertiesSkipped": 0,
  "status": "processing",
  "estimatedTime": "1-5 minutes per property (core processor)"
}
```

## 12. Enrichment Results (Silent Polling)

After submitting enrichment (Section 11), poll silently for results. The user should receive exactly **2 messages** — no more:

1. **Acknowledgment** (immediately after submitting):
```
🔬 Research submitted for [X] properties — "[prompt]"
Working on it now...
```
Include the project link as an inline button in the SAME message:
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

2. **Final results** (after polling completes or times out):
**⚠️ MANDATORY**: GET project details (Section 2) to read the enrichment column values. Do NOT just say "Research complete" — show actual values:

```
✅ Zoning research complete!
1. 123 Main St — C-2 Commercial
2. 456 Oak Ave — I-1 Industrial
3. 789 Elm St — PD (Planned Development)
...and 9 more in your project.
```
With project link button.

### Silent Polling Rules

- Poll the status endpoint below, outputting `___` with each poll (no user-facing text)
- **Max 20 polls**, ~30 seconds apart
- If results arrive: use the combined command below to check status AND fetch project details in one call
- If max polls reached with partial results: deliver what's available
- If max polls reached with no results: tell user results are still processing and they can check the project later
- **NEVER** send "still processing", "checking...", or interim progress messages

Use this combined command to poll — it checks enrichment status AND fetches project details in one call:

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/enrichment?columnId={columnId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" && echo '---PROJECT_DETAILS---' && curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

The output has two JSON responses separated by `---PROJECT_DETAILS---`. When enrichment status shows results are complete, read the actual values from the second response's `properties[].fields` to include in your final message.

## CRITICAL: When to Use Places Search (Sections 13-15)

Places Search uses **Google Places API** to find **existing locations** — real businesses, stores, chains, restaurants, offices that are operating today.

**USE Places Search for:**
- Finding all locations of a brand/chain: "Where are all the Topgolf locations in Texas?"
- Locating existing businesses: "Find Starbucks near my properties"
- Nearby analysis: "What restaurants are within 1 mile of each property?"

**DO NOT use Places Search for:**
- Available space for sale or lease → use **cobroker-search** (Quick/Deep Search)
- Vacant land or development sites → use **cobroker-search**

**If ambiguous**, ask: "Are you looking for existing [business type] locations, or available space for sale or lease?"

## 13. Search Places (as Properties)

Search Google Places and save results as properties in a project. Uses a **two-step flow**: preview first, then save on user approval.

### Step 1: Preview (search without saving)

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/new/places/search" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "query": "Topgolf in Texas", "preview": true }'
```

Preview response (200):
```json
{
  "success": true,
  "preview": true,
  "query": "Topgolf in Texas",
  "placesFound": 15,
  "places": [
    { "name": "Topgolf Dallas", "address": "8787 Park Ln, Dallas, TX 75231", "latitude": 32.87, "longitude": -96.76, "type": "Entertainment center", "googleMapsUrl": "...", "placeId": "ChIJ..." }
  ]
}
```

After receiving the preview, **present the results conversationally** and ask the user with inline keyboard buttons:

```
buttons: [[{"text": "✅ Save to Project", "callback_data": "places_save"}, {"text": "❌ No Thanks", "callback_data": "places_cancel"}]]
```

### Step 2: Save (only after user approves)

When the user clicks "Save to Project" (or says "yes", "save", "go"):

```bash
# Save to new project
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/new/places/search" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "query": "Topgolf in Texas", "projectName": "Topgolf Texas" }'

# Save to existing project
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/places/search" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "query": "Topgolf in Texas" }'
```

Save response (201):
```json
{
  "success": true,
  "projectId": "uuid",
  "destination": "properties",
  "placesFound": 15,
  "propertiesAdded": 15,
  "places": [...],
  "projectUrl": "...",
  "publicUrl": "..."
}
```

Parameters:
- `query` (required) — search text (e.g. "Topgolf", "Starbucks in Dallas")
- `preview` (optional, default false) — if true, returns places without saving anything
- `maxResults` (optional, default 50, max 400) — cap total results
- `regionSearch` (optional, default false) — search across 7 US regions for nationwide coverage
- `boundingBox` (optional) — `{ south, north, west, east }` to restrict to a geographic box
- `projectName` (optional) — name for auto-created project (only when projectId is `"new"`)

**IMPORTANT: Always preview first, then save.** Never auto-create a project without user confirmation. The only exception is when a plan step explicitly calls for places search — in that case the user already approved the plan, so skip preview.

Preview is free (no data saved).

After saving, share the project link using an inline URL button:
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

## 14. Search Places (as Logo Layer)

Search Google Places and save results as a map layer with brand logos. Great for "Show Starbucks near my warehouses on the map" type requests.

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/places/search" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "query": "Starbucks", "destination": "layer", "layerName": "Starbucks Locations", "markerColor": "#00704A" }'
```

Additional parameters (on top of Section 13):
- `destination` — must be `"layer"`
- `layerName` (required for layer) — name for the map layer
- `markerColor` (optional, default `"#4285F4"`) — hex color for markers

Layer destination requires an existing project (not `"new"`). Returns 409 if layer name already exists.

Response includes `publicUrl` pointing to map view. Share it using an inline URL button:
```
buttons: [[{"text": "🗺️ View Map", "url": "<publicUrl>"}]]
```

**Preview**: Mention the count and a few representative names:

```
✅ Starbucks layer added — 12 locations pinned on map
Closest to your properties: Starbucks (Mockingbird Ln), Starbucks (Knox St), Starbucks (Greenville Ave)
```

## CRITICAL: Places Must Always Appear on the Map

Whenever you find or reference specific places (brands, chains, businesses) near a project's properties, those places MUST appear as visual pins on the map — not just as text in a table column.

**Rule: Nearby Analysis (Section 15) should ALWAYS be paired with a Places Layer (Section 14) for the same query.**

Example flow for "add McDonald's near each location":
1. First, run Places Layer (Section 14) with `"query": "McDonald's", "destination": "layer"` → puts McDonald's pins on the map
2. Then, run Nearby Analysis (Section 15) with `"query": "McDonald's", "mode": "nearest"` → adds distance data as a column

This gives the user both: visual map pins AND data in the table.

**When to skip the layer**: Only skip the Places Layer step if the user explicitly asks for ONLY the data/count (e.g., "just tell me how many restaurants are nearby, don't add them to the map").

## 15. Nearby Places Analysis

**⚠️ Always pair with Places Layer (Section 14)** — Before running Nearby Analysis, first add a Places Layer for the same query so the user can SEE the places on the map. Nearby Analysis only creates a text column; the map pins come from the Layer.

Analyze what's near each property in a project. Creates a new column with results for each property.

```bash
# Nearest mode — find closest matching place to each property
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/places/nearby" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "query": "grocery store", "radiusMiles": 2, "mode": "nearest" }'

# Count mode — count place types near each property
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/places/nearby" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "placeTypes": ["restaurant", "cafe"], "radiusMiles": 1, "mode": "count" }'
```

Parameters:
- `mode` (required) — `"nearest"` or `"count"`
- `query` (required for nearest) — what to search for (e.g. "grocery store", "Starbucks")
- `placeTypes` (required for count) — array of Google place types (e.g. `["restaurant", "cafe"]`)
- `radiusMiles` (required) — search radius 0.1–50 miles
- `columnName` (optional) — auto-generated if omitted (e.g. "Nearest grocery store (2mi)")

Response (201):
```json
{
  "success": true,
  "projectId": "uuid",
  "columnId": "uuid",
  "columnName": "Nearest grocery store (2mi)",
  "mode": "nearest",
  "radiusMiles": 2,
  "propertiesProcessed": 10,
  "propertiesTotal": 12,
  "propertiesSkipped": 2,
  "results": [
    { "propertyId": "uuid", "address": "123 Main St, Dallas, TX", "nearestPlace": "Kroger", "distanceMiles": 0.3, "totalFound": 5 }
  ]
}
```

**Preview**: Use the `results` array to preview what was added:

```
✅ Nearest grocery store (2 mi) added
1. 123 Main St — Kroger, 0.3 mi (5 found)
2. 456 Oak Ave — Tom Thumb, 0.8 mi (3 found)
3. 789 Elm St — Whole Foods, 1.1 mi (7 found)
...and 7 more in your project.
```

Properties without coordinates are skipped.

After nearby analysis, share the project link using an inline URL button:
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```
Use the project's publicUrl: `https://app.cobroker.ai/public/{projectId}`

## Address Formatting — CRITICAL

Addresses MUST have at least 3 comma-separated components:

- GOOD: `"123 Main St, Dallas, TX 75201"` ← street, city, state+zip
- GOOD: `"123 Main St, Suite 100, Dallas, TX 75201"`
- BAD: `"123 Main St Dallas TX 75201"` ← no commas, rejected
- BAD: `"123 Main St, Dallas TX 75201"` ← only 2 parts, rejected

If the user gives an address without proper commas, reformat it before submitting.

## Workflow Guidelines

1. **User wants to see their projects** → List Projects (Section 1)
2. **User wants details on a project** → Get Project Details (Section 2)
3. **User provides new properties** → Create Project (Section 3) if new, or Add Properties (Section 5) if adding to existing
4. **User wants to rename/update a project** → Update Project (Section 4)
5. **User wants to change a property** → Update Properties (Section 6) — get property IDs from details first
6. **User wants to remove properties** → Delete Properties (Section 7)
7. **User wants to delete a project** → Delete Project (Section 8) — confirm with user first
8. **User asks for demographic data** → Add Demographics (Section 9) — properties must exist first
9. **User asks what demographics are available** → List Demographic Types (Section 10)
10. **User asks to research something about properties** → Research Enrichment (Section 11), send acknowledgment with project button, then poll silently per Section 12
11. **User asks about enrichment status** → Check once with Section 12 endpoint, report result
12. **User asks to find/locate places or chains** → Places Search as Properties (Section 13) — always preview first (`"preview": true`), present results with inline buttons, then save only after user approves. NOTE: If user wants available space for sale/lease, use cobroker-search instead.
13. **User wants places shown on map** → Places Search as Layer (Section 14) — requires existing project
14. **User asks what's near their properties** → FIRST add a Places Layer (Section 14) for the query to show pins on the map, THEN run Nearby Places Analysis (Section 15) for distance/count data in the table

## Constraints

- Maximum 50 properties per request (create or add)
- NEVER fabricate addresses — only import what the user provides or what research found
- Geocoding is automatic if lat/long omitted
- If geocoding fails for some properties, they still import (without map pins)
- Always create projects as `"public": true` so the URL can be shared via Telegram
- Always share the **publicUrl** via an inline keyboard URL button — not as a text link. Include `buttons` in the SAME message tool call: `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]`. Never use projectUrl — Telegram users are not logged in.
- Demographics require properties with coordinates — add properties first, then enrich
- Demographics use ESRI GeoEnrichment API
- Properties without lat/long are skipped during demographic enrichment
- Enrichment is **async** — submit, send ONE acknowledgment with project button, then poll silently (output `___`). See Section 12 for polling rules.
- Properties need addresses (not coordinates) for enrichment — unlike demographics which need coordinates
- Default to `"core"` processor unless user specifies otherwise
- After enrichment completes, results appear as a new column in the project table
- Places search uses Google Places API
- Always preview places search first (`"preview": true`), then save only after user confirms — use `projectId: "new"` to auto-create a project, or existing projectId to add to an existing one
- For places layer, the project must already exist (no auto-create)
- Duplicate layer names return 409 — suggest appending "(2)" or similar
- `regionSearch: true` searches across 7 US regions for comprehensive nationwide coverage (100+ results)
- The `places` array is always returned in search responses — use it to answer the user conversationally before sharing the project link
