#!/bin/bash
# Tests for commit-approval-gate.sh. Run directly: ./test-commit-approval-gate.sh
# Each case feeds a synthetic PreToolUse payload and asserts whether the gate
# asks (outputs permissionDecision "ask") or stays silent (no opinion).

set -u
GATE="$(cd "$(dirname "$0")" && pwd)/commit-approval-gate.sh"
PASS=0
FAIL=0

# Isolate the Watson-lock carve-out from the real /tmp/watson.lock. Point the
# gate at a temp path this test owns, so a concurrent pipeline run holding a
# live /tmp/watson.lock can neither leak into the "expected ask" cases nor get
# clobbered by this test. mktemp -u yields an unused name (absent → no carve-out
# until we deliberately create it below).
WORKBENCH_DEV_TEAM_WATSON_LOCK="$(mktemp -u "${TMPDIR:-/tmp}/watson-lock-test.XXXXXX")"
export WORKBENCH_DEV_TEAM_WATSON_LOCK
DECOY_LOCK=""
cleanup() { rm -f "$WORKBENCH_DEV_TEAM_WATSON_LOCK" "$DECOY_LOCK" 2>/dev/null; }
trap cleanup EXIT

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

echo "Carve-outs:"
payload=$(python3 -c 'import json; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"z\""}}))')
output=$(printf '%s' "$payload" | WORKBENCH_DEV_TEAM_PIPELINE=1 "$GATE")
if [ -z "$output" ]; then
  PASS=$((PASS + 1)); echo "  ✅ WORKBENCH_DEV_TEAM_PIPELINE=1 bypasses the gate"
else
  FAIL=$((FAIL + 1)); echo "  ❌ WORKBENCH_DEV_TEAM_PIPELINE=1 should bypass the gate"
fi

echo "$$" > "$WORKBENCH_DEV_TEAM_WATSON_LOCK"  # this test's live PID simulates a running Watson
output=$(printf '%s' "$payload" | env -u WORKBENCH_DEV_TEAM_PIPELINE "$GATE")
if [ -z "$output" ]; then
  PASS=$((PASS + 1)); echo "  ✅ live watson.lock bypasses the gate"
else
  FAIL=$((FAIL + 1)); echo "  ❌ live watson.lock should bypass the gate"
fi
echo "999999" > "$WORKBENCH_DEV_TEAM_WATSON_LOCK"  # dead PID -> stale lock must NOT bypass
output=$(printf '%s' "$payload" | env -u WORKBENCH_DEV_TEAM_PIPELINE "$GATE")
if printf '%s' "$output" | grep -q '"permissionDecision": *"ask"'; then
  PASS=$((PASS + 1)); echo "  ✅ stale watson.lock does NOT bypass the gate"
else
  FAIL=$((FAIL + 1)); echo "  ❌ stale watson.lock must not bypass the gate"
fi
rm -f "$WORKBENCH_DEV_TEAM_WATSON_LOCK"  # configured lock absent again

# Isolation guarantee: only the configured lock path is consulted. A live lock
# at a DIFFERENT path (standing in for a real /tmp/watson.lock held by a
# concurrent pipeline run) must NOT bypass the gate — proving the override is
# honored and that this test no longer depends on, or clobbers, the real lock.
DECOY_LOCK="$(mktemp "${TMPDIR:-/tmp}/watson-decoy.XXXXXX")"
echo "$$" > "$DECOY_LOCK"  # live PID at a path the gate is NOT pointed at
output=$(printf '%s' "$payload" | env -u WORKBENCH_DEV_TEAM_PIPELINE "$GATE")
if printf '%s' "$output" | grep -q '"permissionDecision": *"ask"'; then
  PASS=$((PASS + 1)); echo "  ✅ live lock at another path does NOT bypass (isolation holds)"
else
  FAIL=$((FAIL + 1)); echo "  ❌ a foreign live lock leaked into the gate"
fi
rm -f "$DECOY_LOCK"; DECOY_LOCK=""

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
