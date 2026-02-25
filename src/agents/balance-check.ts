/**
 * Real-time balance check for external API tool calls.
 *
 * Calls the CoBroker balance-check API before expensive tool invocations
 * (Parallel AI, Gemini, Google Places, ESRI, Brave Search) and blocks
 * if the user's credit balance is exhausted.
 *
 * Requires env vars:
 *   BALANCE_CHECK_URL  — e.g. https://clawbroker.ai/api/balance-check
 *   OPENCLAW_LOG_SECRET — shared auth token
 *   FLY_APP_NAME       — tenant identifier (auto-set by Fly.io)
 */

import { createSubsystemLogger } from "../logging/subsystem.js";

const log = createSubsystemLogger("balance-check");

// URL patterns in exec tool curl commands that indicate expensive external APIs
const EXPENSIVE_API_PATTERNS = [
  "generativelanguage.googleapis.com", // Gemini
  "api.parallel.ai", // Parallel AI (FindAll, Ultra)
  "/places/", // Google Places
  "/demographics", // ESRI
  "api.search.brave.com", // Brave Search
];

// Tool names that are always expensive (not exec-based)
const EXPENSIVE_TOOL_NAMES = new Set(["web_search"]);

// Balance cache: avoid hitting the API on every single tool call
let balanceCache: { allowed: boolean; remaining: number; fetchedAt: number } | null = null;
const CACHE_TTL_MS = 30_000; // 30 seconds

/**
 * Check if a tool call targets an expensive external API.
 */
export function isExpensiveToolCall(toolName: string, params: Record<string, unknown>): boolean {
  if (EXPENSIVE_TOOL_NAMES.has(toolName)) {
    return true;
  }
  if (toolName === "exec") {
    const raw = params.command ?? params.input;
    const command = typeof raw === "string" ? raw : "";
    return EXPENSIVE_API_PATTERNS.some((p) => command.includes(p));
  }
  return false;
}

/**
 * Check if the tenant's balance allows further external API usage.
 * Returns { allowed: true } if balance check is not configured (fail-open).
 * Caches the result for CACHE_TTL_MS to minimize API calls.
 */
export async function checkBalanceAllowed(): Promise<{
  allowed: boolean;
  remaining: number;
}> {
  // Return cached result if fresh
  if (balanceCache && Date.now() - balanceCache.fetchedAt < CACHE_TTL_MS) {
    return { allowed: balanceCache.allowed, remaining: balanceCache.remaining };
  }

  const balanceCheckUrl = process.env.BALANCE_CHECK_URL;
  const authToken = process.env.OPENCLAW_LOG_SECRET;
  const tenantId = process.env.FLY_APP_NAME;

  // Fail-open if not configured
  if (!balanceCheckUrl || !authToken || !tenantId) {
    return { allowed: true, remaining: Infinity };
  }

  try {
    const url = `${balanceCheckUrl}?tenantId=${encodeURIComponent(tenantId)}`;
    const resp = await fetch(url, {
      headers: { Authorization: `Bearer ${authToken}` },
      signal: AbortSignal.timeout(5000),
    });

    if (!resp.ok) {
      log.warn(`balance check HTTP ${resp.status} — failing open`);
      return { allowed: true, remaining: Infinity };
    }

    const data = (await resp.json()) as { allowed?: boolean; remaining_usd?: number };
    const result = {
      allowed: data.allowed !== false,
      remaining: data.remaining_usd ?? Infinity,
    };

    balanceCache = { ...result, fetchedAt: Date.now() };

    if (!result.allowed) {
      log.warn(`balance exhausted: $${result.remaining.toFixed(2)} remaining`);
    }

    return result;
  } catch (err) {
    log.warn(`balance check failed: ${String(err)} — failing open`);
    return { allowed: true, remaining: Infinity };
  }
}

/** Clear the cached balance (e.g. after a payment webhook). */
export function clearBalanceCache(): void {
  balanceCache = null;
}
