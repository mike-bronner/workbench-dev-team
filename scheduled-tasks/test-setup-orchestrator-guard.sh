#!/usr/bin/env bash
# Test for the Step 7a-bis orchestrator-body guard in commands/setup.md.
#
# It extracts the *real* guard snippet from setup.md (the block between the
# `orchestrator-body-guard` sentinel markers) and runs it against fixture
# orchestrator files, so the test can never drift from the shipped logic.
#
# The guard exists because resolving the right PATH (Step 7a) does not
# guarantee good CONTENT: 7a accepts any candidate root where orchestrator.md
# merely EXISTS, so a truncated, half-written, or wrong file passes unchallenged.
# These cases assert the guard rejects every degraded body rather than deploying it.
#
# The guard's lane checks are DERIVED (counts of dispatched lanes and of lanes
# writing a per-item in-flight lock), not a list of agent names — so these
# fixtures break the counts rather than deleting named markers.
#
# Run: bash scheduled-tasks/test-setup-orchestrator-guard.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SRC="$REPO/commands/setup.md"
REAL="$HERE/orchestrator.md"
SNIPPET=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -rf "$SNIPPET" "$WORK"' EXIT

# Pull the snippet out from between the markers (exclusive of the marker lines).
awk '/# >>> orchestrator-body-guard >>>/{f=1;next} /# <<< orchestrator-body-guard <<</{f=0} f' \
  "$SRC" > "$SNIPPET"
if [ ! -s "$SNIPPET" ]; then
  echo "FAIL: could not extract orchestrator-body-guard block from $SRC"; exit 1
fi
if [ ! -f "$REAL" ]; then
  echo "FAIL: missing $REAL"; exit 1
fi

pass=0; fail=0

# run <src-path> -> prints output; returns the guard's exit status
run() { ORCHESTRATOR_SRC="$1" BODY_OUT="$WORK/body.out" bash "$SNIPPET" 2>&1; }

expect_pass() { # <name> <src>
  local out; out=$(run "$2"); local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ok   — $1"; pass=$((pass+1))
  else
    echo "  FAIL — $1: expected accept, got exit $rc: $(printf '%s' "$out" | tr '\n' ' ')"; fail=$((fail+1))
  fi
}

expect_reject() { # <name> <src> <expected-substring-in-output>
  local out; out=$(run "$2"); local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  FAIL — $1: expected reject, guard ACCEPTED it"; fail=$((fail+1))
  elif printf '%s' "$out" | grep -qF -- "$3"; then
    echo "  ok   — $1"; pass=$((pass+1))
  else
    echo "  FAIL — $1: rejected, but not for '$3': $(printf '%s' "$out" | tr '\n' ' ')"; fail=$((fail+1))
  fi
}

echo "Testing orchestrator-body guard ($SNIPPET):"

# --- happy path -------------------------------------------------------------

# 1. The real shipped orchestrator must pass. If this fails, either the guard is
#    wrong or orchestrator.md genuinely lost something — both are worth stopping for.
expect_pass "real orchestrator.md -> accept" "$REAL"

# 2. Frontmatter is optional: a body-only file still passes (awk passes it through).
f="$WORK/nofm.md"
awk 'NR==1 && $0=="---"{f=1;next} f==1 && $0=="---"{f=2;next} f==2{print;next} f!=1{print}' "$REAL" > "$f"
expect_pass "no frontmatter -> accept" "$f"

# --- input handling (fail closed) -------------------------------------------

# 3. Unset input must refuse, not proceed on an empty path.
out=$(env -u ORCHESTRATOR_SRC BODY_OUT="$WORK/body.out" bash "$SNIPPET" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'unset or not a readable file'; then
  echo "  ok   — unset ORCHESTRATOR_SRC -> reject"; pass=$((pass+1))
else
  echo "  FAIL — unset ORCHESTRATOR_SRC: expected reject, got exit $rc"; fail=$((fail+1))
fi

# 4. Nonexistent path must refuse.
expect_reject "nonexistent source -> reject" "$WORK/does-not-exist.md" "unset or not a readable file"

# --- strip failures ---------------------------------------------------------

# 5. Empty source -> empty body.
: > "$WORK/empty.md"
expect_reject "empty source -> reject" "$WORK/empty.md" "stripped body is empty"

# 6. Unterminated frontmatter fence swallows the file -> empty body, never deployed.
#    Built from the body-only copy with every bare '---' removed, so the opening
#    fence added here genuinely has no match anywhere in the file.
{ echo '---'; echo 'name: dispatch-orchestrator'; grep -vx -- '---' "$WORK/nofm.md"; } > "$WORK/unterminated.md"
expect_reject "unterminated frontmatter -> reject" "$WORK/unterminated.md" "stripped body is empty"

# 7. Frontmatter that survives the strip (indented fence the awk rule won't match)
#    must be caught rather than shipped as the prompt.
{ echo '  ---'; echo 'name: dispatch-orchestrator'; echo '  ---'; cat "$REAL"; } > "$WORK/survived.md"
expect_reject "frontmatter survives strip -> reject" "$WORK/survived.md" "frontmatter survived the strip"

# --- truncation -------------------------------------------------------------

# 8. A truncated body is the silent-downgrade case size alone can catch.
head -50 "$REAL" > "$WORK/truncated.md"
expect_reject "truncated body -> reject" "$WORK/truncated.md" "expected >= 200"

# --- derived structural checks: each must independently discriminate ----------
#
# The guard names no agents. These cases break each derived count in isolation
# and confirm the guard goes red — a check that stays green is asserting nothing.
echo "  -- derived structural checks --"

# 9. A lane goes missing: drop one agent's dispatch (leaving its lock line, so
#    only the lane count moves) -> reject on lanes, not on locks.
grep -vF -- '--agent workbench-dev-team:watson' "$REAL" > "$WORK/two-lanes.md"
expect_reject "only 2 dispatched lanes -> reject" "$WORK/two-lanes.md" "distinct agent lane(s) dispatched"

# 10. The pre-#39 regression: agents still dispatched, no per-item in-flight lock
#     written by any of them -> reject on locks. This is the real-world shape of
#     the frozen v0.35.0 orchestrator.
grep -vE -- 'dev-team-logs/[a-z-]+-\$ID\.lock' "$REAL" > "$WORK/nolocks.md"
expect_reject "no in-flight locks (pre-#39) -> reject" "$WORK/nolocks.md" "in-flight lock"

# 11. Boundary: the Lestrade sweep legitimately dispatches without a lock, so a
#     body with exactly 2 lock-writing lanes must still be ACCEPTED. Without this,
#     the floor could be raised to 3 and nothing would catch the false rejection.
grep -vF -- 'dev-team-logs/lestrade-$ID.lock' "$REAL" > "$WORK/two-locks.md"
expect_pass "exactly 2 lock-writing lanes -> accept" "$WORK/two-locks.md"

# 12-13. The circuit-breaker sentinel pair, each half independently.
grep -vF -- '>>> circuit-breaker-preflight >>>' "$REAL" > "$WORK/no-open.md"
expect_reject "missing opening sentinel -> reject" "$WORK/no-open.md" "opening sentinel"
grep -vF -- '<<< circuit-breaker-preflight <<<' "$REAL" > "$WORK/no-close.md"
expect_reject "missing closing sentinel -> reject" "$WORK/no-close.md" "closing sentinel"

# --- cross-file agreement on the one surviving literal ------------------------
#
# The circuit-breaker sentinel pair is the guard's only hard-coded string, and it
# is duplicated across three files: orchestrator.md DECLARES it,
# test-circuit-breaker.sh EXTRACTS between it, and the Step 7a-bis guard ASSERTS
# it. If any one drifts, that file silently becomes a no-op — the extraction
# yields nothing, or the assertion never fires. Pin all three together so a
# rename has to be deliberate and complete.
echo "  -- cross-file sentinel agreement --"
CB_TEST="$HERE/test-circuit-breaker.sh"
for sentinel in '>>> circuit-breaker-preflight >>>' '<<< circuit-breaker-preflight <<<'; do
  missing=""
  for f in "$REAL" "$SNIPPET" "$CB_TEST"; do
    grep -qF -- "$sentinel" "$f" || missing="$missing $(basename "$f")"
  done
  if [ -z "$missing" ]; then
    echo "  ok   — '$sentinel' agreed across orchestrator.md, guard, circuit-breaker test"
    pass=$((pass+1))
  else
    echo "  FAIL — '$sentinel' missing from:$missing"
    fail=$((fail+1))
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "orchestrator-body guard: $pass passed, $fail failed"
else
  echo "orchestrator-body guard: $pass passed, $fail FAILED"
fi
[ "$fail" -eq 0 ]
