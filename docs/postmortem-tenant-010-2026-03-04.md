# Post-Mortem: Tenant-010 Cascade Failure

**Date:** 2026-03-04
**Severity:** Critical (fleet-wide)
**Affected:** 8 of 10 machines at 100% disk, 2 partially affected
**Duration:** ~27 hours (started 2026-03-03 ~16:00 UTC, discovered 2026-03-04 ~18:52 UTC)
**User impact:** 1 beta user session disrupted (ENOSPC on chart generation, session lock during polling)

---

## 1. Executive Summary

A heartbeat timeout value of `525600m` (365 days in minutes) overflowed Node.js's 32-bit signed integer limit for `setTimeout`, causing the timer to fire every 1ms instead of never. This generated continuous `TimeoutOverflowWarning` log lines at ~280 MB/hour, filling the 7.8 GB disk on 8 of 10 fleet machines within ~27 hours. The single active beta session on tenant-010 compounded the damage: the deep research polling pattern used prohibited shell constructs (`for` loops, `while true`, `jq`), locking the user's session for 20+ minutes per query and wasting API spend on a duplicate research run. The agent self-healed the disk on tenant-010 by truncating the log file, but the remaining 7 full-disk machines require manual remediation.

---

## 1a. Discovery Timeline

**How we found it** — Isaac's live monitoring session (~18:49–18:56 UTC):

1. **18:49 UTC** — Isaac opened the admin control UI and noticed the agent claimed "nothing running" while the user's research was actively polling
2. **18:52 UTC** — Checked `fly logs` and found wall-to-wall `TimeoutOverflowWarning` spam (25+ per second)
3. **18:54 UTC** — Discovered the overflow → disk full → polling cascade: the heartbeat overflow filled disks, which caused ENOSPC errors during the user's active session, triggering the agent's self-heal and exposing the fragile polling patterns
4. **~19:00 UTC** — Triggered the formal fleet-wide investigation, capturing the status snapshot in §2

---

## 2. Fleet Status Snapshot

Captured at ~19:01 UTC, 2026-03-04.

| Machine | Overflow Warnings* | Disk Used | Disk Avail | Use% | Log File Size | HEARTBEAT.md | Heartbeat Config |
|---|---|---|---|---|---|---|---|
| cobroker-openclaw (primary) | 58 | 7.8 GB | 0 | **100%** | 7.8 GB | MISSING | `525600m` |
| cobroker-tenant-008 | 95 | 7.8 GB | 0 | **100%** | 7.8 GB | MISSING | `525600m` |
| cobroker-tenant-009 | 50 | 7.8 GB | 0 | **100%** | 7.8 GB | EXISTS | `525600m` |
| cobroker-tenant-010 | 54 | 491 MB | 6.9 GB | **7%** | 452 MB | EXISTS | `525600m` |
| cobroker-tenant-011 | 50 | 7.8 GB | 0 | **100%** | 7.8 GB | MISSING | `525600m` |
| cobroker-tenant-012 | 54 | 7.8 GB | 0 | **100%** | 7.8 GB | EXISTS | `525600m` |
| cobroker-tenant-013 | 50 | 5.4 GB | 2.0 GB | **74%** | 5.4 GB | EXISTS | `525600m` |
| cobroker-tenant-014 | 91 | 7.8 GB | 0 | **100%** | 7.8 GB | EXISTS | `525600m` |
| cobroker-tenant-015 | 51 | 7.8 GB | 0 | **100%** | 7.8 GB | EXISTS | `525600m` |
| cobroker-tenant-016 | 50 | 7.8 GB | 0 | **100%** | 7.8 GB | EXISTS | `525600m` |

\* Warning counts from `fly logs` buffer (last ~100 lines). Actual totals are in the millions.

Tenant-010 shows 7% because the agent self-healed at 18:01:31 UTC by truncating the log (went from 100% to 1%), then the log grew back to 452 MB over the next hour from continued overflow spam.

---

## 3. Issue-by-Issue Breakdown (9 issues total)

### Issue 1 — Heartbeat Timeout Overflow (ROOT CAUSE)

**Symptom:** Every machine emitting `TimeoutOverflowWarning` continuously (multiple per second).

**Root Cause:** The heartbeat config `"every": "525600m"` converts to 31,536,000,000 ms, which exceeds the 32-bit signed integer maximum (2,147,483,647). Node.js clamps overflowed timeouts to 1ms per the [Node.js docs](https://nodejs.org/api/timers.html#settimeoutcallback-delay-args), causing the heartbeat to fire continuously instead of never.

**Evidence:**
```
(node:665) TimeoutOverflowWarning: 31535919790 does not fit into a 32-bit signed integer.
Timeout duration was set to 1.
```

The value counts down from 31,536,000,000 (e.g., `31535919790`, `31535919784`, `31535919777`) — each emission shows the remaining time. At 18:52:09 UTC, 25+ warnings fired within a single second.

**Math:** `525600 minutes × 60,000 ms/min = 31,536,000,000 ms`. Max 32-bit signed int = `2,147,483,647`. Configured value is **14.7x larger** than the max.

**Impact:** Every heartbeat fire generates a log line. At ~1000/sec, this produces ~280 MB/hour of log output, filling 7.8 GB disks in ~27 hours.

**Recommended Fix:** Change `openclaw.json` on all 10 machines:
```json
"heartbeat": {
  "every": "35000m"
}
```
`35000m` = 2,100,000,000 ms — fits in 32-bit signed int (max 2,147,483,647). Effectively disabled (~24.3 days).

**Critical constraint:** `heartbeat: null` is NOT valid — Zod validation rejects it and the gateway exits with code 1. Must use a valid object with a safe value.

**Files to change:** `/data/openclaw.json` on all 10 machines.

---

### Issue 2 — Disk Full (7.8 GB Log File / ENOSPC)

**Symptom:** 8 of 10 machines at 100% disk usage. Agent receives `ENOSPC: no space left on device, write` when attempting file operations.

**Root Cause:** The overflow warnings from Issue 1 wrote continuously to `/tmp/openclaw/openclaw-2026-03-03.log`, growing at ~280 MB/hour until the 7.8 GB volume filled completely.

**Evidence (tenant-010 before self-heal):**
```
$ df -h /
none    7.8G  7.8G    0  100%  /

$ du -sh /tmp/openclaw
7.8G  /tmp/openclaw

$ ls -lah /tmp/openclaw/openclaw-2026-03-03.log
7.8G  openclaw-2026-03-03.log
```

After agent truncated the log at 18:01:31 UTC:
```
$ df -h /
none    7.8G   42M  7.4G    1%  /
```

**Impact:**
- Agent could not generate charts (`ENOSPC` on write)
- Log forwarder could not write cursor file
- Gateway could not create new session files
- 8 machines remain at 100% — all agent operations blocked

**Recommended Fix:** Add log cleanup to `fly-scripts/start.sh`, inserted before the log-forwarder starts:

```sh
# Clean up rolling logs to prevent disk-full.
# Gateway debug/info logs in /tmp/openclaw — NOT the session JSONL used by log-forwarder.
if [ -d /tmp/openclaw ]; then
  find /tmp/openclaw -name "openclaw-*.log" -mtime +0 -delete 2>/dev/null || true
  for f in /tmp/openclaw/openclaw-*.log; do
    [ -f "$f" ] || continue
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$size" -gt 524288000 ]; then
      echo "[start.sh] Truncating oversized log: $f (${size} bytes)"
      : > "$f"
    fi
  done
fi
```

This deletes logs older than 24 hours and truncates any log exceeding 500 MB at startup.

**Note:** The gateway logger (`src/logging/logger.ts`) only deletes files >24hr old at initialization — it has no max file size enforcement. The `start.sh` cleanup is a defense-in-depth measure.

**Files to change:** `fly-scripts/start.sh` (repo) + `/data/start.sh` on all 10 machines.

---

### Issue 3 — Deep Research Polling Fragility

**Symptom:** Agent used prohibited shell constructs to poll the Parallel AI API, locking the user's session for 20+ minutes per research query. Three distinct prohibited patterns observed.

**Root Cause:** The SKILL.md polling instructions (Section 2, Step 2) say "poll every ~30 seconds" but don't specify *how*. The agent improvised with shell loops, which block the entire session.

**Evidence — Pattern 1: `for` loop with `jq` (17:49:36 UTC):**
```bash
for i in $(seq 1 40); do
  sleep 30;
  result=$(curl -s -X GET "https://api.parallel.ai/v1/tasks/runs/trun_...5bc5" \
    -H "x-api-key: $PARALLEL_AI_API_KEY");
  status=$(echo "$result" | jq -r '.status');
  echo "Poll $i: $status";
  if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
    echo "$result"; break;
  fi;
done
```
Result: `jq: Permission denied` — not installed on the container.

**Evidence — Pattern 2: `for` loop with `grep` fallback (17:51:47 UTC):**
```bash
for i in $(seq 1 40); do
  sleep 30;
  result=$(curl -s ...);
  status=$(echo "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4);
  echo "Poll $i: $status";
  if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
    echo "$result"; break;
  fi;
done
```
Result: 40 iterations × 30s sleep = 20 minutes locked in a single tool call.

**Evidence — Pattern 3: `while true` with `python3` (admin session, 17:58:26 UTC):**
```bash
while true; do
  result=$(curl -s "https://api.parallel.ai/v1/tasks/runs/trun_...5bc5" \
    -H "x-api-key: $PARALLEL_AI_API_KEY")
  status=$(echo "$result" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('status','unknown'))")
  echo "$(date -u +%H:%M:%S) status=$status"
  if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
    echo "DONE"; break;
  fi
  sleep 30
done
```
Result: Required SIGTERM to kill (gateway aborted after 10 minutes).

**Counts from session JSONL:**
- `jq` references: 11 total (10 in main session + 1 in earlier session)
- `while` loop references: 22 total
- `for` loop references: 74 total

**Impact:**
- User session locked for 20+ minutes per polling cycle (no interaction possible)
- Gateway aborted long-running tool calls, inserting synthetic error results
- 4 `prompt-error: "aborted"` events in main session, 2 in admin session
- Each individual poll in attempt 1 triggered a full LLM inference (~$0.015-0.035/call)

**Recommended Fix:** Rewrite SKILL.md Section 2/Step 2 with explicit guardrails. Add a new Section 8 "Prohibited Patterns":

```markdown
### Step 2 — Poll for Completion (Silent)

**CRITICAL: Each poll must be a SEPARATE `exec` tool call.**

Poll the task status one time per tool call:

\`\`\`bash
curl -s -X GET "https://api.parallel.ai/v1/tasks/runs/{run_id}" \
  -H "x-api-key: $PARALLEL_AI_API_KEY"
\`\`\`

**Polling rules:**
- **One poll = one `exec` call.** After each call, check the status. If `running`, wait ~30 seconds, then make another `exec` call.
- Maximum **50 polls** (~25 minutes for ultra processor)
- Status values: `running` → poll again, `completed` → get results (Step 3), `failed` → report error
- **Output `NO_REPLY`** with every poll tool call

## 8. Prohibited Patterns

**NEVER use any of these in tool calls. They lock the session and waste API spend.**

- `for` loops (`for i in ...`)
- `while` loops (`while true`, `while [ ... ]`)
- `sleep` inside tool calls (blocks the session)
- `&` (background processes in exec)
- `jq` (not installed on the container)
- Chained commands with `&&` that include `sleep`
- Any construct that runs more than ONE curl call per tool invocation

**If you need to poll, make separate sequential `exec` tool calls — one curl per call.**
```

**Files to change:** `fly-scripts/skills/cobroker-deep-research/SKILL.md` (repo) + `/data/skills/cobroker-deep-research/SKILL.md` on all 10 machines.

---

### Issue 4 — Stale HEARTBEAT.md on 7 Machines

**Symptom:** HEARTBEAT.md still exists in `/data/workspace/` on 7 of 10 machines (009, 010, 012, 013, 014, 015, 016), despite being replaced by `usage-monitor.js` on 2026-03-03.

**Root Cause:** Two contributing factors:
1. The deploy script (`deploy-tenant.sh`) still transfers HEARTBEAT.md at lines 395 and 704-705
2. The gateway's `writeFileIfMissing` may have re-created it from templates on machines where it was initially deleted

**Evidence — deploy-tenant.sh line 395:**
```sh
transfer_file "$REPO_DIR/cobroker-config-backup/HEARTBEAT.md" "workspace/HEARTBEAT.md"
```

**Evidence — deploy-tenant.sh lines 704-705:**
```sh
info "  HEARTBEAT.md (workspace)"
transfer_file "$REPO_DIR/cobroker-config-backup/HEARTBEAT.md" "workspace/HEARTBEAT.md"
```

**Evidence — HEARTBEAT.md content on tenant-010 (168 bytes):**
```markdown
# HEARTBEAT.MD
# Keep this file empty (or with only comments) to skip heartbeat API calls.
# Add tasks below when you want the agent to check something periodically.
```

**Impact:** Low in isolation — the heartbeat config `525600m` (once fixed to `35000m`) means HEARTBEAT.md is rarely evaluated. But its presence is confusing and contradicts the migration to server-side usage monitoring.

**Recommended Fix:**
1. Delete HEARTBEAT.md from 7 machines:
   ```bash
   for T in 009 010 012 013 014 015 016; do
     APP="cobroker-tenant-${T}"
     fly ssh console -a "$APP" -C "rm -f /data/workspace/HEARTBEAT.md"
   done
   ```
2. Remove from `deploy-tenant.sh`:
   - Delete line 395 (`transfer_file ... HEARTBEAT.md`)
   - Delete lines 704-705 (HEARTBEAT.md info + transfer in update path)

**Files to change:** `fly-scripts/deploy-tenant.sh` (repo) + `/data/workspace/HEARTBEAT.md` on 7 machines (delete).

---

### Issue 5 — Prompt Errors (Aborted Tool Calls)

**Symptom:** 4 `prompt-error: "aborted"` events in the main Telegram session, 2 in the admin session.

**Root Cause:** The gateway aborts in-progress LLM inference when a new user message arrives mid-generation. This is by design — it prevents the agent from completing an outdated response. However, the aborted tool calls leave gaps in the session transcript.

**Evidence (from session JSONL):**
```
[openclaw] missing tool result in session history; inserted synthetic error result for transcript repair
```
Occurred at 17:59:34 UTC and 18:36:59 UTC.

**Timeline of aborts:**
| Time (UTC) | Session | Context |
|---|---|---|
| 17:44:55 | Main (Telegram) | During first Puttshack polling cycle |
| 17:45:14 | Main (Telegram) | During system notification delivery |
| 17:59:04 | Main (Telegram) | During second Puttshack polling cycle |
| 18:36:29 | Main (Telegram) | During Brassica polling cycle |

**Impact:** Synthetic error results patched into the transcript after each abort. The agent recovered gracefully in all cases, but each abort wasted the partial LLM inference cost.

**Recommended Fix:** No immediate fix needed — this is expected gateway behavior. The deeper fix is Issue 3 (prevent session-locking polling patterns so the gateway doesn't need to abort).

---

### Issue 6 — Cross-Session Blindness

**Symptom:** The admin webchat session could not see the Telegram session's activity. Admin asked "What are you running?" and the agent replied "Nothing running right now" while actively polling in another session.

**Evidence (admin session `bf97bc1c`, 17:52:50 UTC):**
> Admin: "What are you running right now?"
> Agent: "Nothing running right now — no active sub-agents, no background processes."

At this exact moment, the main Telegram session (`c4633130`) had an active `for` loop polling the Parallel AI API.

**Root Cause:** By design — OpenClaw uses `per-sender` session scope. Each session is isolated. The admin webchat session has no visibility into the Telegram session's state.

**Impact:** Admin confusion. Isaac had to explicitly ask "Are you doing the deep research for Mathew?" and the agent initially denied it. Took multiple follow-up messages before the agent discovered the running research task by checking the API directly.

**Recommended Fix:** Consider adding a cross-session status endpoint or admin tool that can query active exec processes across all sessions. Lower priority — this is a design limitation, not a bug.

**Discovery — WebSocket nudge path:** The gateway uses WebSocket RPC internally (`chat.send`, `chat.inject` methods), but `sessions_send` is in the tool deny list. A `node -e` script over SSH could potentially inject nudge messages into another session. This is a viable path for building cross-session admin intervention without changing gateway code.

---

### Issue 7 — Duplicate Message Delivery

**Symptom:** Puttshack research results sent twice to the user — once from the admin session, once from the Telegram session.

**Evidence:**
- **Message 172** (18:09:10 UTC): Admin session (`bf97bc1c`) detected completion and sent results to Mathew via Telegram
- **Message 173** (18:09:19 UTC): Main Telegram session (`c4633130`) independently detected completion and also sent results

Both sessions were independently polling the same Parallel AI run ID (`trun_...5bc5`) and both detected `status: completed` within seconds of each other.

**Impact:** User received the same research summary twice. Confusing but not harmful.

**Recommended Fix:** Same as Issue 6 — requires cross-session coordination. The `for` loop in the Telegram session had been running autonomously for 19 minutes and couldn't be stopped from the admin session. Fixing Issue 3 (no shell loops) would prevent this scenario because the admin could intervene between individual poll calls.

---

### Issue 8 — Wasted Deep Research Run

**Symptom:** Puttshack research was submitted and completed twice for the same query, doubling the API cost.

**Evidence:**
| Run | Run ID | Submitted | Completed | Duration | Status |
|---|---|---|---|---|---|
| #1 | `trun_68d4c4b0b38941aebbb1ebf0899f9692` | 17:35:31 | 18:01:30 | ~26 min | Completed but results never fetched |
| #2 | `trun_...5bc5` | 17:49:30 | 18:08:52 | ~19 min | Completed, results delivered |

**Root Cause:** The user aborted the first research attempt at 17:45:16 UTC (sent "Hello" during polling). The agent acknowledged the cancellation ("Got it — stopped the Puttshack research") but only stopped *polling* — it did not cancel the Parallel AI task, which continued running server-side. When the user re-asked the same question at 17:49:04, a new run was submitted.

**Impact:** Double API cost for the Parallel AI ultra processor. Run #1's results were never retrieved despite completing successfully. Additionally, Run #2's `modified_at` field was frozen at its creation timestamp for ~45 minutes, suggesting Parallel AI may enforce per-account concurrency — Run #2 was queued behind the still-running Run #1. This makes duplicate submissions even more wasteful: the second run doesn't start processing until the first completes.

**Recommended Fix:**
1. When the user aborts, check if a cancel API exists for the Parallel AI task
2. Store the `run_id` and check its status before submitting a duplicate query
3. Add to SKILL.md: "Before submitting a new research task, check if a previous run for the same topic exists and is still running or recently completed"

---

### Issue 9 — Messages Leaked During Polling

**Symptom:** Agent sent intermediate messages to the user while deep research polling was still active, delivering confusing partial results before the actual research completed.

**Evidence:**
- **17:59:51 UTC:** Preliminary summary "Based on the Puttshack portfolio analysis we did..." sent before deep research completed
- **18:01:53 UTC:** "Now let me check on the deep research" — process narration leaked to user

**Root Cause:** SKILL.md says "output `NO_REPLY` with every poll" but doesn't prohibit sending non-poll messages during the polling window. The agent treated the `NO_REPLY` rule as applying only to poll tool calls, not to the entire polling interval.

**Impact:** User received confusing partial results before the actual research completed. The preliminary summary at 17:59:51 contained cached data from earlier queries, not from the in-progress deep research run.

**Recommended Fix:** Add to SKILL.md Section 3: "Between the acknowledgment (Message 1) and the results (Message 2), send NO messages to the user — not even status updates or intermediate analysis. The user should receive exactly two messages per research task: the acknowledgment and the final results."

---

## 4. Complete Session Timeline

All times UTC, 2026-03-04 unless noted.

### Phase 1: Heartbeat Check (03:51–04:21, March 3)

| Time | Event |
|---|---|
| 03:51:37 (Mar 3) | Heartbeat session `72a3eea1` created |
| 04:21:37 (Mar 3) | Main session `c4633130` created |
| 04:21:42 | Agent reads `usage-alert-state.json`, calls usage API |
| 04:21:45 | `HEARTBEAT_OK`, usage at 13.1% |

### Phase 2: Puttshack Attempt 1 — Individual Exec Polls (17:34–17:44)

| Time | Event |
|---|---|
| 17:34:55 | User "Mathew" (Telegram ID 8224453087): "Give the best places to open two units for Puttshack in Chicago" |
| 17:35:05 | Agent: "Great question — let me run a deep research analysis..." |
| 17:35:31 | Run #1 submitted: `trun_68d4c4b0b38941aebbb1ebf0899f9692` |
| 17:35:35 | Polling begins — individual `sleep 30 && curl` pattern (16+ separate LLM inferences) |
| 17:44:55 | First `prompt-error: "aborted"` — user sent new message mid-inference |

### Phase 3: User Aborts + Process Improvement Requests (17:45–17:48)

| Time | Event |
|---|---|
| 17:45:16 | User: Abort notification + "Hello" |
| 17:45:20 | Agent: "Got it — stopped the Puttshack research" (only stopped polling, not the server-side task) |
| 17:45:44 | User: "can you communicate with me when starting to work on any project?" |
| 17:46:14 | User: "Can you add estimate of time to complete?" |
| 17:46:26 | Agent modifies `/data/workspace/AGENTS.md` to add time estimate rule |

### Phase 4: Puttshack Attempt 2 — For Loop + jq Failure (17:49–18:09)

| Time | Event |
|---|---|
| 17:49:04 | User: "Can you analyze where Puttshack should open another unit in Chicago" |
| 17:49:08 | Agent: "On it — running deep research... ~10-15 min" |
| 17:49:30 | Run #2 submitted: `trun_...5bc5` |
| 17:49:36 | Agent launches `for` loop with `jq` (session `oceanic-zephyr`, pid 7185) |
| 17:51:39 | `jq: Permission denied` errors — not installed |
| 17:51:43 | Agent kills `oceanic-zephyr` (SIGTERM) |
| 17:51:47 | Agent launches new `for` loop with `grep -o` fallback (session `cool-coral`, pid 7220) |
| 17:53:50 | Polls 1-4: all "running" |
| 17:55:54 | Polls 5-8: all "running" |
| 17:57:57 | Polls 9-12: all "running" |
| 17:59:04 | Third `prompt-error: "aborted"` |
| 17:59:34 | Synthetic error result injected into transcript |
| 17:59:51 | User: "What demographics are key to a successful Puttshack?" → Agent delivers detailed breakdown (HHI $85K–$170K, ages 21–39, 40%+ bachelor's) while polling continues in background |
| 18:00:00 | Polls 13-16: all "running" |
| 18:01:58 | Polls 17-20: all "running" |
| 18:04:03 | Polls 21-24: all "running" |
| 18:06:07 | Polls 25-28: all "running" |
| 18:08:10 | Polls 29-32: all "running" |
| 18:08:52 | Poll 34: **COMPLETED** |
| 18:08:56 | Agent fetches full results |
| 18:09:02 | Results: "Chicago Expansion Play: Rosemont/O'Hare" |
| 18:09:19 | Summary delivered to user (message 173) |

### Phase 5: Chart Attempt + Disk Full + Self-Heal (18:01, interleaved with Phase 4)

| Time | Event |
|---|---|
| 18:01:00 | User clicks `chart_puttshack_comps` button |
| 18:01:15 | `ENOSPC: no space left on device, write` on chart generation |
| 18:01:20 | Agent runs `df -h /`: `none 7.8G 7.8G 0 100% /` |
| 18:01:24 | Agent identifies: `7.8G /tmp/openclaw` |
| 18:01:27 | Agent identifies: `7.8G /tmp/openclaw/openclaw-2026-03-03.log` |
| 18:01:31 | **Agent truncates log file.** Post-cleanup: `none 7.8G 42M 7.4G 1% /` |
| 18:01:36 | Chart generation retried — succeeds |
| 18:01:42 | "Local media path is not under an allowed directory: /tmp/chart-puttshack-comps.png" |
| 18:01:45 | Agent copies chart to workspace directory |
| 18:01:48 | Chart sent via Telegram (message 171) |

### Phase 5.5: Admin Session — Cross-Session Discovery (17:52–18:09)

| Time | Event |
|---|---|
| 17:52:43 | Admin session `bf97bc1c` created from `openclaw-control-ui` |
| 17:52:43 | Admin (Isaac): "What are you running right now?" |
| 17:52:50 | Agent: "Nothing running right now — no active sub-agents, no background processes." |
| 17:53:09 | Admin: "Are you doing the deep research for Mathew?" |
| 17:54:12 | Admin: "Are you sure? Check the conversation..." |
| 17:58:26 | Agent launches `while true` polling loop (using `python3` for JSON parsing) |
| 18:08:18 | Admin: "Okay, can you confirm the status?" |
| 18:08:35 | Agent discovers `keen-ember` process FAILED (SIGTERM after 10 minutes) |
| 18:08:40 | Agent launches another `while true` loop (session `fast-cloud`) |
| 18:08:40 | Immediately detects `status: completed` |
| 18:08:48 | Agent saves results to `/data/workspace/deep-research-full.json` |
| 18:09:10 | **Duplicate:** Agent sends results to Mathew via Telegram (message 172) |
| 18:09:16 | Agent reports to admin: "Deep research completed and delivered to Mathew." |

### Phase 6: Admin Intervention + Gamma Presentation (18:17–18:25)

| Time | Event |
|---|---|
| 18:17:17 | Admin: "Ask him if he wants a presentation..." |
| 18:17:24 | "Action send requires a target" error — admin-intervention messages are injected by the gateway and don't carry the original user's chat ID. Agent must determine the Telegram target itself. Self-corrected in 4 seconds. |
| 18:17:28 | Agent sends: "Want me to turn this expansion analysis into a polished presentation?" |
| 18:22:28 | User: "create_puttshack_pres" |
| 18:23:49 | Gamma API submission, generation ID: `2bzFCJFplOg9CfIl669rt` |
| 18:24:46 | Gamma completes, URL: `https://gamma.app/docs/xp59243qpicro25` |
| 18:24:51 | Presentation sent to user (8 slides) |
| 18:27:14 | Admin: "Do you see the conversation about the Gamma presentation?" |
| 18:27:23 | Agent: "No — I don't have any record of a Gamma presentation conversation. My context got reset." |

### Phase 7: Brassica Dallas Research — For Loop + Abort (18:26–18:50)

| Time | Event |
|---|---|
| 18:26:29 | User: "Tell me about Brassica, where should they consider in Dallas?" |
| 18:26:37 | Agent: "Let me pull Brassica's performance data... ~10-15 min total" |
| 18:27:20 | Session `glow-canyon` SIGTERM |
| 18:27:44 | Session `amber-ember` SIGTERM |
| -- | Root cause unknown — likely gateway exec timeout (10-min limit). Agent fell back to third attempt (young-lagoon) which succeeded. |
| 18:27:49 | Session `young-lagoon` succeeds: 6 Ohio store revenue data for Brassica (Upper Arlington $12M leader, range $1.7M–$4.5M/yr per store) |
| 18:28:41 | Run #3 submitted: `trun_...9788` (Brassica DFW) |
| 18:30:53 | Polls 1-4: "running" |
| 18:32:57 | Polls 5-8: "running" |
| 18:35:01 | Polls 9-12: "running" |
| 18:36:29 | Fourth `prompt-error: "aborted"` |
| 18:36:59 | Synthetic error result injected |
| 18:46:19 | Deferred exec notifications (glow-canyon, amber-ember SIGTERMs) |
| 18:46:25 | Agent: "deep research on Brassica's Dallas expansion is still running" |
| 18:48:29 | Polls 17-39: all "running" |
| 18:48:57 | Poll 40: "running" — **HIT 40-POLL LIMIT**, process exits code 0 |
| 18:49:03 | Agent: "Hit 40 polls without completion. Let me do additional checks." |
| 18:49:06 | Second polling batch launched (session `tidy-zephyr`) |
| 18:50:03 | Poll 1: "running", Poll 2: **COMPLETED** |
| 18:50:09 | Results fetched: "Dallas-Fort Worth Entry Blueprint for Brassica" |
| 18:50:30 | Summary delivered to user (message 190, chat 8224453087) |
| 18:50:45 | Agent updates MEMORY.md |
| 18:50:49 | Session ends |

---

## 5. Recommended Fixes — Consolidated

### Fix 1: Heartbeat Timeout (Issue 1)

**What:** Change `heartbeat.every` from `525600m` to `35000m` in `openclaw.json`.

**Where:** `/data/openclaw.json` on all 10 machines.

**Change:**
```json
// BEFORE (overflows 32-bit int)
"heartbeat": { "every": "525600m" }

// AFTER (fits in 32-bit int, ~24.3 days)
"heartbeat": { "every": "35000m" }
```

**Why `35000m`:** 35,000 min × 60,000 ms = 2,100,000,000 ms < 2,147,483,647 (32-bit max).

### Fix 2: Log Cleanup in start.sh (Issue 2)

**What:** Add log rotation/cleanup to startup script.

**Where:** `fly-scripts/start.sh` (repo) → deploy to `/data/start.sh` on all 10 machines.

**Insert after line 8** (after `export XDG_CONFIG_HOME=...`), before log-forwarder starts:
```sh
# Clean up rolling logs to prevent disk-full.
# Gateway debug/info logs in /tmp/openclaw — NOT session JSONL.
if [ -d /tmp/openclaw ]; then
  find /tmp/openclaw -name "openclaw-*.log" -mtime +0 -delete 2>/dev/null || true
  for f in /tmp/openclaw/openclaw-*.log; do
    [ -f "$f" ] || continue
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$size" -gt 524288000 ]; then
      echo "[start.sh] Truncating oversized log: $f (${size} bytes)"
      : > "$f"
    fi
  done
fi
```

### Fix 3: Deep Research SKILL.md Rewrite (Issue 3)

**What:** Add explicit polling guardrails and prohibited patterns section.

**Where:** `fly-scripts/skills/cobroker-deep-research/SKILL.md` (repo) → deploy to `/data/skills/cobroker-deep-research/SKILL.md` on all 10 machines.

**Replace Section 2, Step 2 with:**
```markdown
### Step 2 — Poll for Completion (Silent)

**CRITICAL: Each poll must be a SEPARATE `exec` tool call. Never combine multiple polls into one call.**

Poll the task status one time per tool call:

\`\`\`bash
curl -s -X GET "https://api.parallel.ai/v1/tasks/runs/{run_id}" \
  -H "x-api-key: $PARALLEL_AI_API_KEY"
\`\`\`

**Polling rules:**
- **One poll = one `exec` call.** Check the response. If `running`, output `NO_REPLY`, then make another `exec` call ~30 seconds later.
- Maximum **50 polls** (~25 minutes for ultra processor)
- Status values: `running` → poll again, `completed` → get results (Step 3), `failed` → report error
- **Output `NO_REPLY`** with every poll tool call
- **Use `grep -o` to parse JSON** — `jq` is not installed
```

**Add new Section 8 at the end:**
```markdown
## 8. Prohibited Patterns

**NEVER use any of these in tool calls. They lock the session and waste API spend.**

- `for` loops (`for i in ...`)
- `while` loops (`while true`, `while [ ... ]`)
- `sleep` inside tool calls (blocks the session)
- `&` (background processes in exec)
- `jq` (not installed on the container — use `grep -o` or `node -e`)
- Chained commands with `&&` that include `sleep`
- Any construct that runs more than ONE curl call per tool invocation

**If you need to poll, make separate sequential `exec` tool calls — one curl per call.**
```

### Fix 4: Remove HEARTBEAT.md (Issue 4)

**What:** Delete HEARTBEAT.md from 7 machines and remove from deploy script.

**Where:**
- `/data/workspace/HEARTBEAT.md` on machines 009, 010, 012, 013, 014, 015, 016
- `fly-scripts/deploy-tenant.sh` lines 395 and 704-705

### Fix 5: Duplicate Run Prevention (Issue 8)

**What:** Add run-ID caching to SKILL.md so the agent checks for existing runs before submitting duplicates.

**Where:** `fly-scripts/skills/cobroker-deep-research/SKILL.md` — add to Section 2, before Step 1:

```markdown
### Step 0 — Check for Existing Runs

Before submitting a new research task, check if a recent run for the same topic exists:

\`\`\`bash
cat /data/workspace/deep-research-runs.json 2>/dev/null || echo '[]'
\`\`\`

If a run for the same topic was submitted in the last 30 minutes:
1. Check its status first (`curl -s ... /runs/{run_id}`)
2. If `completed` — fetch results instead of re-submitting
3. If `running` — resume polling instead of re-submitting
4. If `failed` — ok to submit a new run

After submitting a new run, save the run_id:
\`\`\`bash
echo '[{"run_id":"trun_xxx","topic":"...","submitted":"2026-03-04T17:49:30Z"}]' \
  > /data/workspace/deep-research-runs.json
\`\`\`
```

---

## 6. Deployment Procedure

### Step 1: Immediate — Truncate logs on full-disk machines

```bash
for T in openclaw 008 009 011 012 014 015 016; do
  if [ "$T" = "openclaw" ]; then
    APP="cobroker-openclaw"
  else
    APP="cobroker-tenant-${T}"
  fi
  echo "=== $APP ==="
  fly ssh console -a "$APP" -C "sh -c '> /tmp/openclaw/openclaw-2026-03-03.log && df -h /'"
done
```

Also truncate tenant-013 (74% and growing):
```bash
fly ssh console -a cobroker-tenant-013 -C "sh -c '> /tmp/openclaw/openclaw-2026-03-03.log && df -h /'"
```

### Step 2: Fix heartbeat config on all 10 machines

```bash
for T in openclaw 008 009 010 011 012 013 014 015 016; do
  if [ "$T" = "openclaw" ]; then
    APP="cobroker-openclaw"
  else
    APP="cobroker-tenant-${T}"
  fi
  echo "=== $APP ==="
  fly ssh console -a "$APP" -C "sh -c 'sed -i \"s/525600m/35000m/g\" /data/openclaw.json && grep every /data/openclaw.json'"
done
```

### Step 3: Delete HEARTBEAT.md from 7 machines

```bash
for T in 009 010 012 013 014 015 016; do
  APP="cobroker-tenant-${T}"
  echo "=== $APP ==="
  fly ssh console -a "$APP" -C "rm -f /data/workspace/HEARTBEAT.md"
done
```

### Step 4: Deploy updated start.sh (with log cleanup)

```bash
# Update repo file first, then deploy
for T in openclaw 008 009 010 011 012 013 014 015 016; do
  if [ "$T" = "openclaw" ]; then
    APP="cobroker-openclaw"
  else
    APP="cobroker-tenant-${T}"
  fi
  echo "=== $APP ==="
  B64=$(base64 < fly-scripts/start.sh)
  fly ssh console -a "$APP" -C "sh -c 'echo $B64 | base64 -d > /data/start.sh && chown node:node /data/start.sh'"
done
```

### Step 5: Deploy updated SKILL.md

```bash
for T in openclaw 008 009 010 011 012 013 014 015 016; do
  if [ "$T" = "openclaw" ]; then
    APP="cobroker-openclaw"
  else
    APP="cobroker-tenant-${T}"
  fi
  echo "=== $APP ==="
  B64=$(base64 < fly-scripts/skills/cobroker-deep-research/SKILL.md)
  fly ssh console -a "$APP" -C "sh -c 'echo $B64 | base64 -d > /data/skills/cobroker-deep-research/SKILL.md && chown node:node /data/skills/cobroker-deep-research/SKILL.md'"
done
```

### Step 6: Clear sessions and restart all machines

```bash
for T in openclaw 008 009 010 011 012 013 014 015 016; do
  if [ "$T" = "openclaw" ]; then
    APP="cobroker-openclaw"
  else
    APP="cobroker-tenant-${T}"
  fi
  echo "=== $APP ==="
  fly ssh console -a "$APP" -C "sh -c 'rm -rf /data/agents/main/sessions/*'"
  fly apps restart "$APP"
done
```

---

## 7. Verification Checklist

Run after deployment. Every check should pass.

### Per-machine verification

```bash
for T in openclaw 008 009 010 011 012 013 014 015 016; do
  if [ "$T" = "openclaw" ]; then
    APP="cobroker-openclaw"
  else
    APP="cobroker-tenant-${T}"
  fi
  echo ""
  echo "=== $APP ==="

  # 1. No overflow warnings in recent logs
  echo -n "  Overflow warnings: "
  fly logs -a "$APP" --no-tail 2>/dev/null | grep -c "TimeoutOverflowWarning" || echo "0"

  # 2. Disk usage below 50%
  echo -n "  Disk usage: "
  fly ssh console -a "$APP" -C "df -h / | tail -1" 2>/dev/null

  # 3. Heartbeat config is 35000m
  echo -n "  Heartbeat config: "
  fly ssh console -a "$APP" -C "sh -c 'grep -o \"35000m\" /data/openclaw.json && echo OK || echo WRONG'" 2>/dev/null

  # 4. No HEARTBEAT.md in workspace
  echo -n "  HEARTBEAT.md: "
  fly ssh console -a "$APP" -C "sh -c 'ls /data/workspace/HEARTBEAT.md 2>/dev/null && echo EXISTS || echo MISSING'" 2>/dev/null

  # 5. start.sh has log cleanup
  echo -n "  Log cleanup in start.sh: "
  fly ssh console -a "$APP" -C "sh -c 'grep -c \"Truncating oversized\" /data/start.sh 2>/dev/null || echo 0'" 2>/dev/null

  # 6. SKILL.md has prohibited patterns section
  echo -n "  SKILL.md prohibited patterns: "
  fly ssh console -a "$APP" -C "sh -c 'grep -c \"Prohibited Patterns\" /data/skills/cobroker-deep-research/SKILL.md 2>/dev/null || echo 0'" 2>/dev/null

  # 7. Gateway process running
  echo -n "  Gateway PID: "
  fly ssh console -a "$APP" -C "sh -c 'pgrep -f openclaw-gateway || echo DOWN'" 2>/dev/null
done
```

### Expected results per machine

| Check | Expected |
|---|---|
| Overflow warnings | 0 |
| Disk usage | < 50% |
| Heartbeat config | `35000m OK` |
| HEARTBEAT.md | `MISSING` |
| Log cleanup in start.sh | `1` (or higher) |
| SKILL.md prohibited patterns | `1` (or higher) |
| Gateway PID | A number (not `DOWN`) |

---

## Appendix A: Process Statistics

| Metric | Value |
|---|---|
| Total Telegram messages delivered | 14 |
| Total deep research runs | 3 (1 wasted) |
| Total session duration | ~1 hour 16 minutes (17:34–18:50) |
| Total `for` loop references in session JSONL | 74 |
| Total `while` loop references | 22 |
| Total `jq` references | 11 |
| Total `prompt-error: "aborted"` events | 6 (4 main + 2 admin) |
| Synthetic error results injected | 2 |
| Gateway CPU at investigation time | 15.6% |
| Gateway RSS at investigation time | 557 MB |
| Estimated log growth rate | ~280 MB/hour |
| Time from overflow start to disk full | ~27 hours |

## Appendix B: Session Files

| File | Session | Lines | Size |
|---|---|---|---|
| `c4633130-8f22-47cf-a5bb-ec37a3ab2689.jsonl` | Main (Telegram, user Mathew) | 318 | 375 KB |
| `bf97bc1c-890d-4ace-a702-231010fb1ef6.jsonl` | Admin (webchat, Isaac) | 86 | 138 KB |

## Appendix C: Key File Paths

| File | Location | Purpose |
|---|---|---|
| `openclaw.json` | `/data/openclaw.json` | Main config (heartbeat setting) |
| `start.sh` | `/data/start.sh` | Startup wrapper (needs log cleanup) |
| `SKILL.md` | `/data/skills/cobroker-deep-research/SKILL.md` | Deep research skill (needs polling fix) |
| Gateway log | `/tmp/openclaw/openclaw-YYYY-MM-DD.log` | Rolling debug log (overflow target) |
| Session JSONL | `/data/agents/main/sessions/*.jsonl` | Session transcripts |
| Usage state | `/data/workspace/usage-alert-state.json` | Usage monitor threshold state |
| deploy-tenant.sh | `fly-scripts/deploy-tenant.sh` (repo) | Deploy script (remove HEARTBEAT.md refs) |
