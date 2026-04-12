---
name: cobroker-designer
description: >
  Create and edit property flyers, brochures, and offering memorandums.
  Read and modify TypeScript templates, manage image slots, undo/redo
  changes, save reusable templates, and export to PDF. Use whenever
  the user wants to design or update marketing materials for a property.
user-invocable: true
metadata:
  openclaw:
    emoji: "🎨"
---

# Cobroker Designer

Create, read, and modify property marketing materials — flyers, brochures, and offering memorandums. Templates are TypeScript source code that you can edit to change layout, content, and styling.

## CRITICAL: Template Contract

Templates are **TypeScript source strings** that define a `render(data)` function returning HTML:

```typescript
interface PropertyData {
  name?: string; address?: string; city?: string; state?: string; zip?: string;
  latitude?: number; longitude?: number;
  sqft?: number; lotSize?: string; yearBuilt?: number; zoning?: string;
  stories?: number; units?: number; parkingSpaces?: number; propertyType?: string;
  price?: number; leaseRate?: string; pricePerSF?: number;
  capRate?: number; noi?: number;
  images?: string[]; coverPhoto?: string; logo?: string; mapImageUrl?: string;
  broker?: { name?: string; title?: string; phone?: string; email?: string; photo?: string; company?: string };
  demographics?: Array<{ radius?: number; population?: number; avgIncome?: number; medianIncome?: number; households?: number }>;
  customFields?: Record<string, any>;
}

function render(data: PropertyData): string {
  // Build and return a complete HTML document
  return `<!DOCTYPE html><html>...</html>`;
}
```

The engine transpiles TypeScript via esbuild and executes `render(data)`. The returned HTML is displayed in the preview panel and used for PDF export.

## CRITICAL: PDF Compatibility

DocRaptor/Prince does **NOT** support CSS Grid or Flexbox. Follow these rules:

- **ALL layouts must use `<table>` with `table-layout: fixed`** — no `display: grid` or `display: flex`
- Page size: 8.5in x 11in (US Letter), zero margins
- Page breaks: `page-break-before: always` or `break-before: page`
- Images: use `width: 100%; height: auto; object-fit: cover`
- Fonts: use web-safe fonts or Google Fonts via `@import`
- What you see in the preview panel is what the PDF will look like

## CRITICAL: Modification Workflow

1. **Always read** the current template before modifying (Section 3)
2. Make **targeted changes** — don't rewrite sections that don't need changing
3. Send the **COMPLETE** updated TypeScript source (not a diff/patch)
4. Include a `changeSummary` describing what changed
5. The preview refreshes automatically after update

**NEVER** guess what the template contains. Always read it first.

## Auth Headers (all requests)

```
-H "Content-Type: application/json" \
-H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
-H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

## 1. Check if Flyer Exists

Always check before creating to avoid duplicates.

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/flyer/check?propertyId={propertyId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "exists": true,
  "flyerInstanceId": "uuid",
  "version": 3,
  "documentType": "flyer"
}
```

If `exists` is true, use the returned `flyerInstanceId` to read/update. If false, create a new one.

## 2. Create Flyer

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/flyer/create" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "propertyId": "uuid",
    "projectId": "uuid",
    "documentType": "flyer"
  }'
```

Parameters:
- `propertyId` (required) — the property to create a flyer for
- `projectId` (required) — the project containing the property
- `documentType` (optional, default `"flyer"`) — `"flyer"` | `"om"` | `"brochure"`
- `templateName` (optional) — name of a saved template to use as starting point
- `conversationId` (optional) — links the flyer to the current conversation

**Note**: If a flyer already exists for the property (and no `templateName` is given), this endpoint returns the existing instance instead of creating a duplicate. It is safe to call without checking first.

Response:
```json
{
  "flyerInstanceId": "uuid",
  "version": 1,
  "type": "flyer",
  "documentType": "flyer"
}
```

The `type: "flyer"` field triggers a **live preview** in the user's browser panel.

## 3. Read Flyer Template

Read the current template before making any modifications.

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/flyer/instance?instanceId={flyerInstanceId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "flyerInstanceId": "uuid",
  "propertyId": "uuid",
  "projectId": "uuid",
  "documentType": "flyer",
  "version": 3,
  "content": "interface PropertyData { ... }\nfunction render(data: PropertyData): string { ... }",
  "imageOverrides": { "cover": "https://...", "gallery_0": "https://..." },
  "createdAt": "2026-04-09T...",
  "updatedAt": "2026-04-09T..."
}
```

The `content` field is the full TypeScript source. Read it carefully to understand the current layout before modifying.

## 4. Update Flyer Template

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/flyer/update" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "flyerInstanceId": "uuid",
    "content": "interface PropertyData { ... }\nfunction render(data: PropertyData): string { ... }",
    "changeSummary": "Updated headline font size and added broker contact section"
  }'
```

Parameters:
- `flyerInstanceId` (required) — which flyer to update
- `content` (required) — the **complete** TypeScript template source
- `changeSummary` (optional) — human-readable description of what changed (stored in version history)

Response:
```json
{
  "flyerInstanceId": "uuid",
  "version": 4,
  "type": "flyer"
}
```

The preview panel refreshes automatically. The user sees the updated design immediately.

**IMPORTANT**: The `content` must be the complete, valid TypeScript source. The server validates it by running the template — if the `render()` function fails, the update is rejected with an error.

## 5. Set Image Override

Change which image appears in a specific slot without modifying the template code.

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/flyer/image-override" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "flyerInstanceId": "uuid",
    "slot": "cover",
    "imageUrl": "https://example.com/new-cover.jpg"
  }'
```

Parameters:
- `flyerInstanceId` (required)
- `slot` (required) — `"cover"`, `"gallery_0"` through `"gallery_9"`
- `imageUrl` (optional) — the new image URL. Omit to clear the override and restore original.

Each slot is independent — changing the cover does not affect gallery images.

Response:
```json
{
  "flyerInstanceId": "uuid",
  "slot": "cover",
  "imageUrl": "https://...",
  "overrides": { "cover": "https://...", "gallery_0": "https://..." }
}
```

## 6. Undo

Revert to the previous version.

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/flyer/undo" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "flyerInstanceId": "uuid" }'
```

Response:
```json
{
  "flyerInstanceId": "uuid",
  "version": 2,
  "maxVersion": 4,
  "type": "flyer"
}
```

Returns 400 if already at version 1.

## 7. Redo

Move forward to the next version (after undo).

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/flyer/redo" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "flyerInstanceId": "uuid" }'
```

Response:
```json
{
  "flyerInstanceId": "uuid",
  "version": 3,
  "maxVersion": 4,
  "type": "flyer"
}
```

Returns 400 if already at the latest version.

## 8. List Versions

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/flyer/versions?instanceId={flyerInstanceId}" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "versions": [
    { "id": "uuid", "version": 3, "change_summary": "Updated headline", "created_at": "..." },
    { "id": "uuid", "version": 2, "change_summary": "Added photos page", "created_at": "..." },
    { "id": "uuid", "version": 1, "change_summary": null, "created_at": "..." }
  ]
}
```

## 9. Save as Template

Save the current design as a reusable template for future flyers.

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/flyer/templates" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "name": "Modern Red Banner",
    "description": "Clean layout with red accents",
    "flyerInstanceId": "uuid"
  }'
```

Parameters:
- `name` (required) — template name
- `description` (optional)
- `documentType` (optional, default `"flyer"`)
- `flyerInstanceId` (option A) — copy from an existing flyer instance
- `content` (option B) — provide TypeScript source directly

Response:
```json
{
  "template": { "id": "uuid", "name": "Modern Red Banner" }
}
```

## 10. List Templates

```bash
curl -s -X GET "$COBROKER_BASE_URL/api/flyer/templates" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET"
```

Response:
```json
{
  "templates": [
    { "id": "uuid", "name": "Modern Red Banner", "description": "...", "document_type": "flyer", "is_default": false, "version": 1 }
  ]
}
```

## 11. Export to PDF

Generate a PDF from the flyer. This can take up to 60 seconds for complex templates.

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/flyer/export-pdf" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{ "flyerInstanceId": "uuid" }' \
  -o /tmp/flyer.pdf
```

Response: Binary PDF file with `Content-Type: application/pdf`. Save to a file with `-o`.

The PDF includes the template pages plus auto-generated supplemental pages (demographics and nearby retailers) if the property has coordinates. These supplemental pages are added server-side — they are not part of the TypeScript template.

## Workflow Guidelines

1. **User wants a flyer for a property** → Check (Section 1), then Create (Section 2) if none exists, or Read (Section 3) if one does. You need the `propertyId` and `projectId` — get these from `cobroker-projects` (list projects, get details).

2. **User wants to modify the design** → Read (Section 3) the current template, make changes to the TypeScript source, Update (Section 4) with the complete new source. Always describe what you changed.

3. **User wants to change a photo** → Use Image Override (Section 5) with the appropriate slot name. Don't modify the template code for image swaps.

4. **User wants to undo a change** → Undo (Section 6). Tell them the current and max versions.

5. **User wants to save the design for reuse** → Save as Template (Section 9).

6. **User asks what templates are available** → List Templates (Section 10).

## Template Editing Tips

When modifying template TypeScript source:

- **Changing text/headings**: Find the string in the template, replace it
- **Changing colors**: Look for hex codes (#FF0000) or color names, update them
- **Changing layout**: Remember to use `<table>` layouts, not CSS Grid/Flexbox
- **Adding sections**: Follow the existing pattern — each page is wrapped in a container div with `width: 8.5in; min-height: 11in`
- **Conditional content**: Use `if (data.fieldName)` to show/hide sections based on available data
- **Number formatting**: Use helper functions like `toLocaleString()` for thousands separators
- **Safe access**: Always use optional chaining `data.broker?.name` since fields may be undefined

## Important Notes

- **Supplemental pages**: The rendered preview and PDF may include auto-generated demographics and nearby retailers pages appended after your template pages. These are injected server-side when the property has coordinates — they are NOT part of the TypeScript source you edit.
- **Compile errors**: If your template has a syntax error, the update endpoint returns `400` with `{ "error": "Template compile error: ..." }`. Read the error message, fix the TypeScript, and retry.
- **Image slots**: Slots are auto-assigned at render time — the first large image becomes `cover`, subsequent large images become `gallery_0`, `gallery_1`, etc. Google Maps images and icons (<100px) are skipped.

## Constraints

- Templates must compile as valid TypeScript
- The `render()` function must return an HTML string
- Maximum template size: ~100KB of TypeScript source
- Image URLs must be publicly accessible (HTTPS)
- PDF export uses DocRaptor — no CSS Grid, no Flexbox, tables only
- Version history is preserved — undo/redo always available
