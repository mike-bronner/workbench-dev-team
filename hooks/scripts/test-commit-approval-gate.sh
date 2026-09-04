#!/bin/bash
# Tests for commit-approval-gate.sh. Run directly: ./test-commit-approval-gate.sh
# Each case feeds a synthetic PreToolUse payload and asserts whether the gate
# asks (outputs permissionDecision "ask") or stays silent (no opinion).

set -u
GATE="$(cd "$(dirname "$0")" && pwd)/commit-approval-gate.sh"
PASS=0
FAIL=0

run_case() {
  local desc="$1" cmd="$2" expect="$3"  # expect: ask | silent
  local payload output verdict
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  output=$(printf '%s' "$payload" | env -u WORKBENCH_DEV_TEAM_PIPELINE "$GATE")
  if printf '%s' "$output" | grep -q '"permissionDecision": *"ask"'; then
    verdict=ask
  else
    verdict=silent
  fi
  if [ "$verdict" = "$expect" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $desc — expected $expect, got $verdict"
  fi
}

echo "Commit detection:"
run_case "plain git commit"                       'git commit -m "feat: x"'                        ask
run_case "git commit with staged-all flag"        'git commit -am "fix: y"'                        ask
run_case "git -C path commit"                     'git -C /tmp/repo commit -m "z"'                 ask
run_case "git -c key=val commit"                  'git -c user.name=x commit -m "z"'               ask
run_case "compound: cd && git commit"             'cd /tmp/repo && git add . && git commit -m "z"' ask
run_case "compound: commit after semicolon"       'git add .; git commit --no-verify -m "z"'       ask
run_case "env prefix before git"                  'GIT_AUTHOR_NAME=x git commit -m "z"'            ask
run_case "command wrapper"                        'command git commit -m "z"'                      ask
run_case "empty commit (watson scaffold)"         'git commit --allow-empty -m "chore: start"'     ask

echo "Non-commits stay silent:"
run_case "git status"                             'git status'                                     silent
run_case "git log mentioning commit"              'git log --oneline | grep commit'                silent
run_case "git push"                               'git push origin main'                           silent
run_case "git add only"                           'git add -A'                                     silent
run_case "unrelated command"                      'ls -la'                                         silent
run_case "echo containing the words"              'echo "git commit is gated"'                     silent
run_case "git diff"                               'git diff --staged'                              silent

echo "Carve-out — the dispatcher's env flag, and nothing else:"
payload=$(python3 -c 'import json; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"z\""}}))')

# expect_flag <description> <value|UNSET> <ask|silent>
expect_flag() {
  local desc="$1" value="$2" expect="$3" out verdict
  if [ "$value" = UNSET ]; then
    out=$(printf '%s' "$payload" | env -u WORKBENCH_DEV_TEAM_PIPELINE "$GATE")
  else
    out=$(printf '%s' "$payload" | WORKBENCH_DEV_TEAM_PIPELINE="$value" "$GATE")
  fi
  if printf '%s' "$out" | grep -q '"permissionDecision": *"ask"'; then verdict=ask; else verdict=silent; fi
  if [ "$verdict" = "$expect" ]; then
    PASS=$((PASS + 1)); echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $desc — expected $expect, got $verdict"
  fi
}

expect_flag "WORKBENCH_DEV_TEAM_PIPELINE=1 bypasses the gate" 1      silent
expect_flag "an absent flag gates the commit"                 UNSET  ask
# Everything that is not the literal 1 gates. The carve-out fails closed, so a
# typo, a leftover value, or a shell that exports an empty string all keep the
# prompt rather than silently waiving approval.
expect_flag "an explicit 0 gates the commit"                  0      ask
expect_flag "an empty flag gates the commit"                  ""     ask
expect_flag "'true' does not bypass"                          true   ask
expect_flag "'yes' does not bypass"                           yes    ask
expect_flag "'01' does not bypass"                            01     ask

# Regression guard for the leak this carve-out replaced. The gate used to go
# silent whenever /tmp/watson.lock held a live PID — a host-wide answer to a
# per-process question, which waived approval for every concurrent interactive
# session while a scheduled run held it. Nothing on disk may bypass the gate now.
# Any pre-existing lock is saved and put back, so a live pipeline run loses nothing.
REAL_LOCK=/tmp/watson.lock
SAVED_LOCK=""
restore_lock() {
  if [ -n "$SAVED_LOCK" ]; then
    cat "$SAVED_LOCK" > "$REAL_LOCK"
    rm -f "$SAVED_LOCK"
    SAVED_LOCK=""
  else
    rm -f "$REAL_LOCK"
  fi
}
if [ -e "$REAL_LOCK" ]; then
  SAVED_LOCK="$(mktemp "${TMPDIR:-/tmp}/watson-lock-saved.XXXXXX")"
  cat "$REAL_LOCK" > "$SAVED_LOCK"
fi
# The trap covers an interrupt between the write and the restore below.
trap restore_lock EXIT
echo "$$" > "$REAL_LOCK"  # a live PID: the exact condition that used to bypass
expect_flag "a live /tmp/watson.lock no longer bypasses"      UNSET  ask
restore_lock
trap - EXIT

echo "hooks.json wiring survives a space in the plugin path:"
# The harness expands ${CLAUDE_PLUGIN_ROOT} inside the hooks.json `command`
# string and runs it through a shell. An unquoted expansion word-splits on a
# plugin path that contains a space — the norm in Cowork / local-agent-mode
# sessions, where the root lives under ".../Application Support/Claude/..." —
# so the script is never found and the gate silently fails OPEN. Reproduce the
# exact harness path: pull the command template from hooks.json, expand it with
# a spaced CLAUDE_PLUGIN_ROOT, and run it via `sh -c` the way the harness does.
HOOKS_JSON="$(cd "$(dirname "$0")/../.." && pwd)/hooks/hooks.json"
CMD_TEMPLATE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])' "$HOOKS_JSON")"
SPACED_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/plugin root XXXXXX")"  # deliberate space
mkdir -p "$SPACED_ROOT/hooks/scripts"
cp "$GATE" "$SPACED_ROOT/hooks/scripts/commit-approval-gate.sh"
payload=$(python3 -c 'import json; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"z\""}}))')
output=$(printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$SPACED_ROOT" env -u WORKBENCH_DEV_TEAM_PIPELINE sh -c "$CMD_TEMPLATE")
if printf '%s' "$output" | grep -q '"permissionDecision": *"ask"'; then
  PASS=$((PASS + 1)); echo "  ✅ gate fires when the plugin path contains a space"
else
  FAIL=$((FAIL + 1)); echo "  ❌ gate silently failed open on a spaced plugin path"
fi
rm -rf "$SPACED_ROOT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
