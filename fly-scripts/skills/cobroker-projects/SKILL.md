---
name: cobroker-projects
description: >
  Manage CoBroker projects and properties. Create, list, view, update, and delete
  projects. Add, update, and remove properties. Enrich properties with demographic
  data (population, income, jobs, housing). Use whenever the user wants to work
  with CoBroker project data.
user-invocable: true
metadata:
  openclaw:
    emoji: "📋"
---

# CoBroker Projects

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

## Constraints

- Maximum 50 properties per request (create or add)
- NEVER fabricate addresses — only import what the user provides or what research found
- Each geocoded address costs 1 credit (automatic if lat/long omitted)
- If geocoding fails for some properties, they still import (without map pins)
- Always create projects as `"public": true` so the URL can be shared via Telegram
- Always share the **publicUrl** with the user (not projectUrl)
- Demographics require properties with coordinates — add properties first, then enrich
- Each demographic column costs 4 credits per property (ESRI GeoEnrichment API)
- Properties without lat/long are skipped during demographic enrichment
