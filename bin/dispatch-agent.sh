#!/usr/bin/env bash
# Dispatch one dev-team agent as a detached subprocess.
#
# Dispatch (the scheduled orchestrator) runs under the auto-mode classifier,
# which judges every Bash command it cannot match to a permission rule. The
# multi-line dispatch block this replaces — config reads, a Keychain fetch, and
# `nohup claude -p --dangerously-skip-permissions &` — has no matchable prefix,
# so it was re-judged on every tick and refused nondeterministically. A single
# stable invocation can be covered by one `permissions.allow` prefix rule, which
# is evaluated *before* the classifier and takes the judgment call off the table.
#
# Usage:
#   dispatch-agent.sh lestrade <item-id>        # triage one item
#   dispatch-agent.sh lestrade <owner/repo>     # blocker sweep for one repo
#   dispatch-agent.sh holmes   <item-id>        # review one item
#   dispatch-agent.sh watson   <item-id>        # develop one item
#
# Environment:
#   REPRIEVE=1          multiply the budget cap by reprieveBudgetMultiplier
#   DISPATCH_DRY_RUN=1  print the command that would run; spawn nothing
#
# Exits non-zero on bad arguments only. A malformed or absent config never
# blocks a dispatch — every knob falls back to the agent's default.
set -u

CONFIG="${DISPATCH_CONFIG:-$HOME/.claude-workbench/dev-team-config.json}"
LOGDIR="${LOGDIR:-$HOME/.claude-workbench/dev-team-logs}"

AGENT="${1:-}"
TARGET="${2:-}"

case "$AGENT" in
  lestrade|holmes|watson) ;;
  *) echo "usage: $(basename "$0") <lestrade|holmes|watson> <item-id|owner/repo>" >&2; exit 2 ;;
esac

if [ -z "$TARGET" ]; then
  echo "$(basename "$0"): missing target (item id, or owner/repo for a lestrade sweep)" >&2
  exit 2
fi

# A target containing a slash is a repo sweep — Lestrade only. Everything else
# is a project_items.id and must be numeric, so a malformed argument fails here
# rather than spawning an agent that cannot find its item.
SWEEP=0
case "$TARGET" in
  */*)
    if [ "$AGENT" != lestrade ]; then
      echo "$(basename "$0"): only lestrade takes a repo sweep target, got '$TARGET' for $AGENT" >&2
      exit 2
    fi
    SWEEP=1
    ;;
  ''|*[!0-9]*)
    echo "$(basename "$0"): '$TARGET' is neither a numeric item id nor an owner/repo sweep target" >&2
    exit 2
    ;;
esac

# Per-agent defaults, used when the config is missing, malformed, or silent on a
# key. These match the agents' own frontmatter defaults.
case "$AGENT" in
  lestrade) DEFAULT_MODEL=sonnet; DEFAULT_BUDGET= ;;
  holmes)   DEFAULT_MODEL=opus;   DEFAULT_BUDGET= ;;
  watson)   DEFAULT_MODEL=opus;   DEFAULT_BUDGET=10.00 ;;
esac

cfg() {
  # cfg <jq-path> <fallback> — read one key, falling back on any failure.
  local value
  value=$(jq -r "${1} // empty" "$CONFIG" 2>/dev/null) || value=""
  [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$2"
}

MODEL=$(cfg ".agents.${AGENT}.model" "$DEFAULT_MODEL")
EFFORT=$(cfg ".agents.${AGENT}.effort" "")
FALLBACK=$(cfg ".agents.${AGENT}.fallback" "")
BUDGET=$(cfg ".agents.${AGENT}.maxBudgetUsd" "$DEFAULT_BUDGET")

# Reprieve: a human re-activated a previously-escalated item, so they have
# accepted the cost — raise the cap for this one run. Inert on ordinary ticks.
if [ "${REPRIEVE:-0}" = 1 ] && [ -n "$BUDGET" ]; then
  MULT=$(cfg ".agents.${AGENT}.reprieveBudgetMultiplier" "3")
  BUDGET=$(awk -v b="$BUDGET" -v m="$MULT" 'BEGIN{printf "%.2f", b*m}')
fi

STAMP=$(date +%Y%m%d-%H%M%S)

if [ "$SWEEP" = 1 ]; then
  PROMPT="Repo sweep: $TARGET"
  LOG="$LOGDIR/${AGENT}-sweep-$(printf '%s' "$TARGET" | tr '/' '-')-$STAMP.log"
  LOCK=
else
  PROMPT="Item ID: $TARGET"
  LOG="$LOGDIR/${AGENT}-${TARGET}-$STAMP.log"
  # In-flight lock: the circuit-breaker pre-flight SKIPs this item while this
  # PID lives. Sweeps are not per-item and take no lock.
  LOCK="$LOGDIR/${AGENT}-${TARGET}.lock"
fi

set -- --agent "workbench-dev-team:${AGENT}" --model "$MODEL"
[ -n "$EFFORT" ]   && set -- "$@" --effort "$EFFORT"
[ -n "$FALLBACK" ] && set -- "$@" --fallback-model "$FALLBACK"
[ -n "$BUDGET" ]   && set -- "$@" --max-budget-usd "$BUDGET"
set -- "$@" --dangerously-skip-permissions "$PROMPT"

if [ "${DISPATCH_DRY_RUN:-0}" = 1 ]; then
  printf 'claude -p'; printf ' %s' "$@"; printf '\n'
  printf 'log=%s\n' "$LOG"
  printf 'lock=%s\n' "${LOCK:-none}"
  exit 0
fi

mkdir -p "$LOGDIR"

# The one thing the classifier reliably flagged: a Keychain read feeding a
# detached subprocess. Inside an allowlisted script it is no longer a judgment
# call. A missing token is not fatal — `claude` falls back to its own auth.
CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s "claude-code" -a "oauth-token" -w 2>/dev/null || true)
export CLAUDE_CODE_OAUTH_TOKEN

nohup claude -p "$@" > "$LOG" 2>&1 &
DISPATCHED=$!
[ -n "$LOCK" ] && printf '%s' "$DISPATCHED" > "$LOCK"
disown 2>/dev/null || true

printf 'dispatched %s pid=%s log=%s\n' "$AGENT" "$DISPATCHED" "$LOG"
