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
#   2. workbench-core's real guard runs on the block and must not answer "deny".
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
printf 'x=$(mktemp)\nrm -f "$x"\n' > "$SANDBOX/canary.sh"
VERDICTS="$(node "$REPO/tests/scope-verdict.mjs" "$REPO" "${BLOCKS[@]}" "$SANDBOX/canary.sh")" || { echo "❌ workbench-core's destructive-scope guard could not run"; exit 1; }
verdict_of() { printf '%s\n' "$VERDICTS" | awk -F '\t' -v f="$1" '$1 == f { print $2 "\t" $3 }'; }

for b in "${BLOCKS[@]}"; do
  name="setup.md line $((10#$(basename "$b" .sh | tr -dc 0-9)))"
  HITS=$(tr -d "'\"\\\\" < "$b" | grep -inE "$SCOPE_VERBS")
  [ -z "$HITS" ] && ok "$name names none of the guard's verbs" || bad "$name — the guard would read: $HITS"
  VERDICT="$(verdict_of "$b")"
  case "$VERDICT" in deny*) bad "$name — the destructive-scope guard refuses it: $VERDICT" ;;
    "") bad "$name — the destructive-scope guard gave no verdict" ;;
    *) ok "$name passes the destructive-scope guard" ;; esac
done

echo "The check can fail"
tr -d "'\"\\\\" < "$SANDBOX/canary.sh" | grep -qiE "$SCOPE_VERBS" && ok "a block with rm -f \"\$tmp\" is caught" || bad "the verb check missed rm -f"
case "$(verdict_of "$SANDBOX/canary.sh")" in deny*) ok "...and the real guard refuses it" ;; *) bad "the real guard let rm -f \"\$x\" through" ;; esac

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
