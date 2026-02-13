#!/bin/sh
# OpenClaw startup wrapper
# Starts log forwarder in background, then starts gateway as PID 1

# Add /data/bin to PATH for gog and other persistent binaries
export PATH="/data/bin:$PATH"
# Point gog config at persistent volume (survives deploys)
export XDG_CONFIG_HOME="/data/gog-config"

echo "[start.sh] Starting log forwarder..."
node /data/log-forwarder.js &
FORWARDER_PID=$!
echo "[start.sh] Log forwarder started (PID: $FORWARDER_PID)"

echo "[start.sh] Starting OpenClaw gateway..."
exec node dist/index.js gateway --allow-unconfigured --port 3000 --bind lan
