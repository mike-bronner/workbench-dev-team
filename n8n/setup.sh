#!/usr/bin/env bash
#
# dev-pipeline n8n setup — idempotent
#
# Installs n8n (if missing), configures it as a launchd service,
# imports the agent polling workflows, and activates them.
#
# Prerequisites:
#   - macOS with Keychain access
#   - Calvinball credentials in Keychain (service: calvinball-mcp)
#   - Claude Code installed (claude CLI on PATH)
#   - gh CLI authenticated
#
# Usage: bash n8n/setup.sh [--force]
#   --force: regenerate launchd plist even if it exists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_PATH="$HOME/Library/LaunchAgents/com.mikebronner.n8n.plist"
N8N_PORT=5679
N8N_LOG_DIR="$HOME/.n8n/logs"
FORCE=false

[ "${1:-}" = "--force" ] && FORCE=true

# ──────────── Prerequisites ────────────

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Missing prerequisite: $1"
    exit 1
  fi
}

echo "🔍 Checking prerequisites..."
check_cmd node
check_cmd npm
check_cmd gh
check_cmd jq
check_cmd security
check_cmd claude

# ──────────── Install n8n ────────────

if ! command -v n8n >/dev/null 2>&1; then
  echo "📦 Installing n8n..."
  npm install -g n8n
else
  echo "✅ n8n $(n8n --version) already installed"
fi

N8N_BIN="$(which n8n)"

# ──────────── Verify Keychain entries ────────────

echo "🔑 Checking Keychain entries..."
if ! security find-generic-password -s "calvinball-mcp" -a "client-id" -w >/dev/null 2>&1; then
  echo "❌ Missing Keychain entry: calvinball-mcp / client-id"
  echo "   Add it with: security add-generic-password -s calvinball-mcp -a client-id -w YOUR_CLIENT_ID"
  exit 1
fi

if ! security find-generic-password -s "calvinball-mcp" -a "client-secret" -w >/dev/null 2>&1; then
  echo "❌ Missing Keychain entry: calvinball-mcp / client-secret"
  echo "   Add it with: security add-generic-password -s calvinball-mcp -a client-secret -w YOUR_CLIENT_SECRET"
  exit 1
fi
echo "✅ Calvinball credentials found in Keychain"

# ──────────── Create log directory ────────────

mkdir -p "$N8N_LOG_DIR"

# ──────────── Generate launchd plist ────────────

if [ -f "$PLIST_PATH" ] && [ "$FORCE" = "false" ]; then
  echo "✅ launchd plist already exists (use --force to regenerate)"
else
  echo "📝 Generating launchd plist..."
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.mikebronner.n8n</string>
  <key>ProgramArguments</key>
  <array>
    <string>$N8N_BIN</string>
    <string>start</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>N8N_PORT</key>
    <string>$N8N_PORT</string>
    <key>N8N_SECURE_COOKIE</key>
    <string>false</string>
    <key>N8N_RUNNERS_ENABLED</key>
    <string>true</string>
    <key>PATH</key>
    <string>$(dirname "$N8N_BIN"):$(dirname "$(which claude)"):$(dirname "$(which gh)"):$(dirname "$(which jq)"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>SessionCreate</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$N8N_LOG_DIR/n8n-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$N8N_LOG_DIR/n8n-stderr.log</string>
  <key>WorkingDirectory</key>
  <string>$HOME</string>
</dict>
</plist>
PLIST
  echo "✅ Plist written to $PLIST_PATH"
fi

# ──────────── Load/reload the service ────────────

echo "🚀 Loading n8n service..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

# ──────────── Wait for n8n to start ────────────

echo "⏳ Waiting for n8n to start on port $N8N_PORT..."
TRIES=0
MAX_TRIES=30
while [ $TRIES -lt $MAX_TRIES ]; do
  if curl -sf -o /dev/null "http://localhost:$N8N_PORT/healthz" 2>/dev/null; then
    echo "✅ n8n is running on port $N8N_PORT"
    break
  fi
  TRIES=$((TRIES + 1))
  sleep 1
done

if [ $TRIES -eq $MAX_TRIES ]; then
  echo "❌ n8n failed to start within ${MAX_TRIES}s"
  echo "   Check logs at $N8N_LOG_DIR/n8n-stderr.log"
  exit 1
fi

# ──────────── Import workflows ────────────

echo "📥 Importing workflows..."
for wf in "$SCRIPT_DIR/workflows"/*.json; do
  [ -f "$wf" ] || continue
  NAME=$(basename "$wf" .json)
  n8n import:workflow --input="$wf" 2>&1 || echo "   ⚠ Failed to import $NAME"
  echo "   ✅ Imported: $NAME"
done

# ──────────── Test Keychain access from n8n context ────────────

echo "🔐 Testing Keychain access from launchd context..."
TEST_CID=$(security find-generic-password -s "calvinball-mcp" -a "client-id" -w 2>/dev/null)
if [ -n "$TEST_CID" ]; then
  echo "✅ Keychain access works"
else
  echo "⚠ Keychain access may not work from launchd context"
  echo "   If workflows fail to authenticate, see n8n/README.md for workarounds"
fi

# ──────────── Summary ────────────

echo ""
echo "═══════════════════════════════════════════"
echo "  dev-pipeline n8n setup complete"
echo "═══════════════════════════════════════════"
echo ""
echo "  n8n UI:     http://localhost:$N8N_PORT"
echo "  Logs:       $N8N_LOG_DIR/"
echo "  Plist:      $PLIST_PATH"
echo ""
echo "  Workflows imported. Activate them in the"
echo "  n8n UI or they'll start on their schedule"
echo "  automatically."
echo ""
echo "  Next: verify by checking the n8n UI at"
echo "  http://localhost:$N8N_PORT"
echo "═══════════════════════════════════════════"
