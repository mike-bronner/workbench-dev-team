#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CORE="$(node "$HERE/core-root.mjs")" || exit 1
CHECK="$HERE/omit-claude-md-check.py"
CORE_CHECK="$CORE/scripts/omit-claude-md-check.py"
RULES="$ROOT/hooks/mods/session-rules.ts"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
finish() { echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

read_built_ins() {
  python3 -I - "$CORE_CHECK" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('core_check', sys.argv[1])
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
try:
    print(' '.join(sorted(core.built_in_omitters(sys.argv[2].encode()))))
except core.Unreadable:
    print('unreadable')
PY
}
ANCHOR='{agentType:"general-purpose",source:"built-in",getSystemPrompt'
WEB='{agentType:aT,source:"built-in",omitClaudeMd:!0,getSystemPrompt'

echo "── built-in agent names, read chunk by chunk ───────────────────────────"
got="$(read_built_ins "// @bun
var aT=\"flag\";
// @bun
var aT=\"web-fetch\";$ANCHOR$WEB")"
[ "$got" = "web-fetch" ] && ok "a name declared in two chunks resolves in the chunk that uses it" || bad "a name declared in two chunks read as '$got', not 'web-fetch'"

got="$(read_built_ins "// @bun
var aT=\"web-fetch\";
// @bun
$ANCHOR$WEB")"
[ "$got" = "unreadable" ] && ok "a name declared only in another chunk cannot be read" || bad "a name declared only in another chunk read as '$got'"

got="$(read_built_ins "// @bun
var aT=\"flag\";var aT=\"web-fetch\";$ANCHOR$WEB")"
[ "$got" = "unreadable" ] && ok "a name declared twice in one chunk cannot be read" || bad "a name declared twice in one chunk read as '$got'"

got="$(read_built_ins "// @bun
var aT=\"web-fetch\";$WEB")"
[ "$got" = "unreadable" ] && ok "a binary with no general-purpose built-in cannot be read" || bad "a binary with no general-purpose built-in read as '$got'"
echo

echo "── OMITS_CLAUDE_MD against the claude binary ───────────────────────────"
found="${CLAUDE_BINARY:-$(command -v claude 2>/dev/null)}"
if [ -z "$found" ]; then
  echo "  ⏭️  skipped: no claude binary on PATH (set CLAUDE_BINARY to one)"
  finish
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
finish
