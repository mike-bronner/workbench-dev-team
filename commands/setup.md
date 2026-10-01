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
for cmd in gh jq security git python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing prerequisites: ${missing[*]}"
  echo "   Install the missing tools and re-run /workbench-dev-team:setup."
  exit 1
fi
echo "✅ gh, jq, security, git, python3 all present"
```

Do not check for `claude` — we're already running inside a Claude Code session.

`jq` and `python3` are here because the hooks need them. The commit guard reads
its hook payload with `jq`, and without it the guard refuses any call whose text
names a commit or push. The review guard classifies commands in `python3`, and
without it the guard refuses every Bash and editing call from Holmes and his
helpers. So a missing tool blocks work rather than letting it through
unchecked.

If any prerequisite is missing, stop and tell the user how to install it
(`brew install gh jq` for the common case; `security` ships with macOS; `git`
and `python3` come with the Xcode Command Line Tools, `xcode-select --install`).

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
    "lestrade": { "model": "claude-opus-5-5[1m]", "effort": "medium", "fanout": true, "lensModel": "sonnet", "fallback": "haiku" },
    "holmes": { "model": "claude-opus-5-5[1m]", "effort": "medium", "fanout": true, "lensModel": "sonnet", "maxBudgetUsd": 10.00, "fallback": "sonnet" },
    "watson": { "model": "claude-opus-5-5[1m]", "effort": "medium", "maxBudgetUsd": 10.00, "fallback": "sonnet,haiku" }
  }
}
EOF
  echo "✅ Wrote default agent config: $CONFIG"
fi
```

The config is the single source of truth for per-agent model, effort, fallback,
and budget caps, and both dispatch paths take their values from it: the scheduled
Dispatch task passes `--model` / `--effort` / `--fallback-model` /
`--max-budget-usd` from it on every tick, each only when set, and the
`/workbench-dev-team:orchestrate` skill reads it for interactive sub-agent
dispatch. The two paths reach `model` and `effort` differently, which is what
Step 6a below is for. Setup never overwrites an existing config without asking —
the user's edits stick across plugin updates and re-runs. The one question it
asks about an existing config is the pin check below.

**All three agents ship `claude-opus-5-5[1m]` at `medium` effort**, in the
config and in their frontmatter, so they run on exactly that on both paths.
Three reasons:

- **The exact ID, not the `opus` alias.** The alias moves to a new release
  without anyone approving the move. The pin exists to stop that.
- **The `[1m]` variant.** The agents budget about 250k tokens of working
  context, which the standard window may not hold. The pin is there to hold
  the model still, never to shrink its context.
- **`medium` for all three, Holmes included.** Anthropic's Opus 5.5 migration
  guidance reports Opus 5.5 at `medium` beating Opus 5 at `high` on coding. It
  also reports more bugs caught with fewer false alarms in code review. So
  Holmes's old `high` no longer earns its cost.

Speed and permission mode stay unpinned. Agent frontmatter has no speed key,
and a pinned `permissionMode` could override the `--permission-mode auto` the
headless scheduled path depends on.

**Two environment variables still override the pins, on purpose.** They are the
deliberate opt-outs, for a project that needs a different model or effort:

- `CLAUDE_CODE_SUBAGENT_MODEL` together with `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`
  beats the frontmatter `model`. Without the `FORCE` flag, the frontmatter pin
  wins.
- `CLAUDE_CODE_EFFORT_LEVEL` is recorded as beating `--effort`, so it still
  moves the effort of a scheduled run. How it ranks against a frontmatter
  `effort` on the interactive path is not verified.

### Pin check — an existing config that differs from the shipped pins

A config written by an earlier setup still carries that release's defaults: for
example Watson `opus` with no effort, Holmes `opus` at `high`, Lestrade `sonnet`
at `high`. Dispatch passes those as `--model` / `--effort`, which beat the
frontmatter, and Step 6a stamps them over the frontmatter pins. So an old
config is never silent. It keeps the old values on both paths until it changes.

Setup changes it only with the user's say-so, one agent at a time. Run the
check. It writes nothing:

```bash
# >>> config-pin-check >>>  (markers used by commands/test-config-pin.sh — keep them)
# Inputs:  DEVTEAM_CONFIG  (optional) the shared agent config. Defaults to
#                          ~/.claude-workbench/dev-team-config.json.
# Prints:  one "PIN_DIFFERS <agent> model=<value> effort=<value>" line per agent
#          whose model or effort differs from the shipped pin, with "(none)"
#          for an absent or null key. No such line means nothing to ask.
#          One "PIN_MALFORMED <where> type=<json type>" line for a config with
#          the wrong shape: <where> is "config" (the file is not an object),
#          "agents" (.agents is not an object), or an agent name (its entry is
#          not an object). No agent it covers gets a PIN_DIFFERS line.
# Exits:   0 always. It reads and never writes.
PIN_CFG="${DEVTEAM_CONFIG:-$HOME/.claude-workbench/dev-team-config.json}"
PIN_AGENTS="lestrade holmes watson"
PIN_MODEL="claude-opus-5-5[1m]"
PIN_EFFORT="medium"

if [ ! -f "$PIN_CFG" ] || ! jq empty "$PIN_CFG" 2>/dev/null; then
  echo "⚠  $PIN_CFG is missing or not valid JSON — pin check skipped. Fix the file, then re-run setup."
else
  # Test the shape before reading a value. Valid JSON can still be the wrong
  # shape, such as "watson": "opus". Reading into it leaks jq errors and
  # reports "(none)" for a key that is there, and no replacement can be written.
  PIN_ROOT=$(jq -r 'if type == "object" then "agents " + (.agents | type) else "config " + type end' "$PIN_CFG" 2>/dev/null)
  case "$PIN_ROOT" in
    "agents object"|"agents null") PIN_ROOT="" ;;
    "") PIN_ROOT="config unreadable" ;;
  esac
  PIN_COUNT=0
  PIN_BAD=0
  if [ -n "$PIN_ROOT" ]; then
    echo "PIN_MALFORMED ${PIN_ROOT% *} type=${PIN_ROOT##* }"
    PIN_BAD=1
    PIN_AGENTS=""
  fi
  for PIN_AGENT in $PIN_AGENTS; do
    PIN_TYPE=$(jq -r --arg a "$PIN_AGENT" '.agents[$a] | type' "$PIN_CFG" 2>/dev/null)
    case "$PIN_TYPE" in
      object|null) ;;
      *) echo "PIN_MALFORMED $PIN_AGENT type=${PIN_TYPE:-unreadable}"
         PIN_BAD=$((PIN_BAD + 1))
         continue ;;
    esac
    # A non-string value is shown as JSON, so `false` or `5` is never "(none)".
    PIN_CUR_MODEL=$(jq -r --arg a "$PIN_AGENT" '.agents[$a].model | if . == null then empty elif type == "string" then . else tojson end' "$PIN_CFG")
    PIN_CUR_EFFORT=$(jq -r --arg a "$PIN_AGENT" '.agents[$a].effort | if . == null then empty elif type == "string" then . else tojson end' "$PIN_CFG")
    # Effort is compared lower-cased, because Step 6a and the harness both
    # lower-case it. `Medium` already is the pin, and asking about it is noise.
    if [ "$PIN_CUR_MODEL" != "$PIN_MODEL" ] \
       || [ "$(printf '%s' "$PIN_CUR_EFFORT" | tr '[:upper:]' '[:lower:]')" != "$PIN_EFFORT" ]; then
      echo "PIN_DIFFERS $PIN_AGENT model=${PIN_CUR_MODEL:-(none)} effort=${PIN_CUR_EFFORT:-(none)}"
      PIN_COUNT=$((PIN_COUNT + 1))
    fi
  done
  if [ "$PIN_BAD" -gt 0 ]; then
    echo "⚠  Wrong-shaped entries in $PIN_CFG: $PIN_BAD. They are not asked about. Fix each PIN_MALFORMED entry by hand, then re-run setup."
  fi
  if [ "$PIN_COUNT" -eq 0 ] && [ "$PIN_BAD" -eq 0 ]; then
    echo "✅ Every agent in $PIN_CFG already carries the shipped pin ($PIN_MODEL at $PIN_EFFORT)"
  elif [ "$PIN_COUNT" -gt 0 ]; then
    echo "ℹ  $PIN_COUNT agent(s) differ from the shipped pin ($PIN_MODEL at $PIN_EFFORT) — ask before replacing"
  fi
fi
# <<< config-pin-check <<<
```

**Each `PIN_MALFORMED` line → tell the user what to fix by hand.** The entry
it names has the wrong shape, so no replacement can be written to it. Setup
never asks about it and never rewrites it. Say which entry, what it holds, and
what it must hold:

- `config` — the file itself is not a JSON object. It must be `{"agents": {…}}`.
- `agents` — `.agents` is not an object. It must map each agent name to an
  object, for example `"agents": {"watson": {"model": "…", "effort": "…"}}`.
- `lestrade`, `holmes`, or `watson` — that agent's entry is not an object. A
  shorthand such as `"watson": "opus"` must become
  `"watson": {"model": "opus"}`. Its other keys go inside the same object.

The user fixes the file and re-runs setup, which then checks the fixed entry.

**No `PIN_DIFFERS` line → skip to Step 6a.** Otherwise, ask with one
`AskUserQuestion` call holding one question per `PIN_DIFFERS` line (three at
most). Each question names the agent, its current values exactly as printed,
and exactly what replaces them. List the Recommended option first:

```jsonc
AskUserQuestion({
  questions: [
    {
      // One per PIN_DIFFERS line. {MODEL} and {EFFORT} are the printed values,
      // "(none)" included — "(none)" means Claude Code's default applies.
      question: "{Agent} currently runs on model {MODEL} at effort {EFFORT}, from your dev-team config. Replace those two values with the shipped pin: model claude-opus-5-5[1m] at effort medium? Every other key for {Agent} stays as it is.",
      header: "{Agent} pin",
      multiSelect: false,
      options: [
        { label: "Replace with the pin (Recommended)", description: "Sets {Agent}'s model to claude-opus-5-5[1m] and effort to medium. Fanout, lensModel, fallback, and budget are not touched." },
        { label: "Keep my values", description: "Leaves {Agent}'s entry exactly as it is. Setup asks again on its next run." }
      ]
    }
  ]
})
```

Collect every agent the user answered "Replace" for into `PIN_REPLACE`,
space-separated (for example `PIN_REPLACE="holmes watson"`). An agent answered
"Keep", or not asked, stays out of it. Then run the replacement. With an empty
`PIN_REPLACE` it writes nothing at all:

```bash
# >>> config-pin-replace >>>  (markers used by commands/test-config-pin.sh — keep them)
# Inputs:  PIN_REPLACE     space-separated agents the user said yes to. Empty
#                          means no write.
#          DEVTEAM_CONFIG  (optional) as in the pin check.
# Writes:  model and effort for the named agents only. Every other key, and
#          every other agent, keeps its value.
# Exits:   1 when the config is unreadable, when it or a named agent's entry
#          has the wrong shape, or when the write fails. Every check runs before
#          the write, so the file is left as it was unless the write itself
#          fails partway.
PIN_CFG="${DEVTEAM_CONFIG:-$HOME/.claude-workbench/dev-team-config.json}"
PIN_AGENTS="lestrade holmes watson"
PIN_MODEL="claude-opus-5-5[1m]"
PIN_EFFORT="medium"
PIN_REPLACE="${PIN_REPLACE:-}"

# Only an agent the pin check knows about. A typo or an unexpected name would
# otherwise write a new agent entry nobody asked for.
PIN_TARGETS=""
for PIN_AGENT in $PIN_REPLACE; do
  case " $PIN_AGENTS " in
    *" $PIN_AGENT "*) PIN_TARGETS="$PIN_TARGETS $PIN_AGENT" ;;
    *) echo "⚠  '$PIN_AGENT' is not one of: $PIN_AGENTS — not written" ;;
  esac
done

# The same shape test as the pin check, for every named agent. The check never
# asks about a wrong-shaped entry, so this fires only when the file changed in
# between. It refuses the whole write, so no replacement is ever partial.
# shellcheck disable=SC2016  # jq expands these, not the shell
PIN_SHAPE_JQ='if type != "object" then "the config is a JSON \(type), not an object"
  elif (.agents | type) as $t | ($t != "object" and $t != "null")
    then ".agents is a JSON \(.agents | type), not an object"
  else . as $c | $ARGS.positional[]
    | ($c.agents[.] | type) as $t | select($t != "object" and $t != "null")
    | ".agents.\(.) is a JSON \($t), not an object"
  end'

# shellcheck disable=SC2086  # word-splitting PIN_TARGETS into args is the point
if [ -z "$PIN_TARGETS" ]; then
  echo "✅ No pin replacement approved — $PIN_CFG left untouched"
elif [ ! -f "$PIN_CFG" ] || ! jq empty "$PIN_CFG" 2>/dev/null; then
  echo "❌ Refusing to touch $PIN_CFG — it is missing or not valid JSON. Fix it by hand, then re-run."
  exit 1
elif PIN_SHAPE=$(jq -r "$PIN_SHAPE_JQ" "$PIN_CFG" --args $PIN_TARGETS 2>/dev/null) \
       || PIN_SHAPE="its shape could not be read"; [ -n "$PIN_SHAPE" ]; then
  printf '%s\n' "$PIN_SHAPE" | while IFS= read -r PIN_WHY; do
    echo "❌ Refusing to touch $PIN_CFG — $PIN_WHY. Fix that entry by hand, then re-run setup."
  done
  exit 1
else
  # The new config is held in a variable and checked before it is written, so no
  # temporary file is left to tidy up. This block must name no file-removal verb:
  # workbench-core's destructive-scope guard refuses a whole command that removes
  # a path it cannot resolve.
  if PIN_NEW=$(jq --arg m "$PIN_MODEL" --arg e "$PIN_EFFORT" \
        'reduce $ARGS.positional[] as $a (.;
           .agents[$a] = ((.agents[$a] // {}) + {model: $m, effort: $e}))' \
        "$PIN_CFG" --args $PIN_TARGETS 2>/dev/null) \
     && [ -n "$PIN_NEW" ] && printf '%s\n' "$PIN_NEW" | jq empty 2>/dev/null \
     && printf '%s\n' "$PIN_NEW" 2>/dev/null > "$PIN_CFG"; then
    for PIN_AGENT in $PIN_TARGETS; do
      echo "✅ $PIN_AGENT — model: $PIN_MODEL, effort: $PIN_EFFORT (other keys unchanged)"
    done
  else
    echo "❌ Could not write $PIN_CFG."
    exit 1
  fi
fi
# <<< config-pin-replace <<<
```

`commands/test-config-pin.sh` runs both blocks against fixture configs. It
holds their pin to the shipped default config above, so the check can never
ask about a value the default config does not ship.

Both keys are still settable here by hand, per agent. `model` takes any alias
or full model ID. `effort` takes `low`, `medium`, `high`, `xhigh`, `max`, or an
integer. Note `xhigh` is not supported on Sonnet, so a Sonnet agent's ceiling
short of `max` is `high`. Holmes's optional `fanout`
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

### 6a. Stamp the configured model and effort into the agent frontmatter

The scheduled path reads `model` and `effort` off this config on every tick.
**The interactive path cannot.** The Agent tool has no effort parameter, and its
`model` parameter accepts only an alias (`sonnet`, `opus`, `haiku`, `fable`),
never a full model ID. So a sub-agent dispatched from a live conversation takes
both values from its own definition, which is to say from frontmatter. The
frontmatter `model` field takes a full ID, which is how the agents stay on
`claude-opus-5-5[1m]` on this path. A frontmatter line the config disagrees with is
the whole defect: name a value in the config, leave the frontmatter silent, and
that agent runs on whatever the calling session happens to use while the knob
appears to be set.

So the config stays canonical for the *value* and this step copies it into the
*place the interactive dispatch reads*. One edit still moves both paths, and
re-running setup is what re-synchronises them: **edit the config and the
scheduled path changes on the next tick, while interactive dispatch keeps the
last stamped value until setup runs again.**

Silence is a *result* here, never a gap. The step deletes a frontmatter line
whenever the config names no value for it, which is exactly when Dispatch omits
the matching flag, so both paths agree that the agent inherits its caller's
value. No agent ships that way today, and `agents/test-effort-stamp.sh` still
pins the deletion path as well as the write path.
The orchestrate skill therefore never passes the Agent tool's `model`
parameter: it would override the stamped value, and it cannot carry a full ID.

**A live config that differs from the pin wins here.** Whatever the config
names, or leaves out, is what this step stamps. The pin check above is the only
route by which setup moves an existing config onto the pin, and only for an
agent the user said yes to. An agent the user kept keeps its own values on both
paths.

The block writes the installed plugin's `agents/*.md`, resolved the same way
Step 7a resolves the orchestrator and for the same reason. Agents are
discovered from that directory rather than listed here, so a fourth agent is
stamped the day it ships:

```bash
# >>> agent-effort-stamp >>>  (markers used by agents/test-effort-stamp.sh — keep them)
# Inputs:  STAMP_ROOT      (optional) plugin root holding agents/*.md. Resolved
#                          from the install registry when unset.
#          DEVTEAM_CONFIG  (optional) the shared agent config. Defaults to
#                          ~/.claude-workbench/dev-team-config.json.
# Prints:  one line per agent file, and "⚠ …" for anything it refuses to write.
# Exits:   1 only when no plugin root resolves — nothing was stamped, and saying
#          so is the whole point. A refused value or an unreadable config warns
#          and returns 0: neither is worth aborting setup over, and both leave
#          the shipped defaults in place.
STAMP_ROOT="${STAMP_ROOT:-}"
STAMP_CFG="${DEVTEAM_CONFIG:-$HOME/.claude-workbench/dev-team-config.json}"
STAMP_REGISTRY="$HOME/.claude/plugins/installed_plugins.json"
STAMP_WARNED=0

# Resolve the INSTALLED root, never $CLAUDE_PLUGIN_ROOT first. In a resumed
# session that variable names a frozen snapshot (Step 7a explains why), and
# stamping it writes effort into a copy no later session ever loads. Same
# registry query as Step 7a, probing agents/ instead of the orchestrator.
if [ -z "$STAMP_ROOT" ] && [ -f "$STAMP_REGISTRY" ] && jq empty "$STAMP_REGISTRY" 2>/dev/null; then
  STAMP_CAND=$(jq -r --arg key "workbench-dev-team@claude-workbench" '
    (.plugins[$key] // [])
    | map(select((.enabled != false) and ((.installPath // "") != "")))
    | sort_by((.version // "0") | split(".") | map(tonumber? // 0))
    | last // empty
    | .installPath // empty
  ' "$STAMP_REGISTRY" 2>/dev/null || true)
  if [ -n "$STAMP_CAND" ] && [ -d "$STAMP_CAND/agents" ]; then
    STAMP_ROOT="$STAMP_CAND"
  fi
fi

if [ -z "$STAMP_ROOT" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT}/agents" ]; then
  STAMP_ROOT="$CLAUDE_PLUGIN_ROOT"
  echo "⚠  Could not resolve an install path from $STAMP_REGISTRY — stamping the running"
  echo "   plugin root ($STAMP_ROOT). If this session's copy is frozen, later sessions load"
  echo "   agent files this step never touched. Re-run setup from a fresh session."
fi

if [ -z "$STAMP_ROOT" ]; then
  echo "❌ Could not locate the plugin's agents/ directory — neither $STAMP_REGISTRY nor"
  echo "   \$CLAUDE_PLUGIN_ROOT resolved a readable copy. Re-install or update the plugin,"
  echo "   then re-run /workbench-dev-team:setup."
  exit 1
fi

if [ ! -f "$STAMP_CFG" ] || ! jq empty "$STAMP_CFG" 2>/dev/null; then
  echo "⚠  $STAMP_CFG is missing or not valid JSON — leaving the shipped model and effort defaults"
  echo "   in $STAMP_ROOT/agents/ untouched. Fix the file, then re-run setup."
  exit 0
fi

# The harness's own effort enum, plus the integer form its frontmatter schema
# documents. Anything else is normalized to "no override" when the agent loads,
# so writing it would configure nothing while looking configured. `xhigh` is
# valid here even though the schema's field description omits it: the runtime
# check is the enum, and the field is typed as a plain string.
stamp_effort_valid() {
  case "$1" in
    low|medium|high|xhigh|max) return 0 ;;
    ''|*[!0-9]*)               return 1 ;;
    *)                         return 0 ;;
  esac
}

# An alias or a full model ID, with an optional bracketed suffix such as
# `[1m]`. The value lands unquoted in YAML, so anything outside this shape is
# refused rather than written: a space or a `#` would silently change what the
# harness parses. A value holding a newline is refused before the pattern is
# tried: grep matches line by line, so one valid line would pass the whole value
# and write the rest into the frontmatter as extra YAML.
stamp_model_valid() {
  case "$1" in *$'\n'*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/@-]*(\[[A-Za-z0-9]+\])?$'
}

for STAMP_FILE in "$STAMP_ROOT"/agents/*.md; do
  [ -f "$STAMP_FILE" ] || continue
  STAMP_AGENT=$(basename "$STAMP_FILE" .md)

  if ! head -1 "$STAMP_FILE" | grep -qx -- '---' \
     || ! awk 'NR>1 && $0=="---" {ok=1; exit} END {exit !ok}' "$STAMP_FILE"; then
    echo "⚠  $STAMP_AGENT — frontmatter fences missing or unterminated, skipped"
    STAMP_WARNED=$((STAMP_WARNED + 1))
    continue
  fi

  # Lower-cased first, because the harness lower-cases before it checks the enum.
  # Validating the raw string would reject a `High` the runtime accepts happily,
  # and this step's rejection is silent downgrade rather than a visible error.
  STAMP_VALUE=$(jq -r --arg a "$STAMP_AGENT" '.agents[$a].effort // empty' "$STAMP_CFG" 2>/dev/null || true)
  STAMP_VALUE=$(printf '%s' "$STAMP_VALUE" | tr '[:upper:]' '[:lower:]')
  STAMP_MODEL=$(jq -r --arg a "$STAMP_AGENT" '.agents[$a].model // empty' "$STAMP_CFG" 2>/dev/null || true)

  if [ -n "$STAMP_MODEL" ] && ! stamp_model_valid "$STAMP_MODEL"; then
    echo "⚠  $STAMP_AGENT — config model '$STAMP_MODEL' is not an alias or model ID."
    echo "   Refusing to write it; removing any stale model line instead."
    STAMP_MODEL=""
    STAMP_WARNED=$((STAMP_WARNED + 1))
  fi

  if [ -n "$STAMP_VALUE" ] && ! stamp_effort_valid "$STAMP_VALUE"; then
    echo "⚠  $STAMP_AGENT — config effort '$STAMP_VALUE' is not low|medium|high|xhigh|max or an"
    echo "   integer. Refusing to write it; removing any stale effort line instead."
    STAMP_VALUE=""
    STAMP_WARNED=$((STAMP_WARNED + 1))
  fi

  # Rewrite the frontmatter only. Drop every existing `model:` and `effort:`
  # line first, then put the configured ones back directly before the closing
  # fence. Dropping first is what makes a re-run idempotent AND makes a config
  # key that was taken out also take out the line — without it the two paths
  # drift apart silently, which is the whole defect this step exists to close.
  # The new file is held in a variable, so no temporary file is left to tidy up,
  # and this block names no file-removal verb for workbench-core's
  # destructive-scope guard to refuse.
  if STAMP_NEW=$(awk -v model="$STAMP_MODEL" -v val="$STAMP_VALUE" '
        NR==1 && $0=="---"      { print; fm=1; next }
        fm && $0=="---"         { if (model != "") print "model: " model
                                  if (val != "")   print "effort: " val
                                  print; fm=0; next }
        fm && /^(model|effort):/ { next }
                                { print }
      ' "$STAMP_FILE") && [ -n "$STAMP_NEW" ] && printf '%s\n' "$STAMP_NEW" 2>/dev/null > "$STAMP_FILE"; then
    echo "✅ $STAMP_AGENT — model: ${STAMP_MODEL:-(none — inherits the session)}, effort: ${STAMP_VALUE:-(none — inherits the session)}"
  else
    # The awk output is checked before the write, so an empty result never
    # replaces the agent definition.
    echo "⚠  $STAMP_AGENT — frontmatter rewrite failed, left untouched"
    STAMP_WARNED=$((STAMP_WARNED + 1))
  fi
done

if [ "$STAMP_WARNED" -gt 0 ]; then
  echo "⚠  $STAMP_WARNED agent file(s) did not take a configured model or effort — see above."
fi
echo "Agent model and effort stamped from $STAMP_CFG into $STAMP_ROOT/agents/"
# <<< agent-effort-stamp <<<
```

A plugin update replaces `agents/*.md` with the shipped copies, so it resets
every stamp to the shipped defaults. That is why the skill's own description
says to re-run setup after an update — a user whose config matches the defaults
loses nothing, and one who edited it gets their values back on the re-run.

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
isn't valid JSON, checks the new content with `jq empty` before it writes, and
makes **no write** when the file already matches the chosen end-state. Neither
uses a temporary file or a file-removal verb, so workbench-core's
destructive-scope guard has nothing to refuse.

**If `ATTR_CHOICE` is `suppress`:**

```bash
# Already suppressed (present and empty-string) → no write.
if [ -f "$SETTINGS" ] \
  && jq -e '.attribution.commit == "" and .attribution.pr == ""' "$SETTINGS" >/dev/null 2>&1; then
  echo "✅ already suppressed (commit + PR trailers) — no change"
  ATTR_RESULT="suppressed"
else
  if [ -f "$SETTINGS" ]; then
    # Refuse up front if the existing file isn't valid JSON — never clobber it.
    if ! jq empty "$SETTINGS" 2>/dev/null; then
      echo "❌ Refusing to touch $SETTINGS — existing file is not valid JSON. Fix it by hand, then re-run."
      exit 1
    fi
    NEW=$(jq '.attribution.commit = "" | .attribution.pr = ""' "$SETTINGS")
  else
    mkdir -p "$(dirname "$SETTINGS")"
    NEW=$(jq -n '{ attribution: { commit: "", pr: "" } }')
  fi
  # Check the new content before it is written — never leave settings.json
  # malformed. It is held in a variable, so no temporary file is left to tidy up.
  if [ -z "$NEW" ] || ! printf '%s\n' "$NEW" | jq empty 2>/dev/null; then
    echo "❌ Refusing to write — produced invalid JSON for $SETTINGS"
    exit 1
  fi
  printf '%s\n' "$NEW" > "$SETTINGS" || { echo "❌ Could not write $SETTINGS"; exit 1; }
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
  # Drop only our two keys; if that leaves .attribution an empty object, drop it
  # too so the harness default returns. Sibling attribution keys are preserved.
  NEW=$(jq 'del(.attribution.commit, .attribution.pr)
      | if (.attribution // {}) == {} then del(.attribution) else . end' \
      "$SETTINGS")
  # Check the new content before it is written — never leave settings.json
  # malformed. It is held in a variable, so no temporary file is left to tidy up.
  if [ -z "$NEW" ] || ! printf '%s\n' "$NEW" | jq empty 2>/dev/null; then
    echo "❌ Refusing to write — produced invalid JSON for $SETTINGS"
    exit 1
  fi
  printf '%s\n' "$NEW" > "$SETTINGS" || { echo "❌ Could not write $SETTINGS"; exit 1; }
  echo "✅ attribution left in (default Co-Authored-By trailer restored)"
  ATTR_RESULT="default (visible)"
fi
```

Carry `ATTR_RESULT` (`suppressed` or `default (visible)`) into the Step 8
summary.

## Step 6.6 — Install the commit, push, and merge ask rules

The approval is a "Commit it" pick in `AskUserQuestion`, once the human says
their review is done. Claude Code's
own permission prompt is the mechanical backstop on every commit, push, and
pull request merge. This step adds ten `permissions.ask` rules to
`~/.claude/settings.json`:

- `Bash(git commit *)`
- `Bash(git push *)`
- `Bash(git * commit *)`
- `Bash(git * push *)`
- `Bash(git * commit)`
- `Bash(git * push)`
- `Bash(gh pr merge:*)`
- `Bash(gh * pr merge *)`
- `Bash(gh * pr merge)`
- `Bash(gh api *pulls/*/merge*)`

The mid-rule `*` forms catch `git -C <dir> push`, `git -c <key>=<value>
commit`, and `gh -R <owner/repo> pr merge <n>`. A trailing ` *` also matches
the bare command only when it is the rule's only wildcard, so each mid-rule form
has a twin with no trailing `*`. `git * push` catches a bare
`git -C <dir> push`, `git * commit` a bare `git -C <dir> commit`, and
`gh * pr merge` a bare `gh -R <owner/repo> pr merge`, which merges the current
branch's pull request. `gh pr merge:*` is the rule
workbench-core's setup also installs, so the two do not duplicate. The last rule
catches a merge through the REST API. An ask rule applies to every subcommand of
a compound command, including `$( … )`, subshells, and loop bodies. It is
checked before auto mode and before `bypassPermissions`, and the harness strips
`timeout`, `time`, `nice`, `nohup`, `stdbuf`, `command`, `builtin`, and
`noglob` before it matches. Some reads prompt too: `git stash push`,
`git log --grep commit`, and a `gh api` read of `pulls/<n>/merge`. The commit
guard refuses the git ones outright for a sub-agent.

The rules do not see a commit, push, or merge behind `bash -c`, `sh -c`, `env`,
`eval`, a leading `NAME=value` such as `HUSKY=0`, or a program named by its
path. The plugin's commit guard (`hooks/scripts/commit-guard.sh`) refuses those
forms and asks for the plain line. It also refuses a sub-agent's commit or push,
any merge by a sub-agent or by the pipeline, and any push that forces or deletes.

**This is a mistake-catcher, not a security boundary.** A script file, an
interpreter such as `python3 -c`, or a shell alias gets past the rules and the
guard alike. The design stops an honest agent that moves too fast. It does not
stop an agent that sets out to evade it.

**The scheduled pipeline still commits unattended.** Each run starts with
`--permission-mode auto --permission-prompts none`, so the auto-mode classifier
judges what no rule decides, and a prompt nobody answers is denied. An ask rule
is matched before the classifier, so a commit or push still prompts. The
plugin's `PermissionRequest` hook (`hooks/scripts/pipeline-scope.sh`)
answers a pipeline prompt with "allow", and only when
`WORKBENCH_DEV_TEAM_PIPELINE=1` is in its own environment. It allows one plain
`git -C <dir>`, `rm`, or `rmdir` command per call, and only when every path is
absolute and stays inside the roots: all of `$TMPDIR`, where a bare `mktemp -d`
folder lands, and the scratch roots, so another run's clone is in scope too.
The git subcommand must be one the pipelines use: `add`, `checkout`, `commit`,
`diff`, `log`, `merge`, or `push`. It never allows a pull request merge, a force
push, a push to the default branch, or a command that one of your deny rules
matches. `bin/dispatch-agent.sh` exports the flag,
and starts each run in a fresh, empty folder in `~/Developer/scratchpad` rather
than in this repo, and deletes that folder when the run ends. It writes every
permission refusal to the run's log as a `Permission denied:` line. A sub-agent
of an interactive session does not carry the flag unless the session itself
does.

**Do not set `WORKBENCH_DEV_TEAM_PIPELINE=1` with a shell `export` or in a
settings `env` block.** Either one puts the flag on an interactive session. The
hook then allows that session's in-scope commit and push prompts with no human
asked, and the guard stops refusing a sub-agent's commit or push.

The block also removes the old approval gate's three `approve` ask rules from
the settings file. It does not remove the gate's files, because workbench-core's
destructive-scope guard refuses a removal outside the project, and would refuse
the whole block with it. Instead it prints one `LEGACY_LEFT <path>` line for
each file that is still there.

Run it from anywhere:

```bash
# >>> commit-ask-rules-install >>>
set -u
SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-commit-rules-$(date +%Y%m%d-%H%M%S)"

# Additive for everything this step does not own: every other rule and key is
# left exactly as it was. The three legacy approval rules are the only removals.
# The new file is held in a variable and checked before it is written, so no
# temporary file is left to tidy up. This block must name no file-removal verb:
# workbench-core's destructive-scope guard refuses a whole command that removes
# a path outside the project, and ~/.claude sits outside every project.
RULES='["Bash(git commit *)", "Bash(git push *)", "Bash(git * commit *)", "Bash(git * push *)",
        "Bash(git * commit)", "Bash(git * push)", "Bash(gh pr merge:*)", "Bash(gh * pr merge *)", "Bash(gh * pr merge)", "Bash(gh api *pulls/*/merge*)"]'
NEW=$(jq --arg legacy_abs "Bash(bash $HOME/.claude-workbench/bin/approve-commit.sh:*)" \
   --arg legacy_home 'Bash(bash "$HOME/.claude-workbench/bin/approve-commit.sh":*)' \
   --argjson rules "$RULES" \
   '.permissions.ask = (((.permissions.ask // [])
       - [$legacy_abs, $legacy_home, "Bash(approve:*)"]) + $rules | unique)' \
   "$SETTINGS") \
  && printf '%s\n' "$NEW" | jq -e 'type == "object"' >/dev/null \
  && printf '%s\n' "$NEW" > "$SETTINGS" \
  || { echo "❌ Could not update $SETTINGS — commits, pushes, and merges are not prompted until the rules are there."; exit 1; }

# The old gate's script and records, and the review guard's old hold records,
# do nothing now. The human removes them.
for LEGACY in "$HOME/.claude-workbench/bin/approve-commit.sh" "$HOME/.claude-workbench/commit-approvals" \
    "$HOME/.claude-workbench/local-reviews"; do
  [ -e "$LEGACY" ] && echo "LEGACY_LEFT $LEGACY"
done

MISSING=$(jq -r --argjson rules "$RULES" '$rules - (.permissions.ask // []) | .[]' "$SETTINGS")
if [ -n "$MISSING" ]; then
  echo "❌ These ask rules are not in $SETTINGS: $MISSING"
  exit 1
fi
echo "✅ Commit, push, and merge ask rules installed in $SETTINGS"
# <<< commit-ask-rules-install <<<
```

**If the block printed a `LEGACY_LEFT` line, give the human the removal
commands to run.** Do not run them yourself. Show only the lines whose path was
printed, exactly as written here, and repeat them in the Step 8 summary:

```
! rm -f ~/.claude-workbench/bin/approve-commit.sh
! rm -rf ~/.claude-workbench/commit-approvals
! rm -rf ~/.claude-workbench/local-reviews
```

All three are inert, so leaving them in place is safe. The last is the review
guard's old hold records: the guard is static now and reads no state.

**If this block exits non-zero, say so plainly in the Step 8 summary.** Until
the rules are in place, a foreground commit, push, or merge runs with no prompt.
The guard still refuses a sub-agent's commit, push, or merge, so the sub-agent
lane is safe either way. The scheduled pipeline keeps running, but with no rule
its commits and pushes raise no prompt, so the scope hook never judges them. The
guard still refuses its merges and force pushes, and workbench-core's
destructive-scope guard still holds its deletes to scope.

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
[ "$og_lines" -ge 120 ] || og_reject "body is only $og_lines lines (expected >= 120) — truncated or not the orchestrator"

# 3. Lane structure, DERIVED from the body — no agent names appear here, so
#    renaming a lane or adding a fourth one needs no edit in this file. Every
#    dispatch goes through the wrapper script, so one count covers it: distinct
#    `dispatch-agent.sh <agent>` invocations, which must reach all three lanes.
#    (Lestrade's per-repo sweep reuses the `lestrade` token and so collapses
#    into its lane rather than inflating the count.)
#
#    The per-item in-flight lock (#39) is NOT checked here any more. It moved
#    into the wrapper script when the dispatch block collapsed into one command,
#    and 7a-ter verifies it by RUNNING the script's own test suite — an executed
#    assertion rather than a grep for a string in a prompt.
#    The agent token starts with a letter, so the `--check` and `--mark-escalated`
#    modes are not counted as lanes.
og_agents=$(grep -oE -- 'dispatch-agent\.sh"? +[a-z][a-z-]*' "$BODY_OUT" | sort -u | wc -l | tr -d ' ')
[ "$og_agents" -ge 3 ] || og_reject "only $og_agents distinct agent lane(s) dispatched (expected >= 3) — a lane is missing"

# 4. The circuit breaker's two calls back into the wrapper. The pre-flight itself
#    runs inside dispatch-agent.sh, and 7a-ter runs its suite. What the body must
#    still carry is the escalation record, without which a human's re-activation
#    is never recognised, and the stale-claim sweep's liveness check.
grep -qF -- 'dispatch-agent.sh" --mark-escalated' "$BODY_OUT" || og_reject "missing the circuit breaker's --mark-escalated call"
grep -qF -- 'dispatch-agent.sh" --check' "$BODY_OUT" || og_reject "missing the stale-claim sweep's --check call"

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

echo "✅ Orchestrator body verified ($og_lines lines, $og_agents lanes)"
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

### 7a-ter. Install the dispatch wrapper and prove it works

The verified body dispatches every lane through `dispatch-agent.sh`. That script
has to exist at a **stable** path before the task is registered, or every tick
fails at the shell. It is installed to `$HOME/.claude-workbench/bin/` — not the
plugin cache, whose path carries the version and moves on every update (the same
trap #40 fixed for the orchestrator itself).

Run from the resolved `$SRC_ROOT` (Step 7a), not `${CLAUDE_PLUGIN_ROOT}`:

```bash
set -u
WRAPPER_SRC="$SRC_ROOT/bin/dispatch-agent.sh"
WRAPPER_TEST="$SRC_ROOT/bin/test-dispatch-agent.sh"
BREAKER_TEST="$SRC_ROOT/scheduled-tasks/test-circuit-breaker.sh"
WRAPPER_DST="$HOME/.claude-workbench/bin/dispatch-agent.sh"

if [ ! -f "$WRAPPER_SRC" ] || [ ! -f "$WRAPPER_TEST" ] || [ ! -f "$BREAKER_TEST" ]; then
  echo "❌ Dispatch wrapper or one of its tests is missing under $SRC_ROOT — cannot deploy."
  exit 1
fi

# Prove the shipped script behaves before installing it. The two suites cover
# the per-item in-flight lock (#39), the budget cap and its reprieve multiple,
# the per-agent defaults that survive a missing or malformed config, and the
# circuit-breaker pre-flight with its one-shot reprieve marker.
for suite in "$WRAPPER_TEST" "$BREAKER_TEST"; do
  if ! bash "$suite" >/dev/null 2>&1; then
    echo "❌ $suite FAILED — refusing to install a wrapper that does not pass its own suite."
    echo "   Re-run it directly for the detail:  bash $suite"
    exit 1
  fi
done

mkdir -p "$HOME/.claude-workbench/bin"
install -m 755 "$WRAPPER_SRC" "$WRAPPER_DST"
echo "✅ Dispatch wrapper installed and self-tested: $WRAPPER_DST"
```

**If this block exits non-zero, stop Step 7 entirely**, exactly as for the body
guard above — a registered task pointing at a missing or broken wrapper stalls
every lane silently.

Then ensure the permission rule exists, so Dispatch's own Bash call is matched by
a rule rather than judged by the auto-mode classifier. Without it the classifier
re-decides the spawn on every tick and refuses nondeterministically — the stall
this wrapper exists to end. Both spellings are added: the `$HOME` form the
orchestrator writes, and the absolute path it expands to.

```bash
SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-wrapper-$(date +%Y%m%d-%H%M%S)"
# The new file is held in a variable and checked before it is written, so no
# temporary file is left to tidy up, and workbench-core's destructive-scope
# guard finds no file-removal verb to refuse.
NEW=$(jq --arg abs "Bash(bash $HOME/.claude-workbench/bin/dispatch-agent.sh:*)" \
   --arg home 'Bash(bash "$HOME/.claude-workbench/bin/dispatch-agent.sh":*)' \
   '.permissions.allow = ((.permissions.allow // []) + [$abs, $home] | unique)' \
   "$SETTINGS") \
  && printf '%s\n' "$NEW" | jq -e 'type == "object"' >/dev/null \
  && printf '%s\n' "$NEW" > "$SETTINGS" \
  && echo "✅ Dispatch permission rules present in $SETTINGS" \
  || echo "⚠  Could not update $SETTINGS — add the rules by hand or Dispatch stays under the classifier."
```

A failure here is a **warning, not a stop**: the task is still worth registering,
it will just be at the classifier's mercy until the rules land.

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

The working directory pinned here is the router's own. The agents it dispatches
do not inherit it: `bin/dispatch-agent.sh` starts each one in a fresh, empty
folder in `~/Developer/scratchpad`, deletes it when the run ends, and unsets
`CLAUDE_PROJECT_DIR`. A run started in this repo
would take the live plugin repo as its project folder, where workbench-core's
destructive-scope guard lets a delete run unprompted. The cost is that a run
loads no project `CLAUDE.md` and no project settings. User-level settings still
apply, and the tool deny rules runs used to take from this repo's
`settings.local.json` are passed with `--disallowedTools` (`DENIED_TOOLS` in the
wrapper).

```bash
TARGET_CWD="$HOME/Developer/workbench-dev-team"
PATCHED=0
while IFS= read -r -d '' REG; do
  jq -e '.scheduledTasks[] | select(.id == "workbench-dev-team-dispatch")' "$REG" >/dev/null 2>&1 || continue
  if ! jq empty "$REG" 2>/dev/null; then
    echo "⚠  $REG is not valid JSON — skipping"
    continue
  fi
  # Held in a variable and checked before it is written: no temporary file, and
  # no file-removal verb for workbench-core's destructive-scope guard to refuse.
  if [ -d "$TARGET_CWD" ]; then
    NEW=$(jq --arg cwd "$TARGET_CWD" \
      '(.scheduledTasks[] | select(.id == "workbench-dev-team-dispatch")) |= (.model = "claude-sonnet-5" | .cwd = $cwd)' \
      "$REG")
  else
    NEW=$(jq '(.scheduledTasks[] | select(.id == "workbench-dev-team-dispatch")) |= (.model = "claude-sonnet-5")' \
      "$REG")
  fi
  if [ -n "$NEW" ] && printf '%s\n' "$NEW" | jq empty 2>/dev/null && printf '%s\n' "$NEW" > "$REG"; then
    echo "✅ pinned model=claude-sonnet-5 in $REG"
    PATCHED=$((PATCHED + 1))
  else
    echo "⚠  produced invalid JSON patching $REG, or could not write it"
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
  Commit prompts:   10 commit, push, and merge ask rules in ~/.claude/settings.json
                    (or: ⚠ not installed — foreground commits and merges are not prompted)
                    {LEGACY_COMMANDS}
  Scheduled task:   workbench-dev-team-dispatch @ */{CADENCE} * * * *
                    (or: ⚠ not registered — re-run setup to register)
  Prompt source:    {SRC_ROOT}/scheduled-tasks/orchestrator.md (v{SRC_VERSION})
                    body verified — {BODY_LINES} lines, {BODY_LANES} lanes
  Router model:     pinned to Sonnet ({PATCHED} registry(ies) patched)
                    (or: ⚠ could not confirm — verify in the Scheduled panel)

  {STALE_ROOT_WARNING}

  Agents:           Lestrade — {LESTRADE_STAMP}
                    Holmes ($10 cap) — {HOLMES_STAMP}
                    Watson ($10 cap) — {WATSON_STAMP}
                    — models/effort/fallback/budget editable in the agent config
                    — model and effort also stamped into
                      {STAMP_ROOT}/agents/*.md (Step 6a),
                      which is what interactive dispatch reads: re-run setup
                      after editing the config to move that path too

  Verify in Claude Code's scheduled-tasks panel that Dispatch shows Sonnet —
  Step 7d's patch isn't a supported API and can silently stop working.
═══════════════════════════════════════════
```

Substitute the actual cadence, fill `{ATTR_RESULT}` from the user's Step 6.5
choice (`suppressed` or `default (visible)`), fill `{PATCHED}` from Step 7d's
count, fill `{SRC_ROOT}`/`{SRC_VERSION}` from Step 7a,
`{BODY_LINES}`/`{BODY_LANES}` from Step 7a-bis's success line, and
`{STAMP_ROOT}` from Step 6a's closing line — Step 6a runs whether or not the
schedule was registered, so that one is always available — and each
`{<AGENT>_STAMP}` from that agent's Step 6a line (`model: …, effort: …`). Those
are the values the live config actually stamped, which differ from the shipped
pin when the user kept their own at the pin check. Never print the pin in their
place,
and adjust the scheduled-task, prompt-source and router-model lines if
registration was skipped or the patch found nothing.

`{LEGACY_COMMANDS}` is the `! rm` command for each `LEGACY_LEFT` line Step 6.6
printed, one per line. When Step 6.6 printed none, omit that line.

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
  lanes, so no agent name appears in this file — renaming a lane or adding a
  fourth needs no edit here. The guard's literals are the two circuit-breaker
  calls the body makes back into `dispatch-agent.sh` (`--mark-escalated` and
  `--check`). The pre-flight itself lives in that script, where
  `scheduled-tasks/test-circuit-breaker.sh` runs it and Step 7a-ter runs the
  wrapper's own suite before installing it.
  *Scope note: this guards integrity, not staleness.* `setup.md` and the
  orchestrator resolve from the same root, so a frozen root carries a frozen
  guard — staleness is Step 7a's job, via the registry and the version
  comparison.
  Tests: `scheduled-tasks/test-setup-orchestrator-guard.sh` (happy path,
  absent/unreadable input, strip failures, truncation, one case per derived
  check, a boundary case so the Lestrade sweep cannot stand in for a lane, and
  one case per circuit-breaker call)
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
