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
# A config silent on every knob leaves no option between the list and
# --dangerously-skip-permissions, and the prompt must still come last.
out=$(run "$EMPTY" lestrade 7)
expect_denied "denied with no config knobs" "$(dry_denied "$out")"
expect_has "the prompt stays the last argument" "--dangerously-skip-permissions Item ID: 7" "$out"

echo "— config resolution"
out=$(run "$FULL" lestrade 7)
expect_has  "model from config"  "--model haiku"       "$out"
expect_has  "effort from config" "--effort low"        "$out"
expect_lacks "no budget when unset" "--max-budget-usd" "$out"
expect_lacks "no fallback when unset" "--fallback-model" "$out"

out=$(run "$FULL" watson 7)
expect_has  "fallback passed"    "--fallback-model sonnet" "$out"
expect_has  "budget passed"      "--max-budget-usd 10"     "$out"
expect_has  "agent flag"         "--agent workbench-dev-team:watson" "$out"
expect_has  "skip-permissions"   "--dangerously-skip-permissions"    "$out"

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
awk '/cat > "\$CONFIG" <<.EOF.$/{f=1;next} f && /^EOF$/{exit} f' \
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

echo "— the run starts in a fresh, empty folder"
# A real spawn, with `claude` and `security` stubbed on PATH, so no agent starts
# and no Keychain is read. The stub records where it started. `mktemp` is stubbed
# too, because macOS mktemp -d uses DARWIN_USER_TEMP_DIR before TMPDIR: the stub
# accepts exactly `-d` and makes the folder under this suite's work directory.
# The caller stands in for Dispatch in the plugin repo: its cwd is the repo,
# CLAUDE_PROJECT_DIR names it, and LOGDIR is relative, so the log must still
# land beside the caller.
STUB="$WORK/stub"; FAILSTUB="$WORK/failstub"; CALLER="$WORK/caller"; RUNTMP="$WORK/tmp"
mkdir -p "$STUB" "$FAILSTUB" "$CALLER" "$RUNTMP"
printf '#!/bin/sh\nexit 1\n' > "$STUB/security"
printf '#!/bin/sh\nexit 1\n' > "$FAILSTUB/mktemp"
printf '#!/bin/sh\n[ "$*" = -d ] || exit 2\nexec "%s" -d "%s/run.XXXXXX"\n' "$(command -v mktemp)" "$RUNTMP" > "$STUB/mktemp"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$@" > "$STUB_OUT.args"' \
  '{ pwd -P; ls -A | wc -l | tr -d " "; echo "${CLAUDE_PROJECT_DIR-unset}"; echo "${WORKBENCH_DEV_TEAM_PIPELINE-unset}"; echo $$; } > "$STUB_OUT.part"' \
  'mv "$STUB_OUT.part" "$STUB_OUT"; echo "stub ran"' > "$STUB/claude"
chmod +x "$STUB/security" "$STUB/mktemp" "$STUB/claude" "$FAILSTUB/mktemp"
# spawn <item> [extra PATH prefix] -> echoes the script's output
spawn() {
  (cd "$CALLER" && env -u WORKBENCH_DEV_TEAM_PIPELINE PATH="${2:+$2:}$STUB:$PATH" STUB_OUT="$WORK/stub-$1" \
    CLAUDE_PROJECT_DIR="$CALLER" DISPATCH_CONFIG="$FULL" LOGDIR=logs bash "$SCRIPT" watson "$1" 2>&1)
}
wait_for() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done; }
out=$(spawn 9); wait_for "$WORK/stub-9"
expect_has "the dispatch reports a spawn" "dispatched watson pid=" "$out"
started=$(sed -n 1p "$WORK/stub-9" 2>/dev/null)
real_tmp=$(cd -P "$RUNTMP" && pwd -P)
case "$started" in "$real_tmp"/run.?*) echo "  ok   — the run starts in the folder mktemp -d made"; pass=$((pass+1)) ;;
  *) echo "  FAIL — the run started in '$started', not in a mktemp -d folder under $real_tmp"; fail=$((fail+1)) ;; esac
expect_lacks "the run does not start in the caller's cwd" "$CALLER" "$started"
expect_eq "the run's folder is empty"       "0"     "$(sed -n 2p "$WORK/stub-9" 2>/dev/null)"
expect_eq "CLAUDE_PROJECT_DIR is not inherited" "unset" "$(sed -n 3p "$WORK/stub-9" 2>/dev/null)"
expect_eq "the pipeline flag reaches the run" "1"   "$(sed -n 4p "$WORK/stub-9" 2>/dev/null)"
log=$(ls "$CALLER/logs/watson-9-"*.log 2>/dev/null | head -1)
expect_has "a relative LOGDIR still gets the run's output" "stub ran" "$(cat "$log" 2>/dev/null)"
expect_has "the lock holds the spawned PID" "pid=$(cat "$CALLER/logs/watson-9.lock" 2>/dev/null) " "$out"
# The stub records its own $$. Without the exec, the lock would hold the PID of
# the subshell that forked it, and the two would differ.
expect_eq "the lock holds the agent's own PID" "$(sed -n 5p "$WORK/stub-9" 2>/dev/null)" "$(cat "$CALLER/logs/watson-9.lock" 2>/dev/null)"
# What the spawned claude actually received, one argument per line: the list is
# one argument, an option follows it, and the prompt is still the last argument.
spawned_denied=$(awk 'p{print; exit} $0=="--disallowedTools"{p=1}' "$WORK/stub-9.args" 2>/dev/null)
expect_denied "the spawned run is denied all 24 tools" "$spawned_denied"
expect_has "...and an option follows the list" "--" \
  "$(awk 'p==2{print; exit} p{p++} $0=="--disallowedTools"{p=1}' "$WORK/stub-9.args" 2>/dev/null | cut -c1-2)"
expect_eq "...and the prompt is the last argument" "Item ID: 9" "$(tail -1 "$WORK/stub-9.args" 2>/dev/null)"
spawn 10 >/dev/null; wait_for "$WORK/stub-10"
second=$(sed -n 1p "$WORK/stub-10" 2>/dev/null)
if [ -n "$second" ] && [ "$second" != "$started" ]; then echo "  ok   — each run gets its own folder"; pass=$((pass+1))
else echo "  FAIL — two runs shared '$second'"; fail=$((fail+1)); fi
# No folder, no run: a fallback to the caller's cwd is the case this prevents.
out=$(spawn 11 "$FAILSTUB"); code=$?
expect_eq  "a failed mktemp exits non-zero" "1" "$code"
expect_has "...and says nothing was dispatched" "nothing dispatched" "$out"
sleep 0.5
expect_eq  "...and spawns nothing" "absent" "$([ -e "$WORK/stub-11" ] && echo present || echo absent)"
leftover=absent; for f in "$CALLER/logs/"*-11[.-]*; do [ -e "$f" ] && leftover=present; done
expect_eq  "...and writes no log or lock" "absent" "$leftover"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
