#!/usr/bin/env bash
# Test for bin/dispatch-agent.sh.
#
# Runs the real script in DISPATCH_DRY_RUN mode against fixture configs, so the
# assertions cover the shipped argument-building logic without spawning agents.
# The run-folder cases spawn for real, against a stub `claude` on PATH.
#
# Run: bash bin/test-dispatch-agent.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/dispatch-agent.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not found"; exit 1
fi

# dispatch-agent.sh resolves both its config and its log directory out of $HOME.
# Every invocation below overrides DISPATCH_CONFIG and LOGDIR explicitly, but a
# sandboxed HOME is what stops a case that forgets one from reading the
# developer's real dev-team-config.json and writing their real log directory.
mkdir -p "$WORK/home"
export HOME="$WORK/home"

pass=0; fail=0

# mkcfg <name> <json> -> echoes the config path
mkcfg() { printf '%s' "$2" > "$WORK/$1.json"; printf '%s' "$WORK/$1.json"; }

# run <config> <agent> <target> -> echoes dry-run output (stdout+stderr)
#
# WORKBENCH_DEV_TEAM_PIPELINE is unset for every run. The pipeline assertions
# below therefore prove the script sets the flag itself, rather than inheriting
# it from the shell that ran this suite.
run() {
  DISPATCH_CONFIG="$1" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 \
    env -u WORKBENCH_DEV_TEAM_PIPELINE bash "$SCRIPT" "$2" "$3" 2>&1
}

# rc <config> <agent> <target> -> echoes the exit code
rc() {
  DISPATCH_CONFIG="$1" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 \
    bash "$SCRIPT" "$2" "$3" >/dev/null 2>&1
  printf '%s' "$?"
}

# expect_has <name> <needle> <haystack>
expect_has() {
  case "$3" in
    *"$2"*) echo "  ok   — $1"; pass=$((pass+1)) ;;
    *)      echo "  FAIL — $1: expected to contain '$2', got: $3"; fail=$((fail+1)) ;;
  esac
}

# expect_lacks <name> <needle> <haystack>
expect_lacks() {
  case "$3" in
    *"$2"*) echo "  FAIL — $1: expected NOT to contain '$2', got: $3"; fail=$((fail+1)) ;;
    *)      echo "  ok   — $1"; pass=$((pass+1)) ;;
  esac
}

# expect_eq <name> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; pass=$((pass+1))
  else echo "  FAIL — $1: expected '$2' got '$3'"; fail=$((fail+1)); fi
}

echo "Testing dispatch-agent.sh ($SCRIPT):"

FULL=$(mkcfg full '{"agents":{"lestrade":{"model":"haiku","effort":"low"},"holmes":{"model":"sonnet","effort":"high","maxBudgetUsd":5},"watson":{"model":"opus","effort":"high","maxBudgetUsd":10,"fallback":"sonnet","reprieveBudgetMultiplier":3}}}')
EMPTY=$(mkcfg empty '{}')
BROKEN=$(mkcfg broken 'not json at all {{{')
MISSING="$WORK/does-not-exist.json"

echo "— argument validation"
expect_eq "unknown agent rejected"            "2" "$(rc "$FULL" mycroft 42)"
expect_eq "missing target rejected"           "2" "$(rc "$FULL" watson '')"
expect_eq "non-numeric target rejected"       "2" "$(rc "$FULL" watson abc)"
expect_eq "sweep target on watson rejected"   "2" "$(rc "$FULL" watson owner/repo)"
expect_eq "sweep target on holmes rejected"   "2" "$(rc "$FULL" holmes owner/repo)"
expect_eq "lestrade sweep accepted"           "0" "$(rc "$FULL" lestrade owner/repo)"
expect_eq "numeric item accepted"             "0" "$(rc "$FULL" watson 42)"

echo "— prompt and log shape"
out=$(run "$FULL" watson 369)
expect_has  "item prompt"        "Item ID: 369"        "$out"
expect_has  "item log name"      "watson-369-"         "$out"
expect_has  "item takes a lock"  "lock=$WORK/logs/watson-369.lock" "$out"

out=$(run "$FULL" lestrade mike-bronner/phpcs-rules)
expect_has  "sweep prompt"       "Repo sweep: mike-bronner/phpcs-rules" "$out"
expect_has  "sweep log slug"     "lestrade-sweep-mike-bronner-phpcs-rules-" "$out"
expect_has  "sweep takes no lock" "lock=none"          "$out"

echo "— pipeline carve-out"
# Every dispatch is headless, so every dispatch must carry the flag the commit
# guard reads. A lane that misses it is denied at its first commit, because the
# ask-rule prompt needs a human who is not there.
for agent in lestrade holmes watson; do
  expect_has "$agent dispatch is flagged as pipeline" "pipeline=1" "$(run "$FULL" "$agent" 7)"
done
expect_has "sweep dispatch is flagged as pipeline" "pipeline=1" \
  "$(run "$FULL" lestrade mike-bronner/phpcs-rules)"
# The script sets the flag, it does not pass through what it inherited. A stray
# WORKBENCH_DEV_TEAM_PIPELINE=0 in the caller's environment must not disarm the
# carve-out and strand the lane on an approval nobody can give.
out=$(DISPATCH_CONFIG="$FULL" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 \
  WORKBENCH_DEV_TEAM_PIPELINE=0 bash "$SCRIPT" watson 7 2>&1)
expect_has "an inherited 0 cannot disarm the carve-out" "pipeline=1" "$out"

echo "— denied tools"
# The 24 deny rules pipeline runs inherited from this repo's
# .claude/settings.local.json before they moved to an empty folder. Written out
# here on purpose, not read from the script: this is the pin that goes red when
# the script's list loses a name or gains one.
EXPECTED_DENIED="Workflow Artifact Monitor PushNotification RemoteTrigger SendMessage
DesignSync ReportFindings CronCreate CronDelete CronList ScheduleWakeup
TaskCreate TaskGet TaskList TaskOutput TaskStop TaskUpdate EnterWorktree
ExitWorktree ListMcpResourcesTool ReadMcpResourceTool ReadMcpResourceDirTool
NotebookEdit"
expected_denied=$(printf '%s\n' $EXPECTED_DENIED | sort)
expect_eq "the pin itself names 24 tools" "24" "$(printf '%s\n' "$expected_denied" | wc -l | tr -d ' ')"
# expect_denied <label> <comma-joined value passed to --disallowedTools>
expect_denied() {
  local got missing extra
  got=$(printf '%s' "$2" | tr ',' '\n' | sed '/^$/d' | sort)
  missing=$(comm -23 <(printf '%s\n' "$expected_denied") <(printf '%s\n' "$got") | tr '\n' ' ')
  extra=$(comm -13 <(printf '%s\n' "$expected_denied") <(printf '%s\n' "$got") | tr '\n' ' ')
  if [ -z "$missing$extra" ]; then echo "  ok   — $1"; pass=$((pass+1))
  else echo "  FAIL — $1: missing [${missing% }] extra [${extra% }]"; fail=$((fail+1)); fi
}
# dry_denied <dry-run output> -> the value after --disallowedTools, when an
# option follows it. A value followed by the prompt would mean the variadic flag
# could swallow the prompt, so that shape extracts nothing and fails.
dry_denied() { printf '%s\n' "$1" | sed -n 's/^claude -p .* --disallowedTools \([^ ]*\) --.*/\1/p'; }
for agent in lestrade holmes watson; do
  out=$(run "$FULL" "$agent" 7)
  expect_denied "$agent run is denied all 24 tools" "$(dry_denied "$out")"
  expect_eq "$agent run passes the flag once" "1" "$(printf '%s\n' "$out" | grep -o -- '--disallowedTools' | wc -l | tr -d ' ')"
done
out=$(run "$FULL" lestrade mike-bronner/phpcs-rules)
expect_denied "sweep run is denied all 24 tools" "$(dry_denied "$out")"
# A config silent on every knob leaves no config option after the lists, and the
# prompt must still come last.
out=$(run "$EMPTY" lestrade 7)
expect_denied "denied with no config knobs" "$(dry_denied "$out")"
expect_has "the prompt stays the last argument" "--verbose Item ID: 7" "$out"

echo "— allowed MCP servers"
# The pipeline's two MCP servers are allowed by rule, so the auto-mode classifier
# never judges a board write or a memory call. Written out here, not read from
# the script. The value must be followed by an option, or it could swallow the
# prompt.
dry_allowed() { printf '%s\n' "$1" | sed -n 's/^claude -p .* --allowedTools \([^ ]*\) --.*/\1/p'; }
for agent in lestrade holmes watson; do
  out=$(run "$FULL" "$agent" 7)
  expect_eq "$agent run allows exactly the two MCP servers" \
    'mcp__the-index__*,mcp__plugin_workbench-core_memory__*' "$(dry_allowed "$out")"
  expect_eq "$agent run passes the allow flag once" "1" "$(printf '%s\n' "$out" | grep -o -- '--allowedTools' | wc -l | tr -d ' ')"
done
out=$(run "$FULL" lestrade mike-bronner/phpcs-rules)
expect_eq "sweep run allows exactly the two MCP servers" \
  'mcp__the-index__*,mcp__plugin_workbench-core_memory__*' "$(dry_allowed "$out")"

echo "— permission mode"
# Auto mode, named on every run, with prompts answered by nobody, and never the
# bypass flag. stream-json is what the log renderer reads.
for agent in lestrade holmes watson; do
  out=$(run "$FULL" "$agent" 7)
  expect_lacks "$agent run does not bypass permissions" "--dangerously-skip-permissions" "$out"
  expect_lacks "$agent run names no bypass mode"         "bypassPermissions"              "$out"
  expect_has   "$agent run starts in auto mode"          " --permission-mode auto "       "$out"
  expect_has   "$agent run lets nobody answer a prompt"  " --permission-prompts none "    "$out"
  expect_has   "$agent run streams JSON for the log"     " --output-format stream-json --verbose " "$out"
done
out=$(run "$FULL" lestrade mike-bronner/phpcs-rules)
expect_has "sweep run starts in auto mode" " --permission-mode auto --permission-prompts none " "$out"

echo "— config resolution"
out=$(run "$FULL" lestrade 7)
expect_has  "model from config"  "--model haiku"       "$out"
expect_has  "effort from config" "--effort low"        "$out"
expect_lacks "no budget when unset" "--max-budget-usd" "$out"
expect_lacks "no fallback when unset" "--fallback-model" "$out"

out=$(run "$FULL" watson 7)
expect_has  "fallback passed"    "--fallback-model sonnet" "$out"
expect_has  "budget passed"      "--max-budget-usd 10"     "$out"
expect_has  "agent flag"         "--agent workbench-dev-team:watson-index " "$out"

echo "— each lane starts the mode agent its token picks"
# The run loads one mode's prompt, never the public agent's two. --agent resolves
# a type before any hooks module loads, so each must be an agents/*.md file.
for pair in watson:watson-index:7 holmes:holmes-index:7 lestrade:lestrade-item:7 \
            lestrade:lestrade-sweep:mike-bronner/phpcs-rules; do
  IFS=: read -r lane mode target <<< "$pair"
  out=$(run "$FULL" "$lane" "$target")
  expect_has   "$lane $target starts $mode" "--agent workbench-dev-team:$mode " "$out"
  expect_lacks "$lane $target never starts the public type" "--agent workbench-dev-team:$lane " "$out"
  if [ -f "$HERE/../agents/$mode.md" ]; then
    echo "  ok   — agents/$mode.md ships"; pass=$((pass+1))
  else
    echo "  FAIL — agents/$mode.md is missing, so --agent would not find $mode"; fail=$((fail+1))
  fi
done

echo "— defaults survive a bad config"
for label in empty broken missing; do
  case "$label" in
    empty)   c="$EMPTY" ;;
    broken)  c="$BROKEN" ;;
    missing) c="$MISSING" ;;
  esac
  # A config silent on model and effort must leave both flags off. An empty
  # `--model` would either fail the run or pin a value, and either way the
  # agent definition's own value would never apply.
  for agent in lestrade holmes watson; do
    out=$(run "$c" "$agent" 7)
    expect_lacks "$agent no model flag ($label)"  "--model"  "$out"
    expect_lacks "$agent no effort flag ($label)" "--effort" "$out"
  done
  out=$(run "$c" watson 7)
  expect_has  "watson budget default ($label)"  "--max-budget-usd 10.00" "$out"
  out=$(run "$c" lestrade 7)
  expect_lacks "lestrade no budget ($label)"    "--max-budget-usd"      "$out"
  # Holmes's default matches the shipped config's 10.00, so a lost config cannot
  # lift the cap off the one multi-agent lane.
  out=$(run "$c" holmes 7)
  expect_has  "holmes budget default ($label)"  "--max-budget-usd 10.00" "$out"
done

echo "— the shipped default config"
# Read out of setup.md's Step 6 heredoc rather than restated here, so this
# checks the config users actually get. Every agent runs on the exact model ID,
# `[1m]` variant included, at medium effort. The trailing space pins where the
# value ends, so a longer value cannot pass as a prefix match.
SHIPPED="$WORK/shipped.json"
awk '/^SHIPPED_CONFIG=\$\(cat <<.EOF.$/{f=1;next} f && /^EOF$/{exit} f' \
  "$HERE/../commands/setup.md" > "$SHIPPED"
if [ -s "$SHIPPED" ] && jq empty "$SHIPPED" 2>/dev/null; then
  for agent in lestrade holmes watson; do
    out=$(run "$SHIPPED" "$agent" 7)
    expect_has "shipped $agent model is the exact [1m] id" "--model claude-opus-5-5[1m] " "$out"
    expect_has "shipped $agent effort is medium"           "--effort medium "              "$out"
  done
else
  echo "  FAIL — could not extract the shipped config from commands/setup.md"
  fail=$((fail+1))
fi

echo "— model and effort are independent"
# One key set and the other absent, both ways round. A script that gated both
# flags on one key would pass the all-or-nothing cases above.
ONLY_MODEL=$(mkcfg only-model '{"agents":{"watson":{"model":"sonnet"}}}')
out=$(run "$ONLY_MODEL" watson 7)
expect_has   "model alone is passed"          "--model sonnet" "$out"
expect_lacks "absent effort stays off"        "--effort"       "$out"
ONLY_EFFORT=$(mkcfg only-effort '{"agents":{"watson":{"effort":"medium"}}}')
out=$(run "$ONLY_EFFORT" watson 7)
expect_has   "effort alone is passed"         "--effort medium" "$out"
expect_lacks "absent model stays off"         "--model"         "$out"
# An empty string is absent, not a value: it must not reach the command line.
BLANK=$(mkcfg blank '{"agents":{"watson":{"model":"","effort":""}}}')
out=$(run "$BLANK" watson 7)
expect_lacks "empty model string omitted"     "--model"  "$out"
expect_lacks "empty effort string omitted"    "--effort" "$out"

echo "— reprieve"
# The reprieve comes from the breaker's escalation marker, never from the
# caller's environment: an env-prefixed command misses the allow rule. A dry run
# reads the marker and leaves it in place.
mkdir -p "$WORK/logs"
for agent in watson holmes lestrade; do touch "$WORK/logs/$agent-8.escalated"; done
out=$(run "$FULL" watson 8)
expect_has  "watson budget tripled"  "--max-budget-usd 30.00" "$out"
out=$(run "$FULL" holmes 8)
expect_has  "holmes budget tripled"  "--max-budget-usd 15.00" "$out"
out=$(run "$FULL" lestrade 8)
expect_lacks "no budget stays absent under reprieve" "--max-budget-usd" "$out"
out=$(REPRIEVE=1 DISPATCH_CONFIG="$FULL" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 bash "$SCRIPT" watson 7 2>&1)
expect_has  "an env REPRIEVE=1 buys nothing without a marker" "--max-budget-usd 10 " "$out"

echo "— the run starts in a fresh, empty folder in a scratch root"
# A real spawn, with `claude` and `security` stubbed on PATH, so no agent starts
# and no Keychain is read. RUNROOT stands in for ~/Developer/scratchpad. The
# stub records where it started, leaves a file in its folder as a real run
# would, and then prints $STUB_STREAM, a stream-json fixture, when one is set.
# $STUB_HOLD holds it open until that file exists, and $STUB_RC is its exit code.
# The caller stands in for Dispatch in the plugin repo: its cwd is the repo,
# CLAUDE_PROJECT_DIR names it, and LOGDIR is relative, so the log must still
# land beside the caller.
STUB="$WORK/stub"; FAILSTUB="$WORK/failstub"; CALLER="$WORK/caller"; RUNS="$WORK/scratch/runs"
mkdir -p "$STUB" "$FAILSTUB" "$CALLER"
printf '#!/bin/sh\nexit 1\n' > "$STUB/security"
printf '#!/bin/sh\nexit 1\n' > "$FAILSTUB/mktemp"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$@" > "$STUB_OUT.args"' \
  '{ pwd -P; ls -A | wc -l | tr -d " "; echo "${CLAUDE_PROJECT_DIR-unset}"; echo "${WORKBENCH_DEV_TEAM_PIPELINE-unset}"; } > "$STUB_OUT.part"' \
  'mv "$STUB_OUT.part" "$STUB_OUT"' \
  ': > left-by-the-run' \
  'if [ -n "${STUB_HOLD:-}" ]; then while [ ! -e "$STUB_HOLD" ]; do sleep 0.1; done; fi' \
  'echo "stub ran"' \
  '[ -z "${STUB_STREAM:-}" ] || cat "$STUB_STREAM"' \
  'exit "${STUB_RC:-0}"' > "$STUB/claude"
chmod +x "$STUB/security" "$STUB/claude" "$FAILSTUB/mktemp"
# spawn <item> [extra PATH prefix] -> echoes the script's output. SPAWN_AGENT
# picks the lane, and RUNROOT the scratch root, when a case needs another.
spawn() {
  (cd "$CALLER" && env -u WORKBENCH_DEV_TEAM_PIPELINE PATH="${2:+$2:}$STUB:$PATH" STUB_OUT="$WORK/stub-$1" \
    CLAUDE_PROJECT_DIR="$CALLER" DISPATCH_CONFIG="$FULL" LOGDIR=logs RUNROOT="${RUNROOT_OVERRIDE:-$RUNS}" \
    bash "$SCRIPT" "${SPAWN_AGENT:-watson}" "$1" 2>&1)
}
wait_for() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done; }
wait_gone() { local i=0; while [ -e "$1" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done; }
logof() { ls "$CALLER/logs/$1-$2-"*.log 2>/dev/null | head -1; }
out=$(spawn 9); wait_for "$WORK/stub-9"
expect_has "the dispatch reports a spawn" "dispatched watson pid=" "$out"
started=$(sed -n 1p "$WORK/stub-9" 2>/dev/null)
real_runs=$(cd -P "$RUNS" 2>/dev/null && pwd -P)
case "$started" in "$real_runs"/dispatch-watson.??????) echo "  ok   — the run starts in a dispatch-watson.XXXXXX folder in the scratch root"; pass=$((pass+1)) ;;
  *) echo "  FAIL — the run started in '$started', not in a dispatch-watson.XXXXXX folder under $real_runs"; fail=$((fail+1)) ;; esac
expect_lacks "the run does not start in the caller's cwd" "$CALLER" "$started"
expect_eq "the run's folder is empty"       "0"     "$(sed -n 2p "$WORK/stub-9" 2>/dev/null)"
expect_eq "CLAUDE_PROJECT_DIR is not inherited" "unset" "$(sed -n 3p "$WORK/stub-9" 2>/dev/null)"
expect_eq "the pipeline flag reaches the run" "1"   "$(sed -n 4p "$WORK/stub-9" 2>/dev/null)"
wait_gone "$started"
expect_eq "the run's folder is deleted when the run ends" "absent" "$([ -e "$started" ] && echo present || echo absent)"
log=$(logof watson 9)
expect_has "a relative LOGDIR still gets the run's output" "stub ran" "$(cat "$log" 2>/dev/null)"
expect_has "the lock holds the spawned PID" "pid=$(cat "$CALLER/logs/watson-9.lock" 2>/dev/null) " "$out"
# What the spawned claude actually received, one argument per line: each list is
# one argument, an option follows it, and the prompt is still the last argument.
spawned_denied=$(awk 'p{print; exit} $0=="--disallowedTools"{p=1}' "$WORK/stub-9.args" 2>/dev/null)
expect_denied "the spawned run is denied all 24 tools" "$spawned_denied"
expect_has "...and an option follows the list" "--" \
  "$(awk 'p==2{print; exit} p{p++} $0=="--disallowedTools"{p=1}' "$WORK/stub-9.args" 2>/dev/null | cut -c1-2)"
expect_eq "the spawned run allows the two MCP servers" 'mcp__the-index__*,mcp__plugin_workbench-core_memory__*' \
  "$(awk 'p{print; exit} $0=="--allowedTools"{p=1}' "$WORK/stub-9.args" 2>/dev/null)"
expect_eq "the spawned run is in auto mode" "auto" \
  "$(awk 'p{print; exit} $0=="--permission-mode"{p=1}' "$WORK/stub-9.args" 2>/dev/null)"
expect_eq "...with nobody to answer a prompt" "none" \
  "$(awk 'p{print; exit} $0=="--permission-prompts"{p=1}' "$WORK/stub-9.args" 2>/dev/null)"
expect_eq "...and without the bypass flag" "0" \
  "$(grep -c -- '--dangerously-skip-permissions' "$WORK/stub-9.args" 2>/dev/null)"
expect_eq "...and the prompt is the last argument" "Item ID: 9" "$(tail -1 "$WORK/stub-9.args" 2>/dev/null)"
spawn 10 >/dev/null; wait_for "$WORK/stub-10"
second=$(sed -n 1p "$WORK/stub-10" 2>/dev/null)
if [ -n "$second" ] && [ "$second" != "$started" ]; then echo "  ok   — each run gets its own folder"; pass=$((pass+1))
else echo "  FAIL — two runs shared '$second'"; fail=$((fail+1)); fi
wait_gone "$second"

echo "— the run folder lives exactly as long as the run"
# While the agent runs, its folder exists and the lock's PID is alive. When it
# exits, the folder goes and the PID dies with it, so the breaker frees the item.
HOLD="$WORK/hold-12"
out=$(STUB_HOLD="$HOLD" spawn 12); wait_for "$WORK/stub-12"
run12=$(sed -n 1p "$WORK/stub-12" 2>/dev/null); pid12=$(cat "$CALLER/logs/watson-12.lock" 2>/dev/null)
expect_eq "the folder exists while the run is alive" "present" "$([ -n "$run12" ] && [ -d "$run12" ] && echo present || echo absent)"
expect_eq "the lock's PID is alive while the run is" "alive" "$(kill -0 "$pid12" 2>/dev/null && echo alive || echo dead)"
: > "$HOLD"; wait_gone "$run12"
expect_eq "...and the folder goes when the run ends" "absent" "$([ -e "$run12" ] && echo present || echo absent)"
i=0; while kill -0 "$pid12" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
expect_eq "...and the lock's PID dies with it" "dead" "$(kill -0 "$pid12" 2>/dev/null && echo alive || echo dead)"
# A failed run cleans up too.
STUB_RC=3 spawn 13 >/dev/null; wait_for "$WORK/stub-13"
run13=$(sed -n 1p "$WORK/stub-13" 2>/dev/null); wait_gone "$run13"
expect_eq "a run that exits non-zero still loses its folder" "absent" "$([ -n "$run13" ] && [ -e "$run13" ] && echo present || echo absent)"
# A run whose wrapper is sent TERM cleans up once its agent has exited.
HOLD="$WORK/hold-14"
STUB_HOLD="$HOLD" spawn 14 >/dev/null; wait_for "$WORK/stub-14"
run14=$(sed -n 1p "$WORK/stub-14" 2>/dev/null)
kill -TERM "$(cat "$CALLER/logs/watson-14.lock" 2>/dev/null)" 2>/dev/null
sleep 0.3
expect_eq "a TERM does not pull the folder from under a live agent" "present" "$([ -n "$run14" ] && [ -d "$run14" ] && echo present || echo absent)"
: > "$HOLD"; wait_gone "$run14"
expect_eq "a run whose wrapper got TERM still loses its folder" "absent" "$([ -n "$run14" ] && [ -e "$run14" ] && echo present || echo absent)"
# A HUP, as when Dispatch's own shell goes away, neither ends the run nor
# strands its folder.
HOLD="$WORK/hold-19"
STUB_HOLD="$HOLD" spawn 19 >/dev/null; wait_for "$WORK/stub-19"
run19=$(sed -n 1p "$WORK/stub-19" 2>/dev/null); pid19=$(cat "$CALLER/logs/watson-19.lock" 2>/dev/null)
kill -HUP "$pid19" 2>/dev/null; sleep 0.3
expect_eq "a HUP does not end the run" "alive" "$(kill -0 "$pid19" 2>/dev/null && echo alive || echo dead)"
: > "$HOLD"; wait_gone "$run19"
expect_eq "...and the folder still goes when it ends" "absent" "$([ -n "$run19" ] && [ -e "$run19" ] && echo present || echo absent)"

echo "— the run folder is refused when it is not clean"
# No folder, no run: a fallback to the caller's cwd is the case this prevents.
out=$(spawn 11 "$FAILSTUB"); code=$?
expect_eq  "a failed mktemp exits non-zero" "1" "$code"
expect_has "...and says nothing was dispatched" "nothing dispatched" "$out"
sleep 0.5
expect_eq  "...and spawns nothing" "absent" "$([ -e "$WORK/stub-11" ] && echo present || echo absent)"
leftover=absent; for f in "$CALLER/logs/"*-11[.-]*; do [ -e "$f" ] && leftover=present; done
expect_eq  "...and writes no log or lock" "absent" "$leftover"
# A scratch root that is not there yet is made.
out=$(RUNROOT_OVERRIDE="$WORK/scratch/new/deeper" spawn 15); wait_for "$WORK/stub-15"
case "$(sed -n 1p "$WORK/stub-15" 2>/dev/null)" in */new/deeper/dispatch-watson.??????) echo "  ok   — a missing scratch root is made"; pass=$((pass+1)) ;;
  *) echo "  FAIL — a missing scratch root was not made: $out"; fail=$((fail+1)) ;; esac
wait_gone "$(sed -n 1p "$WORK/stub-15" 2>/dev/null)"
# A folder inside a git repository would make that repository the run's project.
mkdir -p "$WORK/repo/runs"; git -C "$WORK/repo" init -q
out=$(RUNROOT_OVERRIDE="$WORK/repo/runs" spawn 16); code=$?
expect_eq  "a run folder inside a git repository exits non-zero" "1" "$code"
expect_has "...and says why" "inside a git repository" "$out"
sleep 0.5
expect_eq  "...and spawns nothing" "absent" "$([ -e "$WORK/stub-16" ] && echo present || echo absent)"
expect_eq  "...and leaves no folder behind" "" "$(ls -A "$WORK/repo/runs")"
leftover=absent; for f in "$CALLER/logs/"*-16[.-]*; do [ -e "$f" ] && leftover=present; done
expect_eq  "...and writes no log or lock" "absent" "$leftover"

echo "— the log names every permission refusal"
# A stream-json fixture shaped like the real one (Claude Code 2.1.286): a refusal
# the permission_denied event reports, a hook's refusal in a sub-agent, which
# only its tool result shows, and the result's own list, which repeats the first
# and adds one more.
STREAM="$WORK/stream.jsonl"
cat > "$STREAM" <<'EOF'
{"type":"system","subtype":"init","session_id":"s"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git -C /x push origin main"}}]},"parent_tool_use_id":null}
{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"t1","message":"Permission to use Bash with command git -C /x push origin main has been denied."}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Permission to use Bash with command git -C /x push origin main has been denied."}]},"parent_tool_use_id":null}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"gh pr merge 5"}}]},"parent_tool_use_id":"a1"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"PreToolUse:Bash hook error: Blocked: the pipeline does not merge.\nReport it."}]},"parent_tool_use_id":"a1"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","is_error":true,"content":"Exit code 1\ntests failed"}]},"parent_tool_use_id":null}
{"type":"result","subtype":"success","is_error":false,"result":"Moved the item to In Review.\nDone.","permission_denials":[{"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git -C /x push origin main"}},{"tool_name":"Write","tool_use_id":"t3","tool_input":{"file_path":"/etc/hosts","content":"FILE-BODY-MUST-NOT-LEAK"}}]}
EOF
STUB_STREAM="$STREAM" spawn 17 >/dev/null; wait_for "$WORK/stub-17"; wait_gone "$(sed -n 1p "$WORK/stub-17" 2>/dev/null)"
log=$(cat "$(logof watson 17)" 2>/dev/null)
expect_has "a rule's refusal is named, with the call and the reason" \
  'Permission denied: Bash {"command":"git -C /x push origin main"} -- Permission to use Bash' "$log"
expect_eq  "...once, though the result lists it again" "1" "$(printf '%s\n' "$log" | grep -c 'git -C /x push origin main"} --')"
expect_has "a hook's refusal in a sub-agent is named, on one line" \
  'Permission denied: Bash in a sub-agent {"command":"gh pr merge 5"} -- PreToolUse:Bash hook error: Blocked: the pipeline does not merge. Report it.' "$log"
expect_has "a refusal only the result lists is named" 'Permission denied: Write {"file_path":"/etc/hosts"} -- refused' "$log"
expect_lacks "...without the content it would have written" "FILE-BODY-MUST-NOT-LEAK" "$log"
expect_lacks "a failed command is not a refusal" "tests failed" "$log"
expect_eq  "every refusal line is findable by one grep" "3" "$(printf '%s\n' "$log" | grep -c '^Permission denied: ')"
expect_eq  "the log still ends with the run's final result" "Moved the item to In Review.
Done." "$(printf '%s\n' "$log" | tail -2)"
expect_lacks "the stream's JSON does not reach the log" '"type":' "$log"
expect_has "a line that is not JSON passes through" "stub ran" "$log"
expect_lacks "a run with a result is not called empty" "No messages returned" "$log"
expect_has "a run with no result says so, as text mode did" "Error: No messages returned from query" "$(cat "$(logof watson 9)" 2>/dev/null)"
# The breaker still reads a rendered budget kill, after a refusal, as one.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"k1","name":"Bash","input":{"command":"grep Exceeded USD budget x"}}]}}' \
  '{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"k1","message":"denied"}' \
  '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"permission_denials":[]}' > "$WORK/kill.jsonl"
STUB_STREAM="$WORK/kill.jsonl" SPAWN_AGENT=holmes spawn 18 >/dev/null; wait_for "$WORK/stub-18"; wait_gone "$(sed -n 1p "$WORK/stub-18" 2>/dev/null)"
expect_eq "a budget kill renders as the text-mode line" "Error: Exceeded USD budget" "$(tail -1 "$(logof holmes 18)" 2>/dev/null)"
verdict=$(cd "$CALLER" && LOGDIR=logs bash "$SCRIPT" --check holmes 18)
expect_has "...which the breaker escalates" "ESCALATE" "$verdict"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
