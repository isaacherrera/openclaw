---
name: cobroker-deep-research
description: >
  Strategic market research using Parallel AI Deep Research (ultra processor).
  Use for expansion planning, competitive intelligence, location strategy, and
  market analysis. NOT for finding properties (use cobroker-search) or locating
  existing businesses (use cobroker-projects places-search).
user-invocable: true
metadata:
  openclaw:
    emoji: "🔬"
---

# Cobroker Deep Research

Strategic market research powered by Parallel AI's Task API with the `ultra` processor (Deep Research mode). Returns comprehensive multi-page markdown reports from extensive web research.

## 0. When to Use

Use this skill for **strategic questions requiring synthesis across multiple data sources**:

- **Expansion planning** — "Where should TopGolf expand next in the Midwest?"
- **Competitive landscape** — "Who are the main competitors for cold storage in Dallas?"
- **Market analysis** — "What's the outlook for flex industrial space in Austin?"
- **Site selection rationale** — "What factors make a location ideal for a drive-thru coffee shop?"
- **Industry intelligence** — "What are the trends in coworking space demand post-2024?"

**Do NOT use for:**
- Finding specific properties for sale/lease → use `cobroker-search`
- Locating existing businesses/chains → use `cobroker-projects` places-search (Section 13)
- Adding demographics to a project → use `cobroker-projects` demographics (Section 9)
- Quick factual lookups → use Gemini research (cobroker-plan Section 0)

**Usage modes:**
- **Standalone** — User asks a self-contained strategic question directly. Run the research immediately.
- **Plan step** — Used as the final `deep-research` step inside cobroker-plan, after places-search and demographics have gathered data. The agent compiles all prior step results into the research query.

If the question needs prior data gathering (places, demographics) before research makes sense, use cobroker-plan to orchestrate the full workflow instead of running standalone.

## 1. Research Query Construction

Before calling the API, compile a rich research query from available context. The query should give the ultra processor enough context to produce a targeted, actionable report.

### Query Template

```
RESEARCH OBJECTIVE:
[What the user wants to know — be specific about the business decision]

EXISTING LOCATION CONTEXT:
[If places-search was run: list locations found, addresses, ratings]
[If no prior data: state what's known about the brand/business]

DEMOGRAPHIC DATA:
[If demographics were gathered: population, income, home values by location]
[If none: skip this section]

BUSINESS CONTEXT:
[Industry, business model, target customer, typical site requirements]
[Company background if known from prior Gemini research]

SPECIFIC QUESTIONS TO ADDRESS:
1. [First specific question]
2. [Second specific question]
3. [Third specific question]

DESIRED OUTPUT FORMAT:
Provide a strategic analysis with:
- Key market findings with data points
- Top 3-5 actionable recommendations ranked by priority
- Risk factors and considerations
- Competitive landscape summary
```

### Guidelines

- **Max input length:** 15,000 characters. Trim verbose demographic tables — summarize key metrics instead.
- **Be specific:** "Where should TopGolf expand in the Chicago metro area given their current locations at X, Y, Z?" beats "Where should TopGolf expand?"
- **Include data:** If prior steps gathered places or demographics, include the key numbers. The ultra processor synthesizes better with concrete data.
- **Frame the decision:** Always state what business decision this research supports.

## 2. API Call Pattern

### Environment

The API key is available as `$PARALLEL_AI_API_KEY`. If the environment variable is missing, tell the user: "Deep research requires a Parallel AI API key. Please contact your admin to configure it."

### Step 1 — Submit Task

```bash
curl -s -X POST "https://api.parallel.ai/v1/tasks/runs" \
  -H "x-api-key: $PARALLEL_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "input": "<research query from Section 1>",
    "processor": "ultra",
    "task_spec": { "output_schema": { "type": "text" } }
  }'
```

Response:
```json
{ "run_id": "trun_abc123", "status": "running" }
```

Capture the `run_id` for polling.

### Step 2 — Poll for Completion (Silent)

Poll the task status. **All polling must use `NO_REPLY`** — do not message the user during polling.

```bash
curl -s -X GET "https://api.parallel.ai/v1/tasks/runs/{run_id}" \
  -H "x-api-key: $PARALLEL_AI_API_KEY"
```

Response:
```json
{ "run_id": "trun_abc123", "status": "running" }
```

**Polling rules:**
- Poll every ~30 seconds
- Maximum **40 polls** for ultra (~20 minutes)
- Status values: `running` → keep polling, `completed` → get results, `failed` → report error
- **Output `NO_REPLY`** with every poll tool call — the user should not see polling activity

### Step 3 — Get Results

Once status is `completed`:

```bash
curl -s -X GET "https://api.parallel.ai/v1/tasks/runs/{run_id}/result" \
  -H "x-api-key: $PARALLEL_AI_API_KEY"
```

Response:
```json
{
  "output": {
    "content": "# Market Analysis: TopGolf Expansion...\n\n## Executive Summary\n...",
    "basis": [
      { "url": "https://...", "title": "..." },
      ...
    ]
  }
}
```

The `content` field contains the full markdown report. The `basis` array contains source URLs.

## 3. User Messaging

Send **exactly 2 messages** to the user for the entire research flow:

### Message 1 — Acknowledgment (immediately after submitting)

```
🔬 Running deep research on **[topic summary]**... This may take 5-25 minutes. I'll notify you when results are ready.
```

Examples:
- "🔬 Running deep research on **TopGolf expansion opportunities in Chicago**... This may take 5-25 minutes. I'll notify you when results are ready."
- "🔬 Running deep research on **cold storage competitive landscape in DFW**... This may take 5-25 minutes. I'll notify you when results are ready."

### Message 2 — Results summary (after polling completes)

The summarized report (see Section 4). This is the only other message.

**No intermediate messages.** No "still working..." updates. No progress bars. The acknowledgment sets expectations; the summary delivers results.

## 4. Result Summarization

The raw report from ultra can be 2,000-5,000+ words. **Never paste the raw report into Telegram.** Always summarize into a concise, actionable format.

### Summary Format (500-800 words max)

```
🔬 Deep Research Complete: **[Topic]**

**Key Findings:**
1. [Most important finding with a specific data point]
2. [Second finding]
3. [Third finding]
4. [Fourth finding if significant]

**Top Recommendations:**
1. [Highest-priority recommendation with reasoning]
2. [Second recommendation]
3. [Third recommendation]

**Risk Factors:**
- [Key risk or consideration]
- [Another risk]
- [Market uncertainty or caveat]

Based on [N] sources analyzed.
```

### Summarization Rules

- **Lead with insights, not process.** Don't say "The research found that..." — just state the finding.
- **Include specific numbers.** "Population within 3 miles is 180,000" not "The area is densely populated."
- **Rank recommendations.** Put the strongest recommendation first.
- **No markdown tables** — Telegram renders them poorly. Use numbered/bulleted lists.
- **No follow-up buttons** — Let the user ask for next steps manually.
- **Cite source count** — "Based on 23 sources analyzed" gives credibility without listing URLs.

## 5. Plan Integration

When used as a step in cobroker-plan, this skill is the `deep-research` step type.

### Typical Plan Position

Deep research is typically the **last step** in a plan because:
1. It takes the longest (5-25 min async)
2. It produces better results when fed data from prior steps
3. The user sees faster steps complete first, maintaining engagement

### Data Handoff

When executing as a plan step, the agent should:
1. Gather results from all prior steps (places found, demographics collected, enrichment data)
2. Compile these into the research query (Section 1 template)
3. Submit the task and poll silently
4. Include the summary in the plan's final completion message

### Example Plan with Deep Research

```
📝 Plan: TopGolf Midwest Expansion Analysis

I'll find TopGolf's current Midwest locations, analyze the demographics, then run a strategic expansion analysis.

Steps:
1. Find TopGolf locations in IL, IN, WI, MI, OH — places-search
2. Add to new project "TopGolf Midwest" — create-project + add-properties
3. Add Population (5 mi radius) — demographics
4. Add Median Household Income (5 mi radius) — demographics
5. Run deep research: Midwest expansion opportunities — deep-research

Note: Step 5 runs async (5-25 min). Steps 1-4 complete first.

Reply "go" to execute, or tell me what to change.
```

## 6. Error Handling

### Missing API Key

If `$PARALLEL_AI_API_KEY` is not set or the submit call returns a 401/403:
```
I can't run deep research right now — the Parallel AI API key isn't configured. I can still help with property search, demographics, and enrichment. Want me to proceed with those instead?
```

### Rate Limit (429)

```
Deep research is temporarily rate-limited. I'll retry in a few minutes, or you can ask me again shortly.
```

Wait 60 seconds, then retry once. If still rate-limited, inform the user.

### Task Failed

If polling returns `status: "failed"`:
```
The deep research task encountered an error. Let me try rephrasing the query and submitting again.
```

Retry once with a simplified query. If it fails again, tell the user and suggest alternative approaches.

### Timeout

If 40 polls complete without `completed` status:
- Run 10 additional polls (~5 more minutes)
- If still not done:
```
The deep research is taking longer than usual. It's still processing — I'll check back. You can also ask me "check research status" in a few minutes.
```

Store the `run_id` so the agent can check status if the user asks later.

### Empty Results

If the result content is empty or under 100 characters:
```
The research completed but returned minimal results. The topic may be too niche or specific. Would you like me to try with a broader query?
```

## 7. Constraints

- **15,000 character input max** — Trim the research query if it exceeds this. Summarize verbose data rather than truncating mid-sentence.
- **Never fabricate results** — Only report what the ultra processor returns. If the report doesn't address a question, say so.
- **Always summarize** — Never paste the raw markdown report into chat. Always use the Section 4 format.
- **Always use `ultra` processor** — This skill is specifically for deep, comprehensive research. There is no "light" mode.
- **One task at a time** — Do not submit multiple concurrent deep research tasks. Complete or cancel one before starting another.
- **No raw source URLs** — Don't list individual source URLs in the summary. Just cite the count ("Based on N sources").
