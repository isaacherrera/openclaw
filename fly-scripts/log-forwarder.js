#!/usr/bin/env node
// log-forwarder.js — Watches OpenClaw session JSONL files and forwards entries
// to the CoBroker dashboard API. Runs as a background process on Fly.
// No npm dependencies — uses only Node.js built-ins.

const fs = require("fs");
const path = require("path");
const https = require("https");

const SESSIONS_ROOT = "/data/agents";
const CURSOR_FILE = "/data/log-cursor.json";
const POLL_INTERVAL_MS = 3000;
const API_URL = "https://app.cobroker.ai/api/openclaw-logs";
const AUTH_TOKEN = process.env.OPENCLAW_LOG_SECRET;
const TENANT_ID = process.env.FLY_APP_NAME || "unknown";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function ts() {
  return new Date().toISOString();
}

function log(msg) {
  console.log(`[${ts()}] [log-forwarder] ${msg}`);
}

function logError(msg) {
  console.error(`[${ts()}] [log-forwarder] ERROR: ${msg}`);
}

function loadCursors() {
  try {
    if (fs.existsSync(CURSOR_FILE)) {
      return JSON.parse(fs.readFileSync(CURSOR_FILE, "utf-8"));
    }
  } catch (err) {
    logError(`Failed to read cursor file: ${err.message}`);
  }
  return {};
}

function saveCursors(cursors) {
  try {
    fs.writeFileSync(CURSOR_FILE, JSON.stringify(cursors, null, 2), "utf-8");
  } catch (err) {
    logError(`Failed to write cursor file: ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// File discovery — manually scan /data/agents/*/sessions/*.jsonl
// ---------------------------------------------------------------------------

function discoverJsonlFiles() {
  const files = [];
  try {
    const agents = fs.readdirSync(SESSIONS_ROOT, { withFileTypes: true });
    for (const agent of agents) {
      if (!agent.isDirectory()) {
        continue;
      }
      const sessionsDir = path.join(SESSIONS_ROOT, agent.name, "sessions");
      try {
        const entries = fs.readdirSync(sessionsDir, { withFileTypes: true });
        for (const entry of entries) {
          if (entry.isFile() && entry.name.endsWith(".jsonl")) {
            files.push(path.join(sessionsDir, entry.name));
          }
        }
      } catch {
        // sessions dir may not exist for every agent — that's fine
      }
    }
  } catch {
    // SESSIONS_ROOT may not exist yet at startup
  }
  return files;
}

function sessionIdFromPath(filePath) {
  // e.g. /data/agents/main/sessions/abc123.jsonl -> abc123
  return path.basename(filePath, ".jsonl");
}

// ---------------------------------------------------------------------------
// HTTP POST helper (native https, returns a Promise)
// ---------------------------------------------------------------------------

function postEntries(entries) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ entries });
    const url = new URL(API_URL);

    const options = {
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(body),
        ...(AUTH_TOKEN ? { Authorization: `Bearer ${AUTH_TOKEN}` } : {}),
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });

    req.on("error", (err) => reject(err));
    req.setTimeout(10000, () => {
      req.destroy(new Error("Request timed out"));
    });
    req.write(body);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Main scan cycle
// ---------------------------------------------------------------------------

async function scanAndForward() {
  const cursors = loadCursors();
  const files = discoverJsonlFiles();

  // Clean up cursors for files that no longer exist (e.g. after session clearing)
  const fileSet = new Set(files);
  for (const key of Object.keys(cursors)) {
    if (!fileSet.has(key)) {
      delete cursors[key];
    }
  }

  const allNewEntries = [];
  const pendingOffsets = {}; // filepath -> new offset (applied only on success)

  for (const filePath of files) {
    try {
      const stat = fs.statSync(filePath);
      let offset = cursors[filePath] || 0;

      // Handle file truncation (e.g. heartbeat transcript pruning).
      // The gateway rewrote the file — read from byte 0 since all content is new.
      if (stat.size < offset) {
        log(
          `File truncated (${offset} -> ${stat.size}), reading new content from start: ${filePath}`,
        );
        offset = 0;
      }

      if (stat.size === offset) {
        continue;
      } // nothing new

      const fd = fs.openSync(filePath, "r");
      const buf = Buffer.alloc(stat.size - offset);
      fs.readSync(fd, buf, 0, buf.length, offset);
      fs.closeSync(fd);

      const chunk = buf.toString("utf-8");
      const lines = chunk.split("\n");
      const sessionId = sessionIdFromPath(filePath);

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) {
          continue;
        }
        try {
          const parsed = JSON.parse(trimmed);
          allNewEntries.push({ session_id: sessionId, tenant_id: TENANT_ID, ...parsed });
        } catch {
          // Skip malformed lines silently
        }
      }

      pendingOffsets[filePath] = stat.size;
    } catch (err) {
      logError(`Error reading ${filePath}: ${err.message}`);
    }
  }

  if (allNewEntries.length === 0) {
    // Persist any pending offsets (e.g. from truncation detection) even when
    // there are no new entries to forward — otherwise the truncation gets
    // re-detected every cycle, creating an infinite loop.
    if (Object.keys(pendingOffsets).length > 0) {
      Object.assign(cursors, pendingOffsets);
      saveCursors(cursors);
    }
    return;
  }

  try {
    const res = await postEntries(allNewEntries);
    if (res.status === 200) {
      log(`Forwarded ${allNewEntries.length} entries (HTTP 200)`);
      Object.assign(cursors, pendingOffsets);
      saveCursors(cursors);
    } else if (res.body && res.body.includes("duplicate key")) {
      // Entries already exist in the database — advance cursors to stop retrying
      log(
        `Duplicate key detected — entries already stored, advancing cursors (${allNewEntries.length} entries)`,
      );
      Object.assign(cursors, pendingOffsets);
      saveCursors(cursors);
    } else {
      logError(`API responded ${res.status} — will retry next cycle. Body: ${res.body}`);
      throw new Error(`API ${res.status}`);
    }
  } catch (err) {
    if (err.message.startsWith("API ")) {
      throw err;
    }
    logError(`Network error posting entries — will retry next cycle: ${err.message}`);
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Start — recursive setTimeout with exponential backoff on errors
// ---------------------------------------------------------------------------

let consecutiveErrors = 0;
const MAX_BACKOFF_MS = 60000;

async function runCycle() {
  try {
    await scanAndForward();
    consecutiveErrors = 0; // success — reset backoff
  } catch {
    consecutiveErrors++;
    // Error already logged inside scanAndForward — just track for backoff
  }

  const delay =
    consecutiveErrors > 0
      ? Math.min(POLL_INTERVAL_MS * 2 ** consecutiveErrors, MAX_BACKOFF_MS)
      : POLL_INTERVAL_MS;

  setTimeout(runCycle, delay);
}

log("Starting up");
log(`Watching: ${SESSIONS_ROOT}/*/sessions/*.jsonl`);
log(`Cursor file: ${CURSOR_FILE}`);
log(`Forwarding to: ${API_URL}`);
log(`Auth token configured: ${AUTH_TOKEN ? "yes" : "NO — set OPENCLAW_LOG_SECRET"}`);
log(`Tenant ID: ${TENANT_ID}`);

// Run first scan immediately, then schedule recursively
void runCycle();
