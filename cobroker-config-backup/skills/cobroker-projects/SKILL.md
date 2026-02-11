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

Enrich properties with ESRI demographic data. Creates a new column and populates values for all properties with coordinates.

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/demographics" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "dataType": "population",
    "radius": 1,
    "mode": "radius"
  }'
```

Parameters:
- `dataType` (required) — demographic metric (see Section 10 for full list)
- `radius` (required) — 0.1 to 100 (miles for radius, minutes for drive/walk)
- `mode` (optional, default `"radius"`) — `"radius"` | `"drive"` | `"walk"`
- `columnName` (optional) — auto-generated if omitted (e.g. "Population (1 mi)")

Response:
```json
{
  "success": true,
  "projectId": "uuid",
  "columnId": "uuid",
  "columnName": "Population (1 mi)",
  "dataType": "population",
  "radius": 1,
  "mode": "radius",
  "propertiesProcessed": 5,
  "propertiesTotal": 5,
  "propertiesFailed": 0
}
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

Cost: 4 credits per property per demographic column.

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
    "processor": "base"
  }'
```

Parameters:
- `prompt` (required) — question to research for each property address
- `columnName` (optional) — auto-generated from prompt if omitted
- `processor` (optional, default `"base"`) — research depth:
  - `"base"` — 1 credit/property, ~15-100s
  - `"core"` — 3 credits/property, ~1-5min
  - `"pro"` — 10 credits/property, ~3-9min
  - `"ultra"` — 30 credits/property, ~5-25min

Response (202 Accepted):
```json
{
  "success": true,
  "projectId": "uuid",
  "columnId": "uuid",
  "columnName": "Zoning",
  "prompt": "What is the zoning classification for this property?",
  "processor": "base",
  "propertiesSubmitted": 5,
  "propertiesTotal": 5,
  "propertiesSkipped": 0,
  "creditsCharged": 5,
  "status": "processing",
  "estimatedTime": "15-100 seconds per property (base processor)"
}
```

## 12. Check Enrichment Status

Poll to check if enrichment tasks have completed.

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/enrichment?columnId={columnId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "success": true,
  "columnId": "uuid",
  "columnName": "Zoning",
  "status": "processing",
  "completed": 3,
  "pending": 1,
  "failed": 1,
  "total": 5,
  "results": [
    {
      "propertyId": "uuid",
      "address": "123 Main St, Dallas, TX 75201",
      "status": "completed",
      "content": "C-2 Commercial",
      "confidence": "high"
    },
    {
      "propertyId": "uuid",
      "address": "456 Oak Ave, Dallas, TX 75202",
      "status": "pending",
      "content": null,
      "confidence": null
    }
  ]
}
```

## 13. Search Places (as Properties)

Search Google Places and save results as properties in a project. Great for "Find all Topgolf locations in Texas" type requests.

```bash
# Add to existing project
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/{projectId}/places/search" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "query": "Topgolf", "maxResults": 50 }'

# Create new project from places search
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects/new/places/search" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "query": "Starbucks in Dallas", "projectName": "Starbucks Dallas Search" }'
```

Parameters:
- `query` (required) — search text (e.g. "Topgolf", "Starbucks in Dallas")
- `maxResults` (optional, default 50, max 400) — cap total results
- `regionSearch` (optional, default false) — search across 7 US regions for nationwide coverage
- `boundingBox` (optional) — `{ south, north, west, east }` to restrict to a geographic box
- `projectName` (optional) — name for auto-created project (only when projectId is `"new"`)

Response (201):
```json
{
  "success": true,
  "projectId": "uuid",
  "destination": "properties",
  "query": "Topgolf",
  "placesFound": 87,
  "propertiesAdded": 87,
  "places": [
    {
      "name": "Topgolf Dallas",
      "address": "8787 Park Ln, Dallas, TX 75231",
      "latitude": 32.87,
      "longitude": -96.76,
      "type": "Entertainment center",
      "googleMapsUrl": "https://maps.google.com/?cid=...",
      "placeId": "ChIJ..."
    }
  ],
  "projectUrl": "https://app.cobroker.ai/project/{id}?view=table",
  "publicUrl": "https://app.cobroker.ai/public/{id}"
}
```

The `places` array is always returned so you can answer conversational questions ("I found 87 Topgolf locations...").

Cost: 1 credit per 10 places (rounded up).

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

Response includes `publicUrl` pointing to map view.

Cost: 1 credit per 10 places (rounded up).

## 15. Nearby Places Analysis

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

Cost: nearest = 2 credits/property, count = 1 credit/property. Properties without coordinates are skipped.

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
10. **User asks to research something about properties** → Research Enrichment (Section 11), then poll status (Section 12) until completed
11. **User asks about enrichment status** → Check Enrichment Status (Section 12)
12. **User asks to find/locate places or chains** → Places Search as Properties (Section 13) — use `projectId: "new"` for fresh search, existing projectId to add to project
13. **User wants places shown on map** → Places Search as Layer (Section 14) — requires existing project
14. **User asks what's near their properties** → Nearby Places Analysis (Section 15) — nearest mode for "closest X" questions, count mode for "how many X nearby"

## Constraints

- Maximum 50 properties per request (create or add)
- NEVER fabricate addresses — only import what the user provides or what research found
- Each geocoded address costs 1 credit (automatic if lat/long omitted)
- If geocoding fails for some properties, they still import (without map pins)
- Always create projects as `"public": true` so the URL can be shared via Telegram
- Always share the **publicUrl** via an inline keyboard URL button — not as a text link. Include `buttons` in the SAME message tool call: `buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]`. Never use projectUrl — Telegram users are not logged in.
- Demographics require properties with coordinates — add properties first, then enrich
- Each demographic column costs 4 credits per property (ESRI GeoEnrichment API)
- Properties without lat/long are skipped during demographic enrichment
- Each enrichment costs 1-30 credits per property depending on processor (base=1, core=3, pro=10, ultra=30)
- Enrichment is **async** — submit first, then poll for results. Tell the user "researching..." and check back.
- Properties need addresses (not coordinates) for enrichment — unlike demographics which need coordinates
- Default to `"base"` processor unless user asks for deeper research
- After enrichment completes, results appear as a new column in the project table
- Places search costs 1 credit per 10 places found (ceil) — Google Places API
- Nearby analysis costs 2 credits/property (nearest) or 1 credit/property (count)
- Use `projectId: "new"` to auto-create a project from places search — good for "find all X" requests
- For places layer, the project must already exist (no auto-create)
- Duplicate layer names return 409 — suggest appending "(2)" or similar
- `regionSearch: true` searches across 7 US regions for comprehensive nationwide coverage (100+ results)
- The `places` array is always returned in search responses — use it to answer the user conversationally before sharing the project link
