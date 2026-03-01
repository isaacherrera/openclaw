---
name: cobroker-presentations
description: >
  Generate professional presentations from research and analysis using Gamma AI.
  Use when the user wants to export text content as slides. Also proactively offer
  after substantial research results (deep research, analytics, general Q&A).
user-invocable: true
metadata:
  openclaw:
    emoji: "🎬"
---

# Cobroker Presentations

Generate professional slide decks and documents from research results using Gamma AI.

**⚠️ CRITICAL — NO_REPLY ON EVERY TURN**: Your text output (the text you write alongside tool calls) MUST be `NO_REPLY` on EVERY turn of this skill. Do NOT write any free text — not even "On it", "Let me generate", or any acknowledgment. ALL user-facing messages must go through the `message` tool only. If you write anything other than `NO_REPLY` as your text output, it leaks as an extra Telegram message.

## 0. When to Use

**Explicit triggers:**
- "create a presentation", "make slides", "export as pptx", "generate a deck"
- "turn that into a presentation", "make a slide deck from that research"

**Proactive offering:**
After delivering a substantial text-based response (500+ words — deep research, analytics, extended Q&A), include a button in the SAME message as your results:
```
buttons: [[{"text": "🎬 Export as presentation", "callback_data": "pres_export"}]]
```

**Do NOT use for:**
- Project/table data exports (that's the web app's report feature)
- Short responses under 200 words
- Chart or numeric data (use cobroker-charts)

## 1. Content Preparation

Take the most recent substantial text output from the conversation and prepare it for Gamma:

1. **Title slide** — Prepend: `# [Topic Title]\n\n[Subtitle from research question]`
2. **Section breaks** — Insert `\n---\n` between logical sections (helps Gamma create distinct slides)
3. **Clean up** — Strip emoji, convert numbered lists to headings for slide boundaries
4. **Min/max** — Minimum 200 characters (reject shorter content with helpful message). Maximum 100,000 tokens (Gamma limit — never hit in practice)

## 2. FIRST STEP — Ask Export Format (MANDATORY)

**⚠️ CRITICAL: You MUST ask the user for their preferred format BEFORE doing anything else.**

There is NO default for `exportAs` — you cannot proceed without the user's choice.

If the user already said "pdf" or "pptx" in their message, skip to Step 0. Otherwise, your VERY FIRST action is:

```
🎬 Ready to create a presentation on **[topic]**

Settings: 5 slides · medium text · AI images
Want to adjust? Just tell me. Otherwise, pick a format:
```
```
buttons: [[{"text": "📄 PDF", "callback_data": "pres_pdf"}, {"text": "📄 PowerPoint", "callback_data": "pres_pptx"}]]
```

**STOP HERE. Do NOT run any bash commands, API calls, or pre-flight checks until the user taps a button.**

When you receive the callback:
- `pres_pdf` → `exportAs = "pdf"`
- `pres_pptx` → `exportAs = "pptx"`

Only THEN proceed to Section 3.

## 3. Customization Defaults

| Parameter | Default | Override Examples |
|-----------|---------|-------------------|
| `numCards` | 5 | "make it 15 slides" |
| `format` | "presentation" | "make it a document" → "document" |
| `exportAs` | **NO DEFAULT — must ask user (Section 2)** | user taps 📄 PDF → "pdf", user taps 📊 PowerPoint → "pptx" |
| `textMode` | "generate" | "keep exact text" → "preserve" |
| `imageOptions.source` | "aiGenerated" | "no images" → "noImages", "web images" → "webAllImages". **Brand rule:** If the user's content references a specific brand or company, use `"webAllImages"` instead so real brand imagery is pulled. |
| `textOptions.amount` | "medium" | "brief" / "detailed" / "extensive" |

## 4. API Call Pattern

The API key is available as `$GAMMA_API_KEY`. If the environment variable is missing, tell the user: "Presentation generation requires configuration. Contact your admin."

**⚠️ SILENT EXECUTION**: After the acknowledgment message (Section 5), ALL subsequent tool calls must use `NO_REPLY` as your text output. Do NOT output free text like "Let me generate..." — it will leak as a separate Telegram message.

**⚠️ URL BUTTONS**: When delivering the download link (exportUrl), use a URL button with the `url` property (NOT `callback_data`). See Section 5 Message 3 for the exact format.

### Step 0 — Pre-flight Check

Verify the API key exists:

```bash
echo "GAMMA_API_KEY=${GAMMA_API_KEY:+SET}"
```

- If output is `GAMMA_API_KEY=SET` → proceed to Step 1
- If output is `GAMMA_API_KEY=` (empty) → send the error message from Section 7 and STOP.

### Step 1 — Submit Generation (POST)

```bash
curl -s -X POST "https://public-api.gamma.app/v1.0/generations" \
  -H "X-API-KEY: $GAMMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "inputText": "<prepared content from Section 1>",
    "textMode": "generate",
    "format": "presentation",
    "numCards": 5,
    "exportAs": "<MUST be pdf or pptx from Section 2>",
    "imageOptions": { "source": "aiGenerated" },
    "textOptions": { "language": "en", "amount": "medium" }
  }'
```

Response:
```json
{ "generationId": "gen_abc123" }
```

Capture the `generationId` for polling.

### Step 2 — Poll for Completion (Single Exec)

Use a single Node.js exec that polls internally at 5-second intervals. This avoids 60+ separate tool calls.

**All output must be `NO_REPLY`** — the user should not see polling activity.

```bash
node -e '
const id = process.argv[1];
const key = process.env.GAMMA_API_KEY;
const maxPolls = 60; // 5 min max
let polls = 0;
const poll = async () => {
  while (polls < maxPolls) {
    polls++;
    const r = await fetch(`https://public-api.gamma.app/v1.0/generations/${id}`, {
      headers: { "X-API-KEY": key }
    });
    const d = await r.json();
    if (d.status === "completed") {
      console.log(JSON.stringify({ status: "completed", gammaUrl: d.gammaUrl, exportUrl: d.exportUrl, numCards: d.numCards }));
      return;
    }
    if (d.status === "failed") {
      console.log(JSON.stringify({ status: "failed", error: d.error || "Unknown error" }));
      return;
    }
    await new Promise(ok => setTimeout(ok, 5000));
  }
  console.log(JSON.stringify({ status: "timeout" }));
};
poll().catch(e => console.log(JSON.stringify({ status: "error", error: e.message })));
' "GEN_ID_HERE"
```

Parse the JSON output to get `gammaUrl` and `exportUrl`.

## 5. User Messaging (2-3 Messages)

### Message 1 — Format Choice (Section 2 — already sent before reaching here)

This was already handled in Section 2. Do not send it again.

### Message 2 — Generating (after user taps a format button)

```
🎬 Creating your [PDF/PowerPoint] on **[topic]**... This usually takes 1-3 minutes.
```

### Message 3 — Results (after polling completes)

```
🎬 **[Topic]**

[N] slides · [PDF/PPTX]
```
```
buttons: [[{"text": "📥 Download", "url": "<exportUrl>"}]]
```

- Use `url` (not `callback_data`) on the download button — opens the file directly
- Do NOT include a "View Online" button — the Gamma viewer requires login
- No intermediate "still working..." messages

## 6. Callback Handling

| Callback | Action |
|----------|--------|
| `pres_export` | Start the presentation flow (Section 2 — ask format) |
| `pres_pdf` | Set `exportAs: "pdf"`, proceed to Section 5 Message 2 (ack) then generate |
| `pres_pptx` | Set `exportAs: "pptx"`, proceed to Section 5 Message 2 (ack) then generate |

## 7. Error Handling

| Condition | Response |
|-----------|----------|
| Missing `$GAMMA_API_KEY` | "Presentation generation requires configuration. Contact your admin." |
| 401/403 from API | Same as missing key message |
| 429 (rate limit) | "Rate-limited right now. Try again in a few minutes." |
| `status: "failed"` | Retry once with `textMode: "condense"` and `numCards` reduced by 2. If still fails: "The presentation couldn't be generated. Try with shorter content or fewer slides." |
| Timeout (5 min) | "Taking longer than expected. Try again shortly." |
| Content < 200 chars | "Not enough content for a presentation. Run some research first, then I can export it as slides." |

## 8. Constraints

- Max input: 100,000 tokens; min: 200 characters
- Slide count: 1-60 (default 5, suggest 5-15 for research)
- `NO_REPLY` during all polling
- No markdown tables in Telegram output
- Max 4 user-facing messages per generation (settings/format from Section 2 + optional settings adjustment + ack + result; or 2-3 if format specified in user's message)
- This skill does NOT interact with CoBroker projects API — purely text content

## 9. Plan Integration

When used as a step in cobroker-plan, this skill is the `presentation` step type.

- **Position:** Always last — depends on text output from prior research/analysis steps
- **Async:** 1-3 minutes
- **Example plan step:** `6. Export analysis as 12-slide presentation — presentation`
