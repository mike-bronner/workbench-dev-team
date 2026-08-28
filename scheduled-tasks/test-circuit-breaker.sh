#!/usr/bin/env bash
# Test for the Dispatch circuit-breaker pre-flight.
#
# It extracts the *real* pre-flight snippet from orchestrator.md (the block
# between the `circuit-breaker-preflight` sentinel markers) and runs it against
# fixture log directories, so the test can never drift from the shipped logic.
#
# Run: bash scheduled-tasks/test-circuit-breaker.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/orchestrator.md"
SNIPPET=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -rf "$SNIPPET" "$WORK"' EXIT

# Pull the snippet out from between the markers (exclusive of the marker lines).
awk '/# >>> circuit-breaker-preflight >>>/{f=1;next} /# <<< circuit-breaker-preflight <<</{f=0} f' \
  "$SRC" > "$SNIPPET"
if [ ! -s "$SNIPPET" ]; then
  echo "FAIL: could not extract circuit-breaker-preflight block from $SRC"; exit 1
fi

pass=0; fail=0
# mklog <dir> <agent> <id> <stamp YYYYMMDDhhmm> <content...>
mklog() {
  local dir="$1" agent="$2" id="$3" stamp="$4"; shift 4
  printf '%s\n' "$*" > "$dir/$agent-$id-$stamp.log"
  touch -t "$stamp" "$dir/$agent-$id-$stamp.log"   # deterministic mtime for ls -t ordering
}
# run <dir> <agent> <id> -> echoes the pre-flight verdict
run() { LOGDIR="$1" AGENT="$2" ID="$3" bash "$SNIPPET"; }
# expect <name> <expected-prefix> <actual>
expect() {
  case "$3" in
    "$2"*) echo "  ok   — $1"; pass=$((pass+1)) ;;
    *)     echo "  FAIL — $1: expected '$2…' got '$3'"; fail=$((fail+1)) ;;
  esac
}

echo "Testing circuit-breaker pre-flight ($SNIPPET):"

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

echo
echo "circuit-breaker: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
