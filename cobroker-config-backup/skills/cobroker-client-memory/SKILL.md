---
name: cobroker-client-memory
description: >
  Remember and manage broker client profiles and their property search criteria.
  Use when the user tells you about a client, their requirements, preferences,
  or when you need to recall what a specific client is looking for.
  Also use when the user says "remember", "my client", "save this criteria",
  or mentions a client by name.
user-invocable: true
metadata:
  openclaw:
    emoji: "🧠"
---

# Cobroker Client Memory

**⚠️ MESSAGE DELIVERY RULE — MANDATORY**
When you call ANY tool, your text output MUST be exactly `___` (three underscores) and nothing else.
The gateway filters `___` automatically — any other text gets delivered as a duplicate message.
ALL user-facing communication goes through `message` tool calls. NEVER narrate alongside tool calls.

## Purpose
You are a broker's AI analyst. Brokers have multiple clients, each with specific
property requirements. Remember every client and their criteria so you can
proactively search and alert when matches are found.

## Storage
Client data is stored in `/data/workspace/MEMORY.md`.

**IMPORTANT — Handle missing file gracefully:**
Before reading MEMORY.md, use `exec` to check if it exists: `test -f /data/workspace/MEMORY.md && cat /data/workspace/MEMORY.md || echo "# Memory"`.
Do NOT use the `read` tool directly — if the file does not exist, the read error gets surfaced to the user.
If the file is empty or missing, treat it as a blank slate and create it on first write.

## Client Profile Format (store in MEMORY.md)
## Client: [Name]
- Company: [company]
- Property Type: [warehouse/retail/office/industrial/land]
- Markets: [cities/regions]
- Size Range: [min-max SF]
- Budget: [max PSF or total]
- Special Requirements: [dock doors, ceiling height, etc.]
- Timeline: [when they need to close]
- Status: [active/paused/closed]
- Last Search: [date]
- Notes: [other context]

## Workflow
1. When user mentions a client, check MEMORY.md for existing profile (use exec, not read)
2. If new: create entry, confirm details with user
3. If existing: update with new information
4. Always confirm: "I've noted that [Client] needs [summary]"

## Constraints
- Always confirm before storing
- Ask clarifying questions if vague
- Never share one client's info when discussing another
