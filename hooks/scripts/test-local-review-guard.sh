#!/bin/bash
# Tests for local-review-guard.sh. Run directly: ./test-local-review-guard.sh
#
# Each case feeds a synthetic hook payload and asserts the guard's behaviour:
# what it arms, what it refuses, what it leaves alone, and what it releases.
#
# Two properties carry most of the weight, and both have a named failure behind
# them. (1) A refused command must come back "deny" and never "ask" — a hook's
# "ask" is classifier-approvable, which is how the sibling commit gate spent its
# whole life stopping nothing. (2) A session that is NOT running a review must be
# untouched while another session is — a host-wide signal would gag the human's
# own window, which is the commit gate's watson.lock leak with the sign flipped.
#
# The sandbox owns HOME, TMPDIR and the state directory, so no case can read or
# write the developer's real environment: the verdict has to come from the
# guard, never from what happens to be on this host.

set -u
GUARD="$(cd "$(dirname "$0")" && pwd)/local-review-guard.sh"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/local-review-guard.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
STATE="$SANDBOX/state"
WORKDIR="$SANDBOX/repo"
mkdir -p "$WORKDIR" "$SANDBOX/home"

BRIEF="Workdir: $WORKDIR (branch: main — in place)

Goal: the guard refuses a mutation and permits a read.

Context: prose.

Constraints:
- none

Done when: the suite is green."

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected $3, got $2"; fi; }

# Build the payload first, then feed it with printf. Piping a generator straight
# into the guard breaks its stdout when the carve-out exits before reading stdin.
run_guard() { # run_guard <payload> [env assignments...]
  local body="$1"; shift
  printf '%s' "$body" | env -u WORKBENCH_DEV_TEAM_PIPELINE \
    WORKBENCH_LOCAL_REVIEW_DIR="$STATE" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" \
    "$@" bash "$GUARD"
}

agent_payload() { # agent_payload <event> <subagent_type> <prompt> [session]
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": sys.argv[1], "tool_name": "Agent",
                  "session_id": sys.argv[4], "agent_id": "",
                  "tool_input": {"subagent_type": sys.argv[2], "prompt": sys.argv[3]}}))' \
    "$1" "$2" "$3" "${4-session-A}"
}

bash_payload() { # bash_payload <command> [session] [agent] [cwd]
  python3 -c '
import json, sys
body = {"hook_event_name": "PreToolUse", "tool_name": "Bash",
        "session_id": sys.argv[2], "agent_id": sys.argv[3],
        "tool_input": {"command": sys.argv[1]}}
if sys.argv[4]:
    body["cwd"] = sys.argv[4]
print(json.dumps(body))' "$1" "${2-session-A}" "${3-agent-1}" "${4-}"
}

verdict_of() {
  if printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; then echo deny
  elif printf '%s' "$1" | grep -q '"permissionDecision": *"ask"'; then echo ask
  else echo silent; fi
}

records() { ls -1 "$STATE" 2>/dev/null | wc -l | tr -d ' '; }
reset_state() { rm -rf "$STATE"; }

arm()    { run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "$BRIEF" "${1-session-A}")" >/dev/null; }
disarm() { run_guard "$(agent_payload PostToolUse "workbench-dev-team:holmes" "$BRIEF" "${1-session-A}")" >/dev/null; }

# bash_verdict <command> [session] [agent] [cwd]
bash_verdict() { verdict_of "$(run_guard "$(bash_payload "$1" "${2-session-A}" "${3-agent-1}" "${4-}")")"; }

echo "── arming: only a Holmes local dispatch arms ──────────────────────────"

reset_state
arm
check "a Holmes prose brief arms the session" "$(records)" 1

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "Item ID: 412")" >/dev/null
check "an 'Item ID' dispatch is Index mode and does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "  412  ")" >/dev/null
check "a bare integer id does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "PVTI_lADOAbc123")" >/dev/null
check "a bare PVTI id does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "3823652e-6394-4478-a87d-a1e838a84e90")" >/dev/null
check "a bare UUID id does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:watson" "$BRIEF")" >/dev/null
check "a Watson dispatch does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "Explore" "$BRIEF")" >/dev/null
check "a generic lens dispatch does not arm" "$(records)" 0

# The scheduled pipeline never reviews a live working tree, and must not inherit
# a rule written for one. Same carve-out signal the commit gate uses, checked
# first so no state is even consulted.
reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "$BRIEF")" WORKBENCH_DEV_TEAM_PIPELINE=1 >/dev/null
check "the pipeline carve-out suppresses arming" "$(records)" 0

echo
echo "── reading and testing stay legal ─────────────────────────────────────"

reset_state
arm
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed: $cmd" "$(bash_verdict "$cmd")" silent
done <<EOF
git -C $WORKDIR status --short
git -C $WORKDIR diff HEAD
git -C $WORKDIR ls-files --others --exclude-standard
git -C $WORKDIR status -sb
git rev-parse --short HEAD
git log --oneline -5
git show HEAD:file.txt
git blame file.txt
bash run-tests.sh
npm test
grep -i needle file.txt
rg --files
cat $WORKDIR/file.txt
EOF

echo
echo "── mutation is refused ────────────────────────────────────────────────"

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused: $cmd" "$(bash_verdict "$cmd")" deny
done <<EOF
git restore .
git restore --staged --worktree src/
git -C $WORKDIR restore agents/lint.sh
git checkout -- .
git switch main
git stash
git stash push -m wip
git reset --hard HEAD
git clean -fd
git commit -m x
git apply patch.diff
chmod 644 agents/lint-holmes-local-mode.sh
chmod +x run-tests.sh
chown mike file.txt
rm -rf build
mv old.txt new.txt
truncate -s 0 file.txt
sed -i '' s/a/b/ file.txt
perl -i -pe s/a/b/ file.txt
npx prettier --write .
ruff check --fix .
find . -name '*.tmp' -delete
xargs -0 rm
sudo rm -rf /
git status && chmod 644 file.txt
EOF

# The measured breach, spelled exactly as it happened: a lens sub-agent changed
# a script from 755 to 644 with the prohibition verbatim in its own prompt.
check "the breach command itself is refused" \
  "$(bash_verdict "chmod 644 /Users/mike/Developer/workbench-dev-team/agents/lint-holmes-local-mode.sh")" deny

echo
echo "── redirection is judged by target, not refused outright ──────────────"

check "redirect to an absolute path outside the tree is allowed" \
  "$(bash_verdict "git diff HEAD > /tmp/review.diff")" silent
check "redirect into the tree under review is refused" \
  "$(bash_verdict "git diff HEAD > $WORKDIR/notes.md")" deny
check "a relative redirect resolved into the tree is refused" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A agent-1 "$WORKDIR")" deny
check "a relative redirect resolved outside the tree is allowed" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A agent-1 "$SANDBOX/elsewhere")" silent
check "a relative redirect with no cwd to resolve it fails closed" \
  "$(bash_verdict "git diff HEAD > notes.md")" deny
check "2>&1 is a descriptor, not a file target" \
  "$(bash_verdict "bash run-tests.sh 2>&1")" silent

echo
echo "── scope: only sub-agents, only the session under review ──────────────"

# The constraint-3 regression guard. A host-wide signal would gag this.
check "a different session is untouched while this one is armed" \
  "$(bash_verdict "chmod 644 file.txt" session-B agent-9)" silent
check "the armed session's main thread keeps its own tools" \
  "$(bash_verdict "chmod 644 file.txt" session-A "")" silent
check "the pipeline carve-out is silent even on an armed session" \
  "$(verdict_of "$(run_guard "$(bash_payload "git restore ." session-A agent-1)" WORKBENCH_DEV_TEAM_PIPELINE=1)")" silent

reset_state
check "an unarmed session is untouched" "$(bash_verdict "git restore .")" silent
check "an unarmed session may still chmod" "$(bash_verdict "chmod 644 file.txt")" silent

echo
echo "── the verdict binds: deny, never ask ─────────────────────────────────"

reset_state
arm
ASK_SEEN=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  [ "$(bash_verdict "$cmd")" = ask ] && ASK_SEEN="$cmd"
done <<EOF
git restore .
chmod 644 file.txt
rm -rf .
git stash
EOF
check "no refusal path returns the classifier-approvable 'ask'" "${ASK_SEEN:-none}" none

DENIAL="$(run_guard "$(bash_payload "git restore .")")"
printf '%s' "$DENIAL" | grep -qi 'local-review guard' && ok "the denial names the guard" \
  || bad "the denial does not name the guard"
printf '%s' "$DENIAL" | grep -q "$WORKDIR" && ok "the denial names the tree it protects" \
  || bad "the denial does not name the tree it protects"
# The commit gate's lane 2 offers no approval path on purpose, and neither does
# this. A denial that prints a way out is an invitation to take it.
printf '%s' "$DENIAL" | grep -qi 'approve\|override\|WORKBENCH_LOCAL_REVIEW_DIR' \
  && bad "the denial leaks a way around itself" \
  || ok "the denial offers no way around itself"

echo
echo "── release: the record is held until the review returns ───────────────"

reset_state
arm
disarm
check "a returning Holmes dispatch releases the record" "$(records)" 0

reset_state
arm
# A lens sub-agent returning mid-review is an Agent PostToolUse too. It must not
# unlock the tree the rest of the fan-out is still reading.
run_guard "$(agent_payload PostToolUse "Explore" "read the diff")" >/dev/null
check "a lens returning does not release the review's record" "$(records)" 1
check "and the tree is still guarded" "$(bash_verdict "git restore .")" deny

reset_state
arm
arm
disarm
check "two reviews in flight need two releases" "$(records)" 1
check "and the second is still guarded" "$(bash_verdict "chmod 644 file.txt")" deny
disarm
check "the second release clears it" "$(records)" 0

# A review that dies without returning must not hold the session forever.
reset_state
arm
python3 - "$STATE" <<'PY'
import json, os, sys, time
directory = sys.argv[1]
for name in os.listdir(directory):
    path = os.path.join(directory, name)
    with open(path) as handle:
        record = json.load(handle)
    record["armed_at"] = time.time() - 7201
    with open(path, "w") as handle:
        json.dump(record, handle)
PY
check "a record past its TTL no longer gates" "$(bash_verdict "git restore .")" silent

echo
echo "── fail-safe inputs ───────────────────────────────────────────────────"

reset_state
arm
check "an unparseable payload yields no opinion" "$(verdict_of "$(printf 'not json' | \
  env -u WORKBENCH_DEV_TEAM_PIPELINE WORKBENCH_LOCAL_REVIEW_DIR="$STATE" \
  HOME="$SANDBOX/home" TMPDIR="$SANDBOX" bash "$GUARD")")" silent
check "a payload with no session id yields no opinion" \
  "$(bash_verdict "git restore ." "" agent-1)" silent
check "a non-Bash, non-Agent tool is not this guard's business" \
  "$(verdict_of "$(run_guard "$(python3 -c '
import json
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Read",
                  "session_id": "session-A", "agent_id": "agent-1",
                  "tool_input": {"file_path": "/etc/hosts"}}))')")")" silent

# A brief with no parseable workdir still arms. Only the redirect rule needs a
# path; every other rule is independent of one, and the dangerous verbs are what
# the breach used.
reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "Goal: review the tree. Done when: done.")" >/dev/null
check "a brief with no Workdir slot still arms" "$(records)" 1
check "and still refuses a mutation" "$(bash_verdict "chmod 644 file.txt")" deny
check "but has no tree to judge a redirect against" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A agent-1 "$WORKDIR")" silent

echo
echo "── --classify: the same rule the lint holds the docs to ───────────────"

printf 'git -C /w status --short\ngit -C /w diff HEAD\nbash run-tests.sh\n' | bash "$GUARD" --classify >/dev/null \
  && ok "--classify passes the reference's own documented commands" \
  || bad "--classify rejects a command the reference tells a reviewer to run"
printf 'git status\ngit restore .\nchmod 644 x\n' | bash "$GUARD" --classify >/dev/null \
  && bad "--classify passed a block containing git restore and chmod" \
  || ok "--classify fails a block containing a destructive command"
CLASSIFIED="$(printf 'git restore .\nchmod 644 x\n' | bash "$GUARD" --classify)"
check "--classify reports every offending line, not just the first" \
  "$(printf '%s\n' "$CLASSIFIED" | grep -c .)" 2
# Prose that names the verbs mid-sentence must stay legal, or the next author is
# taught to delete the warning to get the lint green.
printf 'every other git verb is forbidden. That includes restore, stash, and clean.\n' \
  | bash "$GUARD" --classify >/dev/null \
  && ok "--classify leaves the prohibition's own prose alone" \
  || bad "--classify reddens on prose that merely names the verbs"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
