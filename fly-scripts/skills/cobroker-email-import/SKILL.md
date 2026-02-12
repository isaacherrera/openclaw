---
name: cobroker-email-import
description: >
  Import property data from email attachments into CoBroker projects.
  User forwards emails with documents to CoBroker Gmail, then asks agent to process.
user-invocable: true
metadata:
  openclaw:
    emoji: "📧"
---

# Email Document Import

Import property documents (PDFs, spreadsheets, images) from email into CoBroker projects.

## How It Works

1. User forwards email with attachments to `isaac@flyer.io`
2. User tells agent: "check my email" / "process the docs I sent" / "import those documents"
3. Agent finds the email, downloads attachments, extracts property data, and creates a CoBroker project

## CRITICAL: Message Discipline

- **Do NOT send intermediate status messages** during extraction. Do not tell the user "still extracting", "waiting", "might be stuck", etc. Run the full workflow silently and send only ONE message with the final result.
- **Use a long timeout** (180s) for the extraction command — large PDFs take 30-90 seconds. Do not poll repeatedly.
- **NEVER use markdown tables** — Telegram doesn't render them. Use a simple numbered list instead.
- **Send exactly TWO messages** total: (1) a brief "processing..." acknowledgment, then (2) the final summary with confirm buttons.

## Step-by-Step Workflow

### 1. Find the Email

Search for recent emails with attachments:
```bash
gog gmail messages search "has:attachment newer_than:1d" --max 5 --json
```

If no results, try broader: `newer_than:3d` or `newer_than:7d`.

If multiple emails match, show the user a list and ask which one to process.

### 2. Download Attachments

Download all attachments from the thread:
```bash
gog gmail thread get <threadId> --download --out-dir /tmp/doc-import/
```

List what was downloaded:
```bash
ls -la /tmp/doc-import/
```

**Supported file types**: `.pdf`, `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`, `.csv`, `.xlsx`, `.docx`, `.txt`

**Skip**: `.html`, `.htm`, `.ics`, inline images, signature images, files under 5KB (likely icons)

### 3. Extract Data from Each Document

Run the extractor on each supported file:
```bash
cd /data/doc-extractor && node --max-old-space-size=512 extract.mjs /tmp/doc-import/filename.pdf
```

The extractor returns JSON with:
```json
{
  "_document_type": "offering memo",
  "_summary": "40-page offering memo for retail strip center...",
  "properties": [
    {
      "address": "123 Main St, Dallas, TX 75201",
      "Price": "$1,500,000",
      "Cap Rate": "6.5%",
      "Size": "10,000 SF"
    }
  ]
}
```

For multiple files, run each one and merge the results.

**Cost note**: Each extraction uses ~80-120K tokens for a 40-page PDF. Default model is Sonnet (cost-effective).

### 4. Review with User

Send ONE message with the summary as a numbered list. Example:

📄 **Office List** — 6 properties extracted

1. **Parkside Tower** — 3500 Maple Ave, Dallas, TX · 376K SF · $28-31/SF
2. **7920 Belt Line Rd** — Dallas, TX · 185K SF · $20.50/SF
3. **One Bethany West** — Allen, TX · 200K SF · $29.50/SF

Ready to create a CoBroker project with all 6?

buttons: [[{"text": "✅ Create Project", "callback_data": "import_confirm"}, {"text": "❌ Cancel", "callback_data": "import_cancel"}]]

**NEVER use markdown tables** (`| header | header |`) — they don't render in Telegram.

**NEVER auto-create a project without user confirmation.**

### 5. Create CoBroker Project

On confirmation, POST to the projects API:

```bash
curl -s -X POST "$COBROKER_BASE_URL/api/agent/openclaw/projects" \
  -H "Content-Type: application/json" \
  -H "X-Agent-User-Id: $COBROKER_AGENT_USER_ID" \
  -H "X-Agent-Secret: $COBROKER_AGENT_SECRET" \
  -d '{
    "name": "<project name from document>",
    "description": "Imported from email attachment",
    "source": "openclaw",
    "public": true,
    "properties": [
      {
        "address": "123 Main St, Dallas, TX 75201",
        "fields": {
          "Price": "$1,500,000",
          "Cap Rate": "6.5%",
          "Size": "10,000 SF"
        }
      }
    ]
  }'
```

**Field mapping rules**:
- Remove `_document_type` and `_summary` from property fields (display-only metadata)
- Remove `address` from fields (it's a top-level property field)
- All other extracted fields become CoBroker columns automatically
- Use human-readable field names as-is (e.g. "Cap Rate", not "cap_rate")

**Address validation**: Must have 3+ comma-separated parts. Reformat if needed.

### 6. Share Result

Send the project link as an inline URL button:
```
buttons: [[{"text": "📋 View Project", "url": "<publicUrl>"}]]
```

Always use `publicUrl`, never `projectUrl`.

### 7. Cleanup

```bash
rm -rf /tmp/doc-import/
```

## Constraints

- Maximum 50 properties per project
- Always confirm with user before creating project
- Never auto-process emails — wait for user instruction
- Addresses must have 3+ comma-separated parts
- Always create projects as `"public": true`
- Share links via inline keyboard URL buttons only
- If extraction fails on a file, tell the user and skip it — don't abort the whole import
- If no properties found in a document, tell the user what was found instead

## Custom Extraction

User can provide a custom prompt for extraction:
```bash
cd /data/doc-extractor && node --max-old-space-size=512 extract.mjs /tmp/doc-import/file.pdf --prompt "Extract tenant names and lease expiration dates"
```

User can also specify a different model:
```bash
cd /data/doc-extractor && node --max-old-space-size=512 extract.mjs /tmp/doc-import/file.pdf --model "claude-opus-4-6"
```
