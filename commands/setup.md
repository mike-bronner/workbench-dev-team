---
description: Configure the workbench-dev-team plugin — verify prerequisites, seed Keychain credentials, register The Index MCP, move an old agent config into /config, and install the Dispatch launchd job. Re-run after a plugin update, after a cadence change, or to refresh the OAuth bearer token (annual).
disable-model-invocation: true
---

The user has invoked `/workbench-dev-team:setup`. Walk them through the one-time
(or annual-refresh) configuration of the plugin.

This command is fully idempotent — re-running is safe at any time. It will skip
already-satisfied steps, refresh the OAuth bearer token (1-year lifetime), and
replace rather than duplicate the Dispatch launchd job.

Every plain setting (models, efforts, budgets, fan-out, the Dispatch cadence) is
a row in `/config`, not a question here. This command keeps only the steps that
need a model: Keychain secrets the user pastes, the questions it asks, and the
scheduled-task tools that retire the old router.

## Constants

```text
The Index MCP URL:    https://the-index.mikebronner.dev/mcp
The Index OAuth URL:  https://the-index.mikebronner.dev/oauth/token
Log directory:         ~/.claude-workbench/dev-team-logs
Settings:              /config rows, kept in ~/.claude/settings.json
                       under pluginConfigs["workbench-dev-team@claude-workbench"]
Old agent config:      ~/.claude-workbench/dev-team-config.json (moved by Step 6b)
Dispatch scripts:      ~/.claude-workbench/bin/dispatch-tick.sh, dispatch-agent.sh
Dispatch job:          ~/Library/LaunchAgents/dev.workbench.dev-team-dispatch.plist
Dispatch log:          ~/.claude-workbench/dev-team-logs/dispatch-tick.log
Old scheduled task:    workbench-dev-team-dispatch (retired by Step 7d)
Plugin registry:       ~/.claude/plugins/installed_plugins.json
```

The scripts' source is **resolved at run time in Step 7a**, not hard-coded off
`${CLAUDE_PLUGIN_ROOT}` — the running root can be a frozen session snapshot.
See Step 7a for the resolution order.

## Step 1 — Ask whether to install the Dispatch job

The cadence is the `dispatchCadenceMinutes` row in `/config` (default 20), so
the one question here is whether to install the job now. Ask it with
`AskUserQuestion`, so the rest of the run is non-interactive once credentials
are in place:

```jsonc
AskUserQuestion({
  questions: [
    {
      question: "Install the Dispatch launchd job now? It polls The Index on the dispatchCadenceMinutes cadence from /config, with no model, and replaces the scheduled Claude task.",
      header: "Dispatch",
      multiSelect: false,
      options: [
        { label: "Yes — install it", description: "Installs and loads the job, then retires the old workbench-dev-team-dispatch task and its permission rules." },
        { label: "Skip — install it later", description: "The MCP is set up, but no job is loaded, and an old scheduled task keeps running. Re-run setup any time to install." }
      ]
    }
  ]
})
```

Save the answer as `INSTALL_JOB` (`yes` or `skip`).

## Step 2 — Verify prerequisites

Run a single Bash check for the host tools the rest of the script needs:

```bash
missing=()
for cmd in gh jq security git curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing prerequisites: ${missing[*]}"
  echo "   Install the missing tools and re-run /workbench-dev-team:setup."
  exit 1
fi
echo "✅ gh, jq, security, git, curl, python3 all present"
```

Do not check for `claude` — we're already running inside a Claude Code session.

`curl` and `jq` are what the Dispatch tick talks to The Index with. `python3`
runs the tick's test suite, which Step 7b runs against a local fake Index
before it installs anything. `jq` is also here because the pipeline's permission hook
(`hooks/scripts/pipeline-scope.sh`) reads its payload with it, and without it
the hook allows nothing, so a missing tool blocks the pipeline rather than
letting it through unchecked. The commit guard and the review guard run in the
plugin's hooks module, on workbench-core's `$.workbench` noun, and need no host
tool.

If any prerequisite is missing, stop and tell the user how to install it
(`brew install gh jq` for the common case; `security` and `curl` ship with
macOS; `git` and `python3` come with the Xcode Command Line Tools,
`xcode-select --install`).

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

If missing, tell the user: **"The Dispatch job needs a Claude Code
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

## Step 6 — Create the log directory, and move an old agent config into /config

```bash
mkdir -p "$HOME/.claude-workbench/dev-team-logs"
echo "✅ Log directory ready: $HOME/.claude-workbench/dev-team-logs"
```

Every dev-team knob is a row of the plugin's settings, declared under
`userConfig` in `.claude-plugin/plugin.json` and edited in `/config`. There is
no config file to write. The rows, with their defaults:

| Row | Default | What it sets |
|---|---|---|
| `dispatchCadenceMinutes` | `20` | How often the Dispatch launchd job runs a tick. Step 7 reads it when it installs the job. |
| `lestradeModel`, `holmesModel`, `watsonModel` | `claude-opus-5-5[1m]` | The model of every run, scheduled and interactive. |
| `lestradeEffort`, `holmesEffort`, `watsonEffort` | `medium` | The effort of every run. |
| `lestradeFallback`, `holmesFallback`, `watsonFallback` | `haiku`, `sonnet`, `sonnet,haiku` | The models a scheduled run falls back to. |
| `lestradeMaxBudgetUsd`, `holmesMaxBudgetUsd`, `watsonMaxBudgetUsd` | none, `10`, `10` | The most one scheduled run may spend. |
| `lestradeFanout`, `holmesFanout` | `true` | Whether the agent fans out to helper lenses. |
| `lestradeLensModel`, `holmesLensModel` | `sonnet` | The model the helpers run on. |
| `reprieveBudgetMultiplier` | `3` | What a reprieved run's budget is multiplied by. |

Claude Code keeps a value the user sets in `~/.claude/settings.json`, under
`pluginConfigs["workbench-dev-team@claude-workbench"].options`, and keeps no
default there. Both paths read it on the next dispatch, and nothing has to be
re-run, except for the cadence:

- The scheduled path. `bin/dispatch-agent.sh` reads each row from that file.
  A row the user never set falls back to a default that matches the row's own,
  and `bin/test-dispatch-agent.sh` holds the two together.
- The interactive path. The dev-team mod receives the rows as its plugin
  options, and Claude Code reloads it when one changes. It sets the model and
  the effort at every spawn of Watson, Holmes, or Lestrade.
- A top-level `claude -p --agent` run that `dispatch-agent.sh` starts loads the
  mod too, so the fan-out rows reach Holmes and Lestrade there as well.

**An older install keeps its knobs in `~/.claude-workbench/dev-team-config.json`.**
Nothing reads that file now. Setup moves it into `/config` once, below, and then
renames it, so a later run never moves it over an edit made in `/config`. If the
file does not exist, skip to Step 6.5.

### 6a. Pin check — an old config that differs from the shipped pins

A config written by an earlier setup can still carry that release's defaults:
for example Watson `opus` with no effort, Holmes `opus` at `high`, Lestrade
`sonnet` at `high`. The move below copies every value that differs from its
row's default, so those old values would keep winning on both paths.

So before the move, setup offers to put each agent's model and effort on the
pin, one agent at a time, and only with the user's say-so. The pin is the
`*Model` and `*Effort` rows' default. Run the check. It writes nothing:

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
# Each list is read one word per line through `while read … < <(…)`, never
# split from an unquoted variable: zsh does not split one, so a `for` over
# "$PIN_AGENTS" would run once over the whole string there. The loop runs in
# the current shell in bash and zsh alike, so its counters survive it.
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
  while IFS= read -r PIN_AGENT; do
    [ -n "$PIN_AGENT" ] || continue
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
    # Effort is compared lower-cased, because the dev-team mod and the harness both
    # lower-case it. `Medium` already is the pin, and asking about it is noise.
    if [ "$PIN_CUR_MODEL" != "$PIN_MODEL" ] \
       || [ "$(printf '%s' "$PIN_CUR_EFFORT" | tr '[:upper:]' '[:lower:]')" != "$PIN_EFFORT" ]; then
      echo "PIN_DIFFERS $PIN_AGENT model=${PIN_CUR_MODEL:-(none)} effort=${PIN_CUR_EFFORT:-(none)}"
      PIN_COUNT=$((PIN_COUNT + 1))
    fi
  done < <(printf '%s\n' "$PIN_AGENTS" | tr ' ' '\n')
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

**No `PIN_DIFFERS` line → go on to 6b.** Otherwise, ask with one
`AskUserQuestion` call holding one question per `PIN_DIFFERS` line (three at
most). Each question names the agent, its current values exactly as printed,
and exactly what replaces them. List the Recommended option first:

```jsonc
AskUserQuestion({
  questions: [
    {
      // One per PIN_DIFFERS line. {MODEL} and {EFFORT} are the printed values,
      // "(none)" included — "(none)" means Claude Code's default applies.
      question: "{Agent} currently runs on model {MODEL} at effort {EFFORT}, from your old dev-team config file. Setup is moving that file into /config. Move {Agent} onto the shipped pin, model claude-opus-5-5[1m] at effort medium, instead of those two values? Every other {Agent} value moves as it is.",
      header: "{Agent} pin",
      multiSelect: false,
      options: [
        { label: "Replace with the pin (Recommended)", description: "Sets {Agent}'s model to claude-opus-5-5[1m] and effort to medium. Fanout, lensModel, fallback, and budget are not touched." },
        { label: "Keep my values", description: "Moves {Agent}'s model and effort into /config as they are. You can change them there later." }
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
# otherwise write a new agent entry nobody asked for. Each list is read one
# word per line, never split from an unquoted variable, so zsh reads it as
# bash does (the pin check says why).
PIN_TARGETS=""
while IFS= read -r PIN_AGENT; do
  [ -n "$PIN_AGENT" ] || continue
  case " $PIN_AGENTS " in
    *" $PIN_AGENT "*) PIN_TARGETS="$PIN_TARGETS $PIN_AGENT" ;;
    *) echo "⚠  '$PIN_AGENT' is not one of: $PIN_AGENTS — not written" ;;
  esac
done < <(printf '%s\n' "$PIN_REPLACE" | tr ' \t' '\n\n')

# The same shape test as the pin check, for every named agent. The check never
# asks about a wrong-shaped entry, so this fires only when the file changed in
# between. It refuses the whole write, so no replacement is ever partial.
# The targets reach jq as one string, $targets, which jq splits itself.
# shellcheck disable=SC2016  # jq expands these, not the shell
PIN_SHAPE_JQ='if type != "object" then "the config is a JSON \(type), not an object"
  elif (.agents | type) as $t | ($t != "object" and $t != "null")
    then ".agents is a JSON \(.agents | type), not an object"
  else . as $c | $targets | split(" ")[] | select(length > 0)
    | ($c.agents[.] | type) as $t | select($t != "object" and $t != "null")
    | ".agents.\(.) is a JSON \($t), not an object"
  end'

if [ -z "$PIN_TARGETS" ]; then
  echo "✅ No pin replacement approved — $PIN_CFG left untouched"
elif [ ! -f "$PIN_CFG" ] || ! jq empty "$PIN_CFG" 2>/dev/null; then
  echo "❌ Refusing to touch $PIN_CFG — it is missing or not valid JSON. Fix it by hand, then re-run."
  exit 1
elif PIN_SHAPE=$(jq -r --arg targets "$PIN_TARGETS" "$PIN_SHAPE_JQ" "$PIN_CFG" 2>/dev/null) \
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
  if PIN_NEW=$(jq --arg m "$PIN_MODEL" --arg e "$PIN_EFFORT" --arg targets "$PIN_TARGETS" \
        'reduce ($targets | split(" ")[] | select(length > 0)) as $a (.;
           .agents[$a] = ((.agents[$a] // {}) + {model: $m, effort: $e}))' \
        "$PIN_CFG" 2>/dev/null) \
     && [ -n "$PIN_NEW" ] && printf '%s\n' "$PIN_NEW" | jq empty 2>/dev/null \
     && printf '%s\n' "$PIN_NEW" 2>/dev/null > "$PIN_CFG"; then
    while IFS= read -r PIN_AGENT; do
      [ -n "$PIN_AGENT" ] && echo "✅ $PIN_AGENT — model: $PIN_MODEL, effort: $PIN_EFFORT (other keys unchanged)"
    done < <(printf '%s\n' "$PIN_TARGETS" | tr ' ' '\n')
  else
    echo "❌ Could not write $PIN_CFG."
    exit 1
  fi
fi
# <<< config-pin-replace <<<
```

`commands/test-config-pin.sh` runs both blocks against fixture configs. It
holds their pin to the `*Model` and `*Effort` rows' defaults in plugin.json, so
the check can never ask about a value the rows do not default to.

### 6b. Move the old config into /config

Run this with `PLUGIN_MANIFEST` set to the plugin's manifest,
`$SRC_ROOT/.claude-plugin/plugin.json` once Step 7a has resolved `SRC_ROOT`, or
`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` before it. It writes every
value in the old file that differs from its row's default through
`claude plugin configure`, then checks each one landed where
`dispatch-agent.sh` reads it, and only then renames the old file:

```bash
# >>> config-migrate >>>  (markers used by commands/test-config-pin.sh — keep them)
# Inputs:  PLUGIN_MANIFEST  the plugin's .claude-plugin/plugin.json.
#          DEVTEAM_CONFIG   (optional) the old agent config. Defaults to
#                           ~/.claude-workbench/dev-team-config.json.
#          WORKBENCH_SETTINGS_FILE (optional) Claude Code's user settings.
#                           Defaults to ~/.claude/settings.json.
# Prints:  one "MIGRATE <row>=<value>" line per value written, and one
#          "MIGRATE_SKIPPED <agent>.<key> <why>" line per value no row takes.
# Writes:  the plugin's settings, with `claude plugin configure`. Then the old
#          file is renamed to dev-team-config.json.migrated-<stamp>.
# Exits:   1 when the manifest or the old file cannot be read, when the old
#          file has the wrong shape, when the write fails, or when a written
#          value is not in the settings file afterwards. The old file is renamed
#          only after every check passes, so a failed move can be re-run.
MIG_CFG="${DEVTEAM_CONFIG:-$HOME/.claude-workbench/dev-team-config.json}"
MIG_MANIFEST="${PLUGIN_MANIFEST:-}"
MIG_SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"
MIG_KEY="workbench-dev-team@claude-workbench"

# The plan, from one jq program: each old value, the row it moves to, and
# whether it moves. A value equal to its row's default is left to the default.
# A value no row takes, or one its row cannot hold, is skipped and named. Rows
# hold flat values, so reprieveBudgetMultiplier, once per agent, becomes one
# row, and agents that disagree on it are skipped.
# shellcheck disable=SC2016  # jq expands these, not the shell
MIG_JQ='
  $m[0].userConfig as $rows
  | [ (.agents // {}) | to_entries[] | .key as $agent | .value | to_entries[]
      | { at: "\($agent).\(.key)", value: .value,
          row: (if .key == "reprieveBudgetMultiplier" then .key
                else $agent + (.key[0:1] | ascii_upcase) + .key[1:] end) } ]
  | map(. as $e | $rows[$e.row] as $r
      | ($e.value | type) as $t
      | if $r == null then $e + {skip: "no /config row takes it"}
        elif $t == "null" then $e + {skip: "it is null"}
        elif $r.type == "number" and $t != "number" then $e + {skip: "the row takes a number"}
        elif $r.type == "boolean" and $t != "boolean" then $e + {skip: "the row takes true or false"}
        elif $r.type == "string" and $t != "string" then $e + {skip: "the row takes text"}
        elif $r.options != null and ($r.options | index($e.value | ascii_downcase)) == null
          then $e + {skip: "the row takes one of \($r.options | join(", "))"}
        else ($e.value | if $r.options != null then ascii_downcase else . end) as $v
          | $e + {text: ($v | if type == "number" then . + 0 else . end | tostring), same: ($v == $r.default)}
        end)
  | (map(select(.skip == null)) | group_by(.row)
      | map(if (map(.text) | unique | length) > 1
            then map(. + {skip: "the agents disagree, so set it in /config"})
            else [.[0]] end) | add // []) as $kept
  | { write: ([$kept[] | select(.skip == null and (.same | not)) | {key: .row, value: .text}] | from_entries),
      skipped: ([.[], $kept[] | select(.skip != null) | "\(.at) \(.skip)"] | unique) }'

if [ ! -f "$MIG_CFG" ]; then
  echo "✅ No old agent config at $MIG_CFG. Every setting lives in /config."
elif [ -z "$MIG_MANIFEST" ] || ! jq -e '.userConfig | type == "object"' "$MIG_MANIFEST" >/dev/null 2>&1; then
  echo "❌ PLUGIN_MANIFEST does not name a plugin.json with userConfig rows. Nothing moved."
  exit 1
elif ! jq -e 'type == "object" and ((.agents // {}) | type == "object") and ([(.agents // {})[] | type == "object"] | all)' "$MIG_CFG" >/dev/null 2>&1; then
  echo "❌ $MIG_CFG is not valid JSON, or its shape is wrong. Nothing moved. Fix it by hand, then re-run setup."
  exit 1
elif ! MIG_PLAN=$(jq -c --slurpfile m "$MIG_MANIFEST" "$MIG_JQ" "$MIG_CFG" 2>/dev/null) || [ -z "$MIG_PLAN" ]; then
  echo "❌ Could not read a plan out of $MIG_CFG. Nothing moved."
  exit 1
else
  printf '%s\n' "$MIG_PLAN" | jq -r '.skipped[] | "MIGRATE_SKIPPED \(.)"'
  MIG_WRITE=$(printf '%s\n' "$MIG_PLAN" | jq -c '.write')
  if [ "$MIG_WRITE" != "{}" ]; then
    # `command` skips a shell alias, which can put an option before `plugin`.
    if ! printf '%s\n' "$MIG_WRITE" | command claude plugin configure "$MIG_KEY" --values-stdin >/dev/null 2>&1; then
      echo "❌ claude plugin configure refused the values. Nothing moved, and $MIG_CFG is left as it is."
      exit 1
    fi
    # Each value must now be where bin/dispatch-agent.sh reads it. A number may
    # come back as a number, so it is compared as one.
    MIG_MISSING=$(jq -r --arg k "$MIG_KEY" --argjson w "$MIG_WRITE" '
        (.pluginConfigs[$k].options // {}) as $o
        | $w | to_entries[]
        | select(($o[.key] | tostring) != .value and ($o[.key] | type != "number" or $o[.key] != (.value | tonumber? // null)))
        | .key' "$MIG_SETTINGS" 2>/dev/null) || MIG_MISSING="(the settings file could not be read)"
    if [ -n "$MIG_MISSING" ]; then
      echo "❌ These values are not in $MIG_SETTINGS under pluginConfigs[\"$MIG_KEY\"], where dispatch-agent.sh reads them: $(printf '%s' "$MIG_MISSING" | tr '\n' ' ')"
      echo "   $MIG_CFG is left as it is. Set the values in /config, then check the file."
      exit 1
    fi
    printf '%s\n' "$MIG_WRITE" | jq -r 'to_entries[] | "MIGRATE \(.key)=\(.value)"'
  fi
  # Renamed, never removed, so the old values stay readable.
  MIG_DONE="$MIG_CFG.migrated-$(date +%Y%m%d-%H%M%S)"
  if ! mv "$MIG_CFG" "$MIG_DONE"; then
    echo "❌ Could not rename $MIG_CFG. The values are in /config, but the next setup run would move the file again."
    exit 1
  fi
  echo "✅ Old agent config moved into /config. It is kept as $MIG_DONE."
fi
# <<< config-migrate <<<
```

**Each `MIGRATE_SKIPPED` line → tell the user which value did not move, and
why.** Each one is a value the old file held that no row takes, or that its row
cannot hold, such as an integer effort. The user sets it in `/config` by hand,
or drops it. The renamed file keeps it readable.

**If this block exits non-zero, say so plainly in the Step 8 summary.** The old
file is left in place, so nothing is lost, and the next run tries the move
again.

### How each path reads the rows

`model` takes any alias or full model ID. `effort` takes `low`, `medium`,
`high`, `xhigh`, or `max`. Sonnet does not support `xhigh`, so a Sonnet agent's
ceiling short of `max` is `high`. The fan-out rows turn Holmes's multi-lens
review and Lestrade's four acceptance-criteria lenses (`agents/lestrade.md`,
§4.6) on or off, and the helper-model rows set the model those helpers run on.
The fallback rows go to `--fallback-model` on the scheduled path, so a dispatch
degrades to the next model when the primary is overloaded or retired, instead of
failing. The budget rows cap a run's spend.

The mod ignores a value outside the shape it accepts: a model that is not an
alias or a full ID, and an effort that is not one of the five levels. The agent
file's own frontmatter value then applies, and it applies too wherever the mod
does not run, such as Cowork.

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
path. The plugin's commit guard (`hooks/mods/commit-guard.ts`, in its hooks
module) refuses those forms and asks for the plain line. It also refuses a
sub-agent's commit or push, any merge by a sub-agent or by the pipeline, and any
push that forces or deletes.

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

## Step 7 — Install the Dispatch launchd job

Skip this step entirely if `INSTALL_JOB` from Step 1 was "Skip".

Dispatch is a shell script, `bin/dispatch-tick.sh`. A launchd job runs it on the
`dispatchCadenceMinutes` cadence. It polls The Index's three lanes over HTTPS
and calls `bin/dispatch-agent.sh` for each item, so no model runs in the
router, and a tick with nothing to dispatch costs no tokens. It replaces the
scheduled Claude task, `workbench-dev-team-dispatch`, that ran the same routing
as a prompt. Step 7d retires that task, and only after 7c has proven one tick
of the job works.

### 7a. Resolve the plugin source

**Never install from `${CLAUDE_PLUGIN_ROOT}` when a better source exists.** The
harness expands that variable to the *executing* copy of the plugin, which in a
resumed session is a snapshot materialized once at session creation under
`~/Library/Application Support/Claude/local-agent-mode-sessions/…/plugin_<hash>/`
and never refreshed — not even by a full app restart, because the app resumes
the same session (anthropics/claude-code#45810). Installing from that copy
silently pins Dispatch to whatever the plugin looked like weeks ago. Resolve the
install path recorded in `~/.claude/plugins/installed_plugins.json` instead, and
only fall back to the running root when that file can't answer:

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
    if [ -n "$CAND_ROOT" ] && [ -f "$CAND_ROOT/bin/dispatch-tick.sh" ]; then
      SRC_ROOT="$CAND_ROOT"
      SRC_VERSION="$CAND_VERSION"
    elif [ -n "$CAND_ROOT" ]; then
      echo "⚠  $REGISTRY points at $CAND_ROOT, but bin/dispatch-tick.sh is not readable there."
    fi
  fi
fi

# Fallback: the running root. Correct in a fresh session, stale in a resumed one
# — say so out loud rather than deploying from it quietly.
if [ -z "$SRC_ROOT" ]; then
  if [ -n "$RUN_ROOT" ] && [ -f "$RUN_ROOT/bin/dispatch-tick.sh" ]; then
    SRC_ROOT="$RUN_ROOT"
    SRC_VERSION=$(jq -r '.version // ""' "$RUN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)
    echo "⚠  Could not resolve an install path from $REGISTRY — falling back to the running"
    echo "   plugin root ($SRC_ROOT). If this session's copy is frozen, the scripts installed"
    echo "   below are frozen with it."
  else
    echo "❌ Could not locate bin/dispatch-tick.sh — neither $REGISTRY nor"
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

STALE_ROOT_WARNING=""

if [ -n "$RUN_VERSION" ] && [ -n "$SRC_VERSION" ] && [ "$RUN_VERSION" != "$SRC_VERSION" ]; then
  STALE_ROOT_WARNING="⚠  STALE PLUGIN ROOT — this session ran v$RUN_VERSION; Dispatch was installed from v$SRC_VERSION"
  cat <<EOF2
⚠  ═══════════════ STALE PLUGIN ROOT ═══════════════
   This session is EXECUTING workbench-dev-team v$RUN_VERSION from:
     $RUN_ROOT
   but the INSTALLED plugin is v$SRC_VERSION at:
     $SRC_ROOT
   \$CLAUDE_PLUGIN_ROOT is materialized once when a session is created and is
   never refreshed — not even by an app restart that resumes the same session
   (anthropics/claude-code#45810).
   → The Dispatch scripts ARE being installed from the installed path (v$SRC_VERSION).
   → Every OTHER step in this run still came from the stale v$RUN_VERSION copy.
     Start a brand-new session and re-run /workbench-dev-team:setup for a fully
     current run.
   ═══════════════════════════════════════════════════
EOF2
fi

echo "Dispatch source: $SRC_ROOT (v${SRC_VERSION:-unknown})"
```

Carry `SRC_ROOT`, `SRC_VERSION` and `STALE_ROOT_WARNING` (empty when the
running root is current) into the steps below and the Step 8 summary. If this
block exits non-zero, stop Step 7 entirely.

### 7b. Install the Dispatch scripts and the launchd job, as one step

The job runs the scripts from a **stable** path, `~/.claude-workbench/bin/`,
not from the plugin cache, whose path carries the version and moves on every
update. The job file is `bin/dispatch-tick.plist`, with its placeholders
filled. It goes in `~/Library/LaunchAgents`, and loads in the user's GUI domain,
where the login Keychain is open to the tick's credential reads. Its PATH is
this session's PATH, less any temporary folder and the plugin cache, so the
agents the tick starts find the same `git`, `gh` and `claude` an interactive
session does.

**Run this block, and 7c's, with the Bash tool's `timeout` set to 600000**
(ten minutes). 7b's worst case is its three suites, about 40 seconds, plus up to
ten seconds of launchd retries. 7c's is a 90-second wait for the tick, plus
the same retries. The default two-minute timeout could kill 7c's failure path
before it restores.

The step is one transaction, so no mix of new and old scripts can run:

1. **Every check runs first, and changes nothing but empty folders.** The
   source files and their three suites (the tick's suite runs against a local
   fake Index, so it needs `python3`, and reaches nothing real), the cadence,
   the tools on PATH, the job file's render and lint, the folders it writes,
   and the copy a rollback would restore.
2. **Then it replaces the scripts, writes the job file, and loads it.** Any
   failure from the first replace on runs one restore, which puts back
   everything that ran Dispatch before this setup, all or nothing, and says
   what runs now.

It also survives being stopped:

- From the first replace until success, an INT, TERM or HUP runs the same
  restore, with "Setup was stopped" as its reason.
- A kill no trap can catch leaves `~/.claude-workbench/dispatch-install.state`
  reading `installing`. The next run reads it first, restores what ran before,
  and stops, so it never snapshots unproven scripts as the originals. A kill
  while 7c writes the proven set leaves it reading `proving`, and the next run
  finishes that write.
- The job is unloaded before the first script is replaced, and before a
  restore copies anything, so no tick runs while files move.

What a rollback restores depends on the case:

- **A re-run** restores the **proven set**: the scripts and the job file in
  `~/.claude-workbench/bin.proven/`. Only 7c writes that set, whole, after a
  tick passes its proof, so unproven scripts never reach it.
- **A first install**, where there is no proven set, restores the scripts as
  they were before this setup, from a snapshot taken just before the replace.
  It unloads the new job and moves its file out of LaunchAgents, so launchd
  does not load it at the next login. The old scheduled task, if there is one,
  keeps running Dispatch.

```bash
# >>> dispatch-install >>>  (markers used by commands/test-dispatch-setup.sh — keep them)
# Inputs:  SRC_ROOT — the plugin root Step 7a resolved.
#          WORKBENCH_SETTINGS_FILE (optional) Claude Code's user settings.
# Writes:  dispatch-agent.sh, dispatch-tick.sh and escalation-comment.md in
#          ~/.claude-workbench/bin, then
#          ~/Library/LaunchAgents/dev.workbench.dev-team-dispatch.plist, and
#          loads it, replacing a job an earlier run loaded. On a first install
#          it also writes ~/.claude-workbench/bin.before, a snapshot of bin.
#          It sets ~/.claude-workbench/dispatch-install.state to "installing"
#          before the first replace, and 7c clears it.
# Exits:   1 when a check fails, before anything is replaced, with "Nothing
#          changed". 1 when a step after the first replace fails, or when the
#          shell gets INT, TERM or HUP, after the restore below, whose message
#          says what runs now. 1 after it restores what an earlier, unfinished
#          setup left.
# Every list is written out, never split from a variable, so zsh runs the block
# as bash does.
LD_LABEL="dev.workbench.dev-team-dispatch"
LD_TEMPLATE="${SRC_ROOT:-}/bin/dispatch-tick.plist"
LD_DIR="$HOME/Library/LaunchAgents"
LD_PLIST="$LD_DIR/$LD_LABEL.plist"
LD_STATE="$HOME/.claude-workbench"
LD_BIN="$LD_STATE/bin"
LD_TICK="$LD_BIN/dispatch-tick.sh"
LD_LOG="$LD_STATE/dev-team-logs/dispatch-tick.log"
LD_STAGE="$LD_STATE/dispatch-tick.plist.new"
LD_SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"
LD_DOMAIN="gui/$(id -u)"

# >>> dispatch-restore >>>  (the same text in 7b and 7c; commands/test-dispatch-setup.sh holds the two copies equal)
# The state 7b and 7c share, and the one restore path.
#
# DR_MARK says what an unfinished setup left: "installing" from just before
# 7b's first replace until a 7c pass or a finished restore, and "proving" while
# 7c writes the proven set. Empty means nothing is unfinished. A later run
# reads it first, so a setup that was killed is recovered, never snapshotted.
DR_STATE="$HOME/.claude-workbench"
DR_BIN="$DR_STATE/bin"
DR_PROVEN="$DR_STATE/bin.proven"
DR_PROVEN_JOB="$DR_PROVEN/dispatch-tick.plist"
DR_NEXT="$DR_STATE/bin.proven.next"
DR_REPLACED="$DR_STATE/bin.proven.replaced"
DR_BEFORE="$DR_STATE/bin.before"
DR_ASIDE="$DR_STATE/bin.unproven"
DR_SHELF="$DR_STATE/dispatch-tick.plist.unloaded"
DR_STAGE="$DR_STATE/dispatch-tick.plist.restore"
DR_MARK="$DR_STATE/dispatch-install.state"
DR_PLIST="$HOME/Library/LaunchAgents/dev.workbench.dev-team-dispatch.plist"
DR_JOB="gui/$(id -u)/dev.workbench.dev-team-dispatch"

# dispatch_mark <state>: DR_MARK becomes <state>, written whole. "" clears it.
dispatch_mark() { printf '%s\n' "$1" > "$DR_MARK.new" && mv -f "$DR_MARK.new" "$DR_MARK"; }
dispatch_marked() { [ "$(cat "$DR_MARK" 2>/dev/null)" = "$1" ]; }

# dispatch_finish_proven: move the staged proven set from DR_NEXT into
# DR_PROVEN, then clear the mark. A kill partway leaves the mark at
# "proving", and the next run calls this again to finish.
dispatch_finish_proven() {
  for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md dispatch-tick.plist; do
    if [ -f "$DR_NEXT/$DR_F" ]; then mv -f "$DR_NEXT/$DR_F" "$DR_PROVEN/$DR_F" || return 1; fi
  done
  dispatch_mark ""
}

# dispatch_restore <why>: put back what ran Dispatch before this setup, all or
# nothing, say what runs now, and exit 1. It first ignores further INT, TERM
# and HUP, and unloads the job, so no tick runs while files move. A re-run (a
# proven job file exists) gets the proven scripts and job file back, loaded. A
# first install gets the scripts from the bin.before snapshot back, the new job
# unloaded and its file moved out of LaunchAgents, and the old scheduled task,
# if any, still runs. Every file is copied to a staged name first, and renamed
# into place only when every copy succeeded. Every saved file a restore needs
# is checked before any is copied. When the restore cannot vouch for what bin
# holds, the job file leaves LaunchAgents, so launchd does not load it at the
# next login. A finished restore clears the mark. One that could not finish
# keeps it, so the next run tries again.
dispatch_restore() {
  trap '' INT TERM HUP
  launchctl bootout "$DR_JOB" >/dev/null 2>&1 || true
  DR_OK=1
  if [ -f "$DR_PROVEN_JOB" ]; then
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ -f "$DR_PROVEN/$DR_F" ] || DR_OK=0
    done
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ "$DR_OK" = 1 ] && { cp -p "$DR_PROVEN/$DR_F" "$DR_BIN/$DR_F.new" || DR_OK=0; }
    done
    [ "$DR_OK" = 1 ] && { cp "$DR_PROVEN_JOB" "$DR_STAGE" || DR_OK=0; }
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ "$DR_OK" = 1 ] && { mv -f "$DR_BIN/$DR_F.new" "$DR_BIN/$DR_F" || DR_OK=0; }
    done
    [ "$DR_OK" = 1 ] && { mv -f "$DR_STAGE" "$DR_PLIST" || DR_OK=0; }
    if [ "$DR_OK" != 1 ]; then
      DR_JOBMSG="no job file is left in LaunchAgents for launchd to load at the next login"
      if [ -e "$DR_PLIST" ]; then
        mv -f "$DR_PLIST" "$DR_SHELF" && DR_JOBMSG="its file is moved to $DR_SHELF, so launchd does not load it at the next login" \
          || DR_JOBMSG="its file could not be moved out of LaunchAgents, so launchd loads it at the next login with whatever $DR_BIN holds"
      fi
      echo "❌ $1 This is a re-run, and the proven scripts and job file in $DR_PROVEN could not all be put back, so $DR_BIN may hold new or mixed scripts. The job is unloaded, $DR_JOBMSG, and no Dispatch job runs now. Run setup again, which retries this restore."
      exit 1
    fi
    dispatch_mark ""
    DR_LOADED=0
    for DR_TRY in 1 2 3 4 5; do
      if launchctl bootstrap "gui/$(id -u)" "$DR_PLIST" >/dev/null 2>&1; then
        launchctl print "$DR_JOB" >/dev/null 2>&1 && DR_LOADED=1
        break
      fi
      sleep 1
    done
    if [ "$DR_LOADED" = 1 ]; then
      echo "❌ $1 This is a re-run, so the proven scripts and job file are back and loaded, and Dispatch runs as it did before this setup."
    else
      echo "❌ $1 This is a re-run. The proven scripts and job file are back on disk, but launchctl did not load the job, so no Dispatch job runs now. launchd loads it at the next login. To load it now, run: launchctl bootstrap gui/$(id -u) $DR_PLIST"
    fi
  else
    DR_JOBMSG="The new job is unloaded, and there is no job file in LaunchAgents for launchd to load at the next login."
    if [ -e "$DR_PLIST" ]; then
      if mv -f "$DR_PLIST" "$DR_SHELF"; then
        DR_JOBMSG="The new job is unloaded, and its file is moved to $DR_SHELF, where launchd does not load it at the next login."
      else
        DR_JOBMSG="The new job is unloaded, but its file could not be moved out of LaunchAgents, so launchd loads it again at the next login, beside the old scheduled task, until you remove it."
      fi
    fi
    # The snapshot names the scripts that were there before this setup. A
    # script listed there comes back from it. One that was not there is moved
    # aside, so nothing new is left for the old scheduled task to run.
    [ -f "$DR_BEFORE/manifest" ] || DR_OK=0
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      if [ "$DR_OK" = 1 ] && grep -qx "$DR_F" "$DR_BEFORE/manifest"; then
        [ -f "$DR_BEFORE/$DR_F" ] || DR_OK=0
      fi
    done
    [ "$DR_OK" = 1 ] && { mkdir -p "$DR_ASIDE" || DR_OK=0; }
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      if [ "$DR_OK" = 1 ] && grep -qx "$DR_F" "$DR_BEFORE/manifest"; then
        cp -p "$DR_BEFORE/$DR_F" "$DR_BIN/$DR_F.new" || DR_OK=0
      fi
    done
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ "$DR_OK" = 1 ] || continue
      if grep -qx "$DR_F" "$DR_BEFORE/manifest"; then
        mv -f "$DR_BIN/$DR_F.new" "$DR_BIN/$DR_F" || DR_OK=0
      elif [ -e "$DR_BIN/$DR_F" ]; then
        mv -f "$DR_BIN/$DR_F" "$DR_ASIDE/$DR_F" || DR_OK=0
      fi
    done
    if [ "$DR_OK" = 1 ]; then
      dispatch_mark ""
      echo "❌ $1 This is a first install. $DR_JOBMSG The scripts in $DR_BIN are as they were before this setup, and the old scheduled task, if you have one, still runs Dispatch with them."
    else
      echo "❌ $1 This is a first install. $DR_JOBMSG The scripts in $DR_BIN could not all be put back from $DR_BEFORE, so the old scheduled task, if you have one, may run new or mixed scripts. Run setup again, which retries this restore, or copy them back from $DR_BEFORE by hand."
    fi
  fi
  exit 1
}
# <<< dispatch-restore <<<

# ── 0. An earlier setup that did not finish. ────────────────────────────────
if dispatch_marked proving; then
  if ! dispatch_finish_proven; then
    echo "❌ An earlier setup passed its proof, then stopped while it wrote the proven set to $DR_PROVEN, and finishing that write failed. Nothing else changed. Run setup again once the folder can be written."
    exit 1
  fi
  echo "ℹ  An earlier setup passed its proof, then stopped while it wrote the proven set. That write is finished now."
elif dispatch_marked installing; then
  dispatch_restore "An earlier setup stopped after it replaced the scripts and before a tick was proven, so this run restored what ran before it, and changed nothing else. Run setup again to install."
fi

# ── 1. Checks. Nothing but empty folders changes until all pass. ─────────────
for LD_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md dispatch-tick.plist \
            test-dispatch-agent.sh test-circuit-breaker.sh test-dispatch-tick.sh; do
  [ -f "${SRC_ROOT:-}/bin/$LD_F" ] || { echo "❌ ${SRC_ROOT:-(SRC_ROOT is unset)}/bin/$LD_F is missing. Nothing changed."; exit 1; }
done
# The shipped scripts' own suites: the per-item lock, the budget cap and its
# reprieve multiple, the defaults that survive missing settings, the circuit
# breaker, and every tick behavior.
for LD_S in test-dispatch-agent.sh test-circuit-breaker.sh test-dispatch-tick.sh; do
  if ! bash "$SRC_ROOT/bin/$LD_S" >/dev/null 2>&1; then
    echo "❌ bin/$LD_S FAILED. Refusing to install scripts that do not pass their own suite. Nothing changed."
    echo "   Re-run it directly for the detail:  bash $SRC_ROOT/bin/$LD_S"
    exit 1
  fi
done

# The cadence: the user's dispatchCadenceMinutes, or the row's default.
LD_CADENCE=$(jq -r '.pluginConfigs["workbench-dev-team@claude-workbench"].options.dispatchCadenceMinutes // empty | tostring' "$LD_SETTINGS" 2>/dev/null)
[ -n "$LD_CADENCE" ] || LD_CADENCE=$(jq -r '.userConfig.dispatchCadenceMinutes.default // empty | tostring' "$SRC_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
case "$LD_CADENCE" in
  ''|*[!0-9]*) LD_CADENCE_OK=0 ;;
  *) if [ "$LD_CADENCE" -ge 5 ] && [ "$LD_CADENCE" -le 120 ]; then LD_CADENCE_OK=1; else LD_CADENCE_OK=0; fi ;;
esac
if [ "$LD_CADENCE_OK" != 1 ]; then
  echo "❌ dispatchCadenceMinutes is '${LD_CADENCE}'. Set a whole number of minutes from 5 to 120 in /config, then re-run setup. Nothing changed."
  exit 1
fi

# Each tool is looked for as a file on PATH, not with `command -v`, which
# answers with an alias where the shell has one. The search runs in a command
# substitution, a subshell in bash and zsh alike.
for LD_TOOL in jq curl claude; do
  LD_FOUND=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r LD_D; do
    if [ -x "$LD_D/$LD_TOOL" ]; then printf '%s' "$LD_D/$LD_TOOL"; break; fi
  done)
  if [ -z "$LD_FOUND" ]; then
    echo "❌ $LD_TOOL is not on this session's PATH, so the job could not find it either. Install it, then re-run setup. Nothing changed."
    exit 1
  fi
done

# This session's PATH, each folder once, then the system folders. Left out:
# temporary folders, which another session owns, and the plugin cache, whose
# folders carry a version that the next update moves.
LD_PATH=$(printf '%s:/usr/bin:/bin:/usr/sbin:/sbin' "$PATH" | tr ':' '\n' \
  | awk '/^\// && !/^\/(private\/)?(tmp|var\/folders)\// && !/\/\.claude\/plugins\/cache\// && !seen[$0]++' \
  | paste -sd: -)

# The job file, with each value XML-escaped and put in by plain string
# replacement, so no character in a path can be read as a pattern.
LD_NEW=$(LD_INTERVAL=$((LD_CADENCE * 60)) LD_TICK="$LD_TICK" LD_PATH="$LD_PATH" LD_LOG="$LD_LOG" awk '
  function xml(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
  function put(line, name, value,   at) {
    while ((at = index(line, name)) > 0) line = substr(line, 1, at - 1) value substr(line, at + length(name))
    return line
  }
  { line = $0
    line = put(line, "__TICK__", xml(ENVIRON["LD_TICK"]))
    line = put(line, "__INTERVAL__", ENVIRON["LD_INTERVAL"])
    line = put(line, "__PATH__", xml(ENVIRON["LD_PATH"]))
    line = put(line, "__LOG__", xml(ENVIRON["LD_LOG"]))
    print line }' "$LD_TEMPLATE")
case "$LD_NEW" in
  *__TICK__*|*__INTERVAL__*|*__PATH__*|*__LOG__*) LD_NEW= ;;
esac
# plutil is launchd's own reader. Where it is missing, python3 parses instead.
if [ -n "$LD_NEW" ]; then
  if command -v plutil >/dev/null 2>&1; then
    printf '%s\n' "$LD_NEW" | plutil -lint -s - >/dev/null 2>&1 || LD_NEW=
  else
    printf '%s\n' "$LD_NEW" | python3 -c 'import plistlib, sys; plistlib.load(sys.stdin.buffer)' >/dev/null 2>&1 || LD_NEW=
  fi
fi
if [ -z "$LD_NEW" ]; then
  echo "❌ The job rendered from $LD_TEMPLATE is not a valid property list. Nothing changed."
  exit 1
fi

# A re-run has a complete proven set, a first install has none of it. Part of
# one means a restore could not be complete, so nothing is replaced.
LD_PROVEN_COUNT=0
for LD_P in "$DR_PROVEN/dispatch-agent.sh" "$DR_PROVEN/dispatch-tick.sh" "$DR_PROVEN/escalation-comment.md" "$DR_PROVEN_JOB"; do
  [ -f "$LD_P" ] && LD_PROVEN_COUNT=$((LD_PROVEN_COUNT + 1))
done
case "$LD_PROVEN_COUNT" in
  4) LD_RERUN=1 ;;
  0) LD_RERUN=0 ;;
  *) echo "❌ The proven set in $DR_PROVEN is incomplete: it holds $LD_PROVEN_COUNT of its 4 files, so a rollback could not restore it. Nothing changed. Put the missing files back, or move the folder aside to install as a first install."; exit 1 ;;
esac

# Every folder a write lands in, made if missing, and writable.
for LD_W in "$LD_BIN" "$LD_DIR" "$LD_STATE" "$(dirname "$LD_LOG")"; do
  mkdir -p "$LD_W" 2>/dev/null
  [ -d "$LD_W" ] && [ -w "$LD_W" ] || { echo "❌ $LD_W cannot be written. Nothing changed."; exit 1; }
done

# ── 2. The change. From the first replace on, every failure restores. ───────
if [ "$LD_RERUN" = 0 ]; then
  # A first install keeps a snapshot of the scripts as they are now, for the
  # restore. A snapshot that fails changes nothing that runs.
  LD_SNAP_OK=1
  mkdir -p "$DR_BEFORE" || LD_SNAP_OK=0
  : > "$DR_BEFORE/manifest.new" || LD_SNAP_OK=0
  for LD_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
    if [ "$LD_SNAP_OK" = 1 ] && [ -f "$LD_BIN/$LD_F" ]; then
      { cp -p "$LD_BIN/$LD_F" "$DR_BEFORE/$LD_F" && printf '%s\n' "$LD_F" >> "$DR_BEFORE/manifest.new"; } || LD_SNAP_OK=0
    fi
  done
  [ "$LD_SNAP_OK" = 1 ] && mv -f "$DR_BEFORE/manifest.new" "$DR_BEFORE/manifest" || LD_SNAP_OK=0
  if [ "$LD_SNAP_OK" != 1 ]; then
    echo "❌ Could not snapshot the scripts in $LD_BIN to $DR_BEFORE, so a rollback could not restore them. Nothing changed."
    exit 1
  fi
fi

# From here on the mark says an install is unfinished, and a stop restores.
if ! dispatch_mark installing; then
  echo "❌ Could not write $DR_MARK, so a stopped setup could not be recovered. Nothing changed."
  exit 1
fi
trap 'dispatch_restore "Setup was stopped."' INT TERM HUP
# No tick may run while the scripts are replaced.
launchctl bootout "$LD_DOMAIN/$LD_LABEL" >/dev/null 2>&1 || true

for LD_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
  case "$LD_F" in *.sh) LD_MODE=755 ;; *) LD_MODE=644 ;; esac
  { install -m "$LD_MODE" "$SRC_ROOT/bin/$LD_F" "$LD_BIN/$LD_F.new" && mv -f "$LD_BIN/$LD_F.new" "$LD_BIN/$LD_F"; } \
    || dispatch_restore "Could not install $LD_BIN/$LD_F."
done
{ printf '%s\n' "$LD_NEW" > "$LD_STAGE" && mv -f "$LD_STAGE" "$LD_PLIST"; } \
  || dispatch_restore "Could not write $LD_PLIST."

# The job was unloaded before the replace. A bootout returns before launchd
# lets go of the label, so the bootstrap is tried a few times.
LD_LOADED=0
for LD_TRY in 1 2 3 4 5; do
  if launchctl bootstrap "$LD_DOMAIN" "$LD_PLIST" >/dev/null 2>&1; then
    launchctl print "$LD_DOMAIN/$LD_LABEL" >/dev/null 2>&1 && LD_LOADED=1
    break
  fi
  sleep 1
done
[ "$LD_LOADED" = 1 ] || dispatch_restore "launchctl did not load the new job."
# 7c clears the mark when its tick passes. Until then a stopped setup is
# recovered by the next run.
trap - INT TERM HUP
echo "✅ Dispatch scripts installed and self-tested in $LD_BIN, and the job loaded: $LD_LABEL, every $LD_CADENCE minutes. Its log is $LD_LOG"
# <<< dispatch-install <<<
```

**If this block exits non-zero, stop Step 7 here, and skip 7c and 7d.** Read
its last line to the human. A check that failed says "Nothing changed". A
later failure says whether this was a first install or a re-run, and what
runs Dispatch now.

A change to `dispatchCadenceMinutes` in `/config` reaches the job only when
setup runs again, because launchd reads the interval from the job file.

### 7c. Prove one tick works

A loaded job is not yet a working one: launchd lists a job whose tick fails at
once, or one that kills the agents it starts. So before 7d removes the old
scheduled task, run one tick now and read its log.

**Tell the human first, in plain words:** "Setup now
runs one real Dispatch tick. It polls The Index, and if a lane has work it
dispatches that agent now, exactly as the next scheduled tick would." Then run
the block. It starts the job once with `launchctl kickstart`, and waits up to
90 seconds for this tick's last line, `tick ok <start time>`. A tick prints
that line only when every list call returned an items list, so a lane that
could not list fails the proof too. A tick that stops early, because The Index
cannot be reached, refuses the token, or breaks the protocol, never prints it,
even when it printed the idle line first.

**Run this block with the Bash tool's `timeout` set to 600000** (ten minutes),
as for 7b. Its worst case is the 90-second wait plus about ten seconds of
launchd retries in the restore.

On a pass, the block records the scripts and the job file as the **proven
set**, the copy a later re-run's rollback restores. On a failure, or on an
INT, TERM or HUP before the set is marked, it runs the same restore as 7b.

```bash
# >>> launchd-prove >>>  (markers used by commands/test-dispatch-setup.sh — keep them)
# Inputs:  none. It reads the job, the log, the proven set and the bin.before
#          snapshot 7b left.
# Prints:  the tick's new log lines, then "✅ …" or "❌ …".
# Writes:  on a pass, ~/.claude-workbench/bin.proven, the proven set, through
#          bin.proven.next, and the set it replaces to bin.proven.replaced.
#          Clears ~/.claude-workbench/dispatch-install.state.
# Exits:   1 when no install is waiting for its proof. 1 when launchctl cannot
#          start the job, when this tick's `tick ok` line does not reach the
#          log within 90 seconds, or when the shell gets INT, TERM or HUP, after
#          the restore below. 1 when the proven set cannot be written.
LP_LOG="$HOME/.claude-workbench/dev-team-logs/dispatch-tick.log"

# >>> dispatch-restore >>>  (the same text in 7b and 7c; commands/test-dispatch-setup.sh holds the two copies equal)
# The state 7b and 7c share, and the one restore path.
#
# DR_MARK says what an unfinished setup left: "installing" from just before
# 7b's first replace until a 7c pass or a finished restore, and "proving" while
# 7c writes the proven set. Empty means nothing is unfinished. A later run
# reads it first, so a setup that was killed is recovered, never snapshotted.
DR_STATE="$HOME/.claude-workbench"
DR_BIN="$DR_STATE/bin"
DR_PROVEN="$DR_STATE/bin.proven"
DR_PROVEN_JOB="$DR_PROVEN/dispatch-tick.plist"
DR_NEXT="$DR_STATE/bin.proven.next"
DR_REPLACED="$DR_STATE/bin.proven.replaced"
DR_BEFORE="$DR_STATE/bin.before"
DR_ASIDE="$DR_STATE/bin.unproven"
DR_SHELF="$DR_STATE/dispatch-tick.plist.unloaded"
DR_STAGE="$DR_STATE/dispatch-tick.plist.restore"
DR_MARK="$DR_STATE/dispatch-install.state"
DR_PLIST="$HOME/Library/LaunchAgents/dev.workbench.dev-team-dispatch.plist"
DR_JOB="gui/$(id -u)/dev.workbench.dev-team-dispatch"

# dispatch_mark <state>: DR_MARK becomes <state>, written whole. "" clears it.
dispatch_mark() { printf '%s\n' "$1" > "$DR_MARK.new" && mv -f "$DR_MARK.new" "$DR_MARK"; }
dispatch_marked() { [ "$(cat "$DR_MARK" 2>/dev/null)" = "$1" ]; }

# dispatch_finish_proven: move the staged proven set from DR_NEXT into
# DR_PROVEN, then clear the mark. A kill partway leaves the mark at
# "proving", and the next run calls this again to finish.
dispatch_finish_proven() {
  for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md dispatch-tick.plist; do
    if [ -f "$DR_NEXT/$DR_F" ]; then mv -f "$DR_NEXT/$DR_F" "$DR_PROVEN/$DR_F" || return 1; fi
  done
  dispatch_mark ""
}

# dispatch_restore <why>: put back what ran Dispatch before this setup, all or
# nothing, say what runs now, and exit 1. It first ignores further INT, TERM
# and HUP, and unloads the job, so no tick runs while files move. A re-run (a
# proven job file exists) gets the proven scripts and job file back, loaded. A
# first install gets the scripts from the bin.before snapshot back, the new job
# unloaded and its file moved out of LaunchAgents, and the old scheduled task,
# if any, still runs. Every file is copied to a staged name first, and renamed
# into place only when every copy succeeded. Every saved file a restore needs
# is checked before any is copied. When the restore cannot vouch for what bin
# holds, the job file leaves LaunchAgents, so launchd does not load it at the
# next login. A finished restore clears the mark. One that could not finish
# keeps it, so the next run tries again.
dispatch_restore() {
  trap '' INT TERM HUP
  launchctl bootout "$DR_JOB" >/dev/null 2>&1 || true
  DR_OK=1
  if [ -f "$DR_PROVEN_JOB" ]; then
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ -f "$DR_PROVEN/$DR_F" ] || DR_OK=0
    done
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ "$DR_OK" = 1 ] && { cp -p "$DR_PROVEN/$DR_F" "$DR_BIN/$DR_F.new" || DR_OK=0; }
    done
    [ "$DR_OK" = 1 ] && { cp "$DR_PROVEN_JOB" "$DR_STAGE" || DR_OK=0; }
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ "$DR_OK" = 1 ] && { mv -f "$DR_BIN/$DR_F.new" "$DR_BIN/$DR_F" || DR_OK=0; }
    done
    [ "$DR_OK" = 1 ] && { mv -f "$DR_STAGE" "$DR_PLIST" || DR_OK=0; }
    if [ "$DR_OK" != 1 ]; then
      DR_JOBMSG="no job file is left in LaunchAgents for launchd to load at the next login"
      if [ -e "$DR_PLIST" ]; then
        mv -f "$DR_PLIST" "$DR_SHELF" && DR_JOBMSG="its file is moved to $DR_SHELF, so launchd does not load it at the next login" \
          || DR_JOBMSG="its file could not be moved out of LaunchAgents, so launchd loads it at the next login with whatever $DR_BIN holds"
      fi
      echo "❌ $1 This is a re-run, and the proven scripts and job file in $DR_PROVEN could not all be put back, so $DR_BIN may hold new or mixed scripts. The job is unloaded, $DR_JOBMSG, and no Dispatch job runs now. Run setup again, which retries this restore."
      exit 1
    fi
    dispatch_mark ""
    DR_LOADED=0
    for DR_TRY in 1 2 3 4 5; do
      if launchctl bootstrap "gui/$(id -u)" "$DR_PLIST" >/dev/null 2>&1; then
        launchctl print "$DR_JOB" >/dev/null 2>&1 && DR_LOADED=1
        break
      fi
      sleep 1
    done
    if [ "$DR_LOADED" = 1 ]; then
      echo "❌ $1 This is a re-run, so the proven scripts and job file are back and loaded, and Dispatch runs as it did before this setup."
    else
      echo "❌ $1 This is a re-run. The proven scripts and job file are back on disk, but launchctl did not load the job, so no Dispatch job runs now. launchd loads it at the next login. To load it now, run: launchctl bootstrap gui/$(id -u) $DR_PLIST"
    fi
  else
    DR_JOBMSG="The new job is unloaded, and there is no job file in LaunchAgents for launchd to load at the next login."
    if [ -e "$DR_PLIST" ]; then
      if mv -f "$DR_PLIST" "$DR_SHELF"; then
        DR_JOBMSG="The new job is unloaded, and its file is moved to $DR_SHELF, where launchd does not load it at the next login."
      else
        DR_JOBMSG="The new job is unloaded, but its file could not be moved out of LaunchAgents, so launchd loads it again at the next login, beside the old scheduled task, until you remove it."
      fi
    fi
    # The snapshot names the scripts that were there before this setup. A
    # script listed there comes back from it. One that was not there is moved
    # aside, so nothing new is left for the old scheduled task to run.
    [ -f "$DR_BEFORE/manifest" ] || DR_OK=0
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      if [ "$DR_OK" = 1 ] && grep -qx "$DR_F" "$DR_BEFORE/manifest"; then
        [ -f "$DR_BEFORE/$DR_F" ] || DR_OK=0
      fi
    done
    [ "$DR_OK" = 1 ] && { mkdir -p "$DR_ASIDE" || DR_OK=0; }
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      if [ "$DR_OK" = 1 ] && grep -qx "$DR_F" "$DR_BEFORE/manifest"; then
        cp -p "$DR_BEFORE/$DR_F" "$DR_BIN/$DR_F.new" || DR_OK=0
      fi
    done
    for DR_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
      [ "$DR_OK" = 1 ] || continue
      if grep -qx "$DR_F" "$DR_BEFORE/manifest"; then
        mv -f "$DR_BIN/$DR_F.new" "$DR_BIN/$DR_F" || DR_OK=0
      elif [ -e "$DR_BIN/$DR_F" ]; then
        mv -f "$DR_BIN/$DR_F" "$DR_ASIDE/$DR_F" || DR_OK=0
      fi
    done
    if [ "$DR_OK" = 1 ]; then
      dispatch_mark ""
      echo "❌ $1 This is a first install. $DR_JOBMSG The scripts in $DR_BIN are as they were before this setup, and the old scheduled task, if you have one, still runs Dispatch with them."
    else
      echo "❌ $1 This is a first install. $DR_JOBMSG The scripts in $DR_BIN could not all be put back from $DR_BEFORE, so the old scheduled task, if you have one, may run new or mixed scripts. Run setup again, which retries this restore, or copy them back from $DR_BEFORE by hand."
    fi
  fi
  exit 1
}
# <<< dispatch-restore <<<

# Only an install 7b left unproven has a tick to prove.
if ! dispatch_marked installing; then
  echo "❌ No install is waiting for its proof: 7b did not finish one, or it was already proven or restored. Run 7b first. Nothing changed."
  exit 1
fi
# A stop from here until the proven set is marked runs the restore.
trap 'dispatch_restore "Setup was stopped before the tick was proven."' INT TERM HUP

# Only what this tick writes counts, so the log's size now is the start line.
LP_FROM=0
[ -f "$LP_LOG" ] && LP_FROM=$(wc -c < "$LP_LOG" | tr -d ' ')
launchctl kickstart "$DR_JOB" >/dev/null 2>&1 || dispatch_restore "launchctl could not start the job."
# The wait: LP_TRIES reads, LP_STEP seconds apart, 90 seconds in all. It stays
# well inside the 600000 ms timeout the prose asks for, with the restore's
# retries, so a failed proof always reaches its restore.
LP_TRIES=45
LP_STEP=2
LP_NEW=
LP_OK=0
LP_TRY=0
while [ "$LP_TRY" -lt "$LP_TRIES" ]; do
  LP_TRY=$((LP_TRY + 1))
  [ -f "$LP_LOG" ] && LP_NEW=$(tail -c "+$((LP_FROM + 1))" "$LP_LOG")
  if printf '%s\n' "$LP_NEW" | grep -Eq '^tick ok [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'; then
    LP_OK=1
    break
  fi
  sleep "$LP_STEP"
done
[ -n "$LP_NEW" ] && printf '%s\n' "$LP_NEW"
[ "$LP_OK" = 1 ] || dispatch_restore "The tick did not finish cleanly within 90 seconds: no 'tick ok' line reached $LP_LOG. Read the lines above for the cause."

# The tick passed, so these scripts and this job file are the proven set now.
# All four are staged in DR_NEXT, and the set they replace is copied to the one
# DR_REPLACED slot, both fixed folders reused each run. Then the mark turns to
# "proving", and the staged files are renamed into DR_PROVEN. A kill after the
# mark leaves the next run to finish the renames.
LP_FIRST=1
[ -f "$DR_PROVEN_JOB" ] && LP_FIRST=0
LP_SET=1
mkdir -p "$DR_NEXT" "$DR_PROVEN" "$DR_REPLACED" || LP_SET=0
for LP_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
  [ "$LP_SET" = 1 ] && { cp -p "$DR_BIN/$LP_F" "$DR_NEXT/$LP_F" || LP_SET=0; }
done
[ "$LP_SET" = 1 ] && { cp "$DR_PLIST" "$DR_NEXT/dispatch-tick.plist" || LP_SET=0; }
for LP_F in dispatch-agent.sh dispatch-tick.sh escalation-comment.md dispatch-tick.plist; do
  if [ "$LP_SET" = 1 ] && [ -f "$DR_PROVEN/$LP_F" ]; then cp -p "$DR_PROVEN/$LP_F" "$DR_REPLACED/$LP_F" || LP_SET=0; fi
done
[ "$LP_SET" = 1 ] && { dispatch_mark proving || LP_SET=0; }
trap - INT TERM HUP
[ "$LP_SET" = 1 ] && { dispatch_finish_proven || LP_SET=2; }
LP_CASE="This is a re-run."
[ "$LP_FIRST" = 1 ] && LP_CASE="This is a first install, so skip 7d: the old scheduled task keeps running beside the new job until a setup run proves it."
if [ "$LP_SET" = 0 ]; then
  echo "❌ The tick passed, and the new job runs, but the proven set could not be staged in $DR_NEXT, so $DR_PROVEN is unchanged. $LP_CASE The install is still marked unfinished, so the next setup run restores what ran before it. Fix the folder, then run setup again."
  exit 1
fi
if [ "$LP_SET" = 2 ]; then
  echo "❌ The tick passed, and the new job runs, but the proven set was only partly written to $DR_PROVEN. $LP_CASE The next setup run finishes that write before anything else."
  exit 1
fi
echo "✅ Dispatch tick proven: the tick polled every lane and wrote 'tick ok' to $LP_LOG. These scripts and this job file are now the proven set."
# <<< launchd-prove <<<
```

**If this block exits non-zero, skip 7d**, and read its last line and the log
lines it printed to the human. That line says whether this was a first install,
where the old scheduled task still runs Dispatch, or a re-run, where the proven
scripts and job file are back.

### 7d. Retire the model-run router

Run this step only when 7c printed `✅ Dispatch tick proven`. Two pieces of the
old router are left behind, and each would run beside the new job:

1. **The scheduled task.** Call `mcp__scheduled-tasks__list_scheduled_tasks`.
   If it lists a task whose `taskId` is `workbench-dev-team-dispatch`, call
   `mcp__scheduled-tasks__delete_scheduled_task` with that `taskId`. Dispatch
   would otherwise run twice each cadence, once as a model and once as the job.
   If the tools are not available in this session, tell the human to delete the
   task in the Scheduled panel, and repeat that in the Step 8 summary.
2. **The router's permission rules.** The model-run router called
   `dispatch-agent.sh` through two `permissions.allow` rules. Nothing calls it
   through the Bash tool now: the job runs it directly, and the dev-team mod
   runs it without a tool call. Run this block to remove both rules:

```bash
# >>> router-retire >>>  (markers used by commands/test-dispatch-setup.sh — keep them)
# Inputs:  WORKBENCH_SETTINGS_FILE (optional) Claude Code's user settings.
#          Defaults to ~/.claude/settings.json.
# Writes:  the settings file, less the two dispatch-agent.sh allow rules. Every
#          other rule and key stays. A backup is taken first.
# Exits:   1 when the file is not a JSON object, or the write fails.
RR_SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"
RR_ABS="Bash(bash $HOME/.claude-workbench/bin/dispatch-agent.sh:*)"
# shellcheck disable=SC2016  # the rule spells $HOME literally, as the router wrote it
RR_HOME='Bash(bash "$HOME/.claude-workbench/bin/dispatch-agent.sh":*)'
if [ ! -f "$RR_SETTINGS" ]; then
  echo "✅ No $RR_SETTINGS, so no router rules to remove"
elif ! jq -e 'type == "object"' "$RR_SETTINGS" >/dev/null 2>&1; then
  echo "❌ $RR_SETTINGS is not a JSON object. Left untouched. Remove the two dispatch-agent.sh allow rules by hand."
  exit 1
elif ! jq -e --arg a "$RR_ABS" --arg h "$RR_HOME" '(.permissions.allow // []) | any(. == $a or . == $h)' "$RR_SETTINGS" >/dev/null 2>&1; then
  echo "✅ No router allow rules in $RR_SETTINGS"
else
  cp "$RR_SETTINGS" "$RR_SETTINGS.bak-router-$(date +%Y%m%d-%H%M%S)"
  # Held in a variable and checked before it is written: no temporary file, and
  # no file-removal verb for workbench-core's destructive-scope guard to refuse.
  RR_NEW=$(jq --arg a "$RR_ABS" --arg h "$RR_HOME" '.permissions.allow -= [$a, $h]' "$RR_SETTINGS") \
    && printf '%s\n' "$RR_NEW" | jq -e 'type == "object"' >/dev/null \
    && printf '%s\n' "$RR_NEW" > "$RR_SETTINGS" \
    || { echo "❌ Could not update $RR_SETTINGS. Remove the two dispatch-agent.sh allow rules by hand."; exit 1; }
  echo "✅ Removed the router's two dispatch-agent.sh allow rules from $RR_SETTINGS"
fi
# <<< router-retire <<<
```

A failure here is a **warning, not a stop**: the rules are inert once nothing
runs the router. Say so in the Step 8 summary.

The app's own `scheduled-tasks.json`, which older setups patched to pin the
router's model, needs nothing. Deleting the task removes its entry.

## Step 8 — Final summary

Print a clean summary block:

```text
═══════════════════════════════════════════
  workbench-dev-team setup complete
═══════════════════════════════════════════

  The Index MCP:   https://the-index.mikebronner.dev/mcp
  Log directory:    ~/.claude-workbench/dev-team-logs
  Settings:         /config, workbench-dev-team rows
                    {MIGRATION}
  Attribution:      {ATTR_RESULT} in ~/.claude/settings.json
                    (suppressed = no Co-Authored-By; default (visible) = trailer on)
  Commit prompts:   10 commit, push, and merge ask rules in ~/.claude/settings.json
                    (or: ⚠ not installed — foreground commits and merges are not prompted)
                    {LEGACY_COMMANDS}
  Dispatch job:     dev.workbench.dev-team-dispatch, every {CADENCE} min, no model
                    (or: ⚠ not installed — re-run setup to install)
  Dispatch log:     ~/.claude-workbench/dev-team-logs/dispatch-tick.log
  Scripts from:     {SRC_ROOT}/bin (v{SRC_VERSION}), self-tested
  Old router:       scheduled task deleted, allow rules removed
                    (or: ⚠ {ROUTER_LEFT})

  {STALE_ROOT_WARNING}

  Agents:           Lestrade, Holmes ($10 cap), Watson ($10 cap)
                    — models, effort, fallback and budget are /config rows,
                      read on every dispatch, scheduled and interactive
═══════════════════════════════════════════
```

Fill each slot from the step that produced it:

- `{MIGRATION}`: Step 6b's result. `old config moved, kept as <file>`, with one
  more line per `MIGRATE_SKIPPED` value. Omit the line when there was no old
  config.
- `{ATTR_RESULT}`: the user's Step 6.5 choice, `suppressed` or
  `default (visible)`.
- `{CADENCE}`: the minutes Step 7b printed.
- `{SRC_ROOT}`, `{SRC_VERSION}`: Step 7a.
- `{ROUTER_LEFT}`: what Step 7d could not retire, such as "delete the
  workbench-dev-team-dispatch task in the Scheduled panel". When Step 7 was
  skipped, say the old task, if any, still runs.

`{LEGACY_COMMANDS}` is the `! rm` command for each `LEGACY_LEFT` line Step 6.6
printed, one per line. When Step 6.6 printed none, omit that line.

`{STALE_ROOT_WARNING}` is Step 7a's one-liner. **When it is empty (the common
case — the running root is current) omit that line and the blank line above it
entirely.** When it is non-empty, print it verbatim and do **not** dress it as
a ✅ — a version mismatch is never a clean success, and hiding it is the exact
failure this summary exists to surface.

## Notes

- **Idempotency.** All four keychain checks, the MCP registration (`remove ||
  true` then `add`), the `mkdir -p`, the job install (a bootout, then a
  bootstrap of the same label), and the router retirement are safe to re-run.
  Step 6b renames the old config once it has moved, so a re-run never moves it
  over a later `/config` edit. Step 4 always fetches a fresh token, which is
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
  any time `claude mcp list` shows `the-index` as `Failed to connect`. The
  Dispatch tick mints its own token from the same Keychain client, and caches it
  in `~/.claude-workbench/the-index-token.json` (readable by the user alone)
  until it expires, so it adds one token row to The Index a year, not one a
  tick.
- **Why Step 7a resolves its own source.** Discovered 2026-08-27: the live
  Dispatch prompt was missing the in-flight dispatch lock shipped in v0.37.0+
  and had been stale for 23 days, across two apparently-successful setup runs.
  Root cause: `${CLAUDE_PLUGIN_ROOT}` expands to the *executing* copy of the
  plugin, and in a resumed session that copy is a per-session snapshot
  materialized once at session creation and never refreshed (a full app restart
  resumes the same session, so it doesn't help either —
  anthropics/claude-code#45810). The running root was v0.35.0 while
  `installed_plugins.json` correctly resolved v0.37.4. Step 7a prefers the
  install path recorded in `installed_plugins.json` and only falls back to the
  running root when that file is missing, unparseable, or names no usable path
  — and it compares the two versions so a frozen root produces a loud warning
  instead of a green checkmark. **Caveat: this doesn't repair an
  already-frozen session.** A stale root still carries the old Step 7a, so the
  fix needs one clean bootstrap — a single session started after the update,
  running the patched setup.
- **Why Dispatch is a script, not a scheduled Claude task.** The model-run
  router read a ~3K-token prompt, loaded its tools, and polled four lists on
  every tick, whether or not there was work, and its model was pinned only by
  patching the app's internal `scheduled-tasks.json`. The Index's MCP endpoint
  answers a bare JSON-RPC `tools/call` with a plain JSON reply, so a shell
  script can do the same routing over HTTPS. Every filter and sort already ran
  on the server, and the circuit breaker, budgets and reprieve already lived in
  `dispatch-agent.sh`. The one model-written piece, the escalation comment, is
  now the checked-in `bin/escalation-comment.md`, which the tick's suite holds
  to comms-style, because a comment posted over curl passes no Claude-side
  prose check. The script depends on that endpoint staying stateless. Any reply
  that is not a JSON-RPC result stops the tick with a message that names this.
- **Tests.** `commands/test-dispatch-setup.sh` runs the `dispatch-install`,
  `launchd-prove` and `router-retire` blocks, extracted from between this
  file's sentinels, and holds the two copies of `dispatch_restore` equal, against a throwaway `HOME`, with `launchctl` stubbed, so
  nothing is installed or loaded. `commands/test-config-pin.sh` runs Step 6's
  pin check, pin replacement and move the same way, with `claude` stubbed.
