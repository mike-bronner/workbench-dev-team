#!/usr/bin/env bash
# Test for the Dispatch daily harvest gate.
#
# It extracts the *real* gate snippet from orchestrator.md (the block between the
# `harvest-gate` sentinel markers) and runs it against fixture log directories, so
# the test can never drift from the shipped logic.
#
# Run: bash scheduled-tasks/test-harvest-gate.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/orchestrator.md"
SNIPPET=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -rf "$SNIPPET" "$WORK"' EXIT

# Pull the snippet out from between the markers (exclusive of the marker lines).
awk '/# >>> harvest-gate >>>/{f=1;next} /# <<< harvest-gate <<</{f=0} f' \
  "$SRC" > "$SNIPPET"
if [ ! -s "$SNIPPET" ]; then
  echo "FAIL: could not extract harvest-gate block from $SRC"; exit 1
fi

pass=0; fail=0
# run <dir> [interval-hours] -> echoes the gate verdict
run() { LOGDIR="$1" HARVEST_MIN_INTERVAL_HOURS="${2:-}" bash "$SNIPPET"; }
# stamp <dir> <YYYYMMDDhhmm> -> writes .last-harvest with that mtime
stamp() { touch "$1/.last-harvest"; touch -t "$2" "$1/.last-harvest"; }
# a deterministic "hours ago" stamp string for `touch -t` (portable: compute via perl)
ago() { perl -e 'use POSIX; print strftime("%Y%m%d%H%M", localtime(time - ($ARGV[0]*3600)))' "$1"; }
expect() {
  case "$3" in
    "$2") echo "  ok   — $1"; pass=$((pass+1)) ;;
    *)    echo "  FAIL — $1: expected '$2' got '$3'"; fail=$((fail+1)) ;;
  esac
}

echo "Testing harvest gate ($SNIPPET):"

# 1. No prior harvest (no stamp file) -> HARVEST (first run backfills).
d="$WORK/case1"; mkdir -p "$d"
expect "no stamp -> harvest" "HARVEST" "$(run "$d")"

# 2. Harvested 1h ago, default 24h interval -> SKIP.
d="$WORK/case2"; mkdir -p "$d"; stamp "$d" "$(ago 1)"
expect "1h ago (24h interval) -> skip" "SKIP" "$(run "$d")"

# 3. Harvested 25h ago, default 24h interval -> HARVEST.
d="$WORK/case3"; mkdir -p "$d"; stamp "$d" "$(ago 25)"
expect "25h ago (24h interval) -> harvest" "HARVEST" "$(run "$d")"

# 4. Harvested exactly at the boundary (>= interval is HARVEST) -> HARVEST.
#    Use 24h + a slack minute to avoid a sub-second race at exactly 86400s.
d="$WORK/case4"; mkdir -p "$d"; stamp "$d" "$(ago 24)"
expect "24h+ ago (>= boundary) -> harvest" "HARVEST" "$(run "$d")"

# 5. Config override: 1h interval, harvested 2h ago -> HARVEST (custom cadence honored).
d="$WORK/case5"; mkdir -p "$d"; stamp "$d" "$(ago 2)"
expect "2h ago (1h interval override) -> harvest" "HARVEST" "$(run "$d" 1)"

# 6. Config override: 48h interval, harvested 25h ago -> SKIP (longer cadence honored).
d="$WORK/case6"; mkdir -p "$d"; stamp "$d" "$(ago 25)"
expect "25h ago (48h interval override) -> skip" "SKIP" "$(run "$d" 48)"

# 7. Non-numeric interval falls back to the 24h default -> SKIP at 1h ago.
d="$WORK/case7"; mkdir -p "$d"; stamp "$d" "$(ago 1)"
expect "garbage interval -> default 24h -> skip at 1h" "SKIP" "$(run "$d" "abc")"

echo
echo "harvest-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
