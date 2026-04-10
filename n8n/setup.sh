#!/usr/bin/env bash
#
# dev-pipeline n8n setup — fully automated, idempotent
#
# Sets up n8n as a background service with the Agent Orchestrator workflow.
# Reads/creates credentials in macOS Keychain, configures SSH localhost,
# imports n8n credentials + workflow, and registers the n8n MCP with Claude Code.
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

# ──────────── Helpers ────────────

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Missing prerequisite: $1"
    exit 1
  fi
}

keychain_get() {
  security find-generic-password -s "$1" -a "$2" -w 2>/dev/null
}

keychain_exists() {
  security find-generic-password -s "$1" -a "$2" >/dev/null 2>&1
}

keychain_set() {
  security add-generic-password -s "$1" -a "$2" -w "$3" -U 2>/dev/null
}

prompt_secret() {
  local prompt="$1"
  local value=""
  echo -n "   $prompt: "
  read -r value
  echo "$value"
}

# ──────────── 1. Prerequisites ────────────

echo "🔍 Checking prerequisites..."
check_cmd node
check_cmd npm
check_cmd gh
check_cmd jq
check_cmd security
check_cmd claude
echo "   ✅ node $(node --version), npm $(npm --version)"

if ! command -v n8n >/dev/null 2>&1; then
  echo "📦 Installing n8n..."
  npm install -g n8n
else
  echo "   ✅ n8n $(n8n --version)"
fi

N8N_BIN="$(which n8n)"

# ──────────── 2. Keychain Credentials ────────────

echo ""
echo "🔑 Checking Keychain credentials..."

# Calvinball client-id
if keychain_exists "calvinball-mcp" "client-id"; then
  echo "   ✅ calvinball-mcp / client-id"
else
  echo "   ⚠ calvinball-mcp / client-id not found"
  echo "   You need your Calvinball OAuth client ID (from Laravel Passport)."
  CID=$(prompt_secret "Enter Calvinball client ID")
  keychain_set "calvinball-mcp" "client-id" "$CID"
  echo "   ✅ Stored in Keychain"
fi

# Calvinball client-secret
if keychain_exists "calvinball-mcp" "client-secret"; then
  echo "   ✅ calvinball-mcp / client-secret"
else
  echo "   ⚠ calvinball-mcp / client-secret not found"
  echo "   You need your Calvinball OAuth client secret (from Laravel Passport)."
  CSEC=$(prompt_secret "Enter Calvinball client secret")
  keychain_set "calvinball-mcp" "client-secret" "$CSEC"
  echo "   ✅ Stored in Keychain"
fi

# Claude Code OAuth token
if keychain_exists "claude-code" "oauth-token"; then
  echo "   ✅ claude-code / oauth-token"
else
  echo "   ⚠ claude-code / oauth-token not found"
  echo "   Run this command in a separate terminal:"
  echo ""
  echo "      claude setup-token"
  echo ""
  echo "   Copy the token it prints (starts with sk-ant-oat01-...)."
  CTOKEN=$(prompt_secret "Paste the token")
  keychain_set "claude-code" "oauth-token" "$CTOKEN"
  echo "   ✅ Stored in Keychain"
fi

# GitHub CLI token
if keychain_exists "github-cli" "token"; then
  echo "   ✅ github-cli / token"
else
  echo "   ⚠ github-cli / token not found"
  # Try to extract from gh's own Keychain entry
  GH_RAW=$(security find-generic-password -s "gh:github.com" -w 2>/dev/null || true)
  if [ -n "$GH_RAW" ]; then
    GH_TOK=$(echo "$GH_RAW" | sed 's/^go-keyring-base64://' | base64 -d 2>/dev/null || true)
    if [ -n "$GH_TOK" ]; then
      keychain_set "github-cli" "token" "$GH_TOK"
      echo "   ✅ Extracted from gh CLI Keychain entry"
    fi
  fi
  if ! keychain_exists "github-cli" "token"; then
    echo "   Run 'gh auth login' first, then re-run this script."
    exit 1
  fi
fi

# ──────────── 3. SSH Localhost Setup ────────────

echo ""
echo "🔐 Setting up SSH localhost access..."

# Check Remote Login
if ssh -o BatchMode=yes -o ConnectTimeout=2 localhost "echo ok" >/dev/null 2>&1; then
  echo "   ✅ SSH localhost works"
else
  # Add to known_hosts
  ssh-keyscan -H localhost >> ~/.ssh/known_hosts 2>/dev/null || true

  # Add public key to authorized_keys
  PUBKEY=""
  for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    [ -f "$f" ] && PUBKEY="$f" && break
  done
  if [ -z "$PUBKEY" ]; then
    echo "   ❌ No SSH public key found. Run: ssh-keygen -t ed25519"
    exit 1
  fi
  if ! grep -qF "$(cat "$PUBKEY")" ~/.ssh/authorized_keys 2>/dev/null; then
    cat "$PUBKEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
  fi

  # Test again
  if ssh -o BatchMode=yes -o ConnectTimeout=2 localhost "echo ok" >/dev/null 2>&1; then
    echo "   ✅ SSH localhost configured and working"
  else
    echo "   ❌ SSH localhost failed. Enable Remote Login:"
    echo "      System Settings → General → Sharing → Remote Login → ON"
    exit 1
  fi
fi

# ──────────── 4. Launchd Plist ────────────

echo ""
echo "🚀 Configuring n8n service..."

mkdir -p "$N8N_LOG_DIR"

# Read credentials from Keychain for plist injection
CALVINBALL_CID=$(keychain_get "calvinball-mcp" "client-id")
CALVINBALL_CSEC=$(keychain_get "calvinball-mcp" "client-secret")
CLAUDE_TOKEN=$(keychain_get "claude-code" "oauth-token")
GH_TOKEN=$(keychain_get "github-cli" "token")

# Resolve PATH: put Herd/NVM node dir first
NODE_DIR="$(dirname "$N8N_BIN")"
CLAUDE_DIR="$(dirname "$(which claude)")"
GH_DIR="$(dirname "$(which gh)")"
FULL_PATH="$NODE_DIR:$CLAUDE_DIR:$GH_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [ -f "$PLIST_PATH" ] && [ "$FORCE" = "false" ]; then
  echo "   ✅ Launchd plist exists (use --force to regenerate)"
else
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
    <string>false</string>
    <key>NODE_FUNCTION_ALLOW_BUILTIN</key>
    <string>child_process,fs</string>
    <key>N8N_BLOCK_ENV_ACCESS_IN_NODE</key>
    <string>false</string>
    <key>NODE_FUNCTION_ALLOW_EXTERNAL</key>
    <string>*</string>
    <key>CALVINBALL_CLIENT_ID</key>
    <string>$CALVINBALL_CID</string>
    <key>CALVINBALL_CLIENT_SECRET</key>
    <string>$CALVINBALL_CSEC</string>
    <key>CLAUDE_CODE_OAUTH_TOKEN</key>
    <string>$CLAUDE_TOKEN</string>
    <key>GH_TOKEN</key>
    <string>$GH_TOKEN</string>
    <key>PATH</key>
    <string>$FULL_PATH</string>
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
  chmod 600 "$PLIST_PATH"
  echo "   ✅ Plist generated (chmod 600)"
fi

# ──────────── 5. Start n8n ────────────

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "   ⏳ Waiting for n8n on port $N8N_PORT..."
TRIES=0
while [ $TRIES -lt 30 ]; do
  if curl -sf -o /dev/null "http://localhost:$N8N_PORT/healthz" 2>/dev/null; then
    echo "   ✅ n8n running"
    break
  fi
  TRIES=$((TRIES + 1))
  sleep 1
done
if [ $TRIES -eq 30 ]; then
  echo "   ❌ n8n failed to start. Check $N8N_LOG_DIR/n8n-stderr.log"
  exit 1
fi

# Check if first-time setup needed
SETTINGS=$(curl -sf "http://localhost:$N8N_PORT/rest/settings" 2>/dev/null | jq -r '.data.userManagement.showSetupOnFirstLoad // false' 2>/dev/null || echo "unknown")
if [ "$SETTINGS" = "true" ] || [ "$SETTINGS" = "unknown" ]; then
  echo ""
  echo "   ⚠ First-time n8n setup required."
  echo "   Open http://localhost:$N8N_PORT and create an owner account."
  echo -n "   Press Enter when done: "
  read -r
fi

# ──────────── 6. n8n Credential Imports ────────────

echo ""
echo "📥 Importing n8n credentials..."

# Calvinball OAuth2
CRED_FILE=$(mktemp)
cat > "$CRED_FILE" <<EOF
[{
  "id": "calvinball-oauth2",
  "name": "Calvinball OAuth2",
  "type": "oAuth2Api",
  "data": {
    "grantType": "clientCredentials",
    "accessTokenUrl": "https://calvinball.mikebronner.dev/oauth/token",
    "clientId": "$CALVINBALL_CID",
    "clientSecret": "$CALVINBALL_CSEC",
    "authentication": "body"
  }
}]
EOF
n8n import:credentials --input="$CRED_FILE" 2>&1 | grep -v "^$" || true
echo "   ✅ Calvinball OAuth2"
rm -f "$CRED_FILE"

# Local SSH
SSH_KEY=""
for f in ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
  [ -f "$f" ] && SSH_KEY="$f" && break
done
if [ -n "$SSH_KEY" ]; then
  CRED_FILE=$(mktemp)
  SSH_KEY_CONTENT=$(python3 -c "import json; print(json.dumps(open('$SSH_KEY').read()))")
  cat > "$CRED_FILE" <<EOF
[{
  "id": "local-ssh",
  "name": "Local SSH",
  "type": "sshPrivateKey",
  "data": {
    "host": "localhost",
    "port": 22,
    "username": "$(whoami)",
    "privateKey": $SSH_KEY_CONTENT
  }
}]
EOF
  n8n import:credentials --input="$CRED_FILE" 2>&1 | grep -v "^$" || true
  echo "   ✅ Local SSH"
  rm -f "$CRED_FILE"
fi

# ──────────── 7. Workflow Import + Publish ────────────

echo ""
echo "📥 Importing workflow..."

WORKFLOW_FILE="$SCRIPT_DIR/workflows/orchestrator.json"
if [ -f "$WORKFLOW_FILE" ]; then
  n8n import:workflow --input="$WORKFLOW_FILE" 2>&1 | grep -v "^$" || true
  echo "   ✅ Agent Orchestrator imported"
else
  echo "   ❌ Workflow file not found: $WORKFLOW_FILE"
  exit 1
fi

echo "   ℹ To publish the workflow, open the n8n UI and activate it,"
echo "   or use the n8n MCP from Claude Code."

# ──────────── 8. Claude Code MCP Registration ────────────

echo ""
echo "🔌 Claude Code MCP setup..."

if keychain_exists "n8n-mcp" "api-token"; then
  echo "   ✅ n8n MCP token exists in Keychain"
  N8N_TOKEN=$(keychain_get "n8n-mcp" "api-token")
else
  echo "   ⚠ n8n MCP API token needed."
  echo "   In the n8n UI: Settings → API → Create API Key"
  N8N_TOKEN=$(prompt_secret "Paste the API key")
  keychain_set "n8n-mcp" "api-token" "$N8N_TOKEN"
  echo "   ✅ Stored in Keychain"
fi

# Register with Claude Code (idempotent — overwrites if exists)
claude mcp remove n8n 2>/dev/null || true
claude mcp add n8n "http://localhost:$N8N_PORT/mcp-server/http" \
  --transport http \
  --scope user \
  -H "Authorization: Bearer $N8N_TOKEN" 2>&1 | grep -v "^$" || true
echo "   ✅ Registered with Claude Code"

# ──────────── 9. Summary ────────────

echo ""
echo "═══════════════════════════════════════════"
echo "  dev-pipeline n8n setup complete"
echo "═══════════════════════════════════════════"
echo ""
echo "  n8n UI:      http://localhost:$N8N_PORT"
echo "  Plist:       $PLIST_PATH"
echo "  Logs:        $N8N_LOG_DIR/"
echo "  Workflow:    Agent Orchestrator (14 nodes)"
echo "  Agents:      Wormwood (Haiku), Tracer (Sonnet), Moe (Opus)"
echo ""
echo "  Next steps:"
echo "  1. Activate the workflow in the n8n UI"
echo "  2. Restart Claude Code to load the n8n MCP"
echo "═══════════════════════════════════════════"
