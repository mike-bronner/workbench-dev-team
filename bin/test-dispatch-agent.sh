#!/usr/bin/env bash
# Test for bin/dispatch-agent.sh.
#
# Runs the real script in DISPATCH_DRY_RUN mode against fixture configs, so the
# assertions cover the shipped argument-building logic without spawning agents.
#
# Run: bash bin/test-dispatch-agent.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/dispatch-agent.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not found"; exit 1
fi

pass=0; fail=0

# mkcfg <name> <json> -> echoes the config path
mkcfg() { printf '%s' "$2" > "$WORK/$1.json"; printf '%s' "$WORK/$1.json"; }

# run <config> <agent> <target> -> echoes dry-run output (stdout+stderr)
run() {
  DISPATCH_CONFIG="$1" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 \
    bash "$SCRIPT" "$2" "$3" 2>&1
}

# rc <config> <agent> <target> -> echoes the exit code
rc() {
  DISPATCH_CONFIG="$1" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 \
    bash "$SCRIPT" "$2" "$3" >/dev/null 2>&1
  printf '%s' "$?"
}

# expect_has <name> <needle> <haystack>
expect_has() {
  case "$3" in
    *"$2"*) echo "  ok   — $1"; pass=$((pass+1)) ;;
    *)      echo "  FAIL — $1: expected to contain '$2', got: $3"; fail=$((fail+1)) ;;
  esac
}

# expect_lacks <name> <needle> <haystack>
expect_lacks() {
  case "$3" in
    *"$2"*) echo "  FAIL — $1: expected NOT to contain '$2', got: $3"; fail=$((fail+1)) ;;
    *)      echo "  ok   — $1"; pass=$((pass+1)) ;;
  esac
}

# expect_eq <name> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; pass=$((pass+1))
  else echo "  FAIL — $1: expected '$2' got '$3'"; fail=$((fail+1)); fi
}

echo "Testing dispatch-agent.sh ($SCRIPT):"

FULL=$(mkcfg full '{"agents":{"lestrade":{"model":"haiku","effort":"low"},"holmes":{"model":"sonnet","effort":"high","maxBudgetUsd":5},"watson":{"model":"opus","effort":"high","maxBudgetUsd":10,"fallback":"sonnet","reprieveBudgetMultiplier":3}}}')
EMPTY=$(mkcfg empty '{}')
BROKEN=$(mkcfg broken 'not json at all {{{')
MISSING="$WORK/does-not-exist.json"

echo "— argument validation"
expect_eq "unknown agent rejected"            "2" "$(rc "$FULL" mycroft 42)"
expect_eq "missing target rejected"           "2" "$(rc "$FULL" watson '')"
expect_eq "non-numeric target rejected"       "2" "$(rc "$FULL" watson abc)"
expect_eq "sweep target on watson rejected"   "2" "$(rc "$FULL" watson owner/repo)"
expect_eq "sweep target on holmes rejected"   "2" "$(rc "$FULL" holmes owner/repo)"
expect_eq "lestrade sweep accepted"           "0" "$(rc "$FULL" lestrade owner/repo)"
expect_eq "numeric item accepted"             "0" "$(rc "$FULL" watson 42)"

echo "— prompt and log shape"
out=$(run "$FULL" watson 369)
expect_has  "item prompt"        "Item ID: 369"        "$out"
expect_has  "item log name"      "watson-369-"         "$out"
expect_has  "item takes a lock"  "lock=$WORK/logs/watson-369.lock" "$out"

out=$(run "$FULL" lestrade mike-bronner/phpcs-rules)
expect_has  "sweep prompt"       "Repo sweep: mike-bronner/phpcs-rules" "$out"
expect_has  "sweep log slug"     "lestrade-sweep-mike-bronner-phpcs-rules-" "$out"
expect_has  "sweep takes no lock" "lock=none"          "$out"

echo "— config resolution"
out=$(run "$FULL" lestrade 7)
expect_has  "model from config"  "--model haiku"       "$out"
expect_has  "effort from config" "--effort low"        "$out"
expect_lacks "no budget when unset" "--max-budget-usd" "$out"
expect_lacks "no fallback when unset" "--fallback-model" "$out"

out=$(run "$FULL" watson 7)
expect_has  "fallback passed"    "--fallback-model sonnet" "$out"
expect_has  "budget passed"      "--max-budget-usd 10"     "$out"
expect_has  "agent flag"         "--agent workbench-dev-team:watson" "$out"
expect_has  "skip-permissions"   "--dangerously-skip-permissions"    "$out"

echo "— defaults survive a bad config"
for label in empty broken missing; do
  case "$label" in
    empty)   c="$EMPTY" ;;
    broken)  c="$BROKEN" ;;
    missing) c="$MISSING" ;;
  esac
  out=$(run "$c" watson 7)
  expect_has  "watson model default ($label)"   "--model opus"          "$out"
  expect_has  "watson budget default ($label)"  "--max-budget-usd 10.00" "$out"
  expect_lacks "no effort flag ($label)"        "--effort"              "$out"
  out=$(run "$c" lestrade 7)
  expect_has  "lestrade model default ($label)" "--model sonnet"        "$out"
  expect_lacks "lestrade no budget ($label)"    "--max-budget-usd"      "$out"
  out=$(run "$c" holmes 7)
  expect_has  "holmes model default ($label)"   "--model opus"          "$out"
  expect_lacks "holmes no budget ($label)"      "--max-budget-usd"      "$out"
done

echo "— reprieve"
out=$(REPRIEVE=1 DISPATCH_CONFIG="$FULL" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 bash "$SCRIPT" watson 7 2>&1)
expect_has  "watson budget tripled"  "--max-budget-usd 30.00" "$out"
out=$(REPRIEVE=1 DISPATCH_CONFIG="$FULL" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 bash "$SCRIPT" holmes 7 2>&1)
expect_has  "holmes budget tripled"  "--max-budget-usd 15.00" "$out"
out=$(REPRIEVE=1 DISPATCH_CONFIG="$FULL" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 bash "$SCRIPT" lestrade 7 2>&1)
expect_lacks "no budget stays absent under reprieve" "--max-budget-usd" "$out"
out=$(REPRIEVE=0 DISPATCH_CONFIG="$FULL" LOGDIR="$WORK/logs" DISPATCH_DRY_RUN=1 bash "$SCRIPT" watson 7 2>&1)
expect_has  "budget untouched without reprieve" "--max-budget-usd 10" "$out"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
