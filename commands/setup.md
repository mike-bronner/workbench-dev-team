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
Plugin registry:       ~/.claude/plugins/installed_plugins.json
Orchestrator prompt:   <resolved install path>/scheduled-tasks/orchestrator.md
```

The orchestrator prompt path is **resolved at run time in Step 7a**, not
hard-coded off `${CLAUDE_PLUGIN_ROOT}` — the running root can be a frozen
session snapshot. See Step 7a for the resolution order.

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
    "lestrade": { "model": "sonnet", "effort": "high", "fanout": true, "lensModel": "sonnet", "fallback": "haiku" },
    "holmes": { "model": "opus", "effort": "xhigh", "fanout": true, "lensModel": "sonnet", "maxBudgetUsd": 7.00, "fallback": "sonnet" },
    "watson": { "model": "opus", "effort": "xhigh", "maxBudgetUsd": 10.00, "fallback": "sonnet,haiku" }
  }
}
EOF
  echo "✅ Wrote default agent config: $CONFIG"
fi
```

The config is the single source of truth for per-agent model, effort, fallback,
and budget caps, read by both dispatch paths: the scheduled Dispatch task passes
`--model` / `--effort` / `--fallback-model` / `--max-budget-usd` from it, and the
`/workbench-dev-team:orchestrate` skill reads it for interactive sub-agent
dispatch. Setup never overwrites an existing config — the user's edits stick
across plugin updates and re-runs. All three agents run effort-capable models:
`xhigh` for the long-horizon agentic roles (Watson's development runs, Holmes's
reviews), `high` for Lestrade's bounded triage — note `xhigh` is not supported on
Sonnet, so a Sonnet agent's ceiling short of `max` is `high`. Holmes's optional `fanout`
(bool, default `true`) toggles its multi-lens review fan-out, and `lensModel`
(default: Holmes's own `model`) sets the model its lens and skeptic sub-agents run
on — both default cleanly when absent. Lestrade carries the same two knobs for its
own fan-out — four blind lenses that check the draft acceptance criteria before
scoring (`agents/lestrade.md`, §4.6). The optional `fallback` knob (a
comma-separated model list) is passed to `--fallback-model` on the scheduled path,
so a dispatch degrades to the next model when the primary is overloaded or
unavailable — e.g. a retired model — instead of failing. `maxBudgetUsd` caps a
run's spend: Watson defaults to `10.00`, Holmes's is optional and applied only
when set, and both default cleanly when absent.

## Step 6.5 — Choose commit attribution behavior

The Claude Code harness injects a built-in default that appends a
`Co-Authored-By: Claude` trailer to every commit message (and a comparable PR
footer) **whenever the `attribution` key is absent from `settings.json`**.
Whether that trailer should appear is the user's call — and dev-team owns commit
conventions, so it owns this setting either way: left unmanaged, the key is an
orphan that nothing maintains and silently drifts back to the harness default.

This step **detects the current state, asks the user which behavior they want,
and applies their choice in either direction** — non-destructively, preserving
every other key in `settings.json`. `jq` is already verified in Step 2, so no
re-check is needed.

### 6.5a — Detect the current state

```bash
SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"

ATTR_STATE="default"   # default | suppressed | custom
if [ -f "$SETTINGS" ] && jq empty "$SETTINGS" 2>/dev/null; then
  if jq -e '.attribution.commit == "" and .attribution.pr == ""' "$SETTINGS" >/dev/null 2>&1; then
    ATTR_STATE="suppressed"
  elif jq -e '(.attribution.commit != null) or (.attribution.pr != null)' "$SETTINGS" >/dev/null 2>&1; then
    ATTR_STATE="custom"
  fi
fi

case "$ATTR_STATE" in
  suppressed) echo "ℹ  Current state: attribution suppressed (commit + PR trailers off)";;
  custom)     echo "ℹ  Current state: custom attribution values set";;
  *)          echo "ℹ  Current state: default (Co-Authored-By trailer visible)";;
esac
```

Save the printed classification — feed it into the question text below as
`CURRENT_STATE` (`suppressed`, `custom`, or `default (visible)`).

### 6.5b — Ask the user

Use `AskUserQuestion`, surfacing the detected current state in the question
text. List the Recommended option first:

```jsonc
AskUserQuestion({
  questions: [
    {
      question: "Commit attribution — current state is {CURRENT_STATE}. Should commits and PRs carry Claude Code's Co-Authored-By / attribution footer?",
      header: "Attribution",
      multiSelect: false,
      options: [
        { label: "Suppress trailers (Recommended)", description: "Commits and PRs show no Co-Authored-By / attribution footer. Sets .attribution.commit/pr = \"\"." },
        { label: "Leave attribution in", description: "Keep Claude Code's default Co-Authored-By trailer on commits and PRs." }
      ]
    }
  ]
})
```

Save the answer as `ATTR_CHOICE` (`suppress` or `leave-in`).

### 6.5c — Apply the choice

Run **only** the block matching `ATTR_CHOICE`. Both are non-destructive: `jq`
reads the whole settings object and writes it back with only the two
`attribution` keys touched, so unrelated settings (permissions, env, hooks,
`outputStyle`) are preserved. Each branch refuses up front if the existing file
isn't valid JSON, validates the produced file with `jq empty` before replacing,
and makes **no write** when the file already matches the chosen end-state.

**If `ATTR_CHOICE` is `suppress`:**

```bash
# Already suppressed (present and empty-string) → no write.
if [ -f "$SETTINGS" ] \
  && jq -e '.attribution.commit == "" and .attribution.pr == ""' "$SETTINGS" >/dev/null 2>&1; then
  echo "✅ already suppressed (commit + PR trailers) — no change"
  ATTR_RESULT="suppressed"
else
  tmp="$(mktemp)"
  if [ -f "$SETTINGS" ]; then
    # Refuse up front if the existing file isn't valid JSON — never clobber it.
    if ! jq empty "$SETTINGS" 2>/dev/null; then
      rm -f "$tmp"
      echo "❌ Refusing to touch $SETTINGS — existing file is not valid JSON. Fix it by hand, then re-run."
      exit 1
    fi
    jq '.attribution.commit = "" | .attribution.pr = ""' "$SETTINGS" > "$tmp"
  else
    mkdir -p "$(dirname "$SETTINGS")"
    jq -n '{ attribution: { commit: "", pr: "" } }' > "$tmp"
  fi
  # Validate the produced file before replacing — never leave settings.json malformed.
  if ! jq empty "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "❌ Refusing to write — produced invalid JSON for $SETTINGS"
    exit 1
  fi
  mv "$tmp" "$SETTINGS"
  echo "✅ attribution suppressed (commit + PR trailers)"
  ATTR_RESULT="suppressed"
fi
```

**If `ATTR_CHOICE` is `leave-in`:**

```bash
# Desired end-state: our two keys absent (harness default returns). Already there
# (no file, or both keys absent) → no write, nothing created.
if [ ! -f "$SETTINGS" ] \
  || jq -e '(.attribution.commit == null) and (.attribution.pr == null)' "$SETTINGS" >/dev/null 2>&1; then
  echo "✅ already default (attribution trailer visible) — no change"
  ATTR_RESULT="default (visible)"
else
  # Refuse up front if the existing file isn't valid JSON — never clobber it.
  if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "❌ Refusing to touch $SETTINGS — existing file is not valid JSON. Fix it by hand, then re-run."
    exit 1
  fi
  tmp="$(mktemp)"
  # Drop only our two keys; if that leaves .attribution an empty object, drop it
  # too so the harness default returns. Sibling attribution keys are preserved.
  jq 'del(.attribution.commit, .attribution.pr)
      | if (.attribution // {}) == {} then del(.attribution) else . end' \
      "$SETTINGS" > "$tmp"
  # Validate the produced file before replacing — never leave settings.json malformed.
  if ! jq empty "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "❌ Refusing to write — produced invalid JSON for $SETTINGS"
    exit 1
  fi
  mv "$tmp" "$SETTINGS"
  echo "✅ attribution left in (default Co-Authored-By trailer restored)"
  ATTR_RESULT="default (visible)"
fi
```

Carry `ATTR_RESULT` (`suppressed` or `default (visible)`) into the Step 8
summary.

## Step 7 — Register the scheduled Dispatch task

Skip this step entirely if `REGISTER_SCHEDULE` from Step 1 was "Skip".

### 7a. Resolve the orchestrator source, then read and strip it

**Never read the orchestrator from `${CLAUDE_PLUGIN_ROOT}` when a better source
exists.** The harness expands that variable to the *executing* copy of the
plugin, which in a resumed session is a snapshot materialized once at session
creation under `~/Library/Application Support/Claude/local-agent-mode-sessions/…/plugin_<hash>/`
and never refreshed — not even by a full app restart, because the app resumes
the same session (anthropics/claude-code#45810). Deploying from that copy
silently pins Dispatch to whatever the plugin looked like weeks ago, and
because the stale prompt equals the stale source, setup reports success. Resolve
the install path recorded in `~/.claude/plugins/installed_plugins.json` instead,
and only fall back to the running root when that file can't answer:

```bash
RUN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
REGISTRY="$HOME/.claude/plugins/installed_plugins.json"
PLUGIN_KEY="workbench-dev-team@claude-workbench"

SRC_ROOT=""
SRC_VERSION=""

# `.plugins[$key]` is an ARRAY — one object per install scope (user/project/
# local), each carrying installPath, version, scope, installedAt, lastUpdated,
# gitCommitSha. Keep the enabled entries that actually name a path, then take
# the highest version. Sort numerically per dotted segment: a lexical sort ranks
# "0.9.0" above "0.37.4" and would deploy the older copy.
if [ -f "$REGISTRY" ] && jq empty "$REGISTRY" 2>/dev/null; then
  ENTRY=$(jq -c --arg key "$PLUGIN_KEY" '
    (.plugins[$key] // [])
    | map(select((.enabled != false) and ((.installPath // "") != "")))
    | sort_by((.version // "0") | split(".") | map(tonumber? // 0))
    | last // empty
  ' "$REGISTRY" 2>/dev/null || true)

  if [ -n "$ENTRY" ]; then
    CAND_ROOT=$(printf '%s' "$ENTRY" | jq -r '.installPath // ""')
    CAND_VERSION=$(printf '%s' "$ENTRY" | jq -r '.version // ""')
    # Trust the registry only if the file we actually need is really there.
    if [ -n "$CAND_ROOT" ] && [ -f "$CAND_ROOT/scheduled-tasks/orchestrator.md" ]; then
      SRC_ROOT="$CAND_ROOT"
      SRC_VERSION="$CAND_VERSION"
    elif [ -n "$CAND_ROOT" ]; then
      echo "⚠  $REGISTRY points at $CAND_ROOT, but scheduled-tasks/orchestrator.md is not readable there."
    fi
  fi
fi

# Fallback: the running root. Correct in a fresh session, stale in a resumed one
# — say so out loud rather than deploying from it quietly.
if [ -z "$SRC_ROOT" ]; then
  if [ -n "$RUN_ROOT" ] && [ -f "$RUN_ROOT/scheduled-tasks/orchestrator.md" ]; then
    SRC_ROOT="$RUN_ROOT"
    SRC_VERSION=$(jq -r '.version // ""' "$RUN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)
    echo "⚠  Could not resolve an install path from $REGISTRY — falling back to the running"
    echo "   plugin root ($SRC_ROOT). If this session's copy is frozen, the prompt deployed"
    echo "   below is frozen with it."
  else
    echo "❌ Could not locate scheduled-tasks/orchestrator.md — neither $REGISTRY nor"
    echo "   \$CLAUDE_PLUGIN_ROOT resolved a readable copy. Re-install or update the plugin,"
    echo "   then re-run /workbench-dev-team:setup."
    exit 1
  fi
fi

# Stale-root detection: what this session is EXECUTING vs. what is INSTALLED.
RUN_VERSION=""
if [ -n "$RUN_ROOT" ] && jq empty "$RUN_ROOT/.claude-plugin/plugin.json" 2>/dev/null; then
  RUN_VERSION=$(jq -r '.version // ""' "$RUN_ROOT/.claude-plugin/plugin.json")
fi

ORCHESTRATOR_SRC="$SRC_ROOT/scheduled-tasks/orchestrator.md"
STALE_ROOT_WARNING=""

if [ -n "$RUN_VERSION" ] && [ -n "$SRC_VERSION" ] && [ "$RUN_VERSION" != "$SRC_VERSION" ]; then
  STALE_ROOT_WARNING="⚠  STALE PLUGIN ROOT — this session ran v$RUN_VERSION; Dispatch was deployed from installed v$SRC_VERSION"
  cat <<EOF
⚠  ═══════════════ STALE PLUGIN ROOT ═══════════════
   This session is EXECUTING workbench-dev-team v$RUN_VERSION from:
     $RUN_ROOT
   but the INSTALLED plugin is v$SRC_VERSION at:
     $SRC_ROOT
   \$CLAUDE_PLUGIN_ROOT is materialized once when a session is created and is
   never refreshed — not even by an app restart that resumes the same session
   (anthropics/claude-code#45810).
   → The Dispatch prompt IS being deployed from the installed path (v$SRC_VERSION),
     so the scheduled task will be current.
   → Every OTHER step in this run still came from the stale v$RUN_VERSION copy.
     Start a brand-new session and re-run /workbench-dev-team:setup for a fully
     current run.
   ═══════════════════════════════════════════════════
EOF
fi

echo "Orchestrator source: $ORCHESTRATOR_SRC (v${SRC_VERSION:-unknown})"
```

Carry `STALE_ROOT_WARNING` (empty when the running root is current) into the
Step 8 summary.

### 7a-bis. Strip and verify the orchestrator body

**Resolving the right file is not the same as reading a good file.** Step 7a
guarantees the *path* is the installed one; nothing yet guarantees the
*content*. 7a accepts any candidate root where `orchestrator.md` merely
**exists** — truncated, half-written, or the wrong file entirely all pass
unchallenged, and whatever is there becomes the prompt Dispatch runs every
tick. (Staleness is Step 7a's job, not this one: `setup.md` and the
orchestrator resolve from the same root, so a frozen root carries a frozen
guard. This step is about integrity.)

So strip the frontmatter **deterministically here**, in bash, rather than by
hand — and refuse to deploy a body that has lost anything load-bearing. The
checks are **derived from the body**, not a hand-maintained list of names: they
count lanes and locks rather than looking for `lestrade`/`holmes`/`watson`, so a
rename or a fourth lane needs no edit here. Run this with `ORCHESTRATOR_SRC` set
to the path Step 7a printed:

```bash
# >>> orchestrator-body-guard >>>  (markers used by scheduled-tasks/test-setup-orchestrator-guard.sh — keep them)
# Inputs:  ORCHESTRATOR_SRC — absolute path to the resolved orchestrator.md.
#          BODY_OUT (optional) — destination for the stripped body; defaults to a temp file.
# Prints:  "Orchestrator body: <path>" on success; "❌ …" and exit 1 on any failure.
# Fails closed: a body that cannot be verified is never deployed.
set -u

if [ -z "${ORCHESTRATOR_SRC:-}" ] || [ ! -f "$ORCHESTRATOR_SRC" ]; then
  echo "❌ ORCHESTRATOR_SRC is unset or not a readable file — cannot verify the Dispatch prompt."
  exit 1
fi
BODY_OUT="${BODY_OUT:-$(mktemp)}"

# Strip the leading YAML frontmatter: the opening `---` fence, everything through
# its matching `---`, and any blank lines immediately following. A file with no
# frontmatter passes through unchanged; an unterminated fence yields an empty
# body, which the size check below rejects.
awk 'NR==1 && $0=="---" {fm=1; next}
     fm==1 && $0=="---" {fm=2; next}
     fm==2 {if (!started && $0 ~ /^[[:space:]]*$/) next; started=1; print; next}
     fm!=1 {print}' "$ORCHESTRATOR_SRC" > "$BODY_OUT"

og_fail=0
og_reject() { echo "   ✗ $1"; og_fail=1; }

# 1. The strip produced something, and produced a body — not frontmatter.
[ -s "$BODY_OUT" ] || og_reject "stripped body is empty (unterminated frontmatter fence, or empty source)"
head -1 "$BODY_OUT" | grep -qx -- '---' && og_reject "body still opens with a '---' frontmatter fence"
grep -qF -- 'name: dispatch-orchestrator' "$BODY_OUT" && og_reject "frontmatter survived the strip"

# 2. Non-trivial size — catches truncation and wrong-file.
og_lines=$(wc -l < "$BODY_OUT" | tr -d ' ')
[ "$og_lines" -ge 200 ] || og_reject "body is only $og_lines lines (expected >= 200) — truncated or not the orchestrator"

# 3. Lane structure, DERIVED from the body — no agent names appear here, so
#    renaming a lane or adding a fourth one needs no edit in this file. Two
#    counts, both computed from what the body actually contains:
#      - distinct agents dispatched, which must cover all three lanes;
#      - distinct agents writing a per-item in-flight lock (#39). Every lane that
#        dispatches on a single item records one; the per-repo Lestrade sweep is
#        the one dispatch that legitimately has none, so the floor is 2, not 3.
#    A body that dispatches agents but locks nothing is the exact pre-#39
#    regression: overlapping runs racing each other's board writes.
#    The lock pattern deliberately matches the FILE NAME only, not the log
#    directory, so relocating the log dir needs no edit here. (The pre-flight's
#    own `$LOGDIR/$AGENT-$ID.lock` cannot inflate the count: `$AGENT` is
#    uppercase and `[a-z-]+` will not match it.)
og_agents=$(grep -oE -- '--agent workbench-dev-team:[a-z-]+' "$BODY_OUT" | sort -u | wc -l | tr -d ' ')
og_lockers=$(grep -oE -- '[a-z-]+-\$ID\.lock' "$BODY_OUT" | sort -u | wc -l | tr -d ' ')
[ "$og_agents" -ge 3 ] || og_reject "only $og_agents distinct agent lane(s) dispatched (expected >= 3) — a lane is missing"
[ "$og_lockers" -ge 2 ] || og_reject "only $og_lockers agent lane(s) write a per-item in-flight lock (expected >= 2) — the #39 dispatch race is unguarded"

# 4. The circuit-breaker sentinel pair. This is the guard's only literal, and it
#    is not new maintenance: scheduled-tasks/test-circuit-breaker.sh already
#    extracts the pre-flight from between this exact pair, so the markers are
#    load-bearing whether or not this guard names them.
grep -qF -- '>>> circuit-breaker-preflight >>>' "$BODY_OUT" || og_reject "missing the circuit-breaker-preflight opening sentinel"
grep -qF -- '<<< circuit-breaker-preflight <<<' "$BODY_OUT" || og_reject "missing the circuit-breaker-preflight closing sentinel"

if [ "$og_fail" -ne 0 ]; then
  cat <<EOF
❌ ═══════ ORCHESTRATOR BODY FAILED VERIFICATION ═══════
   Source: $ORCHESTRATOR_SRC
   The resolved Dispatch prompt is missing content the pipeline depends on.
   Deploying it would silently downgrade the running pipeline, so setup is
   stopping rather than writing it.
   → Update or re-install the plugin, then re-run /workbench-dev-team:setup.
   ═════════════════════════════════════════════════════
EOF
  exit 1
fi

echo "✅ Orchestrator body verified ($og_lines lines, $og_agents lanes, $og_lockers locked)"
echo "Orchestrator body: $BODY_OUT"
# <<< orchestrator-body-guard <<<
```

**If this block exits non-zero, stop Step 7 entirely** — do not create or update
the scheduled task, and report the failure in the Step 8 summary. A verified-bad
body is a worse outcome than no deployment.

Otherwise use the `Read` tool on the **absolute path** the block printed as
`Orchestrator body:` — that file is already stripped, so read it verbatim. Never
re-derive the path from `${CLAUDE_PLUGIN_ROOT}`, and never re-strip by hand. Its
contents are the prompt the scheduled task will execute every tick.

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

### 7d. Pin the router's model and working directory (best effort)

`create_scheduled_task`/`update_scheduled_task` have no `model` or `cwd`
parameter — Dispatch silently inherits whatever the app resolves as its
current default at registration time. That default is not guaranteed to be
Sonnet: a fresh registration has been observed picking up Opus instead,
roughly doubling the router's per-tick cost with no error or warning. The
actual value lives outside the MCP tool surface, in the app's own per-profile
`scheduled-tasks.json` registry — a separate file from the `SKILL.md` Step 7c
just wrote.

```bash
TARGET_CWD="$HOME/Developer/workbench-dev-team"
PATCHED=0
while IFS= read -r -d '' REG; do
  jq -e '.scheduledTasks[] | select(.id == "workbench-dev-team-dispatch")' "$REG" >/dev/null 2>&1 || continue
  if ! jq empty "$REG" 2>/dev/null; then
    echo "⚠  $REG is not valid JSON — skipping"
    continue
  fi
  tmp="$(mktemp)"
  if [ -d "$TARGET_CWD" ]; then
    jq --arg cwd "$TARGET_CWD" \
      '(.scheduledTasks[] | select(.id == "workbench-dev-team-dispatch")) |= (.model = "claude-sonnet-5" | .cwd = $cwd)' \
      "$REG" > "$tmp"
  else
    jq '(.scheduledTasks[] | select(.id == "workbench-dev-team-dispatch")) |= (.model = "claude-sonnet-5")' \
      "$REG" > "$tmp"
  fi
  if jq empty "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$REG"
    echo "✅ pinned model=claude-sonnet-5 in $REG"
    PATCHED=$((PATCHED + 1))
  else
    rm -f "$tmp"
    echo "⚠  produced invalid JSON patching $REG — left untouched"
  fi
done < <(find "$HOME/Library/Application Support" -path "*/claude-code-sessions/*/scheduled-tasks.json" -print0 2>/dev/null)

if [ "$PATCHED" -eq 0 ]; then
  echo "⚠  Could not locate/patch the scheduled-tasks registry — verify manually in the Scheduled panel."
fi
```

This edits undocumented internal app state, not a supported API — the file's
location or shape can change silently on a future app update and this step
can start finding nothing without any other symptom. That's exactly why
Step 8 always prints the manual verification line below, regardless of
whether this step reports success.

## Step 8 — Final summary

Print a clean summary block:

```text
═══════════════════════════════════════════
  workbench-dev-team setup complete
═══════════════════════════════════════════

  The Index MCP:   https://the-index.mikebronner.dev/mcp
  Log directory:    ~/.claude-workbench/dev-team-logs
  Agent config:     ~/.claude-workbench/dev-team-config.json
  Attribution:      {ATTR_RESULT} in ~/.claude/settings.json
                    (suppressed = no Co-Authored-By; default (visible) = trailer on)
  Scheduled task:   workbench-dev-team-dispatch @ */{CADENCE} * * * *
                    (or: ⚠ not registered — re-run setup to register)
  Prompt source:    {SRC_ROOT}/scheduled-tasks/orchestrator.md (v{SRC_VERSION})
                    body verified — {BODY_LINES} lines, {BODY_LANES} lanes, {BODY_LOCKS} locked
  Router model:     pinned to Sonnet ({PATCHED} registry(ies) patched)
                    (or: ⚠ could not confirm — verify in the Scheduled panel)

  {STALE_ROOT_WARNING}

  Agents:           Lestrade (Sonnet), Holmes (Opus, $7 cap), Watson (Opus, $10 cap)
                    — models/effort/fallback/budget editable in the agent config

  Verify in Claude Code's scheduled-tasks panel that Dispatch shows Sonnet —
  Step 7d's patch isn't a supported API and can silently stop working.
═══════════════════════════════════════════
```

Substitute the actual cadence, fill `{ATTR_RESULT}` from the user's Step 6.5
choice (`suppressed` or `default (visible)`), fill `{PATCHED}` from Step 7d's
count, fill `{SRC_ROOT}`/`{SRC_VERSION}` from Step 7a and
`{BODY_LINES}`/`{BODY_LANES}`/`{BODY_LOCKS}` from Step 7a-bis's success line,
and adjust the scheduled-task, prompt-source and router-model lines if
registration was skipped or the patch found nothing.

`{STALE_ROOT_WARNING}` is Step 7a's one-liner. **When it is empty (the common
case — the running root is current) omit that line and the blank line above it
entirely.** When it is non-empty, print it verbatim and do **not** dress it as
a ✅ — a version mismatch is never a clean success, and hiding it is the exact
failure this summary exists to surface.

## Notes

- **Idempotency.** All four keychain checks, the MCP registration (`remove ||
  true` then `add`), the `mkdir -p`, and the scheduled-task list-then-create-or-
  update flow are safe to re-run. Step 4 always fetches a fresh token, which is
  exactly the desired behavior on re-run (annual refresh is the dominant use
  case).
- **Why dev-team owns commit attribution.** The harness re-injects a
  `Co-Authored-By: Claude` commit trailer (and a PR footer) whenever the
  `attribution` key is absent from `settings.json` — so the key is an orphan that
  drifts back to the default unless something owns it. Dev-team owns commit
  conventions, so it owns this too. Step 6.5 doesn't force a value: it **detects
  the current state, prompts the user** (suppress vs. leave the trailer in), and
  **applies the choice in either direction** — suppressing sets
  `.attribution.commit/pr = ""`, leaving-in deletes those two keys (and the now-
  empty `.attribution` object) so the harness default returns. Both branches are
  non-destructive (only the two `attribution` keys are touched; every other key
  is preserved), refuse to touch a malformed `settings.json`, validate the
  produced JSON before replacing the real file, and write nothing when the file
  already matches the chosen end-state.
- **OAuth token lifetime.** The Index issues 1-year tokens via
  client_credentials. Schedule a calendar reminder, or just re-run this command
  any time `claude mcp list` shows `the-index` as `Failed to connect`.
- **Why Step 7a resolves its own source.** Discovered 2026-08-27: the live
  Dispatch prompt was missing the in-flight dispatch lock shipped in v0.37.0+
  and had been stale for 23 days, across two apparently-successful setup runs.
  Root cause: `${CLAUDE_PLUGIN_ROOT}` expands to the *executing* copy of the
  plugin, and in a resumed session that copy is a per-session snapshot
  materialized once at session creation and never refreshed (a full app restart
  resumes the same session, so it doesn't help either —
  anthropics/claude-code#45810). The running root was v0.35.0 while
  `installed_plugins.json` correctly resolved v0.37.4; setup compared the
  installed task prompt against the *stale* source, found them identical, wrote
  nothing, and printed the normal success summary. Equal-and-stale was
  indistinguishable from equal-and-correct. Step 7a now prefers the install path
  recorded in `installed_plugins.json` and only falls back to the running root
  when that file is missing, unparseable, or names no usable path — and it
  compares the two versions so a frozen root produces a loud warning instead of
  a green checkmark. **Caveat: this doesn't repair an already-frozen session.**
  A stale root still carries the old Step 7a, so the fix needs one clean
  bootstrap — a single session started after the update, running the patched
  setup — after which the failure class is closed by construction.
- **Why Step 7a-bis verifies the body.** Step 7a resolves the right *path*;
  that is not the same as reading a good *file*. 7a accepts any candidate root
  where `orchestrator.md` merely **exists** — a truncated, half-written, or
  wrong file passes unchallenged, and the deployed prompt is whatever was
  there. Step 7a-bis closes that by stripping the frontmatter deterministically
  in bash (rather than by hand, which is its own error class) and refusing to
  deploy a body that has lost structure, shrunk below a plausible size, or kept
  its frontmatter. It fails closed: a body that cannot be verified is never
  written to the scheduled task.
  **The lane checks are derived, not listed.** They count distinct dispatched
  lanes and distinct lanes writing a per-item in-flight lock, so no agent name
  appears in this file — renaming a lane or adding a fourth needs no edit here.
  The guard's one literal is the `circuit-breaker-preflight` sentinel pair, and
  that is not new maintenance: `scheduled-tasks/test-circuit-breaker.sh`
  already extracts the pre-flight from between those exact markers. The pair
  now appears in three files — `orchestrator.md` declares it, the circuit-breaker
  test extracts between it, this guard asserts it — so a test case pins all
  three together; drift in any one turns that file into a silent no-op.
  *Scope note: this guards integrity, not staleness.* `setup.md` and the
  orchestrator resolve from the same root, so a frozen root carries a frozen
  guard — staleness is Step 7a's job, via the registry and the version
  comparison.
  Tests: `scheduled-tasks/test-setup-orchestrator-guard.sh` (15 cases — happy
  path, absent/unreadable input, strip failures, truncation, one case per
  derived check, a boundary case pinning the two-lock floor so the Lestrade
  sweep isn't falsely rejected, and cross-file agreement on the sentinel pair)
  extracts the *shipped* guard from between this file's
  `orchestrator-body-guard` sentinels, so the test cannot drift from the logic
  it guards.
- **Why Step 7d exists.** Discovered 2026-08-04: recreating the scheduled task
  left it running on Opus instead of Sonnet — roughly double the router's
  per-tick cost, with no error to notice it by. Root cause: neither
  `create_scheduled_task` nor `update_scheduled_task` exposes a `model` or
  `cwd` parameter, so the task inherits the app's default at registration
  time instead of anything this skill controls. The actual value lives in a
  per-profile `scheduled-tasks.json` the scheduled-tasks MCP tools don't
  expose either — Step 7d patches it directly as a best-effort workaround,
  not a supported fix. If a future Claude Code version changes that file's
  location or shape, Step 7d quietly patches nothing; the Step 8 reminder to
  check the Scheduled panel is the backstop for that failure mode.
- **No headless `claude -p` subprocess.** Earlier versions of this configuration
  spawned a headless `claude -p --dangerously-skip-permissions` to register the
  scheduled task. Inside a slash command the parent session calls
  `mcp__scheduled-tasks__*` tools directly, eliminating subprocess spawn,
  shell-quoted prompt templates, and the skip-permissions flag.
