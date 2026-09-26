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

# A throwaway repository to run in. A push is bound to the state of the
# repository it runs in, so the gate reads that state, and needs one to read.
# The commit is written with plumbing: this fixture needs a HEAD and nothing
# else, and nothing here ever talks to a remote — `origin` points at no path.
# fixture_repo <dir> — a repository with one commit on main.
fixture_repo() {
  git init -q -b main "$1"
  local tree commit
  tree=$(git -C "$1" write-tree)
  commit=$(git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid commit-tree "$tree" -m fixture)
  git -C "$1" update-ref refs/heads/main "$commit"
  git -C "$1" remote add origin "$SANDBOX/no-such-remote.git"
}
# advance <dir> — move main on by one commit, as an ungated pull or rebase would.
advance() {
  local tree commit
  tree=$(git -C "$1" write-tree)
  commit=$(git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid commit-tree "$tree" -p HEAD -m moved)
  git -C "$1" update-ref refs/heads/main "$commit"
}
REPO="$SANDBOX/repo"
OTHER_REPO="$SANDBOX/other-repo"
fixture_repo "$REPO"
fixture_repo "$OTHER_REPO"
# The payload's cwd. Every case runs in $REPO unless it sets CWD itself.
CWD="$REPO"

# Run the gate with the sandbox in place of the host's temp dir and home.
gate() { env -u WORKBENCH_COMMIT_APPROVAL_DIR "$@" TMPDIR="$SANDBOX" HOME="$SANDBOX/home" "$GATE"; }

# payload <command> [session-id] [agent-id] [agent-type] — cwd comes from $CWD
# agent_type is carried only so a case can prove the gate ignores it; it is
# omitted from the payload entirely when empty, which is the common shape.
payload() {
  python3 -c '
import json, sys
body = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": sys.argv[2],
        "agent_id": sys.argv[3], "tool_input": {"command": sys.argv[1]}}
if sys.argv[4]:
    body["agent_type"] = sys.argv[4]
if sys.argv[5]:
    body["cwd"] = sys.argv[5]
print(json.dumps(body))' "$1" "${2-session-A}" "${3-}" "${4-}" "$CWD"
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

# The refusal is split across the hook's two channels, and every assertion below
# names the one it means. `permissionDecisionReason` becomes the tool_result a
# PERSON reads, so it is one short line naming the action. `additionalContext`
# survives a deny and reaches only the model, so the request id, the approval
# command, and the policy live there. Asserting on the raw payload instead would
# pass whichever field the text ended up in, which is the drift these catch —
# except where the assertion is that a string appears NOWHERE. That is the
# lane-2 case, and it is deliberately checked against the whole payload.
reason_of() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null
}

context_of() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"].get("additionalContext",""))' 2>/dev/null
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
# It comes out of additionalContext, because an id is something only an agent
# acts on and the human line carries none.
request_id() {
  local out
  out=$(ask_gate "$1" "${2-session-A}" "${3-}" -u WORKBENCH_DEV_TEAM_PIPELINE)
  context_of "$out" | grep -oE '[0-9a-f]{16}' | head -1
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
run_case "empty commit (watson scaffold)"         'git commit --allow-empty -m "chore: start"'     deny

echo "Non-commits stay silent:"
run_case "git status"                             'git status'                                     silent
run_case "git add only"                           'git add -A'                                     silent
run_case "unrelated command"                      'ls -la'                                         silent
run_case "git diff"                               'git diff --staged'                              silent

echo "The human reads one short line that names the action:"
DENY_OUT=$(ask_gate 'git commit -m "feat: x"' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
DENY_REASON=$(reason_of "$DENY_OUT")
DENY_CONTEXT=$(context_of "$DENY_OUT")

check "the human line names the action and nothing else" "$DENY_REASON" \
  '🛑 Blocked: `git commit`. It needs your approval first.'
if [ "$(printf '%s' "$DENY_REASON" | grep -c .)" = "1" ] && [ "${#DENY_REASON}" -le 120 ]; then
  ok "the human line is one line and stays short (${#DENY_REASON} chars)"
else
  bad "the human line grew past one short line (${#DENY_REASON} chars)"
fi
# The three things that used to make the denial 922 characters. Each is acted on
# by an agent alone, and each must now be absent from the line a person reads.
case "$DENY_REASON" in
  *approve-commit.sh*) bad "the human line still carries the approval command" ;;
  *) ok "the human line carries no approval command" ;;
esac
if printf '%s' "$DENY_REASON" | grep -qE '[0-9a-f]{16}'; then
  bad "the human line still carries a request id"
else
  ok "the human line carries no request id"
fi
case "$DENY_REASON" in
  *WORKBENCH_DEV_TEAM_PIPELINE*) bad "the human line still carries the pipeline policy" ;;
  *) ok "the human line carries no policy paragraph" ;;
esac
# No Markdown emphasis: whether a client renders it is unsettled, and the model
# receives the raw source either way, so asterisks would show up as asterisks.
case "$DENY_REASON" in
  *'**'*) bad "the human line uses Markdown emphasis" ;;
  *) ok "the human line carries no Markdown emphasis" ;;
esac

echo "...and the agent still gets everything it needs to recover:"
case "$DENY_CONTEXT" in
  *"Commit approval gate (workbench-dev-team)."*)
    ok "the context names the gate, so the model can report which one fired" ;;
  *) bad "the context does not name the gate" ;;
esac
case "$DENY_CONTEXT" in
  *'bash "$HOME/.claude-workbench/bin/approve-commit.sh"'*) ok "the context names the approve-commit.sh command" ;;
  *) bad "the context does not name the approve-commit.sh command" ;;
esac
if printf '%s' "$DENY_CONTEXT" | grep -qE '[0-9a-f]{16}'; then
  ok "the context carries a request id"
else
  bad "the context carries no request id"
fi
# The prompt's description line is what the human actually reads. Left to the
# session to word, it came out naming the action and not the commit, which is a
# prompt nobody reads. So the denial has to dictate it: the parameter by name,
# and the literal shape.
case "$DENY_CONTEXT" in
  *'`description`'*'"Commit: <first line of the commit message>"'*)
    ok "the context dictates the approval prompt's description" ;;
  *) bad "the context does not dictate the approval prompt's description" ;;
esac
case "$DENY_CONTEXT" in
  *"never set WORKBENCH_DEV_TEAM_PIPELINE"*) ok "the context still forbids setting the pipeline flag" ;;
  *) bad "the context lost the prohibition on setting the pipeline flag" ;;
esac

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
check "a sub-agent cannot spend the foreground's approval" "$(verdict_of "$OUT")" deny

OUT=$(ask_gate "$CMD" "session-A" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "the session that was approved still gets through" "$(verdict_of "$OUT")" silent

echo "Lane 2 — a sub-agent is refused, whatever it asked to run:"
# Every case below carries a non-empty agent_id, which is the harness's own
# marker for a sub-agent and the only signal this lane reads.
sub_case() { # sub_case <desc> <command> <deny|silent>
  local out
  out=$(ask_gate "$2" "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE)
  check "$1" "$(verdict_of "$out")" "$3"
}

sub_case "a commit"                               'git commit -m "feat: x"'                        deny
sub_case "a merge"                                'git merge origin/main'                          deny
sub_case "a rebase"                               'git rebase main'                                deny
sub_case "a pull, which merges"                   'git pull --rebase origin main'                  deny
sub_case "a cherry-pick"                          'git cherry-pick abc1234'                        deny
sub_case "a revert"                               'git revert abc1234'                             deny
sub_case "an am"                                  'git am /tmp/patch.mbox'                         deny
sub_case "a push"                                 'git push origin feature'                        deny
sub_case "a force push"                           'git push --force-with-lease origin feature'     deny
sub_case "a -f force push"                        'git push -f origin feature'                     deny
sub_case "a push in a subshell"                   '(cd /tmp/clone && git push)'                    deny
sub_case "a push behind env"                      'env -i git push'                                deny
sub_case "GIT push"                               'GIT push'                                       deny
sub_case "a push through a -c alias"              'git -c alias.p=push p'                          deny
sub_case "yadm push"                              'yadm push'                                      deny
sub_case "a commit in \$( )"                      'echo "$(git commit -m z)"'                      deny
sub_case "an unreadable commit"                   "git commit -m 'unbalanced"                      deny
sub_case "a gh pr merge"                          'gh pr merge 42 --squash'                        deny
sub_case "a gh pr merge with a repo flag"         'gh -R owner/name pr merge 42'                   deny
sub_case "a commit hidden behind a push"          'git push && git commit -m "z"'                  deny
sub_case "a commit in a -C clone"                 'git -C /tmp/clone commit -m "z"'                deny

# Reads and the rest of gh stay open — a sub-agent that cannot inspect its own
# work cannot write the report it is being told to hand back.
sub_case "git status is untouched"                'git status'                                     silent
sub_case "git diff is untouched"                  'git diff --staged'                              silent
sub_case "gh pr view is untouched"                'gh pr view 42 --comments'                       silent
sub_case "gh pr comment is untouched"             'gh pr comment 42 --body hi'                      silent
sub_case "gh pr create is untouched"              'gh pr create --draft --title x --body y'        silent

echo "...and it is offered nothing it could run to clear that denial:"
SUB_OUT=$(ask_gate 'git commit -m "feat: x"' "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE)
SUB_REASON=$(reason_of "$SUB_OUT")
# These two run against the WHOLE payload, not one channel. The claim is that
# neither half offers the sub-agent a route, so a check on one field alone would
# pass while the other handed it the id.
case "$SUB_OUT" in
  *approve-commit.sh*) bad "the sub-agent denial prints the approval command — it can run that itself" ;;
  *) ok "the sub-agent denial names no approval command, in either channel" ;;
esac
if printf '%s' "$SUB_OUT" | grep -qE '[0-9a-f]{16}'; then
  bad "the sub-agent denial carries a request id — that is half an approval"
else
  ok "the sub-agent denial carries no request id, in either channel"
fi
check "the human line names the action that was gated" "$SUB_REASON" \
  '🛑 Blocked: `git commit`. A sub-agent does not commit, merge, or push.'
if [ "$(printf '%s' "$SUB_REASON" | grep -c .)" = "1" ] && [ "${#SUB_REASON}" -le 120 ]; then
  ok "...in one short line (${#SUB_REASON} chars)"
else
  bad "the sub-agent human line grew past one short line (${#SUB_REASON} chars)"
fi
# The gated verb, not a hardcoded "commit": a push and a merge are refused here
# too, and telling somebody they were blocked committing when they pushed is the
# confusion this whole change exists to remove.
check "the human line names the verb the call actually ran" \
  "$(reason_of "$(ask_gate 'git push origin feature' "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git push`. A sub-agent does not commit, merge, or push.'
case "$(context_of "$SUB_OUT")" in
  *"Hand the work back"*) ok "...and the context says to hand the work back instead" ;;
  *) bad "the sub-agent context does not say to hand the work back" ;;
esac

# A pending record is what approve-commit.sh flips, and lane 2 writes none — so
# there is nothing for any later call to spend. The gate prints no id for a
# sub-agent, so the suite computes the key itself, and confirms its arithmetic
# against an id the gate DID print before trusting it anywhere below.
computed_id() { # computed_id <session> <agent> <command> — in $CWD
  python3 -c 'import hashlib,sys; print(hashlib.sha256("\x1f".join(sys.argv[1:5]).encode("utf-8","surrogatepass")).hexdigest()[:16])' "$1" "$2" "$CWD" "$3"
}
PLANT_CMD='git commit -m "feat: the planted approval"'
check "the suite computes the gate's own request id" \
  "$(computed_id "session-A" "" "$PLANT_CMD")" "$(request_id "$PLANT_CMD" "session-A" "")"

mkdir -p "$STATE"
TRACE_CMD='git commit -m "feat: leaves no trace"'
BEFORE=$(find "$STATE" -type f | wc -l | tr -d ' ')
ask_gate "$TRACE_CMD" "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE >/dev/null
AFTER=$(find "$STATE" -type f | wc -l | tr -d ' ')
check "the sub-agent denial leaves the record directory as it found it" "$AFTER" "$BEFORE"
if [ -e "$STATE/$(computed_id "session-S" "agent-sub" "$TRACE_CMD")" ]; then
  bad "the sub-agent denial wrote a pending record under its own key"
else
  ok "the sub-agent denial writes no pending record for its own command"
fi

# The order of the checks is load-bearing too: lane 2 has to come BEFORE the
# record is read, or an agent holding Bash writes its own approval and spends it.
SUB_ID=$(computed_id "session-S" "agent-sub" "$PLANT_CMD")
python3 - "$STATE/$SUB_ID" "$PLANT_CMD" <<'PY'
import json, sys, time
path, command = sys.argv[1], sys.argv[2]
with open(path, "w") as handle:
    json.dump({"status": "approved", "approved_at": time.time(), "command": command,
               "session_id": "session-S", "agent_id": "agent-sub"}, handle)
PY
OUT=$(ask_gate "$PLANT_CMD" "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a hand-written approval buys a sub-agent nothing" "$(verdict_of "$OUT")" deny
rm -f "$STATE/$SUB_ID"

echo "...and agent_id is the signal, never agent_type:"
# agent_type cannot answer this question. It is present for a scheduled
# `claude -p --agent watson` and an interactively dispatched one alike, and
# absent for a generic sub-agent that has no named type — so a gate keyed on it
# would both misread the pipeline and wave the generic sub-agent through. Two
# payload shapes pin the right signal.
OUT=$(printf '%s' "$(payload 'git commit -m "feat: x"' session-T "agent-generic" "")" \
  | gate -u WORKBENCH_DEV_TEAM_PIPELINE)
# The verdict alone cannot tell the two lanes apart — both deny an unapproved
# commit. The absence of a request id anywhere in the payload is what says it
# was lane 2, so the whole output is searched rather than one channel.
if [ "$(verdict_of "$OUT")" = deny ] && ! printf '%s' "$OUT" | grep -qE '[0-9a-f]{16}'; then
  ok "a sub-agent with no agent_type is refused with no path out"
else
  bad "a sub-agent with no agent_type was handed the foreground's approval path"
fi

OUT=$(printf '%s' "$(payload 'git commit -m "feat: x"' session-T "" "workbench-dev-team:watson")" \
  | gate -u WORKBENCH_DEV_TEAM_PIPELINE)
if context_of "$OUT" | grep -qE '[0-9a-f]{16}'; then
  ok "a foreground session carrying an agent_type still gets the approval path"
else
  bad "an agent_type sent the foreground session down the sub-agent lane"
fi

echo "Lane 3 — merge and its relatives stay the human's own:"
run_case "a merge is not this gate's business"    'git merge origin/main'                          silent
run_case "nor a rebase"                           'git rebase main'                                silent
run_case "nor a pull"                             'git pull --rebase origin main'                  silent
run_case "nor gh pr merge"                        'gh pr merge 42 --squash'                        silent
run_case "a commit behind a push is still caught" 'git push && git commit -m "z"'                  deny

echo "Lane 3 — a push is denied until it is approved, like a commit:"
# A foreground push used to run with no prompt at all, and the prose told agents
# it was the human's to run. Both halves changed: the agent attempts the push,
# and this gate makes the human answer for it.
run_case "a plain push"                           'git push origin main'                           deny
run_case "a bare push"                            'git push'                                       deny
run_case "a push that sets upstream"              'git push -u origin feature'                     deny
run_case "a push in a -C clone"                   'git -C /tmp/repo push origin main'              deny
run_case "a push after a commit"                  'git commit -m "z" && git push'                  deny
run_case "a dry-run push is still a push"         'git push --dry-run origin main'                 deny

PUSH_OUT=$(ask_gate 'git push origin main' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "the human line names the push" "$(reason_of "$PUSH_OUT")" \
  '🛑 Blocked: `git push`. It needs your approval first.'
PUSH_CONTEXT=$(context_of "$PUSH_OUT")
PUSH_ID=$(printf '%s' "$PUSH_CONTEXT" | grep -oE '[0-9a-f]{16}' | head -1)
# A push has no subject, so its approval command carries no label to invent.
# The denial prints the whole line, and the agent runs exactly that.
case "$PUSH_CONTEXT" in
  *"  bash \"\$HOME/.claude-workbench/bin/approve-commit.sh\" $PUSH_ID"$'\n'*)
    ok "the context prints the approval command with no subject label" ;;
  *) bad "the push context does not print the bare approval command: $PUSH_CONTEXT" ;;
esac
case "$PUSH_CONTEXT" in
  *"<commit subject>"*) bad "the push context asks for a commit subject" ;;
  *) ok "...and asks for no commit subject" ;;
esac
case "$PUSH_CONTEXT" in
  *'`description`'*'"Push: <branch> to <remote>"'*)
    ok "the context dictates a description naming the branch and remote" ;;
  *) bad "the push context does not dictate the push description" ;;
esac
case "$PUSH_CONTEXT" in
  *"the commits it sends"*) ok "...and says to show the human what the push publishes" ;;
  *) bad "the push context does not say what to show the human" ;;
esac

BOTH_OUT=$(ask_gate 'git commit -m "feat: x" && git push origin main' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a commit-and-push names both actions in one line" "$(reason_of "$BOTH_OUT")" \
  '🛑 Blocked: `git commit` and `git push`. It needs your approval first.'
case "$(context_of "$BOTH_OUT")" in
  *'"Commit and push: <first line of the commit message>, <branch> to <remote>"'*'run the same command again'*)
    ok "...and one approval, described as both, covers the one command" ;;
  *) bad "the commit-and-push context does not describe both actions" ;;
esac

echo "...and the approved push goes through once, and only that push:"
PUSH_CMD='git push origin feature'
ID=$(request_id "$PUSH_CMD")
approve "$ID"
OUT=$(ask_gate 'git push origin main' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an approval does not cover a different push" "$(verdict_of "$OUT")" deny
OUT=$(ask_gate "$PUSH_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "the approved push goes through" "$(verdict_of "$OUT")" silent
OUT=$(ask_gate "$PUSH_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "...once, and the next run asks again" "$(verdict_of "$OUT")" deny
ID=$(request_id "$PUSH_CMD")
approve "$ID" 901
OUT=$(ask_gate "$PUSH_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an expired push approval is refused" "$(verdict_of "$OUT")" deny
check "...and the human line says it expired" "$(reason_of "$OUT")" \
  '🛑 Blocked: `git push`. Your approval expired after 15 minutes.'

echo "Class (a) — a plain-form push that forces is refused, with no approval path:"
# workbench-core's rails deny `git push --force` by prefix and nothing else, so
# an approval spent on a force push would only buy a second denial, and every
# other spelling would run. So the gate refuses each one here, asserting the
# clause as well as the absence of an id, the way it refuses a sub-agent.
force_case() { # force_case <desc> <command> [force|delete]
  local out kind="${3-force}" want
  out=$(ask_gate "$2" "session-F" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  if [ "$kind" = force ]; then
    want='🛑 Blocked: `git push --force`. Force pushes are not approved here.'
  else
    want='🛑 Blocked: `git push --delete`. Pushes that delete remote refs are not approved here.'
  fi
  if [ "$(reason_of "$out")" = "$want" ] && ! printf '%s' "$out" | grep -qE '[0-9a-f]{16}|approve-commit\.sh'; then
    ok "$1 is refused as $kind, with no id"
  else
    bad "$1 was not refused as $kind: $(reason_of "$out")"
  fi
}
force_case "--force"                              'git push --force origin main'
force_case "a trailing --force"                   'git push origin main --force'
force_case "-f"                                   'git push -f origin main'
force_case "-f in a short cluster"                'git push -uf origin main'
force_case "--force-with-lease"                   'git push --force-with-lease origin main'
force_case "--force-with-lease=<ref>"             'git push --force-with-lease=main:abc origin main'
force_case "a +refspec"                           'git push origin +main'
force_case "a force push behind a commit"         'git commit -m "z" && git push -f'
# Holmes's round-1 corpus, checked against git 2.54: git accepts any unique
# prefix of a long option, and quotes are removed before git sees a word.
force_case "--mirror, which rewrites and deletes" 'git push --mirror origin'
force_case "the --mirr prefix"                    'git push --mirr origin'
force_case "the --force-with prefix"              'git push --force-with origin main'
force_case "the --force-w prefix"                 'git push --force-w origin main'
force_case "a single-quoted +refspec"             "git push origin '+main'"
force_case "a double-quoted +refspec"             'git push origin "+main"'
force_case "a quoted --force"                     'git push "--force" origin'
force_case "a quoted -f"                          "git push '-f' origin"
mkdir -p "$STATE"
FORCE_CMD='git push --force origin main'
FORCE_ID=$(computed_id "session-F" "" "$FORCE_CMD")
if [ -e "$STATE/$FORCE_ID" ]; then
  bad "a force push wrote a pending record someone could approve"
else
  ok "a force push writes no pending record"
fi
# The refusal runs before any record is read, so a planted approval buys nothing.
plant() { # plant <id> <command>
  python3 - "$STATE/$1" "$2" <<'PY'
import json, sys, time
path, command = sys.argv[1], sys.argv[2]
with open(path, "w") as handle:
    json.dump({"status": "approved", "approved_at": time.time(), "command": command,
               "session_id": "session-F", "agent_id": ""}, handle)
PY
}
plant "$FORCE_ID" "$FORCE_CMD"
OUT=$(ask_gate "$FORCE_CMD" "session-F" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a hand-written approval buys a force push nothing" "$(verdict_of "$OUT")" deny
rm -f "$STATE/$FORCE_ID"

echo "...and so is a plain-form push that deletes remote refs:"
# Mike's call: a deletion is refused the same way, with no id, rather than
# approved behind a prompt that names it.
force_case "--delete"                             'git push --delete origin old'                  delete
force_case "the --de prefix"                      'git push --de origin old'                      delete
force_case "-d"                                   'git push -d origin old'                        delete
force_case "-d in a short cluster"                'git push -qd origin old'                       delete
force_case "a :branch refspec"                    'git push origin :old'                          delete
force_case "a remote-qualified :refs/heads/ refspec" 'git push origin :refs/heads/old'            delete
force_case "--prune"                              'git push --prune origin'                       delete
force_case "the --pru prefix"                     'git push --pru origin'                         delete
DELETE_CMD='git push --delete origin old'
DELETE_ID=$(computed_id "session-F" "" "$DELETE_CMD")
ask_gate "$DELETE_CMD" "session-F" "" -u WORKBENCH_DEV_TEAM_PIPELINE >/dev/null
if [ -e "$STATE/$DELETE_ID" ]; then
  bad "a deletion push wrote a pending record someone could approve"
else
  ok "a deletion push writes no pending record"
fi
plant "$DELETE_ID" "$DELETE_CMD"
OUT=$(ask_gate "$DELETE_CMD" "session-F" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a hand-written approval buys a deletion push nothing" "$(verdict_of "$OUT")" deny
rm -f "$STATE/$DELETE_ID"

# The neighbours that are NOT force or deletion stay on the approval path. A
# bare `:` pushes matching branches, and -o takes the rest of its word as a
# value, so `-oF` and `-ocheck=confirmed` carry no -f or -d.
PROMPTED=0
prompted() { # prompted <desc> <command> — denied WITH a request id to approve
  local out
  out=$(ask_gate "$2" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  PROMPTED=$((PROMPTED + 1))
  if [ "$(verdict_of "$out")" = deny ] && context_of "$out" | grep -qE '[0-9a-f]{16}'; then
    ok "$1 is prompted"
  else
    bad "$1 was not prompted: $(reason_of "$out")"
  fi
}
prompted "a plain commit"                         'git commit -m "feat: ✨ Plain."'
prompted "a plain commit with -F"                 'git commit -F /tmp/message.txt'
prompted "a plain push"                           'git push origin main'
prompted "a plain push with -C"                   "git -C $REPO push origin main"
prompted "a plain commit && push"                 'git commit -m "feat: x" && git push origin main'
prompted "a commit whose message holds an apostrophe" "git commit -m \"fix: it's done\""
prompted "a commit whose message holds a # "      "git commit -m 'fix: #12'"
prompted "a quoted word that starts with ="       'git commit -m "=x"'
prompted "a bare : refspec"                       'git push origin :'
prompted "a push option ending in F"              'git push -oF origin main'
prompted "a push option ending in d"              'git push -ocheck=confirmed origin main'
prompted "--dry-run, which is not --delete"       'git push --dry-run origin main'
prompted "--follow-tags, which is not --force"    'git push --follow-tags origin main'
prompted "--porcelain, which is not --prune"      'git push --porcelain origin main'

echo "Class (b) — anything else that could hide a commit or push is refused, in both lanes:"
# Decided by substring over the raw text, so no quote, comment, or line break
# moves a word out of view. Each case is asserted in the foreground, by its exact
# human line and the absence of an id, and in a sub-agent, by its refusal.
HIDDEN=0
hidden_case() { # hidden_case <desc> <command>
  local out sub
  HIDDEN=$((HIDDEN + 1))
  out=$(ask_gate "$2" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  sub=$(ask_gate "$2" "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE)
  if [ "$(reason_of "$out")" = '🛑 Blocked: this command could hide a `git commit` or `git push`. Run it as a plain line of its own.' ] \
     && ! printf '%s' "$out" | grep -qE '[0-9a-f]{16}' && [ "$(verdict_of "$sub")" = deny ]; then
    ok "$1 is refused in both lanes, with no id"
  else
    bad "$1 — foreground: $(reason_of "$out") / sub-agent: $(verdict_of "$sub")"
  fi
}
# Round 2, critical: apostrophes in two `#` comments paired up in shlex and hid
# the commit and the push between them, silently, in both lanes.
hidden_case "the comment-apostrophe script"       $'git add -A # stage what\'s changed\ngit commit -m x\ngit push # that\'s it'
hidden_case "its first line alone"                "git add -A # stage what's changed"
hidden_case "its last line alone"                 "git push # that's it"
prompted    "its middle line alone"               'git commit -m x'
hidden_case "a push with a trailing comment"       'git push origin main # ship it'
hidden_case "a quoted multi-line message"         $'git commit -m \'subject\n\nbody\''
hidden_case "a commit and push under comments"    $'git commit -m x # what\'s\ngit push # it\'s'
# Round 2: fake heredoc openers stripped real command lines.
hidden_case "a quoted <<X opener"                 $'echo \'<<X\'\ngit push\nX'
hidden_case "a <<< here-string"                   $'cat <<< "x"\ngit push'
hidden_case "a <<Y in a comment"                  $'# <<Y\ngit commit -m z\nY'
# Round 2: expansions in the program or verb slot.
hidden_case "a substitution in the verb"          'git $(echo push)'
hidden_case "a default expansion in the verb"     'git ${V:-push}'
hidden_case "an ANSI-C verb"                      "git \$'\\x70ush'"
hidden_case "an ANSI-C force flag"                "git push \$'\\x2d-force' origin"
hidden_case "a brace-expanded verb"               'git {push,}'
hidden_case "an IFS-joined verb"                  'git${IFS}push'
hidden_case "the git-push binary"                 'git-push origin main'
hidden_case "the git-commit binary"               'git-commit -m z'
hidden_case "help.autocorrect on a typo"          'git -c help.autocorrect=immediate psuh origin main'
# Round 2: a loop repeats one approved commit; a pull moves what a push sends.
hidden_case "a commit in a for loop"              'for i in 1 2; do git commit -m x; done'
hidden_case "a push in a while loop"              'while true; do git push; done'
hidden_case "a pull before a push"                'git pull && git push'
hidden_case "a rebase before a push"              'git pull --rebase && git push origin main'
# Round 1: grouping, wrappers, paths, case, quoting, redirects, options, aliases.
hidden_case "a push in a subshell"                '(cd . && git push)'
hidden_case "a push in a brace group"             '{ git push; }'
hidden_case "a push inside if/then"               'if true; then git push; fi'
hidden_case "a negated push"                      '! git push'
hidden_case "a push in \$( )"                     'echo $(git push)'
hidden_case "a push in a quoted \$( )"            'echo "$(git push)"'
hidden_case "a push in backticks"                 'x=`git push`'
hidden_case "a push inside a cd argument"         'cd "$(git push)"'
hidden_case "a push behind env with options"      'env -i FOO=1 git push'
hidden_case "a push behind time"                  'time git push'
hidden_case "a push behind nice -n"               'nice -n 10 git push'
hidden_case "a push behind nohup"                 'nohup git push'
hidden_case "a push behind timeout"               'timeout 5 git push'
hidden_case "a push by absolute path"             '/usr/bin/git push'
hidden_case "GIT push, which runs git on APFS"    'GIT push'
hidden_case "Git push"                            'Git push'
hidden_case "a quoted verb"                       'git "push"'
hidden_case "a redirect glued to the verb"        'git push>/dev/null'
hidden_case "a push after --config-env"           'git --config-env core.x=HOME push'
hidden_case "a push after --attr-source"          'git --attr-source HEAD push'
hidden_case "a push through a -c alias"           'git -c alias.p=push p'
hidden_case "a -c alias to a shell command"       "git -c alias.p='!git push' p"
hidden_case "a --config-env alias"                'git --config-env alias.p=ALIAS p'
hidden_case "yadm push"                           'yadm push'
hidden_case "yadm commit"                         'yadm commit -m "z"'
hidden_case "a push after a comment-like word"    'echo a#b; git push'
hidden_case "a commit in a subshell"              '(git commit -m "z")'
hidden_case "a commit behind env"                 'env -i git commit -m "z"'
hidden_case "GIT commit"                          'GIT commit -m "z"'
hidden_case "a quoted commit verb"                'git "commit" -m "z"'
hidden_case "a commit through a -c alias"         'git -c alias.ci=commit ci -m "z"'
hidden_case "an unbalanced quote"                 "git commit -m 'unbalanced"
hidden_case "a push naming a variable"            'git push origin "$BRANCH"'
hidden_case "a push naming a brace expansion"     'git push origin {a,b}'
hidden_case "push config from the environment"    'GIT_CONFIG_PARAMETERS="x" git push'
hidden_case "push config through --config-env"    'git --config-env remote.origin.push=P push'
hidden_case "a backslashed +refspec"              'git push origin \+main'
hidden_case "ANSI-C quoted --force"               "git push \$'--force' origin"
hidden_case "a force behind a line continuation"  $'git push origin main \\\n  --force'
hidden_case "-c remote.<r>.push=+…"               'git -c remote.origin.push=+refs/heads/*:refs/heads/* push'
hidden_case "-c remote.<r>.mirror=true"           'git -c remote.origin.mirror=true push'
hidden_case "-c remote.<r>.push=:branch"          'git -c remote.origin.push=:old push'
hidden_case "a force push in a subshell"          '(git push -f)'
hidden_case "a force push behind env"             'env -i git push --force'
hidden_case "two pushes"                          'git push origin main && git push origin other'
hidden_case "two commits"                         'git commit -m a && git commit -m b'
hidden_case "a push before a commit"              'git push && git commit -m "z"'
hidden_case "a push after a cd"                   "cd $OTHER_REPO && git push origin main"
hidden_case "a push after an unresolvable cd"     'cd "$SOMEWHERE" && git push'
hidden_case "-c user.name before commit"          'git -c user.name=x commit -m "z"'
hidden_case "cd, add, and commit"                 'cd /tmp/repo && git add . && git commit -m "z"'
hidden_case "a commit after a semicolon"          'git add .; git commit --no-verify -m "z"'
hidden_case "an env assignment before git"        'GIT_AUTHOR_NAME=x git commit -m "z"'
hidden_case "the command wrapper"                 'command git commit -m "z"'
hidden_case "a rebase that runs a push"           "git rebase --exec 'git push' main"
hidden_case "a submodule loop that pushes"        "git submodule foreach 'git push'"
# Round 3: send-pack is the plumbing under push. It is refused outright rather
# than prompted, because the plain form prompts for commit and push alone.
hidden_case "send-pack with a +refspec"           'git send-pack ../remote.git +main:main'
hidden_case "send-pack --force"                   'git send-pack --force ../remote.git main'
hidden_case "send-pack in plain words"            'git send-pack ../remote.git main'
# Round 3: zsh expands a bare word that starts with `=` to a path, so
# `-m =ls` would send /bin/ls. The Bash tool runs zsh.
hidden_case "a zsh =word in a commit"             'git commit -m =ls'
hidden_case "a zsh =word in a push"               'git push =origin main'
# The cost, stated as tests so it stays visible: innocent text that names git
# and a verb, outside the plain form, is refused too.
hidden_case "a log piped into grep commit"        'git log --oneline | grep commit'
hidden_case "an echo naming git commit"           'echo "git commit is gated"'
hidden_case "a heredoc body that says git push"   $'cat > /tmp/x <<EOF\ngit push --force\nEOF'

echo "...and a sub-agent is refused on the lane-2 verbs hidden the same way:"
sub_case "a merge after a cd"                     'cd /tmp/clone && git merge main'                deny
sub_case "a rebase in a subshell"                 '(git rebase main)'                              deny
sub_case "an am behind env"                       'env -i git am /tmp/p.mbox'                      deny
check "the sub-agent human line for a hidden shape" \
  "$(reason_of "$(ask_gate '(git push)' "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: a command that names a git commit, merge, or push. A sub-agent does not commit, merge, or push.'

echo "Class (c) — everything else passes untouched:"
SILENT=0
silent_case() { # silent_case <desc> <command> — silent in both lanes
  local out sub
  SILENT=$((SILENT + 1))
  out=$(ask_gate "$2" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  sub=$(ask_gate "$2" "session-S" "agent-sub" -u WORKBENCH_DEV_TEAM_PIPELINE)
  if [ "$(verdict_of "$out")" = silent ] && [ "$(verdict_of "$sub")" = silent ]; then
    ok "$1 is silent in both lanes"
  else
    bad "$1 — foreground: $(verdict_of "$out") / sub-agent: $(verdict_of "$sub")"
  fi
}
silent_case "git status"                          'git status'
silent_case "git log"                             'git log --oneline -5'
silent_case "git log with a quoted format"        "git log --format='%h %s' -5"
silent_case "git diff"                            'git diff --staged'
silent_case "git show"                            'git show HEAD --stat'
silent_case "git log --grep push"                 'git log --grep push'
silent_case "git log --grep commit"               'git log --grep=commit'
silent_case "git stash push"                      'git stash push -m wip'
silent_case "git help push"                       'git help push'
silent_case "git add"                             'git add -A'
silent_case "git -C path status"                  "git -C $REPO status"
silent_case "a status after a cd"                 'cd /tmp && git status'
silent_case "a log piped to head"                 'git log --oneline | head -5'
silent_case "gh pr view"                          'gh pr view 42 --comments'
silent_case "gh pr comment"                       'gh pr comment 42 --body hi'
silent_case "gh pr create"                        'gh pr create --draft --title x --body y'
silent_case "a github URL with quotes"            'curl -s "https://github.com/x/y"'
silent_case "ls"                                  'ls -la'
silent_case "echo"                                'echo hello'

echo "An approval is bound to its directory, and a push to the repository's state:"
BIND_CMD='git push origin main'
ID=$(request_id "$BIND_CMD")
approve "$ID"
CWD="$OTHER_REPO"
OUT=$(ask_gate "$BIND_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "the same push from another repository is denied" "$(verdict_of "$OUT")" deny
CWD="$REPO"
OUT=$(ask_gate "$BIND_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "...while the repository it was approved in gets through" "$(verdict_of "$OUT")" silent

# rebind <desc> <mutation...> — approve the push, change the repository, and
# expect the spend to be refused as changed. The mutation runs as given.
rebind() {
  local desc="$1" out id
  shift
  id=$(request_id "$BIND_CMD")
  approve "$id"
  "$@" || bad "the mutation itself failed: $*"
  out=$(ask_gate "$BIND_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  check "$desc" "$(reason_of "$out")" '🛑 Blocked: `git push`. The repository changed since you approved it.'
}
rebind "a push whose branch moved after approval is denied" advance "$REPO"
OUT=$(ask_gate "$BIND_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
if context_of "$OUT" | grep -qE '[0-9a-f]{16}'; then
  ok "...and a fresh approval is offered for what the push now sends"
else
  bad "the changed-repository denial offers no fresh approval"
fi
git -C "$REPO" branch -q side
rebind "a push whose HEAD moved to another branch is denied" git -C "$REPO" symbolic-ref HEAD refs/heads/side
git -C "$REPO" symbolic-ref HEAD refs/heads/main
rebind "a push whose remote URL changed is denied"          git -C "$REPO" remote set-url origin "$SANDBOX/elsewhere.git"
rebind "a push after a new tag is denied"                   git -C "$REPO" update-ref refs/tags/v-new HEAD
rebind "a push after branch.<b>.pushRemote changed is denied" git -C "$REPO" config branch.main.pushRemote origin
rebind "a push after push.default changed is denied"        git -C "$REPO" config push.default current
rebind "a push after url.<u>.pushInsteadOf changed is denied" git -C "$REPO" config url.file:///elsewhere/.pushInsteadOf "$SANDBOX/"

ID=$(request_id "$BIND_CMD")
case "$(context_of "$(ask_gate "$BIND_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" in
  *"bound to main at $(git -C "$REPO" rev-parse HEAD | cut -c1-12)"*)
    ok "the context tells the agent which branch and commit the push is bound to" ;;
  *) bad "the context does not name the bound branch and commit" ;;
esac
approve "$ID"
OUT=$(ask_gate "$BIND_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an unchanged repository lets the approved push through" "$(verdict_of "$OUT")" silent

echo "...and a commit to HEAD and the staged content:"
# track <file> <content> — a tracked, committed file in $REPO, written with plumbing.
track() {
  printf '%s\n' "$2" > "$REPO/$1"
  git -C "$REPO" add "$1"
  local tree commit
  tree=$(git -C "$REPO" write-tree)
  commit=$(git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid commit-tree "$tree" -p HEAD -m track)
  git -C "$REPO" update-ref refs/heads/main "$commit"
}
track tracked.txt one
STAGE_CMD='git commit -m "feat: the staged one"'
printf 'staged\n' > "$REPO/staged.txt"
git -C "$REPO" add staged.txt
ID=$(request_id "$STAGE_CMD")
approve "$ID"
printf 'more\n' >> "$REPO/staged.txt"
git -C "$REPO" add staged.txt
OUT=$(ask_gate "$STAGE_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a commit whose staged content changed after approval is denied" "$(reason_of "$OUT")" \
  '🛑 Blocked: `git commit`. The staged changes differ from what you approved.'
if context_of "$OUT" | grep -qE '[0-9a-f]{16}'; then ok "...with a fresh id"; else bad "no fresh id after a staged change"; fi

ID=$(request_id "$STAGE_CMD")
approve "$ID"
advance "$REPO"
OUT=$(ask_gate "$STAGE_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a commit whose HEAD moved after approval is denied" "$(reason_of "$OUT")" \
  '🛑 Blocked: `git commit`. The staged changes differ from what you approved.'

ID=$(request_id "$STAGE_CMD")
approve "$ID"
printf 'edited but not staged\n' >> "$REPO/tracked.txt"
OUT=$(ask_gate "$STAGE_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a plain commit ignores a working-tree edit it does not take" "$(verdict_of "$OUT")" silent

worktree_case() { # worktree_case <desc> <command> — the working tree is bound
  local id out
  id=$(request_id "$2")
  approve "$id"
  printf 'x\n' >> "$REPO/tracked.txt"
  out=$(ask_gate "$2" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
  check "$1" "$(reason_of "$out")" '🛑 Blocked: `git commit`. The staged changes differ from what you approved.'
}
worktree_case "-a binds the working tree"             'git commit -am "feat: all"'
worktree_case "--all binds the working tree"          'git commit --all -m "feat: all"'
worktree_case "a pathspec binds the working tree"     'git commit -m "feat: one" tracked.txt'
worktree_case "--only binds the working tree"         'git commit --only -m "feat: one" tracked.txt'
worktree_case "-i binds the working tree"             'git commit -i -m "feat: one" tracked.txt'
worktree_case "a pathspec after -- binds it"          'git commit -m "feat: one" -- tracked.txt'
worktree_case "-p binds the working tree"             'git commit -p -m "feat: some"'
worktree_case "--patch binds the working tree"        'git commit --patch -m "feat: some"'
worktree_case "--interactive binds the working tree"  'git commit --interactive -m "feat: some"'
worktree_case "a bare -U, which git takes as -p, binds it" 'git commit -U -m "feat: some"'
# -U<n> is only a context size, so it takes nothing from the working tree.
UCTX='git commit -U3 -m "feat: context only"'
ID=$(request_id "$UCTX")
approve "$ID"
printf 'x\n' >> "$REPO/tracked.txt"
check "-U<n> alone does not bind the working tree" "$(verdict_of "$(ask_gate "$UCTX" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" silent

# Round 3: diff.external made the digest hash a program's output. A constant
# printer made every staged change look the same.
CONSTANT="$SANDBOX/constant-diff.sh"
printf '#!/bin/sh\necho same\n' > "$CONSTANT"
chmod +x "$CONSTANT"
git -C "$REPO" config diff.external "$CONSTANT"
# A staged change before the approval, so the driver prints the same constant
# at approval and at spend time: the digest must see past it.
printf 'staged before approval\n' >> "$REPO/staged.txt"
git -C "$REPO" add staged.txt
ID=$(request_id "$STAGE_CMD")
approve "$ID"
printf 'changed under an external diff\n' >> "$REPO/staged.txt"
git -C "$REPO" add staged.txt
check "an external diff driver cannot hide a staged change" \
  "$(reason_of "$(ask_gate "$STAGE_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git commit`. The staged changes differ from what you approved.'
ID=$(request_id 'git commit -am "feat: under ext diff"')
approve "$ID"
printf 'worktree change under an external diff\n' >> "$REPO/tracked.txt"
check "...nor a working-tree change" \
  "$(reason_of "$(ask_gate 'git commit -am "feat: under ext diff"' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git commit`. The staged changes differ from what you approved.'
git -C "$REPO" config --unset diff.external
# A textconv driver cannot hide a change the same way: the diff header still
# carries the blob ids. What --no-textconv prevents is the gate running a
# program the repository configured, from inside a hook. So the driver leaves a
# marker when it runs, and the test asserts it never does.
MARKER="$SANDBOX/textconv-ran"
TEXTCONV="$SANDBOX/marking-textconv.sh"
printf '#!/bin/sh\ntouch %s\ncat "$1"\n' "$MARKER" > "$TEXTCONV"
chmod +x "$TEXTCONV"
printf '*.conv diff=marking\n' > "$REPO/.git/info/attributes"
git -C "$REPO" config diff.marking.textconv "$TEXTCONV"
printf 'one\n' > "$REPO/data.conv"
git -C "$REPO" add data.conv
printf 'two\n' > "$REPO/data.conv"
rm -f "$MARKER"
ask_gate 'git commit -am "feat: textconv"' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE >/dev/null
if [ -e "$MARKER" ]; then
  bad "the gate ran the repository's textconv driver"
else
  ok "the gate runs no textconv driver while reading the staged and working-tree diffs"
fi
rm -f "$REPO/.git/info/attributes" "$MARKER"
git -C "$REPO" config --unset diff.marking.textconv

echo "...and a combined commit && push to both:"
COMBO='git commit -m "feat: combo" && git push origin main'
ID=$(request_id "$COMBO")
approve "$ID"
printf 'restaged for the combo\n' >> "$REPO/staged.txt"
git -C "$REPO" add staged.txt
check "a commit && push whose staged content changed is denied" \
  "$(reason_of "$(ask_gate "$COMBO" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git commit` and `git push`. The staged changes differ from what you approved.'
ID=$(request_id "$COMBO")
approve "$ID"
git -C "$REPO" update-ref refs/tags/combo-tag HEAD
check "a commit && push whose refs changed is denied" \
  "$(reason_of "$(ask_gate "$COMBO" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git commit` and `git push`. The repository changed since you approved it.'
ID=$(request_id "$COMBO")
approve "$ID"
check "an unchanged commit && push goes through once" \
  "$(verdict_of "$(ask_gate "$COMBO" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" silent
ID=$(request_id "$STAGE_CMD")
case "$(context_of "$(ask_gate "$STAGE_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" in
  *"bound to HEAD and the staged changes"*) ok "the context says what the commit is bound to" ;;
  *) bad "the context does not say what the commit is bound to" ;;
esac

echo "...and -C is resolved by git, through symlinks, not by path arithmetic:"
# `lnk/..` is $OTHER_REPO when lnk points into it. Folding the path textually
# gives $REPO, and would bind the approval to the wrong repository.
mkdir -p "$OTHER_REPO/sub"
ln -s "$OTHER_REPO/sub" "$REPO/lnk"
case "$(context_of "$(ask_gate 'git -C lnk/.. push origin main' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" in
  *"/other-repo/.git:"*) ok "-C lnk/.. binds the repository git will use" ;;
  *) bad "-C lnk/.. bound the wrong repository" ;;
esac
rm "$REPO/lnk"

echo "...and a command the gate cannot bind is refused:"
CWD="$SANDBOX"
check "a push outside any repository is refused" \
  "$(reason_of "$(ask_gate "$BIND_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git push`. The gate cannot read the repository this push runs in.'
check "a commit outside any repository is refused" \
  "$(reason_of "$(ask_gate "$STAGE_CMD" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git commit`. The gate cannot read the repository this commit runs in.'
CWD="$REPO"
OUT=$(ask_gate "git -C $OTHER_REPO push origin main" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
case "$(context_of "$OUT")" in
  *"/other-repo/.git:"*) ok "-C moves the push to the repository it names" ;;
  *) bad "the gate read the wrong repository for -C: $(context_of "$OUT")" ;;
esac
MIRROR_REPO="$SANDBOX/mirror-repo"
fixture_repo "$MIRROR_REPO"
git -C "$MIRROR_REPO" config remote.origin.mirror true
CWD="$MIRROR_REPO"
check "a plain push in a mirror-configured repository is refused as force" \
  "$(reason_of "$(ask_gate 'git push' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)")" \
  '🛑 Blocked: `git push --force`. Force pushes are not approved here.'
CWD="$REPO"

echo "Cases per class: prompted $PROMPTED, refused-hidden $HIDDEN, silent $SILENT"

echo "Fail-closed paths:"
# Each of these asserts the MESSAGE as well as the verdict. Both branches end in
# a denial that an unapproved commit would have earned anyway, so a check on the
# verdict alone passes whether or not the branch it names still exists. The
# human line carries the one clause that distinguishes them; the diagnostic
# detail sits in the context, where it is the model that acts on it.
OUT=$(ask_gate "$CMD" EMPTY "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "a payload with no session id is denied" "$(verdict_of "$OUT")" deny
check "...and the human line says the session id is what it lacks" "$(reason_of "$OUT")" \
  '🛑 Blocked: `git commit`. No session id, so no approval can bind to it.'

# An approval that cannot be deleted cannot be spent, and an unspendable
# approval is a standing waiver for that command. Plant one, then make the
# directory read-only so the record survives the commit that used it.
CMD_STUCK='git commit -m "feat: the record that will not die"'
ID=$(request_id "$CMD_STUCK")
approve "$ID"
chmod 555 "$STATE"
OUT=$(ask_gate "$CMD_STUCK" "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an approval that cannot be deleted is refused" "$(verdict_of "$OUT")" deny
check "...and the human line says the record could not be spent" "$(reason_of "$OUT")" \
  '🛑 Blocked: `git commit`. The approval record cannot be deleted.'
case "$(context_of "$OUT")" in
  *"approves every commit or push after it"*) ok "...and the context says why that is refused" ;;
  *) bad "the undeletable-record context lost the reason it fails closed" ;;
esac
chmod 755 "$STATE"
rm -f "$STATE/$ID"

mkdir -p "$STATE"
chmod 000 "$STATE"
OUT=$(ask_gate 'git commit -m "feat: unwritable"' "" "" -u WORKBENCH_DEV_TEAM_PIPELINE)
check "an unwritable record directory is denied" "$(verdict_of "$OUT")" deny
check "...and the human line says the record cannot be written" "$(reason_of "$OUT")" \
  '🛑 Blocked: `git commit`. The approval record cannot be written.'
case "$(context_of "$OUT")" in
  *"Cannot write the approval record under"*) ok "...and the context names the directory" ;;
  *) bad "the unwritable-directory context no longer names the directory" ;;
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

# Every scheduled run IS an agent run, so lane 1 has to outrank lane 2 — and it
# does, by being checked first. A regression that ordered them the other way
# would deadlock every tick at its first commit, which is the whole reason the
# carve-out exists.
pipe_case() { # pipe_case <desc> <command>
  local out
  out=$(ask_gate "$2" "session-P" "agent-watson" WORKBENCH_DEV_TEAM_PIPELINE=1)
  check "the flagged pipeline still runs $1 as an agent" "$(verdict_of "$out")" silent
}

pipe_case "a commit"      'git commit -m "chore: pipeline"'
pipe_case "a push"        'git push origin watson/42'
pipe_case "a force push"  'git push -f origin watson/42'
pipe_case "a delete push" 'git push origin :watson/42'
pipe_case "an unreadable push" 'git push origin "$BRANCH"'
pipe_case "a merge"       'git merge origin/main'
pipe_case "a gh pr merge" 'gh pr merge 42 --squash'

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
