#!/usr/bin/env node
// usage-monitor.js — Server-side usage threshold monitor
// Replaces the LLM-based heartbeat system. Calls the CoBroker usage API
// directly and sends Telegram alerts via Bot API when thresholds are crossed.
// No npm dependencies — uses only Node.js built-ins.

const fs = require("fs");
const https = require("https");
const http = require("http");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const CHECK_INTERVAL_MS = 30 * 60 * 1000; // 30 minutes
const STATE_FILE = "/data/workspace/usage-alert-state.json";
const SESSIONS_FILE = "/data/agents/main/sessions/sessions.json";
const THRESHOLDS = [95, 90, 75, 50]; // highest first

const COBROKER_BASE_URL = process.env.COBROKER_BASE_URL;
const COBROKER_AGENT_USER_ID = process.env.COBROKER_AGENT_USER_ID;
const COBROKER_AGENT_SECRET = process.env.COBROKER_AGENT_SECRET;
const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function ts() {
  return new Date().toISOString();
}

function log(msg) {
  console.log(`[${ts()}] [usage-monitor] ${msg}`);
}

function logError(msg) {
  console.error(`[${ts()}] [usage-monitor] ERROR: ${msg}`);
}

// ---------------------------------------------------------------------------
// State management
// ---------------------------------------------------------------------------

function readState() {
  try {
    if (fs.existsSync(STATE_FILE)) {
      return JSON.parse(fs.readFileSync(STATE_FILE, "utf-8"));
    }
  } catch (err) {
    logError(`Failed to read state file: ${err.message}`);
  }
  return { last_alerted_threshold: 0, last_percent_used: 0, updated_at: null };
}

function writeState(state) {
  try {
    const dir = STATE_FILE.substring(0, STATE_FILE.lastIndexOf("/"));
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2), "utf-8");
  } catch (err) {
    logError(`Failed to write state file: ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// Chat ID resolution
// ---------------------------------------------------------------------------

function resolveChatId(state) {
  // 1. From state file
  if (state.chat_id) {
    return state.chat_id;
  }

  // 2. Grep sessions.json for telegram sender
  try {
    if (fs.existsSync(SESSIONS_FILE)) {
      const content = fs.readFileSync(SESSIONS_FILE, "utf-8");
      const match = content.match(/"from":"telegram:(\d+)"/);
      if (match) {
        return match[1];
      }
    }
  } catch (err) {
    logError(`Failed to read sessions file: ${err.message}`);
  }

  return null;
}

// ---------------------------------------------------------------------------
// HTTP helpers (native, Promise-based)
// ---------------------------------------------------------------------------

function httpGet(url, headers) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const mod = parsed.protocol === "https:" ? https : http;

    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path: parsed.pathname + parsed.search,
      method: "GET",
      headers,
    };

    const req = mod.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });

    req.on("error", (err) => reject(err));
    req.setTimeout(15000, () => req.destroy(new Error("Request timed out")));
    req.end();
  });
}

function httpPost(url, body, headers) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const mod = parsed.protocol === "https:" ? https : http;
    const jsonBody = JSON.stringify(body);

    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path: parsed.pathname + parsed.search,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(jsonBody),
        ...headers,
      },
    };

    const req = mod.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });

    req.on("error", (err) => reject(err));
    req.setTimeout(15000, () => req.destroy(new Error("Request timed out")));
    req.write(jsonBody);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Usage API
// ---------------------------------------------------------------------------

async function fetchUsage() {
  const url = `${COBROKER_BASE_URL}/api/agent/openclaw/usage`;
  const headers = {
    "X-Agent-User-Id": COBROKER_AGENT_USER_ID,
    "X-Agent-Secret": COBROKER_AGENT_SECRET,
  };

  const res = await httpGet(url, headers);
  if (res.status !== 200) {
    throw new Error(`Usage API returned HTTP ${res.status}`);
  }

  const data = JSON.parse(res.body);
  if (!data.success) {
    throw new Error(`Usage API returned success=false`);
  }

  return { ...data.usage, payment_url: data.payment_url };
}

// ---------------------------------------------------------------------------
// Telegram Bot API
// ---------------------------------------------------------------------------

async function sendTelegramMessage(chatId, text) {
  const url = `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`;
  const body = {
    chat_id: chatId,
    text,
    parse_mode: "Markdown",
  };

  const res = await httpPost(url, body, {});
  if (res.status !== 200) {
    throw new Error(`Telegram API returned HTTP ${res.status}: ${res.body}`);
  }

  return JSON.parse(res.body);
}

// ---------------------------------------------------------------------------
// Alert message templates
// ---------------------------------------------------------------------------

function buildAlertMessage(threshold, spent, budget, paymentUrl) {
  const s = spent.toFixed(2);
  const b = budget.toFixed(2);
  const link = paymentUrl ? `[Add credits here](${paymentUrl})` : "";

  switch (threshold) {
    case 50:
      return `Heads up — you've used about half your budget ($${s} of $${b}). You're on track, just keeping you in the loop. Need more credits? ${link}`;
    case 75:
      return `Hey, you've used about 75% of your budget ($${s} of $${b} spent). You might want to pace your usage for the rest of the cycle. ${link}`;
    case 90:
      return `Important — you've used 90% of your budget ($${s} of $${b}). Usage will be blocked when your credits run out. ${link}`;
    case 95:
      return `You're almost out of credits — $${s} of $${b} used. ${link} to avoid interruption`;
    default:
      return `Usage alert: $${s} of $${b} used (${threshold}%). ${link}`;
  }
}

// ---------------------------------------------------------------------------
// Main check cycle
// ---------------------------------------------------------------------------

async function checkUsage() {
  // 1. Read state
  const state = readState();

  // 2. Fetch usage from API
  let usage;
  try {
    usage = await fetchUsage();
  } catch (err) {
    logError(`Failed to fetch usage: ${err.message}`);
    return;
  }

  const percentUsed = usage.percent_used;
  const totalSpent = usage.total_spent_usd;
  const totalBudget = usage.total_budget_usd;
  const paymentUrl = usage.payment_url;

  log(
    `Usage: ${percentUsed.toFixed(1)}% ($${totalSpent.toFixed(2)} of $${totalBudget.toFixed(2)})`,
  );

  // 3. Detect budget reset (percent drops 5+ points below last reading)
  if (state.last_percent_used > 0 && percentUsed < state.last_percent_used - 5) {
    log(
      `Budget reset detected (${state.last_percent_used.toFixed(1)}% -> ${percentUsed.toFixed(1)}%) — resetting thresholds`,
    );
    writeState({
      last_alerted_threshold: 0,
      last_percent_used: percentUsed,
      chat_id: state.chat_id || undefined,
      updated_at: new Date().toISOString(),
    });
    return;
  }

  // 4. Find highest crossed threshold
  let crossedThreshold = 0;
  for (const t of THRESHOLDS) {
    if (percentUsed >= t) {
      crossedThreshold = t;
      break; // THRESHOLDS is sorted highest-first
    }
  }

  // 5. Check if we need to alert
  if (crossedThreshold === 0 || crossedThreshold <= state.last_alerted_threshold) {
    // No new threshold crossed — nothing to do
    return;
  }

  log(
    `New threshold crossed: ${crossedThreshold}% (last alerted: ${state.last_alerted_threshold}%)`,
  );

  // 6. Resolve chat ID
  const chatId = resolveChatId(state);
  if (!chatId) {
    logError("No chat ID available — cannot send alert. Updating state to prevent retry.");
    writeState({
      last_alerted_threshold: crossedThreshold,
      last_percent_used: percentUsed,
      updated_at: new Date().toISOString(),
    });
    return;
  }

  // 7. Send Telegram alert
  const message = buildAlertMessage(crossedThreshold, totalSpent, totalBudget, paymentUrl);
  try {
    await sendTelegramMessage(chatId, message);
    log(`Alert sent to chat ${chatId} for ${crossedThreshold}% threshold`);
  } catch (err) {
    logError(`Failed to send Telegram alert: ${err.message}`);
    // Don't update state — will retry next cycle
    return;
  }

  // 8. Update state (only after successful send)
  writeState({
    last_alerted_threshold: crossedThreshold,
    last_percent_used: percentUsed,
    chat_id: chatId,
    updated_at: new Date().toISOString(),
  });
}

// ---------------------------------------------------------------------------
// Startup validation
// ---------------------------------------------------------------------------

function validateEnv() {
  const missing = [];
  if (!COBROKER_BASE_URL) {
    missing.push("COBROKER_BASE_URL");
  }
  if (!COBROKER_AGENT_USER_ID) {
    missing.push("COBROKER_AGENT_USER_ID");
  }
  if (!COBROKER_AGENT_SECRET) {
    missing.push("COBROKER_AGENT_SECRET");
  }
  if (!TELEGRAM_BOT_TOKEN) {
    missing.push("TELEGRAM_BOT_TOKEN");
  }
  return missing;
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const missingEnv = validateEnv();

log("Starting up");
log(`Check interval: ${CHECK_INTERVAL_MS / 60000} minutes`);
log(`State file: ${STATE_FILE}`);
log(`Thresholds: ${THRESHOLDS.join(", ")}%`);

if (missingEnv.length > 0) {
  log(`Missing env vars: ${missingEnv.join(", ")} — usage checks will be skipped`);
}

async function runCycle() {
  if (missingEnv.length > 0) {
    // Skip silently — already logged at startup
    setTimeout(runCycle, CHECK_INTERVAL_MS);
    return;
  }

  try {
    await checkUsage();
  } catch (err) {
    logError(`Unexpected error in check cycle: ${err.message}`);
  }

  setTimeout(runCycle, CHECK_INTERVAL_MS);
}

// Run first check immediately, then schedule recursively
void runCycle();
