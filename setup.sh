#!/usr/bin/env bash
#
# workbench-dev-team setup — Calvinball MCP + Dispatch (local orchestrator)
#
# This script:
#   1. Verifies prerequisites (gh, jq, claude, security).
#   2. Verifies Keychain entries exist for the Calvinball OAuth client used
#      by the Calvinball MCP server (prompts if missing).
#   3. Registers the Calvinball MCP with Claude Code at user scope so it's
#      available to headless `claude -p --agent ...` subagent dispatches.
#   4. Creates the log directory the Dispatcher writes to.
#   5. Registers the scheduled Dispatch task via a headless `claude -p`
#      session that calls mcp__scheduled-tasks__create_scheduled_task
#      (or update_scheduled_task if the task already exists).
#
# Usage:
#   bash setup.sh                  # default cadence: every 20 min
#   bash setup.sh --cadence=30     # every 30 min
#   bash setup.sh --skip-schedule  # skip step 5 (don't register scheduled task)

set -euo pipefail

CALVINBALL_MCP_URL="https://calvinball.mikebronner.dev/mcp"
CALVINBALL_TOKEN_URL="https://calvinball.mikebronner.dev/oauth/token"
LOG_DIR="$HOME/.claude-workbench/dev-team-logs"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCHESTRATOR_FILE="$REPO_DIR/scheduled-tasks/orchestrator.md"
TASK_ID="workbench-dev-team-dispatch"

# ──────────── Flag parsing ────────────

CADENCE=20
SKIP_SCHEDULE=0
for arg in "$@"; do
  case $arg in
    --cadence=*)
      CADENCE="${arg#*=}"
      ;;
    --skip-schedule)
      SKIP_SCHEDULE=1
      ;;
    -h|--help)
      sed -n '2,19p' "$0" | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "❌ Unknown flag: $arg"
      echo "   Usage: bash setup.sh [--cadence=20|30] [--skip-schedule]"
      exit 1
      ;;
  esac
done

if [ "$CADENCE" != "20" ] && [ "$CADENCE" != "30" ]; then
  echo "❌ --cadence must be 20 or 30 (got: $CADENCE)"
  exit 1
fi

CRON="*/$CADENCE * * * *"

# ──────────── Helpers ────────────

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Missing prerequisite: $1"
    exit 1
  fi
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
check_cmd gh
check_cmd jq
check_cmd security
check_cmd claude
echo "   ✅ gh, jq, security, claude"

# ──────────── 2. Keychain credentials ────────────

echo ""
echo "🔑 Checking Keychain credentials..."

if keychain_exists "calvinball-mcp" "client-id"; then
  echo "   ✅ calvinball-mcp / client-id"
else
  echo "   ⚠  calvinball-mcp / client-id not found"
  CID=$(prompt_secret "Enter Calvinball client ID")
  keychain_set "calvinball-mcp" "client-id" "$CID"
  echo "   ✅ Stored in Keychain"
fi

if keychain_exists "calvinball-mcp" "client-secret"; then
  echo "   ✅ calvinball-mcp / client-secret"
else
  echo "   ⚠  calvinball-mcp / client-secret not found"
  CSEC=$(prompt_secret "Enter Calvinball client secret")
  keychain_set "calvinball-mcp" "client-secret" "$CSEC"
  echo "   ✅ Stored in Keychain"
fi

# GitHub CLI token — dispatched agents need `gh` authenticated.
if keychain_exists "github-cli" "token"; then
  echo "   ✅ github-cli / token"
else
  echo "   ⚠  github-cli / token not found"
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

# Claude Code OAuth token — required by scheduled `claude -p` invocations.
if keychain_exists "claude-code" "oauth-token"; then
  echo "   ✅ claude-code / oauth-token"
else
  echo "   ⚠  claude-code / oauth-token not found"
  echo "      In a separate terminal, run: claude setup-token"
  echo "      Copy the token (starts with sk-ant-oat01-)."
  CTOKEN=$(prompt_secret "Paste the token")
  keychain_set "claude-code" "oauth-token" "$CTOKEN"
  echo "   ✅ Stored in Keychain"
fi

# ──────────── 3. Register Calvinball MCP ────────────
#
# Claude Code's HTTP MCP client doesn't implement the OAuth 2.1 client_credentials
# grant. The --client-id/--client-secret flags on `claude mcp add` are for
# interactive auth-code flows. For headless use, we fetch a bearer token
# ourselves and pass it via --header. Calvinball tokens are good for ~1 year,
# so set-and-forget works fine — re-run setup.sh to refresh.

echo ""
echo "🔌 Registering Calvinball MCP with Claude Code..."

CLIENT_ID=$(security find-generic-password -s "calvinball-mcp" -a "client-id" -w)
CLIENT_SECRET=$(security find-generic-password -s "calvinball-mcp" -a "client-secret" -w)

TOKEN_RESP=$(curl -sS -X POST "$CALVINBALL_TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "scope=calvinball.mcp.read calvinball.mcp.write")

TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty')
if [ -z "$TOKEN" ]; then
  echo "   ❌ Could not fetch OAuth token from $CALVINBALL_TOKEN_URL"
  echo "      Response: $TOKEN_RESP"
  exit 1
fi
echo "   ✅ Fetched bearer token (1-year lifetime)"

claude mcp remove calvinball 2>/dev/null || true
claude mcp add calvinball "$CALVINBALL_MCP_URL" \
  --transport http \
  --scope user \
  --header "Authorization: Bearer $TOKEN" 2>&1 | grep -E "^(Added|Error)" || true
echo "   ✅ Registered (user scope) → $CALVINBALL_MCP_URL"

# Verify connection
sleep 1
if claude mcp list 2>&1 | grep -q "calvinball.*Connected"; then
  echo "   ✅ Connection verified"
else
  echo "   ⚠  'claude mcp list' does not yet show Connected — may take a moment"
fi

# ──────────── 4. Log directory ────────────

echo ""
echo "📁 Creating log directory..."
mkdir -p "$LOG_DIR"
echo "   ✅ $LOG_DIR"

# ──────────── 5. Register scheduled Dispatch task ────────────

if [ "$SKIP_SCHEDULE" = "1" ]; then
  echo ""
  echo "⏭  Skipping scheduled-task registration (--skip-schedule)."
else
  if [ ! -f "$ORCHESTRATOR_FILE" ]; then
    echo ""
    echo "❌ Missing orchestrator prompt: $ORCHESTRATOR_FILE"
    echo "   This file is shipped with the plugin — try reinstalling."
    exit 1
  fi

  echo ""
  echo "⏰ Registering scheduled Dispatch task ($CRON)..."
  echo "   (spawning 'claude -p' to call mcp__scheduled-tasks__create_scheduled_task)"

  # The headless Claude is told to:
  #   1. List existing scheduled tasks.
  #   2. Read the orchestrator file (stripping YAML frontmatter).
  #   3. Create or update the task keyed on $TASK_ID.
  #
  # We pass the orchestrator file PATH, not its contents, to avoid any
  # shell-quoting pitfalls. Claude uses its Read tool.

  REGISTRATION_PROMPT="You are performing a one-shot task registration. Do only what follows — do not ask questions, do not explain.

1. Call mcp__scheduled-tasks__list_scheduled_tasks.

2. Use the Read tool to read this file in its entirety:
   $ORCHESTRATOR_FILE

   Strip the leading YAML frontmatter block (everything between the first pair of --- lines, inclusive of both ---). The remaining markdown body is the task prompt.

3. If the list in step 1 includes a task with taskId '$TASK_ID':
     Call mcp__scheduled-tasks__update_scheduled_task with:
       taskId: '$TASK_ID'
       cronExpression: '$CRON'
       prompt: <the stripped body from step 2>
       description: 'Dispatch — poll Calvinball every $CADENCE min and fire workbench-dev-team agents on pending items.'
   Otherwise:
     Call mcp__scheduled-tasks__create_scheduled_task with the same four arguments.

4. Print exactly one line: 'registered' if created, 'updated' if updated. Then stop."

  # Run the registration. --dangerously-skip-permissions so the headless
  # session doesn't block on approval prompts for the scheduled-tasks MCP.
  if claude -p --dangerously-skip-permissions --no-session-persistence "$REGISTRATION_PROMPT"; then
    echo "   ✅ Scheduled task '$TASK_ID' is live at cron '$CRON'."
  else
    echo "   ❌ Registration failed. Re-run with --skip-schedule and register manually."
    echo "      See README for the one-shot command."
    exit 1
  fi
fi

# ──────────── Done ────────────

echo ""
echo "═══════════════════════════════════════════"
echo "  workbench-dev-team setup complete"
echo "═══════════════════════════════════════════"
echo ""
echo "  Calvinball MCP:   $CALVINBALL_MCP_URL"
echo "  Log directory:    $LOG_DIR"
if [ "$SKIP_SCHEDULE" = "1" ]; then
  echo "  Scheduled task:   ⚠  not registered (--skip-schedule)"
else
  echo "  Scheduled task:   $TASK_ID @ $CRON"
fi
echo ""
echo "  Agents: Wormwood (Haiku), Tracer (Sonnet), Moe (Opus, \$5 cap)"
echo "  Verify in Claude Code's scheduled-tasks panel."
echo "═══════════════════════════════════════════"
