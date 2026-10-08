#!/usr/bin/env bash
# Test for bin/scan-run-logs.awk, the dev-team mod's runs-pane log reader.
# Runs the real program on fixture logs and pins its output, the format
# hooks/mods/runs.ts endsOf parses (tests/panes.test.ts holds that side).
#
# Run: bash bin/test-scan-run-logs.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
AWK="$HERE/scan-run-logs.awk"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

RS=$(printf '\036')

printf '%s\n' 'started' 'Permission denied: Bash {"command":"git push"} -- refused' 'working' 'more work' \
  'Permission denied: Write {"file_path":"/x"} -- refused' 'Error: Exceeded USD budget' > "$WORK/watson-42-20261008-101500.log"
printf '%s\n' 'one line' > "$WORK/holmes-7-20261008-101000.log"
: > "$WORK/lestrade-9-20261008-100000.log"
printf '%s\n' 'a' 'b' 'c' 'd' 'e' > "$WORK/lestrade-sweep-o-r-20261008-090000.log"

echo "— one pass over four logs"
OUT=$(awk -f "$AWK" "$WORK/watson-42-20261008-101500.log" "$WORK/holmes-7-20261008-101000.log" \
  "$WORK/lestrade-9-20261008-100000.log" "$WORK/lestrade-sweep-o-r-20261008-090000.log")
expect_eq "headers, refusal counts and the last three other lines, file by file, an empty log's header last" \
"${RS}2	$WORK/watson-42-20261008-101500.log
working
more work
Error: Exceeded USD budget
${RS}0	$WORK/holmes-7-20261008-101000.log
one line
${RS}0	$WORK/lestrade-sweep-o-r-20261008-090000.log
c
d
e
${RS}0	$WORK/lestrade-9-20261008-100000.log" "$OUT"

echo "— a log whose last lines are refusals"
printf '%s\n' 'done: the work is in review' 'Permission denied: Bash {"command":"Exceeded USD budget"} -- refused' > "$WORK/watson-5-20261008-110000.log"
OUT=$(awk -f "$AWK" "$WORK/watson-5-20261008-110000.log")
expect_eq "a refusal that quotes a signature is counted, never read as the end" \
"${RS}1	$WORK/watson-5-20261008-110000.log
done: the work is in review" "$OUT"

echo "— a log deleted between the listing and the scan"
OUT=$(awk -f "$AWK" "$WORK/holmes-7-20261008-101000.log" "$WORK/missing.log" "$WORK/watson-5-20261008-110000.log" 2>"$WORK/err")
RC=$?
expect_eq "exits 0" 0 "$RC"
expect_eq "says nothing on stderr" "" "$(cat "$WORK/err")"
expect_eq "skips it with no header, and reads the others" \
"${RS}0	$WORK/holmes-7-20261008-101000.log
one line
${RS}1	$WORK/watson-5-20261008-110000.log
done: the work is in review" "$OUT"

echo "— it writes nothing"
BEFORE=$(ls -la "$WORK")
awk -f "$AWK" "$WORK"/*.log >/dev/null
expect_eq "the fixture folder is unchanged" "$BEFORE" "$(ls -la "$WORK")"

echo
echo "scan-run-logs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
