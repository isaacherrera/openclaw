#!/bin/sh
# OpenClaw startup wrapper
# Starts log forwarder in background, then starts gateway as PID 1

# Add /data/bin to PATH for gog and other persistent binaries
export PATH="/data/bin:$PATH"

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

echo "[start.sh] Starting log forwarder..."
node /data/log-forwarder.js &
FORWARDER_PID=$!
echo "[start.sh] Log forwarder started (PID: $FORWARDER_PID)"

echo "[start.sh] Starting usage monitor..."
node /data/usage-monitor.js &
MONITOR_PID=$!
echo "[start.sh] Usage monitor started (PID: $MONITOR_PID)"

echo "[start.sh] Starting OpenClaw gateway..."
exec node dist/index.js gateway --allow-unconfigured --port 3000 --bind lan
