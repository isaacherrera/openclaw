---
name: fly-agent
description: >
  Manage Fly.io tenant VMs for the CoBroker platform. Start, stop, restart,
  check status, view logs, update configs, manage secrets, and deploy images.
  Use when the user mentions tenant VMs, says "check tenants", "restart VM",
  "VM status", "deploy to tenants", "update config", or references
  cobroker-tenant-*.
user-invocable: true
metadata:
  openclaw:
    emoji: "🖥️"
---

# Fly.io Tenant VM Management

Manage the CoBroker tenant VM fleet on Fly.io — status, lifecycle, config, secrets, deploys.

## CRITICAL: Safety Rules

> **`cobroker-openclaw` is Isaac's personal VM — NOT a tenant.**
> NEVER stop, destroy, clear sessions, update config, or deploy to `cobroker-openclaw` unless Isaac explicitly names it.
> Read-only operations (status, logs) on the primary are fine.
>
> When the user says "all tenants" or "all VMs", this means the **pool** (cobroker-tenant-008 through cobroker-tenant-012), NOT the primary.
>
> **Confirm before mutating**: stop, destroy, restart, clear sessions, update config, set secrets, deploy.
> Use inline keyboard buttons for confirmation:
> ```
> buttons: [[{"text": "✅ Confirm", "callback_data": "confirm"}, {"text": "❌ Cancel", "callback_data": "cancel"}]]
> ```
> Wait for the user to press Confirm before executing. If they press Cancel or say "no", abort.
>
> **Read-only operations execute immediately** — no confirmation needed.

## CRITICAL: Message Formatting

- **Never use markdown tables** in Telegram — they render as monospace garbage.
- Use simple numbered lists or bullet points for multi-tenant output.
- Keep status lines compact: `tenant-008: ✅ running (iad) — v2026.2.21`
- Use code blocks only for JSON/config output, not for status summaries.

## 0. Prerequisites

All requests require `FLY_API_TOKEN` set as an environment variable.

### API Base URL

From inside a Fly machine, use the internal API for low-latency access:

```
FLY_API_BASE="http://_api.internal:4280/v1"
```

If internal fails (timeout/connection refused), fall back to external:

```
FLY_API_BASE="https://api.machines.dev/v1"
```

### Auth Header (all requests)

```
-H "Authorization: Bearer $FLY_API_TOKEN"
```

### Tenant App Naming

All tenant apps follow the pattern: `cobroker-tenant-NNN` (e.g., `cobroker-tenant-008`).

When the user says "tenant 8" or "tenant-008" or "VM 8", resolve to `cobroker-tenant-008`.

### Current Tenant Pool

- cobroker-tenant-008
- cobroker-tenant-009
- cobroker-tenant-010
- cobroker-tenant-011
- cobroker-tenant-012

## 1. List All Tenant VMs

When the user says "list tenants", "show VMs", "tenant status", or "check tenants":

```bash
for APP in cobroker-tenant-008 cobroker-tenant-009 cobroker-tenant-010 cobroker-tenant-011 cobroker-tenant-012; do
  curl -s "$FLY_API_BASE/apps/$APP/machines" \
    -H "Authorization: Bearer $FLY_API_TOKEN"
done
```

Each response returns an array of machine objects. Extract from each:
- `id` — machine ID
- `state` — "started", "stopped", "created", "destroyed"
- `region` — e.g., "iad"
- `config.image` — deployed image tag
- `config.metadata.fly_process_group` — should be "app"

Format response as a compact list:

```
🖥️ Tenant Fleet Status

1. tenant-008: ✅ running (iad) — d8964e5be92e48
2. tenant-009: ✅ running (iad) — d8d4e22b712e08
3. tenant-010: ✅ running (iad) — 28601e2f6563d8
4. tenant-011: ⏹️ stopped (iad) — 6839497b4161d8
5. tenant-012: ✅ running (iad) — 1859436f5ed718

4/5 running
```

Use ✅ for "started", ⏹️ for "stopped", ⚠️ for any other state.

## 2. Get Single VM Status

When the user asks about a specific tenant:

```bash
curl -s "$FLY_API_BASE/apps/{app}/machines" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

Show detailed info:

```
🖥️ tenant-008 Details

- State: ✅ running
- Machine: d8964e5be92e48
- Region: iad
- Image: registry.fly.io/cobroker-openclaw:deployment-...
- CPUs: 1 (shared)
- Memory: 512 MB
- Created: 2026-02-19
```

## 3. VM Lifecycle — Start

**Requires confirmation.**

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}/start" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

After starting, wait for the machine to reach "started" state:

```bash
curl -s "$FLY_API_BASE/apps/{app}/machines/{machine_id}/wait?state=started&timeout=30" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

Report: "✅ tenant-008 started successfully"

If wait times out (30s), report: "⚠️ tenant-008 start initiated but not yet confirmed — check again in a moment"

## 4. VM Lifecycle — Stop

**Requires confirmation.**

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}/stop" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

Wait for stopped state:

```bash
curl -s "$FLY_API_BASE/apps/{app}/machines/{machine_id}/wait?state=stopped&timeout=30" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

Report: "⏹️ tenant-008 stopped"

## 5. VM Lifecycle — Restart

**Requires confirmation.**

Stop the machine (Section 4), wait for stopped, then start it (Section 3), wait for started.

Report: "🔄 tenant-008 restarted successfully"

## 6. Batch Operations

When the user says "restart all tenants", "stop all VMs", etc.:

1. Confirm the full list: "I'll restart these 5 tenants: tenant-008, -009, -010, -011, -012. Confirm?"
2. On confirmation, execute sequentially (not parallel) to avoid API rate limits.
3. Report each result as it completes.
4. End with a summary: "✅ 5/5 tenants restarted"

## 7. View Logs

Use `flyctl` CLI for logs (REST API doesn't have a clean logs endpoint):

```bash
flyctl logs -a {app} --no-tail -n 50
```

Show the last 50 lines. If the user asks for more, increase `-n`.

For filtered logs (e.g., "show errors"):

```bash
flyctl logs -a {app} --no-tail -n 100 | grep -i "error\|warn\|fatal"
```

## 8. Read Tenant Config

Execute a command on the tenant machine to read openclaw.json:

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}/exec" \
  -H "Authorization: Bearer $FLY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"cmd": ["cat", "/data/openclaw.json"]}'
```

The response has `stdout` (base64-encoded) and `exit_code`. Decode stdout:

```bash
echo "<base64_stdout>" | base64 -d
```

Show the JSON config to the user in a code block. Redact any values that look like secrets or tokens.

## 9. Update Tenant Config

**Requires confirmation.**

When the user wants to modify a tenant's openclaw.json (e.g., "add user X to tenant-008's allowFrom"):

### Step 1 — Read current config (Section 8)

### Step 2 — Show the proposed change

Tell the user exactly what will change:
```
I'll update tenant-008's openclaw.json:

channels.telegram.allowFrom:
  Before: ["*"]
  After: ["*", "username123"]

Confirm?
```

### Step 3 — Write updated config

Use exec to write the file:

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}/exec" \
  -H "Authorization: Bearer $FLY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"cmd": ["sh", "-c", "echo '\''<escaped_json>'\'' > /data/openclaw.json && chown node:node /data/openclaw.json"]}'
```

### Step 4 — Restart the tenant (Section 5) to apply changes

### Step 5 — Verify by re-reading config (Section 8)

## 10. List Skills on a Tenant

Execute on the tenant:

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}/exec" \
  -H "Authorization: Bearer $FLY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"cmd": ["sh", "-c", "ls -1 /data/skills/"]}'
```

Show as a simple list with the skill count.

## 11. Clear Sessions

**Requires confirmation.**

Clearing sessions forces the gateway to re-snapshot skills on next message. This is low-risk — sessions auto-reset daily at 4am ET anyway.

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}/exec" \
  -H "Authorization: Bearer $FLY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"cmd": ["sh", "-c", "rm -rf /data/agents/main/sessions/* && echo done"]}'
```

After clearing, restart the tenant (Section 5) so the gateway picks up fresh skills.

Report: "🗑️ Sessions cleared and tenant-008 restarted — skills will re-snapshot on next message"

## 12. List Secrets

Use `flyctl` CLI (secrets are not available via REST API):

```bash
flyctl secrets list -a {app}
```

This shows secret **names** and digest info — never the actual values.

Format as a simple list:

```
🔐 tenant-008 Secrets

1. ANTHROPIC_API_KEY (set 2026-02-19)
2. TELEGRAM_BOT_TOKEN (set 2026-02-19)
3. OPENCLAW_GATEWAY_TOKEN (set 2026-02-19)
...

6 secrets configured
```

## 13. Set Secrets

**Requires confirmation.**

```bash
flyctl secrets set KEY=value -a {app}
```

This automatically triggers a machine restart. Wait 10-15 seconds after setting, then verify the tenant is running (Section 2).

Report: "🔐 Secret KEY set on tenant-008 — machine restarted automatically"

**NEVER echo or log secret values.** Only confirm the key name was set.

## 14. Deploy / Update Image

**Requires confirmation.**

To update a tenant to a new image (usually the primary's latest):

### Step 1 — Get the primary's current image tag

```bash
curl -s "$FLY_API_BASE/apps/cobroker-openclaw/machines" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

Extract `config.image` from the response.

### Step 2 — Confirm with the user

```
I'll update tenant-008 to image:
registry.fly.io/cobroker-openclaw:deployment-01KJ0XSCNQ2ZNQHYJZHCGY21A6

This will restart the tenant. Confirm?
```

### Step 3 — Update the machine config

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}" \
  -H "Authorization: Bearer $FLY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "image": "<new_image_tag>",
      "auto_destroy": false
    }
  }'
```

**Important**: The update endpoint does a full config replace. You must include the complete machine config, not just the image. First GET the current machine config, then modify only the `image` field and POST back the full config.

### Step 4 — Wait for the machine to be running

```bash
curl -s "$FLY_API_BASE/apps/{app}/machines/{machine_id}/wait?state=started&timeout=60" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

Report: "🚀 tenant-008 updated to <image_tag> and running"

### Batch Deploy

When user says "deploy to all tenants" or "update all VMs":

1. Get the primary's image tag
2. Confirm: "I'll deploy <image> to all 5 tenants. This will restart each one sequentially."
3. Execute one at a time, reporting each result
4. Summary: "🚀 5/5 tenants updated to <image_tag>"

## 15. Destroy Tenant

**Requires explicit confirmation with the app name.**

This is a high-risk operation. Ask the user to type the full app name to confirm:

"⚠️ This will permanently destroy cobroker-tenant-008 and its volume. Type the full app name to confirm: `cobroker-tenant-008`"

### Step 1 — Stop the machine (Section 4)

### Step 2 — Delete the app

```bash
flyctl apps destroy {app} --yes
```

Or via API:

```bash
curl -s -X DELETE "$FLY_API_BASE/apps/{app}" \
  -H "Authorization: Bearer $FLY_API_TOKEN"
```

### Step 3 — Remind about Supabase cleanup

After destroying, remind the user:

"🗑️ cobroker-tenant-008 destroyed. Remember to clean up Supabase records:
- openclaw_logs (tenant_id = 'tenant-008')
- Any other tables referencing this tenant"

Do NOT perform Supabase cleanup automatically — just remind.

## 16. Batch Health Check

When the user says "health check", "are tenants healthy", "check all VMs":

1. List all tenants (Section 1)
2. For each running tenant, exec a quick health probe:

```bash
curl -s -X POST "$FLY_API_BASE/apps/{app}/machines/{machine_id}/exec" \
  -H "Authorization: Bearer $FLY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"cmd": ["sh", "-c", "cat /data/openclaw.json | head -c 1 && echo ok"]}'
```

This verifies the volume is mounted and the config file is readable.

3. Report:

```
🏥 Tenant Health Check

1. tenant-008: ✅ running, config readable
2. tenant-009: ✅ running, config readable
3. tenant-010: ✅ running, config readable
4. tenant-011: ⏹️ stopped (skipped)
5. tenant-012: ✅ running, config readable

4/5 healthy, 1 stopped
```

## 17. Trigger Patterns

Use this skill when the user says things like:

- "Check tenants" / "tenant status" / "VM status" → Section 1
- "How is tenant-008?" / "status of VM 10" → Section 2
- "Start tenant-008" / "wake up VM 8" → Section 3
- "Stop tenant-008" / "shut down VM 10" → Section 4
- "Restart tenant-008" / "reboot all tenants" → Section 5/6
- "Show logs for tenant-008" → Section 7
- "Show tenant-008's config" / "read openclaw.json" → Section 8
- "Update config on tenant-008" / "add user to allowFrom" → Section 9
- "What skills does tenant-008 have?" → Section 10
- "Clear sessions on tenant-008" → Section 11
- "What secrets are on tenant-008?" → Section 12
- "Set BRAVE_API_KEY on tenant-008" → Section 13
- "Deploy latest to tenant-008" / "update all VMs" → Section 14
- "Destroy tenant-008" → Section 15
- "Health check" / "are tenants ok?" → Section 16

## 18. Error Handling

- If `FLY_API_TOKEN` is not set, tell the user: "I need the FLY_API_TOKEN secret to manage Fly VMs. Ask Isaac to set it."
- If the internal API (`_api.internal`) times out, retry once with the external API (`api.machines.dev`).
- If a machine operation fails, show the error message from the API response and suggest next steps.
- If `flyctl` is not found at `/data/bin/flyctl`, tell the user it needs to be installed.
- Never retry a failed mutating operation automatically — report the failure and let the user decide.
