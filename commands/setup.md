---
description: Configure the workbench-dev-team plugin — verify prerequisites, seed Keychain credentials, register The Index MCP, and deploy the scheduled Dispatch task. Re-run after a plugin update or to refresh the OAuth bearer token (annual).
---

The user has invoked `/workbench-dev-team:setup`. Walk them through the one-time
(or annual-refresh) configuration of the plugin.

This command is fully idempotent — re-running is safe at any time. It will skip
already-satisfied steps, refresh the OAuth bearer token (1-year lifetime), and
update rather than duplicate the scheduled Dispatch task.

## Constants

```text
The Index MCP URL:    https://the-index.mikebronner.dev/mcp
The Index OAuth URL:  https://the-index.mikebronner.dev/oauth/token
Log directory:         ~/.claude-workbench/dev-team-logs
Agent config:          ~/.claude-workbench/dev-team-config.json
Scheduled task ID:     workbench-dev-team-dispatch
Orchestrator prompt:   ${CLAUDE_PLUGIN_ROOT}/scheduled-tasks/orchestrator.md
```

## Step 1 — Collect cadence and scheduling preference

Use `AskUserQuestion` to gather two choices up front, so the rest of the run is
non-interactive once credentials are in place:

```jsonc
AskUserQuestion({
  questions: [
    {
      question: "Dispatch cadence — how often should the orchestrator poll The Index?",
      header: "Cadence",
      multiSelect: false,
      options: [
        { label: "Every 20 min", description: "Default. Cron: */20 * * * *" },
        { label: "Every 30 min", description: "Cron: */30 * * * *" }
      ]
    },
    {
      question: "Register the scheduled Dispatch task now?",
      header: "Schedule",
      multiSelect: false,
      options: [
        { label: "Yes — register it", description: "Creates or updates the workbench-dev-team-dispatch task" },
        { label: "Skip — register it later", description: "MCP is set up but no task is scheduled. Re-run setup any time to register." }
      ]
    }
  ]
})
```

Save the answers as `CADENCE` (`20` or `30`) and `REGISTER_SCHEDULE` (boolean).
Build `CRON="*/${CADENCE} * * * *"`.

## Step 2 — Verify prerequisites

Run a single Bash check for the host tools the rest of the script needs:

```bash
missing=()
for cmd in gh jq security; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing prerequisites: ${missing[*]}"
  echo "   Install the missing tools and re-run /workbench-dev-team:setup."
  exit 1
fi
echo "✅ gh, jq, security all present"
```

Do not check for `claude` — we're already running inside a Claude Code session.

If any prerequisite is missing, stop and tell the user how to install it
(`brew install gh jq` for the common case; `security` ships with macOS).

## Step 3 — Seed Keychain credentials

Four entries are required. For each, check existence first; only prompt the
user for missing ones.

### Helper functions (run once at the top of the step)

```bash
keychain_exists() {
  security find-generic-password -s "$1" -a "$2" >/dev/null 2>&1
}
keychain_set() {
  security add-generic-password -s "$1" -a "$2" -w "$3" -U 2>/dev/null
}
```

### 3a. `the-index-mcp / client-id`

```bash
if keychain_exists "the-index-mcp" "client-id"; then
  echo "✅ the-index-mcp / client-id (already in Keychain)"
else
  echo "⚠  the-index-mcp / client-id is missing"
fi
```

If missing, ask the user in chat: **"Paste your The Index OAuth client ID. I'll
store it in the macOS Keychain under `the-index-mcp / client-id`."** Wait for
the next user message, then:

```bash
keychain_set "the-index-mcp" "client-id" "<value>"
echo "✅ Stored"
```

### 3b. `the-index-mcp / client-secret`

Same pattern as 3a. Prompt: **"Paste your The Index OAuth client secret."**

### 3c. `github-cli / token`

This one has a fast path — try to extract the token from the existing `gh` CLI
Keychain entry before asking the user:

```bash
if keychain_exists "github-cli" "token"; then
  echo "✅ github-cli / token (already in Keychain)"
else
  echo "⚠  github-cli / token is missing — trying to extract from gh CLI"
  GH_RAW=$(security find-generic-password -s "gh:github.com" -w 2>/dev/null || true)
  if [ -n "$GH_RAW" ]; then
    GH_TOK=$(echo "$GH_RAW" | sed 's/^go-keyring-base64://' | base64 -d 2>/dev/null || true)
    if [ -n "$GH_TOK" ]; then
      keychain_set "github-cli" "token" "$GH_TOK"
      echo "✅ Extracted from gh CLI Keychain entry"
    fi
  fi
  if ! keychain_exists "github-cli" "token"; then
    echo "❌ Could not auto-extract. Run 'gh auth login' first, then re-run /workbench-dev-team:setup."
    exit 1
  fi
fi
```

If extraction fails, stop and tell the user to run `gh auth login` first.

### 3d. `claude-code / oauth-token`

```bash
if keychain_exists "claude-code" "oauth-token"; then
  echo "✅ claude-code / oauth-token (already in Keychain)"
fi
```

If missing, tell the user: **"The scheduled Dispatch task needs a Claude Code
OAuth token to invoke `claude -p` headlessly. Open a separate terminal and run:**

```
claude setup-token
```

**Then paste the token here (it starts with `sk-ant-oat01-`)."** Wait for the
next message, then store:

```bash
keychain_set "claude-code" "oauth-token" "<value>"
echo "✅ Stored"
```

## Step 4 — Fetch OAuth bearer token

```bash
CLIENT_ID=$(security find-generic-password -s "the-index-mcp" -a "client-id" -w)
CLIENT_SECRET=$(security find-generic-password -s "the-index-mcp" -a "client-secret" -w)

TOKEN_RESP=$(curl -sS -X POST "https://the-index.mikebronner.dev/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "scope=index.mcp.read index.mcp.write")

TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty')
if [ -z "$TOKEN" ]; then
  echo "❌ Could not fetch OAuth token"
  echo "   Response: $TOKEN_RESP"
  exit 1
fi
echo "✅ Fetched bearer token (1-year lifetime)"
```

The token has roughly a 1-year lifetime — re-run this command annually (or
whenever the OAuth client secret rotates) to refresh it.

## Step 5 — Register The Index MCP with Claude Code

Claude Code's HTTP MCP client doesn't implement the OAuth 2.1
`client_credentials` grant — `--client-id`/`--client-secret` flags are for
interactive auth-code flows only. Headless registration uses the bearer token
fetched in Step 4 via `--header`:

```bash
claude mcp remove the-index 2>/dev/null || true
claude mcp add the-index "https://the-index.mikebronner.dev/mcp" \
  --transport http \
  --scope user \
  --header "Authorization: Bearer $TOKEN"

sleep 1
if claude mcp list 2>&1 | grep -q "the-index.*Connected"; then
  echo "✅ The Index MCP registered (user scope) and connected"
else
  echo "⚠  'claude mcp list' does not yet show Connected — registration may take a moment"
  echo "   Verify after the next Claude Code restart."
fi
```

**Note for the user:** The MCP is registered at user scope, so all future Claude
Code sessions (including the headless `claude -p` invocations used by Dispatch)
will see it. The current session may need a restart to pick it up.

## Step 6 — Create the log directory and agent config

```bash
mkdir -p "$HOME/.claude-workbench/dev-team-logs"
echo "✅ Log directory ready: $HOME/.claude-workbench/dev-team-logs"

CONFIG="$HOME/.claude-workbench/dev-team-config.json"
if [ -f "$CONFIG" ]; then
  echo "✅ Agent config already present: $CONFIG (left untouched)"
else
  cat > "$CONFIG" <<'EOF'
{
  "agents": {
    "lestrade": { "model": "sonnet", "effort": "high" },
    "holmes": { "model": "opus", "effort": "xhigh", "fanout": true, "lensModel": "sonnet" },
    "watson": { "model": "fable", "effort": "xhigh", "maxBudgetUsd": 10.00 }
  }
}
EOF
  echo "✅ Wrote default agent config: $CONFIG"
fi
```

The config is the single source of truth for per-agent model, effort, and
Watson's budget cap, read by both dispatch paths: the scheduled Dispatch task
passes `--model` / `--effort` / `--max-budget-usd` from it, and the
`/workbench-dev-team:orchestrate` skill reads it for interactive sub-agent
dispatch. Setup never overwrites an existing config — the user's edits stick
across plugin updates and re-runs. All three agents now run effort-capable
models: `xhigh` for the long-horizon agentic roles (Watson's development runs,
Holmes's reviews), `high` for Lestrade's bounded triage — note `xhigh` is not
supported on Sonnet, so Lestrade's ceiling short of `max` is `high`.
Holmes's optional `fanout` (bool, default `true`) toggles its
multi-lens review fan-out, and `lensModel` (default: Holmes's own `model`) sets
the model its lens and skeptic sub-agents run on — both default cleanly when
absent.

## Step 7 — Register the scheduled Dispatch task

Skip this step entirely if `REGISTER_SCHEDULE` from Step 1 was "Skip".

### 7a. Read and strip the orchestrator prompt

Use the `Read` tool to read the orchestrator file:

```
${CLAUDE_PLUGIN_ROOT}/scheduled-tasks/orchestrator.md
```

Strip the leading YAML frontmatter — everything between the first `---` line
and its matching closing `---` (inclusive of both `---` markers and any blank
line after the closing one). The remaining markdown body is the prompt the
scheduled task will execute every tick.

### 7b. Check for an existing task

Call `mcp__scheduled-tasks__list_scheduled_tasks` and look for a task whose
`taskId` is `workbench-dev-team-dispatch`.

### 7c. Create or update

Build the description string: `"Dispatch — poll The Index every {CADENCE} min and fire workbench-dev-team agents on pending items."`

**If the task already exists**, call `mcp__scheduled-tasks__update_scheduled_task`:

```jsonc
{
  taskId: "workbench-dev-team-dispatch",
  cronExpression: CRON,
  prompt: <stripped orchestrator body>,
  description: <description string>
}
```

**If the task does not exist**, call `mcp__scheduled-tasks__create_scheduled_task`
with the same four arguments.

Confirm to the user which action was taken (`registered` or `updated`).

## Step 8 — Final summary

Print a clean summary block:

```text
═══════════════════════════════════════════
  workbench-dev-team setup complete
═══════════════════════════════════════════

  The Index MCP:   https://the-index.mikebronner.dev/mcp
  Log directory:    ~/.claude-workbench/dev-team-logs
  Agent config:     ~/.claude-workbench/dev-team-config.json
  Scheduled task:   workbench-dev-team-dispatch @ */{CADENCE} * * * *
                    (or: ⚠ not registered — re-run setup to register)

  Agents:           Lestrade (Haiku), Holmes (Sonnet), Watson (Opus, $5 cap)
                    — models/effort/budget editable in the agent config

  Verify in Claude Code's scheduled-tasks panel.
═══════════════════════════════════════════
```

Substitute the actual cadence and adjust the scheduled-task line if registration
was skipped.

## Notes

- **Idempotency.** All four keychain checks, the MCP registration (`remove ||
  true` then `add`), the `mkdir -p`, and the scheduled-task list-then-create-or-
  update flow are safe to re-run. Step 4 always fetches a fresh token, which is
  exactly the desired behavior on re-run (annual refresh is the dominant use
  case).
- **OAuth token lifetime.** The Index issues 1-year tokens via
  client_credentials. Schedule a calendar reminder, or just re-run this command
  any time `claude mcp list` shows `the-index` as `Failed to connect`.
- **No headless `claude -p` subprocess.** Earlier versions of this configuration
  spawned a headless `claude -p --dangerously-skip-permissions` to register the
  scheduled task. Inside a slash command the parent session calls
  `mcp__scheduled-tasks__*` tools directly, eliminating subprocess spawn,
  shell-quoted prompt templates, and the skip-permissions flag.
