---
name: cobroker-import-properties
description: >
  Import property addresses into a Cobroker project with automatic geocoding.
  Use when the user asks to save properties, create a project from addresses,
  import a list of locations, or when you have collected property data that
  should be stored in Cobroker for mapping and analysis.
user-invocable: true
metadata:
  openclaw:
    emoji: "📥"
    requires:
      env: ["COBROKER_API_KEY", "COBROKER_API_URL", "COBROKER_USER_ID"]
---

# Cobroker Property Import

Import properties into a Cobroker project for mapping, analysis, and tracking.

## API Call

Use `curl` via exec to POST to the import endpoint:

```bash
curl -s -X POST "$COBROKER_API_URL/api/agent/openclaw/import-properties" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_API_KEY" \
  -d '{
    "name": "Project Name",
    "description": "Optional description",
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

## Request Fields

- **name** (required): Project name, max 200 chars
- **public** (required): Always set to `true` so the public URL can be shared with the user
- **description** (optional): Project description
- **source** (optional): Defaults to "openclaw"
- **properties** (required): Array of 1-50 properties
  - **address** (required): Full address with commas — see formatting rules below
  - **latitude/longitude** (optional): If omitted, system geocodes automatically (1 credit per address)
  - **fields** (optional): Key-value metadata (any string keys/values)

## Address Formatting — CRITICAL

Addresses MUST have at least 3 comma-separated components:

- GOOD: `"123 Main St, Dallas, TX 75201"` <- street, city, state+zip
- GOOD: `"123 Main St, Suite 100, Dallas, TX 75201"`
- BAD: `"123 Main St Dallas TX 75201"` <- no commas, rejected
- BAD: `"123 Main St, Dallas TX 75201"` <- only 2 parts, rejected

If the user gives an address without proper commas, reformat it before submitting.

## Response (success)

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

## Workflow

### Step 1: Collect Property Data
Gather from the user:
- Project name (or generate a descriptive one)
- List of addresses with any associated data (price, size, type, etc.)

### Step 2: Format & Submit
- Ensure every address has >=3 comma-separated parts (street, city, state/zip)
- Build the JSON payload with all properties and their fields
- Always set `"public": true`
- POST via curl

### Step 3: Present Results
Share with the user:
- How many properties were imported and geocoded
- The **public URL** (publicUrl from response) — this is the link to share
- The dashboard URL (projectUrl) for the full table view

## Constraints
- Maximum 50 properties per import
- NEVER fabricate addresses — only import what the user provides or what research found
- Each geocoded address costs 1 credit
- If geocoding fails for some properties, they still import (without map pins)
- Always create projects as public so the URL can be shared via Telegram
