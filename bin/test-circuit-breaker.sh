#!/usr/bin/env bash
# Test for the Dispatch circuit-breaker pre-flight.
#
# The pre-flight lives in bin/dispatch-agent.sh, and `--check` prints its
# verdict without spawning anything. Every case below runs the shipped script
# against a fixture log directory, so the test can never drift from the logic
# the pipeline runs.
#
# Run: bash bin/test-circuit-breaker.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/dispatch-agent.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The script falls back to LOGDIR="$HOME/.claude-workbench/dev-team-logs". Every
# `run` below passes LOGDIR, but a case that ever forgot would read this machine's
# real Dispatch logs and take its verdict from whatever the last live tick wrote.
# A sandboxed HOME makes that impossible rather than merely unlikely.
mkdir -p "$WORK/home"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not found"; exit 1
fi

pass=0; fail=0
# mklog <dir> <agent> <id> <stamp YYYYMMDDhhmm> <content...>
mklog() {
  local dir="$1" agent="$2" id="$3" stamp="$4"; shift 4
  printf '%s\n' "$*" > "$dir/$agent-$id-$stamp.log"
  # `touch -t` reads the stamp in the local zone. TZ=UTC pins it, so every
  # machine writes the same absolute mtime. Do not drop it.
  TZ=UTC touch -t "$stamp" "$dir/$agent-$id-$stamp.log"   # deterministic mtime for ls -t ordering
}
# run <dir> <agent> <id> -> echoes the pre-flight verdict
run() { LOGDIR="$1" HOME="$WORK/home" bash "$SCRIPT" --check "$2" "$3"; }
# expect <name> <expected-prefix> <actual>
expect() {
  case "$3" in
    "$2"*) echo "  ok   — $1"; pass=$((pass+1)) ;;
    *)     echo "  FAIL — $1: expected '$2…' got '$3'"; fail=$((fail+1)) ;;
  esac
}

echo "Testing circuit-breaker pre-flight ($SCRIPT --check):"

# 1. No prior runs -> DISPATCH
d="$WORK/case1"; mkdir -p "$d"
expect "no logs -> dispatch" "DISPATCH" "$(run "$d" watson 131)"

# 2. Single content-filter failure -> ESCALATE on first hit (deterministic, any lane — incl. Watson)
d="$WORK/case2"; mkdir -p "$d"
mklog "$d" watson 131 202606210800 "API Error: Output blocked by content filtering policy"
expect "watson content filter (1 strike) -> escalate" "ESCALATE" "$(run "$d" watson 131)"

# 3. Successful last run -> DISPATCH
d="$WORK/case3"; mkdir -p "$d"
mklog "$d" holmes 200 202606210800 "Review complete. Approved PR #5. Done."
expect "success -> dispatch" "DISPATCH" "$(run "$d" holmes 200)"

# 4. Review-stage lane, one generic fatal, below strike threshold -> DISPATCH (let it retry)
d="$WORK/case4"; mkdir -p "$d"
mklog "$d" holmes 99 202606210800 "API Error: 529 overloaded"
expect "holmes 1 transient fatal -> dispatch (retry)" "DISPATCH" "$(run "$d" holmes 99)"

# 5. Review-stage lane, three consecutive identical generic fatals -> ESCALATE
d="$WORK/case5"; mkdir -p "$d"
mklog "$d" holmes 99 202606210800 "API Error: 529 overloaded"
mklog "$d" holmes 99 202606210820 "API Error: 529 overloaded"
mklog "$d" holmes 99 202606210840 "API Error: 529 overloaded"
expect "holmes 3 identical fatals -> escalate" "ESCALATE" "$(run "$d" holmes 99)"

# 6. Review-stage lane, latest fatal but streak broken by an earlier success -> DISPATCH
d="$WORK/case6"; mkdir -p "$d"
mklog "$d" holmes 99 202606210800 "All good. Review posted."
mklog "$d" holmes 99 202606210820 "API Error: 529 overloaded"
expect "holmes broken streak -> dispatch" "DISPATCH" "$(run "$d" holmes 99)"

# 7. Logs for a different item id must not bleed in -> DISPATCH
d="$WORK/case7"; mkdir -p "$d"
mklog "$d" watson 131 202606210800 "API Error: Output blocked by content filtering policy"
expect "other item's logs ignored -> dispatch" "DISPATCH" "$(run "$d" watson 777)"

# 8. Watson NEVER escalates on generic fatals -> DISPATCH (escalation is Holmes's, post-review).
#    Three identical fatals that WOULD escalate on a review-stage lane (case 5) must not on Watson.
d="$WORK/case8"; mkdir -p "$d"
mklog "$d" watson 99 202606210800 "API Error: 529 overloaded"
mklog "$d" watson 99 202606210820 "API Error: 529 overloaded"
mklog "$d" watson 99 202606210840 "API Error: 529 overloaded"
expect "watson 3 identical fatals -> dispatch (no pre-review escalation)" "DISPATCH" "$(run "$d" watson 99)"

# 9. Human re-activation (escalation marker present) -> REPRIEVE, even atop logs that would otherwise
#    escalate. This is the override: a manually re-reviewed item must NOT bounce straight back out.
d="$WORK/case9"; mkdir -p "$d"
mklog "$d" holmes 215 202606210800 "Error: Exceeded USD budget (7)"
touch "$d/holmes-215.escalated"
expect "marker + budget death -> reprieve (human override)" "REPRIEVE" "$(run "$d" holmes 215)"

# 10. Budget exceeded on a review-stage lane -> ESCALATE on the FIRST hit (deterministic; don't burn more).
d="$WORK/case10"; mkdir -p "$d"
mklog "$d" holmes 300 202606210800 "Error: Exceeded USD budget (7)"
expect "holmes budget death (1 hit) -> escalate" "ESCALATE" "$(run "$d" holmes 300)"

# 11. Budget exceeded on the Watson lane -> DISPATCH while under the strike count. Watson resumes on
#     a persistent branch, so one capped run is progress, not a wall.
d="$WORK/case11"; mkdir -p "$d"
mklog "$d" watson 300 202606210800 "Error: Exceeded USD budget (10)"
expect "watson budget death (1 strike) -> dispatch" "DISPATCH" "$(run "$d" watson 300)"

# 11a. Two strikes is still under the floor -> DISPATCH.
d="$WORK/case11a"; mkdir -p "$d"
mklog "$d" watson 301 202606210800 "Error: Exceeded USD budget (10)"
mklog "$d" watson 301 202606210820 "Error: Exceeded USD budget (10)"
expect "watson budget death (2 strikes) -> dispatch" "DISPATCH" "$(run "$d" watson 301)"

# 11b. Three consecutive budget kills -> ESCALATE. Measured ceiling across 1,015 runs was 3; a 4th
#      means the work is not converging inside the cap and wants a human.
d="$WORK/case11b"; mkdir -p "$d"
mklog "$d" watson 302 202606210800 "Error: Exceeded USD budget (10)"
mklog "$d" watson 302 202606210820 "Error: Exceeded USD budget (10)"
mklog "$d" watson 302 202606210840 "Error: Exceeded USD budget (10)"
expect "watson budget death (3 strikes) -> escalate" "ESCALATE" "$(run "$d" watson 302)"

# 11c. Streak-break boundary: the count is CONSECUTIVE-from-newest, so a clean run resets it. Three
#      budget kills total, but the streak from the newest is 1 -> DISPATCH. Three kills with no
#      break would escalate (11b), so this pins the reset itself, not merely the total.
d="$WORK/case11c"; mkdir -p "$d"
mklog "$d" watson 303 202606210800 "Error: Exceeded USD budget (10)"
mklog "$d" watson 303 202606210820 "Error: Exceeded USD budget (10)"
mklog "$d" watson 303 202606210840 "done: pushed 4 commits, CI green"
mklog "$d" watson 303 202606210900 "Error: Exceeded USD budget (10)"
expect "watson budget kills split by a clean run -> dispatch" "DISPATCH" "$(run "$d" watson 303)"

# 11d. The graceful wind-down must NEVER escalate: it does not write the harness kill signature, and
#      it is how multi-file work completes inside a per-run cap. Three of them in a row -> DISPATCH.
d="$WORK/case11d"; mkdir -p "$d"
mklog "$d" watson 304 202606210800 "Budget cap reached mid-issue. The PR stays a draft: 6 of 9 files done."
mklog "$d" watson 304 202606210820 "Budget cap reached mid-issue. The PR stays a draft: 8 of 9 files done."
mklog "$d" watson 304 202606210840 "Budget cap reached mid-issue. The PR stays a draft: 8 of 9 files done."
expect "watson graceful wind-downs -> dispatch (never escalate)" "DISPATCH" "$(run "$d" watson 304)"

# 11e. Holmes budget kill, but the DEV LANE logged a run on this item afterwards -> DISPATCH. Watson
#      regenerates Holmes's workload: a follow-up commit leaves the next review a small diff, not a
#      repeat of the job that died, so the "same wall" premise fails. Regression for item 575
#      (phpcs-rules#375), escalated on a log from a review round that had finished two hours earlier.
d="$WORK/case11e"; mkdir -p "$d"
mklog "$d" holmes 575 202608280815 "Error: Exceeded USD budget (7)"
mklog "$d" watson 575 202608281016 "Follow-up commit 856d018 pushed. PR ready for re-review."
expect "holmes budget death + newer watson run -> dispatch" "DISPATCH" "$(run "$d" holmes 575)"

# 11f. The same fixture with the watson log made OLDER than the kill -> ESCALATE. Pins the mtime
#      COMPARISON rather than the mere existence of a dev-lane log: without it, any item Watson had
#      ever touched would become permanently unescalatable.
d="$WORK/case11f"; mkdir -p "$d"
mklog "$d" watson 575 202608280700 "Implementation pushed. Moving to In Review."
mklog "$d" holmes 575 202608280815 "Error: Exceeded USD budget (7)"
expect "holmes budget death + older watson run -> escalate" "ESCALATE" "$(run "$d" holmes 575)"

# 11g. Lestrade is excluded from the exception -> ESCALATE even with a newer watson log. Triage runs
#      before any Watson does, so a newer dev-lane log cannot mean a triage item's workload changed.
d="$WORK/case11g"; mkdir -p "$d"
mklog "$d" lestrade 575 202608280815 "Error: Exceeded USD budget (7)"
mklog "$d" watson 575 202608281016 "Follow-up commit pushed."
expect "lestrade budget death + newer watson run -> escalate" "ESCALATE" "$(run "$d" lestrade 575)"

# 12. Marker also resets the generic strike count -> REPRIEVE (re-activation after ANY escalation type).
d="$WORK/case12"; mkdir -p "$d"
mklog "$d" holmes 99 202606210800 "API Error: 529 overloaded"
mklog "$d" holmes 99 202606210820 "API Error: 529 overloaded"
mklog "$d" holmes 99 202606210840 "API Error: 529 overloaded"
touch "$d/holmes-99.escalated"
expect "marker + 3 identical fatals -> reprieve (human override)" "REPRIEVE" "$(run "$d" holmes 99)"

# 13. A live in-flight run on this item -> SKIP (the race that let a second Holmes stomp the board).
#     $$ is this test's own pid — guaranteed alive.
d="$WORK/case13"; mkdir -p "$d"
mklog "$d" holmes 431 202606210800 "Review complete. Approved."
echo $$ > "$d/holmes-431.lock"
expect "live lock -> skip" "SKIP" "$(run "$d" holmes 431)"

# 14. Live lock beats every other verdict — an in-flight run is never escalated out from under itself.
d="$WORK/case14"; mkdir -p "$d"
mklog "$d" holmes 431 202606210800 "Error: Exceeded USD budget (7)"
echo $$ > "$d/holmes-431.lock"
expect "live lock + budget death -> skip (not escalate)" "SKIP" "$(run "$d" holmes 431)"

# 15. ...and beats the human-reactivation reprieve too: dispatching a reprieve alongside a live run
#     would duplicate it. The marker survives, so the reprieve is still there on the next tick.
d="$WORK/case15"; mkdir -p "$d"
mklog "$d" holmes 431 202606210800 "Error: Exceeded USD budget (7)"
touch "$d/holmes-431.escalated"
echo $$ > "$d/holmes-431.lock"
expect "live lock + reprieve marker -> skip (not reprieve)" "SKIP" "$(run "$d" holmes 431)"

# 16. Dead pid in the lock -> the item is free -> DISPATCH. A detached run that died (or finished)
#     never cleans up after itself, so a stale lock must never wedge the lane.
d="$WORK/case16"; mkdir -p "$d"
cb_dead=$$; while kill -0 "$cb_dead" 2>/dev/null; do cb_dead=$((cb_dead + 7717)); done   # find a pid nobody holds
mklog "$d" holmes 431 202606210800 "Review complete. Approved."
echo "$cb_dead" > "$d/holmes-431.lock"
expect "dead lock -> dispatch" "DISPATCH" "$(run "$d" holmes 431)"

# 17. Malformed lock (truncated write, garbage) -> treated as free -> DISPATCH, never a crash.
d="$WORK/case17"; mkdir -p "$d"
mklog "$d" holmes 431 202606210800 "Review complete. Approved."
printf 'not-a-pid\n' > "$d/holmes-431.lock"
expect "malformed lock -> dispatch" "DISPATCH" "$(run "$d" holmes 431)"

# 18. Empty lock file -> treated as free -> DISPATCH.
d="$WORK/case18"; mkdir -p "$d"
mklog "$d" holmes 431 202606210800 "Review complete. Approved."
: > "$d/holmes-431.lock"
expect "empty lock -> dispatch" "DISPATCH" "$(run "$d" holmes 431)"

# 18b. A lock holding `0` -> DISPATCH. `kill -0 0` signals the CALLER'S OWN process group and always
#      succeeds, so an unguarded check would read a truncated `0` as a live run and wedge the item forever.
d="$WORK/case18b"; mkdir -p "$d"
mklog "$d" holmes 431 202606210800 "Review complete. Approved."
printf '0\n' > "$d/holmes-431.lock"
expect "lock of 0 -> dispatch (not our own process group)" "DISPATCH" "$(run "$d" holmes 431)"

# 19. The lock is per ITEM, not per lane — a live run on item 431 must not hold item 432.
#     Parallel agents on different items are the point; the guard must not serialize the lane.
d="$WORK/case19"; mkdir -p "$d"
echo $$ > "$d/holmes-431.lock"
expect "other item's lock ignored -> dispatch" "DISPATCH" "$(run "$d" holmes 432)"

# 20. The lock is per AGENT too — Watson working item 431 must not block Holmes reviewing it later.
d="$WORK/case20"; mkdir -p "$d"
echo $$ > "$d/watson-431.lock"
expect "other agent's lock ignored -> dispatch" "DISPATCH" "$(run "$d" holmes 431)"

# 21. A permission refusal quotes the refused call, and the wrapper prints it just
# before the final result. A refused command that names a signature is not that
# signature, so a run that ended cleanly after one still dispatches.
d="$WORK/case21"; mkdir -p "$d"
mklog "$d" holmes 500 202606210800 'Permission denied: Bash {"command":"grep Exceeded USD budget run.log"} -- refused
Permission denied: Bash {"command":"echo content filtering policy"} -- refused
Review posted.'
expect "a refusal quoting a signature -> dispatch" "DISPATCH" "$(run "$d" holmes 500)"

# 22. ...while a real budget kill after refusals still escalates.
d="$WORK/case22"; mkdir -p "$d"
mklog "$d" holmes 501 202606210800 'Permission denied: Bash {"command":"git -C /x push origin main"} -- refused
Error: Exceeded USD budget'
expect "a budget kill after refusals -> escalate" "ESCALATE" "$(run "$d" holmes 501)"

echo
echo "Testing the verdicts on the dispatch path (stubbed claude):"
# A real dispatch, with `claude` and `security` stubbed on PATH, so each case
# proves what the script DOES with a verdict: spawn or not, and what it leaves
# on disk. The stub records its arguments, so a spawn is visible.
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/spawned"\n' "$WORK" > "$STUB/claude"
printf '#!/bin/sh\nexit 1\n' > "$STUB/security"
chmod +x "$STUB/claude" "$STUB/security"
CFG="$WORK/cfg.json"
printf '%s' '{"pluginConfigs":{"workbench-dev-team@claude-workbench":{"options":{"holmesMaxBudgetUsd":10,"watsonMaxBudgetUsd":10,"reprieveBudgetMultiplier":3}}}}' > "$CFG"
# dispatch <dir> <agent> <id> -> the script's output; spawns land in $WORK/spawned
dispatch() {
  rm -f "$WORK/spawned"
  LOGDIR="$1" DISPATCH_SETTINGS="$CFG" HOME="$WORK/home" PATH="$STUB:$PATH" \
    bash "$SCRIPT" "$2" "$3" 2>&1
  sleep 1   # the stub runs detached; give it time to record its spawn
}
spawned() { [ -s "$WORK/spawned" ] && echo yes || echo no; }

d="$WORK/path1"; mkdir -p "$d"
mklog "$d" watson 131 202606210800 "API Error: Output blocked by content filtering policy"
out=$(dispatch "$d" watson 131)
expect "ESCALATE is printed as the first line" "ESCALATE" "$out"
expect "...and nothing is spawned" "no" "$(spawned)"

d="$WORK/path2"; mkdir -p "$d"
echo $$ > "$d/holmes-431.lock"
out=$(dispatch "$d" holmes 431)
expect "SKIP is printed as the first line" "SKIP" "$out"
expect "...and nothing is spawned" "no" "$(spawned)"
expect "...and the live run's lock is left alone" "$$" "$(cat "$d/holmes-431.lock")"

d="$WORK/path3"; mkdir -p "$d"
mklog "$d" holmes 215 202606210800 "Error: Exceeded USD budget (10)"
touch "$d/holmes-215.escalated"
out=$(dispatch "$d" holmes 215)
expect "REPRIEVE is printed first" "REPRIEVE" "$out"
expect "...and the run is spawned" "yes" "$(spawned)"
case "$(cat "$WORK/spawned" 2>/dev/null)" in
  *"--max-budget-usd 30.00 "*) echo "  ok   — ...at the multiplied budget"; pass=$((pass+1)) ;;
  *) echo "  FAIL — the reprieve did not multiply the budget: $(cat "$WORK/spawned" 2>/dev/null)"; fail=$((fail+1)) ;;
esac
if [ -e "$d/holmes-215.escalated" ]; then
  echo "  FAIL — the reprieve marker survived its dispatch, so every tick would reprieve again"; fail=$((fail+1))
else
  echo "  ok   — ...and the marker is consumed, so the reprieve is one-shot"; pass=$((pass+1))
fi
# The fresh run's own (clean) log is now the newest, so the next tick reads it
# as an ordinary item. Before the fix the marker survived and this said REPRIEVE.
expect "the next check is an ordinary verdict, not a second reprieve" "DISPATCH" "$(run "$d" holmes 215)"

d="$WORK/path4"; mkdir -p "$d"
touch "$d/watson-77.escalated"
LOGDIR="$d" DISPATCH_SETTINGS="$CFG" DISPATCH_DRY_RUN=1 HOME="$WORK/home" bash "$SCRIPT" watson 77 >/dev/null 2>&1
if [ -e "$d/watson-77.escalated" ]; then
  echo "  ok   — a dry run consumes no marker"; pass=$((pass+1))
else
  echo "  FAIL — a dry run consumed the reprieve marker"; fail=$((fail+1))
fi

d="$WORK/path5"; mkdir -p "$d"
out=$(LOGDIR="$d" HOME="$WORK/home" bash "$SCRIPT" --mark-escalated holmes 88)
expect "--mark-escalated reports the marker" "marked holmes-88 escalated" "$out"
expect "...and the next check is a reprieve" "REPRIEVE" "$(run "$d" holmes 88)"
LOGDIR="$d" HOME="$WORK/home" bash "$SCRIPT" --mark-escalated lestrade owner/repo >/dev/null 2>&1
expect "--mark-escalated refuses a sweep target" "2" "$?"
LOGDIR="$d" HOME="$WORK/home" bash "$SCRIPT" --check watson abc >/dev/null 2>&1
expect "--check refuses a non-numeric id" "2" "$?"

echo
echo "circuit-breaker: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
