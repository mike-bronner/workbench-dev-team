#!/bin/bash
# Every shell block in commands/setup.md must pass workbench-core's
# destructive-scope guard. Run directly: bash commands/test-setup-scope-guard.sh
#
# That guard refuses a whole Bash call that removes a path outside every root,
# or a path it cannot resolve, such as rm -f "$tmp". Setup writes into ~/.claude,
# ~/.claude-workbench, and the plugin install, all outside the project, so one
# such line refuses the whole block and the step never runs. Six blocks did.
#
# Two checks per block:
#   1. Hermetic, and it runs in CI: the block names none of the guard's verbs as
#      a whole word, after quotes and backslashes are dropped. The guard's
#      prefilter is silent on such a block, so the guard can never refuse it.
#      The verb list is the guard's own (SCOPE_VERBS in its prefilter).
#   2. When a workbench-core checkout is found, the real guard runs on the block
#      and must not answer "deny".
# The comment of a block counts too: the prefilter reads raw text.

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_MD="$REPO/commands/setup.md"
PASS=0
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required to run this suite"; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/setup-scope-guard.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# One file per fenced shell block, named for the line its fence opens on.
awk -v dir="$SANDBOX" '
  /^```(bash|sh|shell|zsh)[[:space:]]*$/ { f = sprintf("%s/block-L%04d.sh", dir, NR); inb = 1; next }
  /^```/ { if (inb) { inb = 0; close(f) } ; next }
  inb { print > f }' "$SETUP_MD"
BLOCKS=("$SANDBOX"/block-L*.sh)
if [ ! -e "${BLOCKS[0]}" ] || [ "${#BLOCKS[@]}" -lt 15 ]; then
  echo "❌ found ${#BLOCKS[@]} shell blocks in $SETUP_MD — the fence pattern stopped matching"
  exit 1
fi
echo "${#BLOCKS[@]} shell blocks in commands/setup.md"

SCOPE_VERBS='(^|[^[:alnum:]])(rm|rmdir|reset|clean|stash|delete)([^[:alnum:]]|$)'
SCOPE_GUARD=""
for g in "${WORKBENCH_CORE_ROOT:-}/hooks/destructive-scope-guard.sh" "$HOME/Developer/workbench-core/hooks/destructive-scope-guard.sh"; do
  [ -f "$g" ] && { SCOPE_GUARD="$g"; break; }
done

for b in "${BLOCKS[@]}"; do
  name="setup.md line $((10#$(basename "$b" .sh | tr -dc 0-9)))"
  HITS=$(tr -d "'\"\\\\" < "$b" | grep -inE "$SCOPE_VERBS")
  [ -z "$HITS" ] && ok "$name names none of the guard's verbs" || bad "$name — the guard would read: $HITS"
  if [ -n "$SCOPE_GUARD" ]; then
    VERDICT=$(jq -cn --rawfile c "$b" --arg cwd "$REPO" \
      '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd, session_id: "s"}' | bash "$SCOPE_GUARD")
    case "$VERDICT" in *'"deny"'*) bad "$name — the destructive-scope guard refuses it: $VERDICT" ;;
      *) ok "$name passes the destructive-scope guard" ;; esac
  fi
done
[ -n "$SCOPE_GUARD" ] || echo "  ⏭  workbench-core not found, so its guard was not run (set WORKBENCH_CORE_ROOT to run it)"

echo "The check can fail"
printf 'x=$(mktemp)\nrm -f "$x"\n' > "$SANDBOX/canary.sh"
tr -d "'\"\\\\" < "$SANDBOX/canary.sh" | grep -qiE "$SCOPE_VERBS" && ok "a block with rm -f \"\$tmp\" is caught" || bad "the verb check missed rm -f"
if [ -n "$SCOPE_GUARD" ]; then
  VERDICT=$(jq -cn --rawfile c "$SANDBOX/canary.sh" --arg cwd "$REPO" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd, session_id: "s"}' | bash "$SCOPE_GUARD")
  case "$VERDICT" in *'"deny"'*) ok "...and the real guard refuses it" ;; *) bad "the real guard let rm -f \"\$x\" through: $VERDICT" ;; esac
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
