#!/usr/bin/env bash
# Dispatch one dev-team agent as a detached subprocess, behind the circuit breaker.
#
# Dispatch (the scheduled orchestrator) runs under the auto-mode classifier,
# which judges every Bash command it cannot match to a permission rule. The
# multi-line dispatch block this replaces — config reads, a Keychain fetch, and
# a backgrounded `nohup claude -p … &` — has no matchable prefix,
# so it was re-judged on every tick and refused nondeterministically. A single
# stable invocation can be covered by one `permissions.allow` prefix rule, which
# is evaluated *before* the classifier and takes the judgment call off the table.
#
# The circuit-breaker pre-flight and its marker live here for the same reason.
# They used to be a ~115-line bash block the orchestrator re-typed for every item
# on every tick (about 7K tokens a tick), and the reprieve step then consumed its
# marker with an `rm` outside every scratch root, which workbench-core's
# destructive-scope guard always denies. The marker survived, so a reprieved item
# re-ran on every tick at the multiplied budget. Inside this allowlisted script
# neither the rm nor the reprieve budget is a separate Bash call.
#
# Usage:
#   dispatch-agent.sh lestrade <item-id>        # triage one item
#   dispatch-agent.sh lestrade <owner/repo>     # blocker sweep for one repo (no pre-flight)
#   dispatch-agent.sh holmes   <item-id>        # review one item
#   dispatch-agent.sh watson   <item-id>        # develop one item
#   dispatch-agent.sh --check <agent> <item-id>          # print the pre-flight verdict, spawn nothing
#   dispatch-agent.sh --mark-escalated <agent> <item-id> # record that the breaker escalated this item
#
# An item dispatch runs the pre-flight first, and its first output line says what
# happened:
#   dispatched <agent> pid=… log=…   the normal case
#   SKIP<TAB><reason>                a run on this item is still alive; nothing spawned
#   ESCALATE<TAB><reason>            the item is wedged; nothing spawned. The caller
#                                    escalates it, then runs --mark-escalated.
#   REPRIEVE<TAB><note>              a human re-activated an escalated item; the
#                                    marker is consumed and a `dispatched` line
#                                    follows, with the budget multiplied.
#
# Environment read:
#   DISPATCH_DRY_RUN=1  print the command that would run; spawn nothing, consume nothing
#   LOGDIR, DISPATCH_CONFIG, RUNROOT  test overrides
#
# Environment set on the child:
#   WORKBENCH_DEV_TEAM_PIPELINE=1   tells the plugin's hooks this run is the
#                                   autonomous pipeline. See the export below.
#
# Exits non-zero on bad arguments, and when the run's folder cannot be made
# empty and outside every git repository. That check comes before any log or
# lock is written. A malformed or absent config never blocks a dispatch — every
# knob falls back to its default,
# and a knob with no default (model, effort) is left off, so the agent
# definition's own pin applies where it has one and Claude Code's default
# applies where it has none.
set -u

CONFIG="${DISPATCH_CONFIG:-$HOME/.claude-workbench/dev-team-config.json}"
LOGDIR="${LOGDIR:-$HOME/.claude-workbench/dev-team-logs}"
RUNROOT="${RUNROOT:-$HOME/Developer/scratchpad}"   # a scratch root; each run's folder goes here

MODE=dispatch
case "${1:-}" in
  --check) MODE=check; shift ;;
  --mark-escalated) MODE=mark; shift ;;
esac

AGENT="${1:-}"
TARGET="${2:-}"

case "$AGENT" in
  lestrade|holmes|watson) ;;
  *) echo "usage: $(basename "$0") [--check|--mark-escalated] <lestrade|holmes|watson> <item-id|owner/repo>" >&2; exit 2 ;;
esac

if [ -z "$TARGET" ]; then
  echo "$(basename "$0"): missing target (item id, or owner/repo for a lestrade sweep)" >&2
  exit 2
fi

# A target containing a slash is a repo sweep — Lestrade only, and a plain
# dispatch only. Everything else is a project_items.id and must be numeric, so a
# malformed argument fails here rather than spawning an agent that cannot find
# its item, or writing a marker for one.
SWEEP=0
case "$TARGET" in
  */*)
    if [ "$AGENT" != lestrade ] || [ "$MODE" != dispatch ]; then
      echo "$(basename "$0"): only a lestrade dispatch takes a repo sweep target, got '$TARGET'" >&2
      exit 2
    fi
    SWEEP=1
    ;;
  ''|*[!0-9]*)
    echo "$(basename "$0"): '$TARGET' is neither a numeric item id nor an owner/repo sweep target" >&2
    exit 2
    ;;
esac

ID="$TARGET"
MARKER="$LOGDIR/$AGENT-$ID.escalated"   # presence => the breaker escalated this item before

# ── The circuit breaker ───────────────────────────────────────────────────────
#
# An agent can die on a fatal, non-recoverable error before it ever runs a tool
# — most notably `API Error: Output blocked by content filtering policy`. It then
# never moves its own item, so every tick re-dispatches it forever. The breaker
# reads the item's own run logs and lock, never its content, and prints one of
# DISPATCH, SKIP, REPRIEVE, or ESCALATE. The policy, lane by lane:
#
#   - A live run on this item holds it (SKIP). A dispatched agent writes its
#     status at the END of its run, so for its whole life the item still reads as
#     lane-eligible, and a second run would duplicate it and race its board
#     writes. The lock is per agent and per item. A dead PID reads as free.
#   - A human re-activation wins (REPRIEVE). The marker says the breaker escalated
#     this item before, so its return to the lane means a human moved it back.
#     One fresh run, at a raised budget. If it wedges again, escalation starts
#     from scratch, so each human touch buys one real attempt.
#   - The content filter escalates on the first hit, in any lane. The deliverable
#     itself trips it, so no retry can succeed.
#   - A hard USD budget kill escalates on the first hit for Lestrade and Holmes:
#     the same workload at the same cap hits the same wall. Two exceptions. Holmes
#     is dispatched instead when the dev lane logged a run after the killed
#     review, because Watson's push made the next review a different job (item
#     575, phpcs-rules#375). And Watson escalates only after CB_FATAL_STRIKES
#     consecutive budget kills, because it resumes on a persistent branch and each
#     capped run starts further along. Measured over 1,015 runs: 69 hard kills
#     across 52 items, and no item needed a 4th. Watson's graceful wind-down
#     never writes the kill signature and never escalates.
#   - Any other fatal escalates after CB_FATAL_STRIKES identical runs for
#     Lestrade and Holmes, and never for Watson: a 529 or a partial is not
#     provably terminal, and "tried too many times" is Holmes's call after review.
preflight() {
  CB_BUDGET_SIG='Exceeded USD budget'   # the HARD kill the harness writes
  # The last three lines of a run's log, not counting its permission refusals.
  # They print during the run and just before its final result, and they quote
  # the refused call, so a refused command that names a signature would
  # otherwise read as one.
  cb_tail() { grep -v '^Permission denied: ' "$1" 2>/dev/null | tail -3; }
  CB_FATAL_STRIKES=3
  local cb_lock="$LOGDIR/$AGENT-$ID.lock" cb_latest cb_pid cb_f cb_sig cb_strikes cb_newer_watson
  cb_latest=$(ls -t "$LOGDIR/$AGENT-$ID-"*.log 2>/dev/null | head -1)
  cb_pid=$(cat "$cb_lock" 2>/dev/null || true)
  case "$cb_pid" in ''|0|*[!0-9]*) cb_pid= ;; esac   # `kill -0 0` hits our own process group — never a run
  if [ -n "$cb_pid" ] && kill -0 "$cb_pid" 2>/dev/null; then
    printf 'SKIP\ta run dispatched on this item is still alive (pid %s) — a second one would duplicate its work and race its board writes\n' "$cb_pid"
  elif [ -f "$MARKER" ]; then
    printf 'REPRIEVE\thuman re-activated a previously-escalated item — granting one fresh run with a raised budget\n'
  elif [ -z "$cb_latest" ]; then
    echo DISPATCH
  elif cb_tail "$cb_latest" | grep -qi 'content filtering policy'; then
    printf 'ESCALATE\toutput blocked by the content filtering policy — a required deliverable trips the output content filter, so the run can never succeed on retry\n'
  elif cb_tail "$cb_latest" | grep -qF "$CB_BUDGET_SIG"; then
    if [ "$AGENT" = watson ]; then
      cb_strikes=0
      # Newest first, one path per line: ls -t is what orders by mtime.
      while IFS= read -r cb_f; do
        cb_tail "$cb_f" | grep -qF "$CB_BUDGET_SIG" || break   # streak broken
        cb_strikes=$((cb_strikes + 1))
      done < <(ls -t "$LOGDIR/$AGENT-$ID-"*.log 2>/dev/null)
      if [ "$cb_strikes" -ge "$CB_FATAL_STRIKES" ]; then
        printf 'ESCALATE\t%s consecutive runs were killed by the USD budget cap without reaching review — raise agents.watson.maxBudgetUsd or split the work, then move the item back to its lane for a raised-budget reprieve\n' "$cb_strikes"
      else
        echo DISPATCH
      fi
    else
      cb_newer_watson=$(ls -t "$LOGDIR/watson-$ID-"*.log 2>/dev/null | head -1)
      if [ "$AGENT" = holmes ] && [ -n "$cb_newer_watson" ] && [ "$cb_newer_watson" -nt "$cb_latest" ]; then
        echo DISPATCH   # the dev lane moved this item on — not the same wall
      else
        printf 'ESCALATE\tthe run hit the configured USD budget cap before completing, so re-running at the same cap will hit the same wall — raise agents.%s.maxBudgetUsd or split the work, then move the item back to its lane for a raised-budget reprieve\n' "$AGENT"
      fi
    fi
  elif [ "$AGENT" = watson ]; then
    echo DISPATCH
  else
    cb_sig=$(cb_tail "$cb_latest" | grep -iE '^(API Error|Execution error|Error:)' | tail -1)
    if [ -z "$cb_sig" ]; then
      echo DISPATCH
    else
      cb_strikes=0
      while IFS= read -r cb_f; do
        cb_tail "$cb_f" | grep -qiF "$cb_sig" || break   # streak broken
        cb_strikes=$((cb_strikes + 1))
      done < <(ls -t "$LOGDIR/$AGENT-$ID-"*.log 2>/dev/null)
      if [ "$cb_strikes" -ge "$CB_FATAL_STRIKES" ]; then
        printf 'ESCALATE\t%s consecutive runs died with the same fatal error: %s\n' "$cb_strikes" "$cb_sig"
      else
        echo DISPATCH
      fi
    fi
  fi
}

if [ "$MODE" = check ]; then
  preflight
  exit 0
fi

if [ "$MODE" = mark ]; then
  # Called only after the escalation `move` succeeded: without a real escalation
  # there is nothing for a later re-activation to reprieve.
  mkdir -p "$LOGDIR"
  : > "$MARKER"
  printf 'marked %s-%s escalated\n' "$AGENT" "$ID"
  exit 0
fi

REPRIEVE=0
if [ "$SWEEP" = 0 ]; then
  VERDICT=$(preflight)
  case "$VERDICT" in
    SKIP*|ESCALATE*) printf '%s\n' "$VERDICT"; exit 0 ;;
    REPRIEVE*) printf '%s\n' "$VERDICT"; REPRIEVE=1 ;;
  esac
fi

# Per-agent budget default, used when the config is missing, malformed, or silent
# on the key. It matches the shipped config, so a lost config cannot lift a cap.
# Model and effort have no default here on purpose. The config is where they are
# set, and the shipped one pins every agent to claude-opus-5-5[1m] at medium. An
# absent key omits the flag, so the run falls back to the mode agent's own
# frontmatter, which bin/compose-agents.sh copies from the public agent file. A
# baked-in value here would be one more copy to drift.
case "$AGENT" in
  lestrade) DEFAULT_BUDGET= ;;
  holmes)   DEFAULT_BUDGET=10.00 ;;
  watson)   DEFAULT_BUDGET=10.00 ;;
esac

cfg() {
  # cfg <jq-path> <fallback> — read one key, falling back on any failure.
  local value
  value=$(jq -r "${1} // empty" "$CONFIG" 2>/dev/null) || value=""
  [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$2"
}

MODEL=$(cfg ".agents.${AGENT}.model" "")
EFFORT=$(cfg ".agents.${AGENT}.effort" "")
FALLBACK=$(cfg ".agents.${AGENT}.fallback" "")
BUDGET=$(cfg ".agents.${AGENT}.maxBudgetUsd" "$DEFAULT_BUDGET")

# Reprieve: a human re-activated a previously-escalated item, so they have
# accepted the cost — raise the cap for this one run. Inert on ordinary ticks.
if [ "$REPRIEVE" = 1 ] && [ -n "$BUDGET" ]; then
  MULT=$(cfg ".agents.${AGENT}.reprieveBudgetMultiplier" "3")
  BUDGET=$(awk -v b="$BUDGET" -v m="$MULT" 'BEGIN{printf "%.2f", b*m}')
fi

STAMP=$(date +%Y%m%d-%H%M%S)

# The mode agent the run starts as. Each prompt below is a token that picks one
# mode, so the run loads only that mode's prompt: agents/<mode>.md, composed by
# bin/compose-agents.sh. `--agent` resolves a type before any hooks module
# loads, so these are agent files and never a type the dev-team mod registers.
case "$AGENT" in
  watson) MODE_TYPE=watson-index ;;
  holmes) MODE_TYPE=holmes-index ;;
  lestrade) if [ "$SWEEP" = 1 ]; then MODE_TYPE=lestrade-sweep; else MODE_TYPE=lestrade-item; fi ;;
esac

if [ "$SWEEP" = 1 ]; then
  PROMPT="Repo sweep: $TARGET"
  LOG="$LOGDIR/${AGENT}-sweep-$(printf '%s' "$TARGET" | tr '/' '-')-$STAMP.log"
  LOCK=
else
  PROMPT="Item ID: $TARGET"
  LOG="$LOGDIR/${AGENT}-${TARGET}-$STAMP.log"
  # In-flight lock: the pre-flight SKIPs this item while this PID lives. Sweeps
  # are not per-item and take no lock.
  LOCK="$LOGDIR/${AGENT}-${TARGET}.lock"
fi

# Tools no pipeline run may use. Before each run started in its own empty folder
# (see RUNDIR below), runs started in this repo and inherited these as deny rules
# from its .claude/settings.local.json. That file is personal and untracked, and
# the installed copy of this script runs from ~/.claude-workbench/bin, where no
# repo is in reach. So the list lives here, in the one file that is installed,
# and bin/test-dispatch-agent.sh pins every name. A bare tool name as a deny rule
# removes the tool from the run.
DENIED_TOOLS=(
  Workflow Artifact Monitor PushNotification RemoteTrigger SendMessage
  DesignSync ReportFindings
  CronCreate CronDelete CronList ScheduleWakeup
  TaskCreate TaskGet TaskList TaskOutput TaskStop TaskUpdate
  EnterWorktree ExitWorktree
  ListMcpResourcesTool ReadMcpResourceTool ReadMcpResourceDirTool
  NotebookEdit
)

# MCP servers whose calls no pipeline run sends to the auto-mode classifier: the
# two every agent's frontmatter names. Under the old bypass mode no MCP call was
# ever judged, and the classifier's default rules name board writes and review
# approvals, which are these agents' whole job. An allow rule is matched before
# the classifier, and auto mode keeps an MCP allow rule where it drops a broad
# Bash or Agent one. A server's tools take a glob only after a literal
# mcp__<server>__ prefix, so each server is named here.
ALLOWED_TOOLS=('mcp__the-index__*' 'mcp__plugin_workbench-core_memory__*')

# --disallowedTools and --allowedTools take variadic lists. Each goes in as one
# comma-joined value, and an option always follows it, so neither can swallow
# the prompt.
set -- --agent "workbench-dev-team:${MODE_TYPE}" \
  --disallowedTools "$(IFS=,; printf '%s' "${DENIED_TOOLS[*]}")" \
  --allowedTools "$(IFS=,; printf '%s' "${ALLOWED_TOOLS[*]}")"
[ -n "$MODEL" ]    && set -- "$@" --model "$MODEL"
[ -n "$EFFORT" ]   && set -- "$@" --effort "$EFFORT"
[ -n "$FALLBACK" ] && set -- "$@" --fallback-model "$FALLBACK"
[ -n "$BUDGET" ]   && set -- "$@" --max-budget-usd "$BUDGET"
# The permission mode is named, never left to the default: one -p run was seen
# starting in auto mode with no flag, where the docs say default. Auto mode lets
# the classifier judge what no rule decides, and `--permission-prompts none`
# denies anything that would still prompt, since nobody is at the keyboard.
# This replaced --dangerously-skip-permissions, which the classifier's own
# default rules name as an unsafe way to start an agent loop. stream-json, which
# needs --verbose, is the one output that reports every refusal, sub-agents'
# included. The renderer below turns it back into a plain-text log.
set -- "$@" --permission-mode auto --permission-prompts none \
  --output-format stream-json --verbose "$PROMPT"

# Mark the child as the autonomous pipeline. The commit guard in the hooks
# module (hooks/mods/commit-guard.ts) needs no flag: it reads the run's main
# loop as a top-level agent, which may commit and push, and still refuses its
# merges and every sub-agent's commit. `hooks/scripts/pipeline-scope.sh`
# (PermissionRequest) reads the flag, and answers a prompt for one plain
# `git -C <dir>`, rm, or rmdir line with "allow" when every path is absolute and
# stays inside the roots: all
# of $TMPDIR, so another run's clone is in scope too, and the scratch roots.
# Nobody is at the keyboard, and `--permission-prompts none` denies every prompt
# the hook does not allow. An ask rule is matched before the classifier, so the
# commit and push ask rules prompt, and without the flag every scheduled run
# would die at its first commit. The approval chain here is board dispatch,
# Holmes review, and the human's own PR merge.
#
# The dispatcher sets it, never the agent. It reaches exactly the process this
# script spawns and its children, so an interactive session on the same machine
# is untouched — the property the old host-wide /tmp/watson.lock could not offer.
export WORKBENCH_DEV_TEAM_PIPELINE=1

if [ "${DISPATCH_DRY_RUN:-0}" = 1 ]; then
  printf 'claude -p'; printf ' %s' "$@"; printf '\n'
  printf 'log=%s\n' "$LOG"
  printf 'lock=%s\n' "${LOCK:-none}"
  printf 'runroot=%s\n' "$RUNROOT"
  # Read back the exported variable rather than restating the literal, so the
  # dry run cannot claim a carve-out the real invocation does not set.
  printf 'pipeline=%s\n' "${WORKBENCH_DEV_TEAM_PIPELINE:-unset}"
  exit 0
fi

# The run starts in a fresh, empty folder, never in the caller's cwd. Dispatch
# itself runs in ~/Developer/workbench-dev-team, and a child started there would
# take the live plugin repo as its project folder. workbench-core's
# destructive-scope guard treats the project folder as in scope, so a pipeline
# `git reset --hard` or `rm -rf` there would run unprompted. The cost, accepted:
# the run loads no project CLAUDE.md and no project settings. The deny rules it
# used to take from there are passed as DENIED_TOOLS above. User-level settings
# still apply. CLAUDE_PROJECT_DIR is unset, so the child can only take its
# project folder from the new cwd.
#
# The folder is made in a scratch root, ~/Developer/scratchpad, because Mike's
# rule is that scratch lives in one and whoever makes it deletes it. A bare
# mktemp -d in $TMPDIR, as this used to be, was never deleted. A folder inside a
# git repository would make that repository the run's project, so one is
# refused. No clean folder, no run: falling back to the caller's cwd is the case
# this exists to prevent.
RUNDIR=
mkdir -p "$RUNROOT" 2>/dev/null && RUNDIR=$(mktemp -d "$RUNROOT/dispatch-$AGENT.XXXXXX" 2>/dev/null)
if [ -z "$RUNDIR" ] || [ ! -d "$RUNDIR" ]; then
  echo "$(basename "$0"): could not create a run folder under $RUNROOT; nothing dispatched" >&2
  exit 1
fi
if git -C "$RUNDIR" rev-parse --git-dir >/dev/null 2>&1; then
  rmdir "$RUNDIR"
  echo "$(basename "$0"): run folder $RUNDIR is inside a git repository; nothing dispatched" >&2
  exit 1
fi
unset CLAUDE_PROJECT_DIR

mkdir -p "$LOGDIR"

# The one thing the classifier reliably flagged: a Keychain read feeding a
# detached subprocess. Inside an allowlisted script it is no longer a judgment
# call. A missing token is not fatal — `claude` falls back to its own auth.
CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s "claude-code" -a "oauth-token" -w 2>/dev/null || true)
export CLAUDE_CODE_OAUTH_TOKEN

# Turns the run's stream-json into the plain-text log the breaker and a human
# read. Each refused tool call becomes one line, as it happens:
#   Permission denied: <tool>[ in a sub-agent] <input> -- <reason>
# The input is cut to 300 characters, and a file tool's content, old_string,
# new_string, and edits are left out, so a refused write never copies its
# content into the log. Three sources, because none of them sees every refusal: the permission_denied
# event (rules, unanswered prompts, the classifier, in sub-agents too), a
# tool result that starts "PreToolUse:" (a hook's deny, which that event
# skips), and the result's permission_denials list for anything else in the
# main thread. A call already printed is not printed twice. Then the final
# result prints as text mode prints it, so the log ends as it always has. A line
# that is not JSON passes through unchanged.
RENDER='
def clip: tostring | gsub("[\r\n]+"; " ") | if length > 300 then .[0:300] + "..." else . end;
def brief: if type == "object" then del(.content, .old_string, .new_string, .edits) else . end | tojson | clip;
def denied($tool; $sub; $input; $why):
  "Permission denied: \($tool // "tool")\(if $sub then " in a sub-agent" else "" end) \($input // "(input not seen)") -- \($why // "no reason given" | clip)";
def result_text:
  if .subtype == "success" then .result // ""
  elif .subtype == "error_during_execution" then "Execution error"
  elif .subtype == "error_max_turns" then "Error: Reached max turns"
  elif .subtype == "error_max_budget_usd" then "Error: Exceeded USD budget"
  else "Error: " + ((.errors // [])[0] // .subtype // "unknown result" | tostring) end;
foreach (inputs, null) as $line ({calls: {}, seen: {}, ended: false};
  .out = []
  | if $line == null then
      if .ended then . else .out = ["Error: No messages returned from query"] end
    else
      ($line | try fromjson catch null) as $m
      | if ($m | type) != "object" then .out = [$line]
        elif $m.type == "assistant" then
          reduce ($m.message.content[]? | objects | select(.type == "tool_use" and (.id | type) == "string")) as $c
            (.; .calls[$c.id] = {name: $c.name, input: ($c.input | brief)})
        elif $m.type == "system" and $m.subtype == "permission_denied" then
          .calls[$m.tool_use_id // ""] as $c
          | (if $m.tool_use_id then .seen[$m.tool_use_id] = true else . end)
          | .out = [denied($m.tool_name; $m.agent_id; $c.input; $m.message // $m.decision_reason)]
        elif $m.type == "user" then
          .calls as $calls
          | [ $m.message.content[]? | objects | select(.type == "tool_result" and .is_error == true)
              | {id: .tool_use_id, text: (.content | if type == "array" then map(.text? // "") | join(" ") else tostring end)}
              | select(.text | startswith("PreToolUse:")) ] as $blocked
          | reduce ($blocked[] | .id | strings) as $id (.; .seen[$id] = true)
          | .out = [$blocked[] | $calls[.id // ""] as $c | denied($c.name; $m.parent_tool_use_id; $c.input; .text)]
        elif $m.type == "result" then
          .seen as $seen
          | .ended = true
          | .out = [($m.permission_denials // [])[] | select(.tool_use_id == null or ($seen[.tool_use_id] | not))
                    | denied(.tool_name; null; (.tool_input | brief); "refused")]
                   + [$m | result_text]
        else . end
    end;
  .out[])'

# The redirect opens in this script's cwd, so a relative LOGDIR still resolves
# where the pre-flight reads it. The wrapper subshell owns the run folder: its
# EXIT trap deletes it when the agent exits, on success or failure. A TERM ends
# the wrapper through that trap too, and a HUP is ignored, as nohup ignores it
# for the agent. $! is the wrapper's PID, which lives until the agent has exited
# and its folder is gone, so the lock holds for the whole run.
(
  trap '' HUP
  trap 'rm -rf -- "$RUNDIR"' EXIT
  trap 'exit 143' TERM
  cd "$RUNDIR" || exit 1
  nohup claude -p "$@" | jq -nrR --unbuffered "$RENDER"
) > "$LOG" 2>&1 &
DISPATCHED=$!
[ -n "$LOCK" ] && printf '%s' "$DISPATCHED" > "$LOCK"
disown 2>/dev/null || true

# One reprieve per human touch: the marker goes once the fresh run is spawned. If
# that run wedges too, the breaker escalates from scratch and writes a new one.
[ "$REPRIEVE" = 1 ] && rm -f "$MARKER"

printf 'dispatched %s pid=%s log=%s\n' "$AGENT" "$DISPATCHED" "$LOG"
