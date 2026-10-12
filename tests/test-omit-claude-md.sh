#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CORE="${WORKBENCH_CORE_DIR:-$ROOT/../workbench-core}"
CHECK="$HERE/omit-claude-md-check.py"
RULES="$ROOT/hooks/mods/session-rules.ts"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

echo "── OMITS_CLAUDE_MD against the claude binary ───────────────────────────"
found="${CLAUDE_BINARY:-$(command -v claude 2>/dev/null)}"
if [ -z "$found" ]; then
  echo "  ⏭️  skipped: no claude binary on PATH (set CLAUDE_BINARY to one)"
  exit 0
fi
if [ ! -d "$CORE/agents" ]; then
  echo "  ⏭️  skipped: no workbench-core checkout at $CORE (set WORKBENCH_CORE_DIR to one)"
  exit 0
fi
binary="$(readlink -f "$found")"

if python3 -I "$CHECK" "$binary" "$CORE"; then
  ok "session-rules.ts names every agent that omits CLAUDE.md, and no other"
else
  bad "session-rules.ts differs from the agents that omit CLAUDE.md in $binary and $CORE"
fi

python3 -I "$CHECK" "$binary" "$CORE" /dev/stdin < <(sed "s/^  'Explore',\$//" "$RULES") >/dev/null 2>&1
[ $? -eq 1 ] && ok "a list missing Explore fails" || bad "a list missing Explore does not fail"

python3 -I "$CHECK" "$binary" "$CORE" /dev/stdin < <(sed "s/^  'Plan',\$/  'Plan', 'Bogus',/" "$RULES") >/dev/null 2>&1
[ $? -eq 1 ] && ok "a list naming an extra agent fails" || bad "a list naming an extra agent does not fail"

python3 -I "$CHECK" "$binary" "$CORE" /dev/stdin < /dev/null >/dev/null 2>&1
[ $? -eq 2 ] && ok "a file with no OMITS_CLAUDE_MD cannot be read" || bad "a file with no OMITS_CLAUDE_MD is not refused"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
