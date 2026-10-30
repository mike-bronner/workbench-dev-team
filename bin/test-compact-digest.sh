#!/usr/bin/env bash
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/dispatch-agent.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not found"; exit 1
fi

mkdir -p "$WORK/home"
export HOME="$WORK/home"
unset WORKBENCH_MEMORY_PATH

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1: $2"; fail=$((fail+1)); }
expect_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2' got '$3'"; fi; }
expect_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain '$2', got: $3" ;; esac; }
expect_lacks() { case "$3" in *"$2"*) bad "$1" "expected NOT to contain '$2', got: $3" ;; *) ok "$1" ;; esac; }
expect_le()    { if [ "$3" -le "$2" ]; then ok "$1"; else bad "$1" "expected at most $2, got $3"; fi; }

size_of() { wc -c < "$1" | tr -d ' '; }

mkdigest() {
  local file="$1" k=0 spec name tally bytes events; shift
  mkdir -p "$(dirname "$file")"
  {
    printf -- '---\nname: Dev-Team Top Review Lessons\ntype: reference\n---\n\n'
    printf '# Top Review Lessons — read before coding or triaging\n\n**Clean first-pass approvals:** 99\n\n'
    printf '## The meta-rule\n\nFixing the reported instance is not evidence the class was swept.\n\n---\n\n'
    for spec in "$@"; do
      IFS=: read -r name tally bytes <<< "$spec"
      k=$((k + 1))
      if [ "$tally" = 1 ]; then events='1 event'; else events="$tally events"; fi
      printf '## %s. %s — %s\n\n' "$k" "$name" "$events"
      printf -- '- rule for %s %s\n\n' "$name" "$(head -c "$bytes" < /dev/zero | tr '\0' x)"
    done
    [ -z "${EXTRA:-}" ] || printf '%s\n\n' "$EXTRA"
    printf -- '---\n\n## Maintaining this digest\n\nRules, not history.\n'
  } > "$file"
}

mkdigest_at() {
  local file="$1" target="$2" last name tally bytes; shift 2
  mkdigest "$file" "$@"
  last="${*: -1}"
  IFS=: read -r name tally bytes <<< "$last"
  bytes=$((bytes + target - $(size_of "$file")))
  set -- "${@:1:$#-1}" "$name:$tally:$bytes"
  mkdigest "$file" "$@"
}

compact() { WORKBENCH_MEMORY_PATH="$1" bash "$SCRIPT" --compact-digest 2>&1; }
digest() { printf '%s/dev-team/top-lessons.md' "$1"; }

echo "Testing the top-lessons digest ceiling ($SCRIPT):"

echo "— no digest, or one within the ceiling, is left alone"
V="$WORK/absent"
out=$(compact "$V"); rc=$?
expect_eq "an absent digest exits 0" 0 "$rc"
expect_eq "...prints nothing" "" "$out"
expect_eq "...and creates nothing" absent "$([ -e "$V" ] && echo present || echo absent)"

V="$WORK/under"; mkdigest "$(digest "$V")" a:5:2000 b:3:2000
cp "$(digest "$V")" "$WORK/under.orig"
out=$(compact "$V"); rc=$?
expect_eq "a digest under the ceiling exits 0" 0 "$rc"
expect_eq "...prints nothing" "" "$out"
expect_eq "...and is byte-identical" same "$(cmp -s "$WORK/under.orig" "$(digest "$V")" && echo same || echo changed)"

V="$WORK/at"; mkdigest_at "$(digest "$V")" 15000 a:5:9000 b:3:5000
cp "$(digest "$V")" "$WORK/at.orig"
expect_eq "the at-ceiling fixture is 15000 bytes" 15000 "$(size_of "$(digest "$V")")"
out=$(compact "$V")
expect_eq "a digest at exactly the ceiling is left alone" same "$(cmp -s "$WORK/at.orig" "$(digest "$V")" && echo same || echo changed)"

V="$WORK/nonl"; mkdigest_at "$(digest "$V")" 15001 a:5:9000 b:3:5000
head -c 15000 "$WORK/nonl/dev-team/top-lessons.md" > "$WORK/nonl.orig"
cp "$WORK/nonl.orig" "$(digest "$V")"
out=$(compact "$V")
expect_eq "a 15000-byte digest with no final newline is measured as wc -c measures it" same \
  "$(cmp -s "$WORK/nonl.orig" "$(digest "$V")" && echo same || echo changed)"

V="$WORK/past"; mkdigest_at "$(digest "$V")" 15001 a:5:9000 b:3:5000
out=$(compact "$V"); rc=$?
expect_eq "one byte past the ceiling compacts, and exits 0" 0 "$rc"
expect_has "...and says so" "DIGEST	compacted" "$out"
expect_has "...with the size wc -c measured" "from 15001 to " "$out"
expect_le "...to at most the ceiling" 15000 "$(size_of "$(digest "$V")")"

echo "— over the ceiling, the least-cited lessons leave and keep their tallies"
V="$WORK/over"; F=$(digest "$V")
mkdigest "$F" correctness:~108:6000 test-honesty:89:5000 nitpick:13:3000 escalation:9:2500 external-ci-blocker:1:500
grep '^- rule for correctness\|^- rule for test-honesty\|^- rule for nitpick' "$F" > "$WORK/over.kept"
expect_le "the fixture starts over the ceiling" "$(size_of "$F")" 15001
out=$(compact "$V"); rc=$?
expect_eq "compaction exits 0" 0 "$rc"
expect_le "the digest ends at or under the ceiling" 15000 "$(size_of "$F")"
expect_has "the report names what moved, least-cited first" \
  "Moved to the compacted-out line with their tallies: external-ci-blocker (1), escalation (9)." "$out"
expect_eq "the most-cited lessons keep their headings and tallies" \
  "## 1. correctness — ~108 events|## 2. test-honesty — 89 events|## 3. nitpick — 13 events" \
  "$(grep '^## [0-9]' "$F" | paste -sd'|' -)"
expect_eq "...and their rule text, byte for byte" same \
  "$(grep '^- rule for correctness\|^- rule for test-honesty\|^- rule for nitpick' "$F" | cmp -s - "$WORK/over.kept" && echo same || echo changed)"
expect_eq "the dropped lessons' tallies sit on one compacted-out line" \
  "**Compacted out (tally kept, rules dropped; events in dev-team/review-learnings/):** external-ci-blocker — 1 event; escalation — 9 events" \
  "$(grep '^\*\*Compacted out' "$F")"
expect_lacks "the dropped lessons' rule text is gone" "rule for escalation" "$(cat "$F")"
expect_has "the clean-approval count is carried through" "**Clean first-pass approvals:** 99" "$(cat "$F")"
expect_has "the meta-rule is carried through" "## The meta-rule" "$(cat "$F")"
expect_has "the maintenance section is carried through" "## Maintaining this digest" "$(cat "$F")"
c=$(grep -n '^\*\*Compacted out' "$F" | cut -d: -f1); r=$(grep -n '^---$' "$F" | tail -1 | cut -d: -f1)
l=$(grep -n '^## [0-9]' "$F" | tail -1 | cut -d: -f1)
expect_eq "the compacted-out line sits after the ranked list, before its closing rule" yes \
  "$([ "${l:-0}" -lt "${c:-0}" ] && [ "${c:-0}" -lt "${r:-0}" ] && echo yes || echo no)"
expect_eq "no temporary file is left beside the digest" "top-lessons.md" "$(ls -A "$V/dev-team")"
out=$(compact "$V")
expect_eq "a second run finds nothing to do" "" "$out"

echo "— the lowest tally goes first wherever it sits, and a tie drops the later lesson"
V="$WORK/middle"; F=$(digest "$V")
mkdigest "$F" a:50:6000 low:2:4000 c:40:6000
compact "$V" >/dev/null
expect_eq "the middle lesson leaves and the rest are renumbered" "## 1. a — 50 events|## 2. c — 40 events" \
  "$(grep '^## [0-9]' "$F" | paste -sd'|' -)"

V="$WORK/tie"; F=$(digest "$V")
mkdigest "$F" a:10:6000 b:5:5000 c:5:4500
compact "$V" >/dev/null
expect_eq "of two equal tallies the later one leaves" "## 1. a — 10 events|## 2. b — 5 events" \
  "$(grep '^## [0-9]' "$F" | paste -sd'|' -)"

echo "— an earlier compacted-out line is extended, never replaced"
V="$WORK/again"; F=$(digest "$V")
EXTRA='**Compacted out (tally kept, rules dropped; events in dev-team/review-learnings/):** old-cat — 3 events' \
  mkdigest "$F" a:50:7000 b:20:6000 c:4:3000
compact "$V" >/dev/null
expect_eq "the earlier entry keeps its tally and the new one joins it" \
  "**Compacted out (tally kept, rules dropped; events in dev-team/review-learnings/):** old-cat — 3 events; c — 4 events" \
  "$(grep '^\*\*Compacted out' "$F")"
expect_eq "...on one line" 1 "$(grep -c '^\*\*Compacted out' "$F")"
expect_le "...and the digest is at or under the ceiling" 15000 "$(size_of "$F")"

echo "— when compaction cannot bring it under, nothing is written and the failure is reported"
V="$WORK/stuck"; F=$(digest "$V")
mkdigest "$F" big:50:16000 small:1:100
cp "$F" "$WORK/stuck.orig"
out=$(compact "$V"); rc=$?
expect_eq "it exits 1" 1 "$rc"
expect_has "it prints a warning" "DIGEST	⚠️ " "$out"
expect_has "...that says compaction cannot bring it under" "compaction cannot bring it under" "$out"
expect_has "...and that Holmes writes a count bump only" "Holmes writes a count bump only until someone consolidates the digest by hand." "$out"
expect_eq "the digest is byte-identical" same "$(cmp -s "$WORK/stuck.orig" "$F" && echo same || echo changed)"
expect_eq "no temporary file is left beside the digest" "top-lessons.md" "$(ls -A "$V/dev-team")"

V="$WORK/shapeless"; F="$(digest "$V")"; mkdir -p "$V/dev-team"
head -c 16000 < /dev/zero | tr '\0' x > "$F"
cp "$F" "$WORK/shapeless.orig"
out=$(compact "$V"); rc=$?
expect_eq "an over-ceiling digest with no ranked lessons exits 1" 1 "$rc"
expect_has "...with a warning" "DIGEST	⚠️ " "$out"
expect_eq "...and is unchanged" same "$(cmp -s "$WORK/shapeless.orig" "$F" && echo same || echo changed)"

V="$WORK/locked"; F=$(digest "$V")
mkdigest "$F" a:50:9000 b:5:7000
cp "$F" "$WORK/locked.orig"
chmod 555 "$V/dev-team"
out=$(compact "$V"); rc=$?
chmod 755 "$V/dev-team"
expect_eq "an over-ceiling digest whose folder cannot be written exits 1" 1 "$rc"
expect_has "...with a warning" "DIGEST	⚠️ " "$out"
expect_eq "...and is unchanged" same "$(cmp -s "$WORK/locked.orig" "$F" && echo same || echo changed)"

V="$WORK/locked-under"; mkdigest "$(digest "$V")" a:5:2000
chmod 555 "$V/dev-team"
out=$(compact "$V"); rc=$?
chmod 755 "$V/dev-team"
expect_eq "a digest within the ceiling needs no write, so a read-only folder passes" 0 "$rc"
expect_eq "...silently" "" "$out"

V="$WORK/nomv"; F=$(digest "$V")
mkdigest "$F" a:50:9000 b:5:7000
cp "$F" "$WORK/nomv.orig"
mkdir -p "$WORK/mvstub"; printf '#!/bin/sh\nexit 1\n' > "$WORK/mvstub/mv"; chmod +x "$WORK/mvstub/mv"
out=$(PATH="$WORK/mvstub:$PATH" compact "$V"); rc=$?
expect_eq "a compacted copy that cannot replace the digest exits 1" 1 "$rc"
expect_has "...with a warning that says so" "the compacted copy could not replace it" "$out"
expect_has "...that names count bump only" "Holmes writes a count bump only" "$out"
expect_eq "...the digest is unchanged" same "$(cmp -s "$WORK/nomv.orig" "$F" && echo same || echo changed)"
expect_eq "...and no temporary file is left beside it" "top-lessons.md" "$(ls -A "$V/dev-team")"

echo "— the drop loop counts the compacted-out line it is about to write"
mkdigest "$WORK/m1.md" a:50:6000 c:5:500 b:20:6000
mkdigest "$WORK/m2.md" a:50:6000 b:20:6000
sec_c=$(( $(size_of "$WORK/m1.md") - $(size_of "$WORK/m2.md") ))
V="$WORK/header"; F=$(digest "$V")
mkdigest_at "$F" $((15000 - 40 + sec_c - 13)) a:50:6000 c:5:500 b:20:6000
out=$(compact "$V"); rc=$?
expect_eq "a first drop that lands 40 bytes under before the header goes on, and exits 0" 0 "$rc"
expect_le "...ends at or under the ceiling" 15000 "$(size_of "$F")"
expect_eq "...with both dropped lessons on the compacted-out line" \
  "**Compacted out (tally kept, rules dropped; events in dev-team/review-learnings/):** c — 5 events; b — 20 events" \
  "$(grep '^\*\*Compacted out' "$F")"

echo "— a ~ tally keeps its marker"
V="$WORK/approx"; F=$(digest "$V")
mkdigest "$F" a:50:9000 b:~3:7000
out=$(compact "$V")
expect_eq "the dropped entry is written exactly as its heading counted it" \
  "**Compacted out (tally kept, rules dropped; events in dev-team/review-learnings/):** b — ~3 events" \
  "$(grep '^\*\*Compacted out' "$F")"
expect_has "...and the report keeps it too" "tallies: b (~3)." "$out"

echo "— the digest keeps its file mode"
V="$WORK/mode"; F=$(digest "$V")
mkdigest "$F" a:50:9000 b:5:7000
chmod 600 "$F"
compact "$V" >/dev/null
expect_eq "a 600 digest is compacted" "b — 5 events" "$(grep '^\*\*Compacted out' "$F" | sed 's/.*:\*\* //')"
expect_eq "...and stays 600" "-rw-------" "$(ls -l "$F" | cut -c1-10)"
V="$WORK/mode644"; F=$(digest "$V")
mkdigest "$F" a:50:9000 b:5:7000
chmod 644 "$F"
compact "$V" >/dev/null
expect_eq "a 644 digest stays 644" "-rw-r--r--" "$(ls -l "$F" | cut -c1-10)"

echo "— a change during compaction is never overwritten"
mkdir -p "$WORK/cmpstub"
printf '%s\n' '#!/bin/sh' \
  'n=$(cat "$CMP_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CMP_COUNT"' \
  'if [ "$n" -le "${CMP_TOUCH:-0}" ]; then printf "%s\n" "- concurrent edit $n" >> "$3"; fi' \
  'exec /usr/bin/cmp "$@"' > "$WORK/cmpstub/cmp"
chmod +x "$WORK/cmpstub/cmp"

V="$WORK/race1"; F=$(digest "$V")
mkdigest "$F" a:50:9000 b:5:7000
out=$(PATH="$WORK/cmpstub:$PATH" CMP_COUNT="$WORK/race1.n" CMP_TOUCH=1 compact "$V"); rc=$?
expect_eq "one change during compaction is retried, and exits 0" 0 "$rc"
expect_eq "...after two attempts" 2 "$(cat "$WORK/race1.n")"
expect_has "...and the compacted digest keeps the change" "- concurrent edit 1" "$(cat "$F")"
expect_le "...at or under the ceiling" 15000 "$(size_of "$F")"
expect_eq "...and no temporary file is left beside it" "top-lessons.md" "$(ls -A "$V/dev-team")"

V="$WORK/race2"; F=$(digest "$V")
mkdigest "$F" a:50:9000 b:5:7000
out=$(PATH="$WORK/cmpstub:$PATH" CMP_COUNT="$WORK/race2.n" CMP_TOUCH=2 compact "$V"); rc=$?
expect_eq "a change during both attempts exits 1" 1 "$rc"
expect_has "...with a warning that says so" "it changed during both compaction attempts" "$out"
expect_has "...the digest keeps both changes" "- concurrent edit 2" "$(cat "$F")"
expect_has "...and is not compacted" "## 2. b — 5 events" "$(cat "$F")"
expect_eq "...and no temporary file is left beside it" "top-lessons.md" "$(ls -A "$V/dev-team")"

echo "— the usage names the mode"
expect_has "a bad argument prints --compact-digest in the usage" "--compact-digest" "$(bash "$SCRIPT" bogus 2>&1)"

echo "— the vault is found as workbench-core finds it"
CORE_CFG="$HOME/.claude/plugins/data/workbench-core-claude-workbench/config.json"
mkdir -p "$(dirname "$CORE_CFG")"
V="$WORK/configured"; mkdigest "$(digest "$V")" a:50:9000 b:5:7000
printf '{"memory_path": "%s"}\n' "$V" > "$CORE_CFG"
out=$(bash "$SCRIPT" --compact-digest 2>&1)
expect_has "the memory_path in core's config.json names the vault" "$V/dev-team/top-lessons.md" "$out"
rm -f "$CORE_CFG"
V="$HOME/Documents/Claude/Memory"; mkdigest "$(digest "$V")" a:50:9000 b:5:7000
out=$(bash "$SCRIPT" --compact-digest 2>&1)
expect_has "without either, the vault is ~/Documents/Claude/Memory" "$V/dev-team/top-lessons.md" "$out"

echo "— a Holmes dispatch holds the digest at its ceiling before the run starts"
STUB="$WORK/stub"; mkdir -p "$STUB" "$WORK/caller"
printf '#!/bin/sh\nexit 1\n' > "$STUB/security"
printf '%s\n' '#!/bin/sh' \
  'wc -c < "$STUB_DIGEST" | tr -d " " > "$STUB_OUT.part"' \
  'mv "$STUB_OUT.part" "$STUB_OUT"' \
  'echo "stub ran"' > "$STUB/claude"
chmod +x "$STUB/security" "$STUB/claude"
dispatch() {
  (cd "$WORK/caller" && env -u WORKBENCH_DEV_TEAM_PIPELINE PATH="$STUB:$PATH" WORKBENCH_MEMORY_PATH="$1" \
    STUB_DIGEST="$(digest "$1")" STUB_OUT="$WORK/stub-$3" DISPATCH_SETTINGS="$WORK/none.json" \
    LOGDIR="$WORK/logs" RUNROOT="$WORK/runs" bash "$SCRIPT" "$2" "$3" 2>&1)
}
wait_for() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done; }
log_settled() { local i=0; while ! grep -q "$2" "$1" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done; }

V="$WORK/d-over"; mkdigest "$(digest "$V")" a:50:9000 b:5:7000
out=$(dispatch "$V" holmes 31); wait_for "$WORK/stub-31"
expect_le "the Holmes run starts with the digest at or under the ceiling" 15000 "$(cat "$WORK/stub-31" 2>/dev/null || echo 99999)"
expect_eq "the first line is still the dispatched line" dispatched "$(printf '%s\n' "$out" | sed -n 1p | cut -d' ' -f1)"
expect_has "a DIGEST line follows it" "DIGEST	compacted" "$(printf '%s\n' "$out" | sed -n 2p)"

V="$WORK/d-stuck"; mkdigest "$(digest "$V")" big:50:16000 small:1:100
cp "$(digest "$V")" "$WORK/d-stuck.orig"
out=$(dispatch "$V" holmes 32); wait_for "$WORK/stub-32"
expect_eq "a digest that cannot come under still lets the run start" "dispatched" "$(printf '%s\n' "$out" | sed -n 1p | cut -d' ' -f1)"
expect_has "...and the dispatcher prints the warning after it" "DIGEST	⚠️ " "$(printf '%s\n' "$out" | sed -n 2p)"
LOG=$(ls "$WORK/logs/holmes-32-"*.log 2>/dev/null | head -1)
log_settled "$LOG" "DIGEST"
expect_has "...and the warning is the last line of the run's log" "DIGEST	⚠️ " "$(tail -1 "$LOG" 2>/dev/null)"
ran_at=$(grep -n 'stub ran' "$LOG" 2>/dev/null | cut -d: -f1); warned_at=$(grep -n '^DIGEST' "$LOG" 2>/dev/null | cut -d: -f1)
expect_eq "...after the run's own output" yes "$([ "${ran_at:-0}" -gt 0 ] && [ "${ran_at:-0}" -lt "${warned_at:-0}" ] && echo yes || echo no)"
expect_eq "...once" 1 "$(grep -c '^DIGEST' "$LOG" 2>/dev/null)"
expect_eq "...and the digest is unchanged" same "$(cmp -s "$WORK/d-stuck.orig" "$(digest "$V")" && echo same || echo changed)"

V="$WORK/d-under"; mkdigest "$(digest "$V")" a:5:2000
out=$(dispatch "$V" holmes 33); wait_for "$WORK/stub-33"
expect_eq "a digest within the ceiling adds no DIGEST line" "" "$(printf '%s\n' "$out" | sed -n 2p)"
LOG=$(ls "$WORK/logs/holmes-33-"*.log 2>/dev/null | head -1)
log_settled "$LOG" "Error: No messages"
expect_eq "...and the run's log holds no DIGEST line" 0 "$(grep -c '^DIGEST' "$LOG" 2>/dev/null)"

V="$WORK/d-watson"; mkdigest "$(digest "$V")" a:50:9000 b:5:7000
cp "$(digest "$V")" "$WORK/d-watson.orig"
out=$(dispatch "$V" watson 34); wait_for "$WORK/stub-34"
expect_eq "a Watson dispatch leaves the digest alone" same "$(cmp -s "$WORK/d-watson.orig" "$(digest "$V")" && echo same || echo changed)"
expect_lacks "...and prints no DIGEST line" "DIGEST" "$out"

out=$(cd "$WORK/caller" && WORKBENCH_MEMORY_PATH="$V" DISPATCH_DRY_RUN=1 DISPATCH_SETTINGS="$WORK/none.json" \
  LOGDIR="$WORK/logs" bash "$SCRIPT" holmes 35 2>&1)
expect_eq "a Holmes dry run leaves the digest alone" same "$(cmp -s "$WORK/d-watson.orig" "$(digest "$V")" && echo same || echo changed)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
