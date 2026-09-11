#!/bin/bash
# Tests for commit-approval-gate.sh. Run directly: ./test-commit-approval-gate.sh
# Each case feeds a synthetic PreToolUse payload and asserts the gate's verdict:
# deny (the commit is refused), or silent (no opinion, normal flow applies).
#
# "ask" is a verdict on purpose here too — it must never come back. A hook's
# "ask" is classifier-approvable, so the auto-mode classifier answers it and no
# human is prompted. That is the bug this gate was rebuilt to fix, and a
# regression to it would look exactly like the four years of green this suite
# used to report.

set -u
GATE="$(cd "$(dirname "$0")" && pwd)/commit-approval-gate.sh"
PASS=0
FAIL=0

# Everything this suite writes lives here, and the trap takes it away on any
# exit path. Every gate invocation below also runs with TMPDIR and HOME pointed
# inside, so no case can read or write the developer's real environment — the
# verdict must come from the gate, never from what happens to be on this host.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/commit-approval-gate.XXXXXX")"
trap 'chmod 755 "$SANDBOX/home/.claude-workbench/commit-approvals" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"

# Where the gate keeps approval records once HOME points into the sandbox. The
# suite never sets WORKBENCH_COMMIT_APPROVAL_DIR, so the default path is the one
# under test.
STATE="$SANDBOX/home/.claude-workbench/commit-approvals"

# Run the gate with the sandbox in place of the host's temp dir and home.
gate() { env -u WORKBENCH_COMMIT_APPROVAL_DIR "$@" TMPDIR="$SANDBOX" HOME="$SANDBOX/home" "$GATE"; }

# payload <command> [session-id] [agent-id]
payload() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":sys.argv[2],"agent_id":sys.argv[3],"tool_input":{"command":sys.argv[1]}}))' \
    "$1" "${2-session-A}" "${3-}"
}

# Build the payload first, then feed it with printf. Piping the generator
# straight into the gate breaks its stdout when the carve-out exits before
# reading stdin, and python reports that on stderr as a BrokenPipeError.
ask_gate() { # ask_gate <command> <session|""|EMPTY> <agent> [env-overrides...]
  local cmd="$1" session="${2:-session-A}" agent="$3" body
  [ "$session" = EMPTY ] && session=""   # a payload that carries no session id
  shift 3
  body=$(payload "$cmd" "$session" "$agent")
  printf '%s' "$body" | gate "$@"
}

verdict_of() {
  if printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; then
    echo deny
  elif printf '%s' "$1" | grep -q '"permissionDecision": *"ask"'; then
    echo ask
  else
    echo silent
  fi
}

reason_of() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null
}

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

check() { # check <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected $3, got $2"; fi
}

run_case() { # run_case <desc> <command> <deny|silent>
  local out
  out=$(ask_gate "$2" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  check "$1" "$(verdict_of "$out")" "$3"
}

# request_id <command> [session] [agent] — the id the gate prints when it
# refuses. Read out of the denial rather than recomputed here: a test that
# rebuilds the gate's own hash asserts its copy of the formula, not the gate.
request_id() {
  local out
  out=$(ask_gate "$1" "${2-session-A}" "${3-}" -u WORKBENCH_DEV_TEAM_PIPELINE)
  reason_of "$out" | grep -oE '[0-9a-f]{16}' | head -1
}

# approve <request-id> [age-seconds] — flip a pending record to approved, as
# bin/approve-commit.sh does. Ages it by the given number of seconds, so an expiry
# case needs no clock games.
approve() {
  python3 - "$STATE/$1" "${2-0}" <<'PY'
import json, sys, time
path, age = sys.argv[1], float(sys.argv[2])
with open(path) as handle:
    record = json.load(handle)
record["status"] = "approved"
record["approved_at"] = time.time() - age
with open(path, "w") as handle:
    json.dump(record, handle)
PY
}

echo "Commit detection — every commit is denied until it is approved:"
run_case "plain git commit"                       'git commit -m "feat: x"'                        deny
run_case "git commit with staged-all flag"        'git commit -am "fix: y"'                        deny
run_case "git -C path commit"                     'git -C /tmp/repo commit -m "z"'                 deny
run_case "git -c key=val commit"                  'git -c user.name=x commit -m "z"'               deny
run_case "compound: cd && git commit"             'cd /tmp/repo && git add . && git commit -m "z"' deny
run_case "compound: commit after semicolon"       'git add .; git commit --no-verify -m "z"'       deny
run_case "env prefix before git"                  'GIT_AUTHOR_NAME=x git commit -m "z"'            deny
run_case "command wrapper"                        'command git commit -m "z"'                      deny
run_case "empty commit (watson scaffold)"         'git commit --allow-empty -m "chore: start"'     deny

echo "Non-commits stay silent:"
run_case "git status"                             'git status'                                     silent
run_case "git log mentioning commit"              'git log --oneline | grep commit'                silent
run_case "git push"                               'git push origin main'                           silent
run_case "git add only"                           'git add -A'                                     silent
run_case "unrelated command"                      'ls -la'                                         silent
run_case "echo containing the words"              'echo "git commit is gated"'                     silent
run_case "git diff"                               'git diff --staged'                              silent

echo "The denial tells the agent how to get an approval:"
DENY_OUT=$(ask_gate 'git commit -m "feat: x"' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
DENY_REASON=$(reason_of "$DENY_OUT")
case "$DENY_REASON" in
  *'bash "$HOME/.claude-workbench/bin/approve-commit.sh"'*) ok "the denial names the approve-commit.sh command" ;;
  *) bad "the denial does not name the approve-commit.sh command" ;;
esac
if printf '%s' "$DENY_REASON" | grep -qE '[0-9a-f]{16}'; then
  ok "the denial carries a request id"
else
  bad "the denial carries no request id"
fi

echo "The approval lifecycle:"
CMD='git commit -m "feat: the approved one"'
ID=$(request_id "$CMD")

OUT=$(ask_gate "$CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a pending record is not an approval" "$(verdict_of "$OUT")" deny

approve "$ID"
OUT=$(ask_gate "$CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an approved record lets the commit through" "$(verdict_of "$OUT")" silent

OUT=$(ask_gate "$CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "one approval covers one commit, and no second" "$(verdict_of "$OUT")" deny

ID=$(request_id "$CMD")
approve "$ID" 901   # the TTL is 900s
OUT=$(ask_gate "$CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an expired approval does not let the commit through" "$(verdict_of "$OUT")" deny
case "$(reason_of "$OUT")" in
  *expired*) ok "the expiry denial says so" ;;
  *) bad "the expiry denial does not mention the expiry" ;;
esac
OUT=$(ask_gate "$CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an expired approval is destroyed, not re-read" "$(verdict_of "$OUT")" deny

echo "An approval covers ONE command, ONE agent, ONE session — nothing wider:"
ID=$(request_id "$CMD" "session-A" "")
approve "$ID"
OUT=$(ask_gate 'git commit -m "feat: a different commit"' "session-A" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "another command in the same session is still denied" "$(verdict_of "$OUT")" deny

OUT=$(ask_gate "$CMD" "session-B" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "the same command in another session is still denied" "$(verdict_of "$OUT")" deny

OUT=$(ask_gate "$CMD" "session-A" "agent-2" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "the same command from another agent is still denied" "$(verdict_of "$OUT")" deny

OUT=$(ask_gate "$CMD" "session-A" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "the agent that was approved still gets through" "$(verdict_of "$OUT")" silent

# Two agents in one session are the shape that once let four unapproved commits
# land. Each holds its own id, so one agent's approval is invisible to the other.
ID_ONE=$(request_id "$CMD" "session-C" "agent-1")
ID_TWO=$(request_id "$CMD" "session-C" "agent-2")
if [ -n "$ID_ONE" ] && [ "$ID_ONE" != "$ID_TWO" ]; then
  ok "two agents in one session get separate request ids"
else
  bad "two agents in one session share a request id"
fi

echo "Fail-closed paths:"
# Each of these asserts the REASON as well as the verdict. Both branches end in
# a denial that an unapproved commit would have earned anyway, so a check on the
# verdict alone passes whether or not the branch it names still exists.
OUT=$(ask_gate "$CMD" EMPTY "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a payload with no session id is denied" "$(verdict_of "$OUT")" deny
case "$(reason_of "$OUT")" in
  *"no session id"*) ok "...and says the session id is what it lacks" ;;
  *) bad "the no-session denial is the generic one — the session guard is gone" ;;
esac

# An approval that cannot be deleted cannot be spent, and an unspendable
# approval is a standing waiver for that command. Plant one, then make the
# directory read-only so the record survives the commit that used it.
CMD_STUCK='git commit -m "feat: the record that will not die"'
ID=$(request_id "$CMD_STUCK")
approve "$ID"
chmod 555 "$STATE"
OUT=$(ask_gate "$CMD_STUCK" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an approval that cannot be deleted is refused" "$(verdict_of "$OUT")" deny
case "$(reason_of "$OUT")" in
  *"cannot be deleted"*) ok "...and says the record could not be spent" ;;
  *) bad "the undeletable-record denial is the generic one — the guard is gone" ;;
esac
chmod 755 "$STATE"
rm -f "$STATE/$ID"

mkdir -p "$STATE"
chmod 000 "$STATE"
OUT=$(ask_gate 'git commit -m "feat: unwritable"' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an unwritable record directory is denied" "$(verdict_of "$OUT")" deny
case "$(reason_of "$OUT")" in
  *"cannot write the approval record"*) ok "...and names the directory it cannot write" ;;
  *) bad "the unwritable-directory denial is the generic one — the write guard is gone" ;;
esac
chmod 755 "$STATE"

OUT=$(printf 'not json' | gate -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an unparseable payload stays silent" "$(verdict_of "$OUT")" silent

echo "Carve-out — the dispatcher's env flag, and nothing else:"
PIPE_CMD='git commit -m "chore: pipeline"'

# expect_flag <description> <value|UNSET> <deny|silent>
expect_flag() {
  local desc="$1" value="$2" expect="$3" out
  if [ "$value" = UNSET ]; then
    out=$(ask_gate "$PIPE_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  else
    out=$(ask_gate "$PIPE_CMD" "" "" WORKBENCH_DEV_TEAM_PIPELINE="$value")
  fi
  check "$desc" "$(verdict_of "$out")" "$expect"
}

expect_flag "WORKBENCH_DEV_TEAM_PIPELINE=1 bypasses the gate" 1      silent
expect_flag "an absent flag gates the commit"                 UNSET  deny
# Everything that is not the literal 1 gates. The carve-out fails closed, so a
# typo, a leftover value, or a shell that exports an empty string all keep the
# denial rather than silently waiving approval.
expect_flag "an explicit 0 gates the commit"                  0      deny
expect_flag "an empty flag gates the commit"                  ""     deny
expect_flag "'true' does not bypass"                          true   deny
expect_flag "'yes' does not bypass"                           yes    deny
expect_flag "'01' does not bypass"                            01     deny

# The pipeline must not need an approval record, a writable state directory, or
# a session id — it never reaches any of that code. Prove it with the whole
# state directory unwritable and the session id gone.
chmod 000 "$STATE"
OUT=$(ask_gate "$PIPE_CMD" EMPTY "" WORKBENCH_DEV_TEAM_PIPELINE=1)
check "the pipeline commits with no session id and no writable state" "$(verdict_of "$OUT")" silent
chmod 755 "$STATE"

# Regression guard for the leak this carve-out replaced. The gate used to go
# silent whenever a watson.lock held a live PID — a host-wide answer to a
# per-process question, which waived approval for every concurrent interactive
# session while a scheduled run held it. Nothing on disk may bypass the gate now.
#
# The lock is planted INSIDE the sandbox, never at the real /tmp/watson.lock.
# Writing the live path made this the one case that touched state outside the
# repo: it clobbered a running Dispatch tick's lock for the length of the case,
# and two copies of this suite running in parallel restored each other's file.
# `gate` already points TMPDIR and HOME here, so both plausible lookups resolve
# into the sandbox.
mkdir -p "$SANDBOX/home/.claude-workbench"
echo "$$" > "$SANDBOX/watson.lock"                        # a live PID: the exact
echo "$$" > "$SANDBOX/home/.claude-workbench/watson.lock" # condition that used to bypass
expect_flag "a live watson.lock no longer bypasses"           UNSET  deny
rm -f "$SANDBOX/watson.lock" "$SANDBOX/home/.claude-workbench/watson.lock"

# ...and the gate's SOURCE must consult no lock file at all. The case above can
# only plant a lock where the gate might look; a reintroduction that hard-codes
# /tmp/watson.lock would sail past it while re-opening the exact hole. Full-line
# comments are stripped first, because the gate's own header documents the leak
# it replaced and that prose must stay readable.
if grep -v '^[[:space:]]*#' "$GATE" | grep -q 'watson\.lock'; then
  bad "the gate reads a lock file again — the host-wide bypass is back"
else
  ok "the gate source consults no lock file"
fi

# The verdict itself is load-bearing. "ask" is what the gate used to return, and
# what the auto-mode classifier answered on the human's behalf for its whole
# life. No path may return it again.
if grep -v '^[[:space:]]*#' "$GATE" | grep -q '"ask"'; then
  bad "the gate can still return \"ask\" — the classifier will answer it"
else
  ok "the gate never returns \"ask\""
fi

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
SPACED_ROOT="$(mktemp -d "$SANDBOX/plugin root XXXXXX")"  # deliberate space
mkdir -p "$SPACED_ROOT/hooks/scripts"
cp "$GATE" "$SPACED_ROOT/hooks/scripts/commit-approval-gate.sh"
OUT=$(payload 'git commit -m "z"' | env -u WORKBENCH_DEV_TEAM_PIPELINE -u WORKBENCH_COMMIT_APPROVAL_DIR \
  CLAUDE_PLUGIN_ROOT="$SPACED_ROOT" TMPDIR="$SANDBOX" HOME="$SANDBOX/home" sh -c "$CMD_TEMPLATE")
check "gate fires when the plugin path contains a space" "$(verdict_of "$OUT")" deny

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
