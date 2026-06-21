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

# 2. Single content-filter failure -> ESCALATE on first hit (deterministic)
d="$WORK/case2"; mkdir -p "$d"
mklog "$d" watson 131 202606210800 "API Error: Output blocked by content filtering policy"
expect "content filter (1 strike) -> escalate" "ESCALATE" "$(run "$d" watson 131)"

# 3. Successful last run -> DISPATCH
d="$WORK/case3"; mkdir -p "$d"
mklog "$d" holmes 200 202606210800 "Review complete. Approved PR #5. Done."
expect "success -> dispatch" "DISPATCH" "$(run "$d" holmes 200)"

# 4. One generic fatal, below strike threshold -> DISPATCH (let it retry)
d="$WORK/case4"; mkdir -p "$d"
mklog "$d" watson 99 202606210800 "API Error: 529 overloaded"
expect "1 transient fatal -> dispatch (retry)" "DISPATCH" "$(run "$d" watson 99)"

# 5. Three consecutive identical generic fatals -> ESCALATE
d="$WORK/case5"; mkdir -p "$d"
mklog "$d" watson 99 202606210800 "API Error: 529 overloaded"
mklog "$d" watson 99 202606210820 "API Error: 529 overloaded"
mklog "$d" watson 99 202606210840 "API Error: 529 overloaded"
expect "3 identical fatals -> escalate" "ESCALATE" "$(run "$d" watson 99)"

# 6. Latest fatal but streak broken by an earlier success -> DISPATCH
d="$WORK/case6"; mkdir -p "$d"
mklog "$d" watson 99 202606210800 "All good. PR opened."
mklog "$d" watson 99 202606210820 "API Error: 529 overloaded"
expect "broken streak -> dispatch" "DISPATCH" "$(run "$d" watson 99)"

# 7. Logs for a different item id must not bleed in -> DISPATCH
d="$WORK/case7"; mkdir -p "$d"
mklog "$d" watson 131 202606210800 "API Error: Output blocked by content filtering policy"
expect "other item's logs ignored -> dispatch" "DISPATCH" "$(run "$d" watson 777)"

echo
echo "circuit-breaker: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
