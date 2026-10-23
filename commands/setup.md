---
description: Configure the workbench-dev-team plugin — verify prerequisites, check Keychain credentials, register The Index MCP, move an old agent config into /config, install the dispatcher, and install the Dispatch prompt into the workbench-dev-team-dispatch scheduled task. Re-run after a plugin update, after a cadence change, or to refresh the OAuth bearer token (annual).
disable-model-invocation: true
---

The user has invoked `/workbench-dev-team:setup`. Walk them through the one-time
(or annual-refresh) configuration of the plugin.

This command is fully idempotent — re-running is safe at any time. It will skip
already-satisfied steps, refresh the OAuth bearer token (1-year lifetime),
replace the installed dispatcher with the current one, and refresh the Dispatch
task's prompt and schedule.

Dispatch is the Claude scheduled task `workbench-dev-team-dispatch`. On every
run it polls The Index and runs `~/.claude-workbench/bin/dispatch-agent.sh`
once per item. Its prompt ships as `scheduled-tasks/orchestrator.md`. Setup
installs the dispatcher, keeps the task's two allow rules, and creates the task
when it is missing or updates its prompt and schedule when it exists. It never
deletes or disables the task, and it never removes its allow rules.

Every plain setting (models, efforts, budgets, fan-out, the Dispatch cadence)
is a row in `/config`, not a question here. This command keeps only the steps
that need a model: Keychain secrets the user stores, the questions it asks, and
the scheduled-tasks tools that install the Dispatch task.

## Constants

```text
The Index MCP URL:    https://the-index.mikebronner.dev/mcp
The Index OAuth URL:  https://the-index.mikebronner.dev/oauth/token
Log directory:         ~/.claude-workbench/dev-team-logs
Settings:              /config rows, kept in ~/.claude/settings.json
                       under pluginConfigs["workbench-dev-team@claude-workbench"]
Old agent config:      ~/.claude-workbench/dev-team-config.json (moved by Step 6b)
Dispatcher:            ~/.claude-workbench/bin/dispatch-agent.sh
Dispatch task:         workbench-dev-team-dispatch (a Claude scheduled task)
Dispatch prompt:       <resolved plugin root>/scheduled-tasks/orchestrator.md
Plugin registry:       ~/.claude/plugins/installed_plugins.json
```

The dispatcher's and the prompt's source is **resolved at run time in Step
7a**, not hard-coded off `${CLAUDE_PLUGIN_ROOT}` — the running root can be a
frozen session snapshot. See Step 7a for the resolution order.

## Step 1 — Check the Dispatch scheduled task

Read what runs Dispatch before anything changes. The tools are deferred, so
load them first:

```
ToolSearch  query: select:mcp__scheduled-tasks__list_scheduled_tasks,mcp__scheduled-tasks__create_scheduled_task,mcp__scheduled-tasks__update_scheduled_task
```

Then call `mcp__scheduled-tasks__list_scheduled_tasks`, and look for the task
whose `taskId` is `workbench-dev-team-dispatch`. Save the result as
`DISPATCH_TASK`:

- `found`, with the task's schedule and whether it is enabled.
- `missing`, when the list has no such task.
- `unknown`, when the tools do not load or the call fails.

Step 7e creates the task when it is `missing`, and updates it when it is
`found`. **Setup never deletes this task and never disables it.** When the task
is `found` but disabled, leave it disabled, and say so in the Step 8 summary:
the human disabled it, and only the human turns it back on. If `DISPATCH_TASK`
is `unknown`, Step 7e writes nothing. Ask the human to check the Scheduled
panel, and repeat it in the Step 8 summary.

## Step 2 — Verify prerequisites

Run a single Bash check for the host tools the rest of the script needs:

```bash
missing=""
for cmd in gh jq security git curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing="$missing $cmd"
  fi
done
if test -n "$missing"; then
  echo "❌ Missing prerequisites:$missing"
  echo "   Install the missing tools and re-run /workbench-dev-team:setup."
  exit 1
fi
echo "✅ gh, jq, security, git, curl all present"
```

Do not check for `claude` — we're already running inside a Claude Code session.

`curl` fetches the OAuth token in Step 4, and the `/dev-team-board` pane mints
its own token and fetches The Index with `curl` and `jq`, through
`bin/dispatch-tick.sh --board`.
`jq` is also here because the pipeline's permission hook
(`hooks/scripts/pipeline-scope.sh`) reads its payload with it, and without it
the hook allows nothing, so a missing tool blocks the pipeline rather than
letting it through unchecked. The review guard runs in the plugin's hooks
module, on workbench-core's `$.workbench` noun, and needs no host tool.

If any prerequisite is missing, stop and tell the user how to install it
(`brew install gh jq` for the common case; `security` and `curl` ship with
macOS; `git` comes with the Xcode Command Line Tools,
`xcode-select --install`).

## Step 3 — Check Keychain credentials

Four entries are required. Check each one with its service spelled out, as
below. The standing rule every session carries applies here: read only the
Keychain entries setup's own processes use, store a secret only in the
Keychain, and never show one. Setup still never stores a secret itself,
because the secret would first have to pass through the conversation. For each
missing entry, give the human the `!` command to run, then run the check again.

```bash
missing=""
security find-generic-password -s the-index-mcp -a client-id >/dev/null 2>&1 \
  && echo "✅ the-index-mcp / client-id" || missing="$missing the-index-mcp/client-id"
security find-generic-password -s the-index-mcp -a client-secret >/dev/null 2>&1 \
  && echo "✅ the-index-mcp / client-secret" || missing="$missing the-index-mcp/client-secret"
security find-generic-password -s github-cli -a token >/dev/null 2>&1 \
  && echo "✅ github-cli / token" || missing="$missing github-cli/token"
security find-generic-password -s claude-code -a oauth-token >/dev/null 2>&1 \
  && echo "✅ claude-code / oauth-token" || missing="$missing claude-code/oauth-token"
[ -z "$missing" ] && echo "✅ All four Keychain entries are present" || echo "⚠  Missing:$missing"
```

For each missing entry, show the human its command below, and ask them to run
it in this session with the `!` prefix. Each `-w` comes last with no value, so
`security` asks for the secret at a hidden prompt, and the secret never reaches
the conversation or the shell history. The one exception is the gh entry: its
`-w "$(gh auth token)"` puts the token on that command line while `security`
runs, where another process on the machine could briefly see it.

- `the-index-mcp / client-id`, The Index OAuth client ID:
  `! security add-generic-password -s the-index-mcp -a client-id -U -w`
- `the-index-mcp / client-secret`, The Index OAuth client secret:
  `! security add-generic-password -s the-index-mcp -a client-secret -U -w`
- `github-cli / token`, the GitHub token for dispatched agents. `gh` must be
  logged in first (`gh auth login`). This one reads the token from `gh`, so
  there is no prompt:
  `! security add-generic-password -s github-cli -a token -U -w "$(gh auth token)"`
- `claude-code / oauth-token`, the Claude Code OAuth token for the headless
  `claude -p` runs Dispatch starts. The human gets one by running
  `claude setup-token` in a separate terminal (it starts with
  `sk-ant-oat01-`), then pastes it at the prompt of:
  `! security add-generic-password -s claude-code -a oauth-token -U -w`

When the human says they ran them, run the check block again. If an entry is
still missing, stop, and say which one.

## Step 4 — Fetch OAuth bearer token

```bash
CLIENT_ID=$(security find-generic-password -s "the-index-mcp" -a "client-id" -w)
CLIENT_SECRET=$(security find-generic-password -s "the-index-mcp" -a "client-secret" -w)

TOKEN_RESP=$(curl -q -sS -X POST "https://the-index.mikebronner.dev/oauth/token" \
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
| `dispatchCadenceMinutes` | `20` | How often the Dispatch task runs. Step 7d turns it into the task's schedule, so re-run setup after a change. The `/dev-team-board` pane also fetches at most this often. |
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
         PIN_BAD=$(expr "$PIN_BAD" + 1)
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
      PIN_COUNT=$(expr "$PIN_COUNT" + 1)
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
  if [[ " $PIN_AGENTS " == *" $PIN_AGENT "* ]]; then
    PIN_TARGETS="$PIN_TARGETS $PIN_AGENT"
  else
    echo "⚠  '$PIN_AGENT' is not one of: $PIN_AGENTS — not written"
  fi
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
      MIG_WHERE=$(printf 'pluginConfigs["%s"]' "$MIG_KEY")
      echo "❌ These values are not in $MIG_SETTINGS under $MIG_WHERE, where dispatch-agent.sh reads them: $(printf '%s' "$MIG_MISSING" | tr '\n' ' ')"
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

## Step 7 — Install the dispatcher and the Dispatch task

The Dispatch task runs `bash "$HOME/.claude-workbench/bin/dispatch-agent.sh"`
once per item, and the dev-team mod runs the same file in place of an
interactive Watson `Item ID: <n>` dispatch. The dispatcher holds the circuit
breaker, the budgets, the reprieve, and the spawn. It lives at that stable
path, not in the plugin cache, whose path carries the version and moves on
every update. A plugin update does not refresh it, so this step does.

Then 7d and 7e install the task's prompt, `scheduled-tasks/orchestrator.md`,
and its schedule into the scheduled task.

### 7a. Resolve the plugin source

**Never install from `${CLAUDE_PLUGIN_ROOT}` when a better source exists.** The
harness expands that variable to the *executing* copy of the plugin, which in a
resumed session is a snapshot materialized once at session creation under
`~/Library/Application Support/Claude/local-agent-mode-sessions/…/plugin_<hash>/`
and never refreshed — not even by a full app restart, because the app resumes
the same session (anthropics/claude-code#45810). Installing from that copy
silently pins the dispatcher to whatever the plugin looked like weeks ago. Resolve the
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
    if [ -n "$CAND_ROOT" ] && [ -f "$CAND_ROOT/bin/dispatch-agent.sh" ]; then
      SRC_ROOT="$CAND_ROOT"
      SRC_VERSION="$CAND_VERSION"
    elif [ -n "$CAND_ROOT" ]; then
      echo "⚠  $REGISTRY points at $CAND_ROOT, but bin/dispatch-agent.sh is not readable there."
    fi
  fi
fi

# Fallback: the running root. Correct in a fresh session, stale in a resumed one
# — say so out loud rather than deploying from it quietly.
if [ -z "$SRC_ROOT" ]; then
  if [ -n "$RUN_ROOT" ] && [ -f "$RUN_ROOT/bin/dispatch-agent.sh" ]; then
    SRC_ROOT="$RUN_ROOT"
    SRC_VERSION=$(jq -r '.version // ""' "$RUN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)
    echo "⚠  Could not resolve an install path from $REGISTRY — falling back to the running"
    echo "   plugin root ($SRC_ROOT). If this session's copy is frozen, the dispatcher installed"
    echo "   below is frozen with it."
  else
    echo "❌ Could not locate bin/dispatch-agent.sh — neither $REGISTRY nor"
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
  STALE_ROOT_WARNING="⚠  STALE PLUGIN ROOT — this session ran v$RUN_VERSION; the dispatcher was installed from v$SRC_VERSION"
  cat <<EOF2
⚠  ═══════════════ STALE PLUGIN ROOT ═══════════════
   This session is EXECUTING workbench-dev-team v$RUN_VERSION from:
     $RUN_ROOT
   but the INSTALLED plugin is v$SRC_VERSION at:
     $SRC_ROOT
   \$CLAUDE_PLUGIN_ROOT is materialized once when a session is created and is
   never refreshed — not even by an app restart that resumes the same session
   (anthropics/claude-code#45810).
   → The dispatcher IS being installed from the installed path (v$SRC_VERSION).
   → Every OTHER step in this run still came from the stale v$RUN_VERSION copy.
     Start a brand-new session and re-run /workbench-dev-team:setup for a fully
     current run.
   ═══════════════════════════════════════════════════
EOF2
fi

echo "Dispatcher source: $SRC_ROOT (v${SRC_VERSION:-unknown})"
```

Carry `SRC_ROOT`, `SRC_VERSION` and `STALE_ROOT_WARNING` (empty when the
running root is current) into the steps below and the Step 8 summary. If this
block exits non-zero, stop Step 7 entirely, so the task is not written either.

### 7b. Install the dispatcher, after its suites pass

```bash
# >>> dispatcher-install >>>  (markers used by commands/test-dispatch-setup.sh — keep them)
DI_SRC="${SRC_ROOT:-}/bin"
DI_BIN="$HOME/.claude-workbench/bin"
for DI_F in dispatch-agent.sh test-dispatch-agent.sh test-circuit-breaker.sh; do
  if [ ! -f "$DI_SRC/$DI_F" ]; then
    echo "❌ $DI_SRC/$DI_F is missing, so the dispatcher was not installed. Nothing changed."
    exit 1
  fi
done
for DI_F in test-dispatch-agent.sh test-circuit-breaker.sh; do
  if ! bash "$DI_SRC/$DI_F" >/dev/null 2>&1; then
    echo "❌ bin/$DI_F failed, so the dispatcher was not installed. Nothing changed. For the detail, run: bash $DI_SRC/$DI_F"
    exit 1
  fi
done
if ! { mkdir -p "$DI_BIN" \
    && install -m 755 "$DI_SRC/dispatch-agent.sh" "$DI_BIN/dispatch-agent.sh.new" \
    && mv -f "$DI_BIN/dispatch-agent.sh.new" "$DI_BIN/dispatch-agent.sh"; }; then
  echo "❌ Could not write $DI_BIN/dispatch-agent.sh. The dispatcher installed before, if any, still runs."
  exit 1
fi
echo "✅ Dispatcher installed and self-tested: $DI_BIN/dispatch-agent.sh"
# <<< dispatcher-install <<<
```

The two suites cover the per-item in-flight lock, the budget cap and its
reprieve multiple, the defaults that apply when a `/config` row is unset, and
the circuit-breaker pre-flight with its one-shot reprieve marker.

**If this block exits non-zero, read its last line to the human, go on to 7c,
and skip 7e.** The Dispatch task keeps running the dispatcher and the prompt it
had, and the allow rules serve that dispatcher too. The prompt is not
installed beside a dispatcher that failed its suites.

### 7c. Keep the dispatcher's allow rules

The Dispatch task is a model run under the auto-mode classifier. Two
`permissions.allow` rules match its dispatcher call, so the classifier never
judges the spawn. Without them it judges every tick's spawn and refuses some of
them at random. The two rules are the `$HOME` form the task's prompt writes,
and the absolute path that form expands to. This block adds whichever rule is
absent. It never removes a rule.

```bash
# >>> dispatcher-allow >>>  (markers used by commands/test-dispatch-setup.sh — keep them)
DA_SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"
DA_ABS="Bash(bash $HOME/.claude-workbench/bin/dispatch-agent.sh:*)"
# shellcheck disable=SC2016  # the rule spells $HOME literally, as the task's prompt writes it
DA_HOME='Bash(bash "$HOME/.claude-workbench/bin/dispatch-agent.sh":*)'
DA_OLD='{}'
if [ -f "$DA_SETTINGS" ]; then
  if ! jq -e 'type == "object"' "$DA_SETTINGS" >/dev/null 2>&1; then
    echo "❌ $DA_SETTINGS is not a JSON object. Left untouched. Add the two dispatch-agent.sh allow rules by hand."
    exit 1
  fi
  DA_OLD=$(cat "$DA_SETTINGS")
fi
if printf '%s\n' "$DA_OLD" | jq -e --arg a "$DA_ABS" --arg h "$DA_HOME" \
    '(.permissions.allow // []) | any(. == $a) and any(. == $h)' >/dev/null 2>&1; then
  echo "✅ Both dispatch-agent.sh allow rules are in $DA_SETTINGS"
else
  [ -f "$DA_SETTINGS" ] && cp "$DA_SETTINGS" "$DA_SETTINGS.bak-dispatcher-$(date +%Y%m%d-%H%M%S)"
  # Held in a variable and checked before it is written: no temporary file, and
  # no file-removal verb for workbench-core's destructive-scope guard to refuse.
  DA_NEW=$(printf '%s\n' "$DA_OLD" | jq --arg a "$DA_ABS" --arg h "$DA_HOME" \
      '.permissions.allow = ((.permissions.allow // []) as $r | $r + ([$a, $h] - $r))') \
    && printf '%s\n' "$DA_NEW" | jq -e 'type == "object"' >/dev/null \
    && printf '%s\n' "$DA_NEW" > "$DA_SETTINGS" \
    || { echo "❌ Could not update $DA_SETTINGS. Add the two dispatch-agent.sh allow rules by hand."; exit 1; }
  echo "✅ Added the dispatch-agent.sh allow rules to $DA_SETTINGS"
fi
# <<< dispatcher-allow <<<
```

A failure here is a **warning, not a stop**. Dispatch still runs, but the
classifier judges its spawns until the rules are in place. Say so in the
Step 8 summary.

### 7d. Prepare the prompt and the schedule

The first block strips the frontmatter from the shipped prompt, checks what is
left, and writes the body to `~/.claude-workbench/dispatch-prompt.md`. The
second turns `dispatchCadenceMinutes` into the task's cron schedule.

```bash
# >>> dispatch-prompt >>>  (markers used by commands/test-dispatch-setup.sh — keep them)
DP_SRC="${SRC_ROOT:-}/scheduled-tasks/orchestrator.md"
DP_OUT="$HOME/.claude-workbench/dispatch-prompt.md"
if [ ! -f "$DP_SRC" ]; then
  echo "❌ $DP_SRC is missing. The Dispatch task was not changed."
  exit 1
fi
DP_BODY=$(awk 'NR==1 && $0=="---" {fm=1; next}
     fm==1 && $0=="---" {fm=2; next}
     fm==2 {if (!started && $0 ~ /^[[:space:]]*$/) next; started=1; print; next}
     fm!=1 {print}' "$DP_SRC")
DP_WHY=""
[ -n "$DP_BODY" ] || DP_WHY="its body is empty"
[ -z "$DP_WHY" ] && printf '%s\n' "$DP_BODY" | head -1 | grep -qx -- '---' && DP_WHY="its body still opens with a frontmatter fence"
[ -z "$DP_WHY" ] && printf '%s\n' "$DP_BODY" | grep -qF -- 'name: dispatch-orchestrator' && DP_WHY="its frontmatter survived the strip"
DP_LANES=$(printf '%s\n' "$DP_BODY" | grep -oE -- 'dispatch-agent\.sh" +[a-z][a-z-]*' | sort -u | wc -l | tr -d ' ')
[ -z "$DP_WHY" ] && [ "$DP_LANES" -lt 3 ] && DP_WHY="it dispatches $DP_LANES lanes, not 3"
[ -z "$DP_WHY" ] && ! printf '%s\n' "$DP_BODY" | grep -qF -- 'dispatch-agent.sh" --mark-escalated' && DP_WHY="it lacks the --mark-escalated call"
[ -z "$DP_WHY" ] && ! printf '%s\n' "$DP_BODY" | grep -qF -- 'dispatch-agent.sh" --check' && DP_WHY="it lacks the --check call"
if [ -n "$DP_WHY" ]; then
  echo "❌ $DP_SRC failed its check: $DP_WHY. The Dispatch task was not changed. Update or re-install the plugin, then re-run setup."
  exit 1
fi
if ! { mkdir -p "$(dirname "$DP_OUT")" && printf '%s\n' "$DP_BODY" > "$DP_OUT"; }; then
  echo "❌ Could not write $DP_OUT. The Dispatch task was not changed."
  exit 1
fi
echo "✅ Dispatch prompt checked: $DP_LANES lanes"
echo "Dispatch prompt: $DP_OUT"
# <<< dispatch-prompt <<<
```

```bash
# >>> dispatch-schedule >>>  (markers used by commands/test-dispatch-setup.sh — keep them)
DS_SETTINGS="${WORKBENCH_SETTINGS_FILE:-$HOME/.claude/settings.json}"
DS_MIN=$(jq -r '.pluginConfigs["workbench-dev-team@claude-workbench"].options.dispatchCadenceMinutes // empty | tostring' "$DS_SETTINGS" 2>/dev/null)
[ -n "$DS_MIN" ] || DS_MIN=$(jq -r '.userConfig.dispatchCadenceMinutes.default // empty | tostring' "${SRC_ROOT:-}/.claude-plugin/plugin.json" 2>/dev/null)
case "$DS_MIN" in
  5|6|10|12|15|20|30) DS_CRON="*/$DS_MIN * * * *" ;;
  60) DS_CRON="0 * * * *" ;;
  *)
    echo "❌ dispatchCadenceMinutes is '$DS_MIN'. Set it in /config to 5, 6, 10, 12, 15, 20, 30 or 60, so each run starts at the same minutes of every hour, then re-run setup. The Dispatch task was not changed."
    exit 1
    ;;
esac
echo "Dispatch schedule: $DS_CRON (every $DS_MIN min)"
# <<< dispatch-schedule <<<
```

**If either block exits non-zero, skip 7e**, and read its last line to the
human.

### 7e. Create or update the Dispatch task

Skip this step when `DISPATCH_TASK` from Step 1 is `unknown`, or when 7b or 7d
exited non-zero. Say why in the Step 8 summary.

Otherwise use the `Read` tool on the **absolute path** 7d printed as
`Dispatch prompt:`. That file is already stripped, so pass its contents
verbatim. Never strip the source file by hand. The description is
`"Dispatch — poll The Index every {MINUTES} min and fire workbench-dev-team agents on pending items."`,
with the minutes 7d printed.

- **When `DISPATCH_TASK` is `found`**, call
  `mcp__scheduled-tasks__update_scheduled_task` with `taskId:
  "workbench-dev-team-dispatch"`, `cronExpression` (the schedule 7d printed),
  `prompt` (the file's contents), and `description`. Pass nothing else, so a
  task the human disabled stays disabled.
- **When `DISPATCH_TASK` is `missing`**, call
  `mcp__scheduled-tasks__create_scheduled_task` with the same four arguments.

Then call `mcp__scheduled-tasks__list_scheduled_tasks` once more, and confirm
that the task is there with the new schedule. Tell the human which action ran,
`created` or `updated`.

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
  Dispatch task:    workbench-dev-team-dispatch {TASK_ACTION}, {TASK_STATE}
                    prompt from {SRC_ROOT}/scheduled-tasks/orchestrator.md
                    (or: ⚠ {TASK_PROBLEM})
  Dispatcher:       ~/.claude-workbench/bin/dispatch-agent.sh, self-tested
                    from {SRC_ROOT}/bin (v{SRC_VERSION})
                    (or: ⚠ not installed — the dispatcher installed before still runs)
  Allow rules:      2 dispatch-agent.sh rules in ~/.claude/settings.json
                    (or: ⚠ not in place — the classifier judges each dispatch)

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
- `{TASK_ACTION}`: Step 7e's action, `created` or `updated`.
- `{TASK_STATE}`: the schedule 7d printed, and whether the task is enabled,
  such as `*/20 * * * *, enabled`. For a task the human disabled, write
  `disabled — turn it on in the Scheduled panel`.
- `{TASK_PROBLEM}`: why Step 7e wrote nothing, when it did not run. For
  `unknown`, write "could not read the scheduled tasks. Check the Scheduled
  panel, then re-run setup." When 7b or 7d failed, name that step and its last
  line, and say the task keeps the prompt and schedule it had.
- `{SRC_ROOT}`, `{SRC_VERSION}`: Step 7a.

`{STALE_ROOT_WARNING}` is Step 7a's one-liner. **When it is empty (the common
case — the running root is current) omit that line and the blank line above it
entirely.** When it is non-empty, print it verbatim and do **not** dress it as
a ✅ — a version mismatch is never a clean success, and hiding it is the exact
failure this summary exists to surface.

## Notes

- **Idempotency.** All four keychain checks, the MCP registration (`remove ||
  true` then `add`), the `mkdir -p`, the dispatcher install (a staged copy
  renamed over the old one), and the allow rules (added only when absent) are
  safe to re-run. Step 7e updates the task it finds rather than creating a
  second one. Step 6b renames the old
  config once it has moved, so a re-run never moves it over a later `/config`
  edit. Step 4 always fetches a fresh token, which is exactly the desired
  behavior on re-run (annual refresh is the dominant use case).
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
  `installed_plugins.json` correctly resolved v0.37.4. Step 7a prefers the
  install path recorded in `installed_plugins.json` and only falls back to the
  running root when that file is missing, unparseable, or names no usable path
  — and it compares the two versions so a frozen root produces a loud warning
  instead of a green checkmark. **Caveat: this doesn't repair an
  already-frozen session.** A stale root still carries the old Step 7a, so the
  fix needs one clean bootstrap — a single session started after the update,
  running the patched setup.
- **Why Dispatch is a scheduled Claude task, and setup never retires it.**
  Release 0.53.0 replaced the task with a launchd job that ran
  `bin/dispatch-tick.sh`, and its setup deleted the task and its allow rules.
  Mike decided on 2026-10-12 that Dispatch stays the Claude scheduled task
  `workbench-dev-team-dispatch`, so setup installs no job of its own. The
  task's prompt, `scheduled-tasks/orchestrator.md`, ships again, corrected for
  the `/config` rows, and Step 7e installs it, so a re-run after a plugin update
  refreshes the live task. Setup still never deletes or disables the task.
  `bin/dispatch-tick.sh` stays in the plugin, because the `/dev-team-board`
  pane fetches The Index through `bin/dispatch-tick.sh --board`.
- **Tests.** `commands/test-dispatch-setup.sh` runs the `dispatcher-install`,
  `dispatcher-allow`, `dispatch-prompt` and `dispatch-schedule` blocks,
  extracted from between this file's sentinels, against a throwaway `HOME`, so
  nothing is installed. The prompt case runs on the shipped
  `scheduled-tasks/orchestrator.md`. `commands/test-config-pin.sh` runs Step 6's
  pin check, pin replacement and move the same way, with `claude` stubbed.
  `commands/lint-setup-dispatch.sh` fails when a step of this file names a
  launchd job, or a scheduled-tasks tool other than the list, create and update
  tools, or passes `enabled`. The `dispatcher-allow` tests show that setup
  removes no allow rule.
