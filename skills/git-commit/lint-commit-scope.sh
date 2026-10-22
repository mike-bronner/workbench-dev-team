#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

flat() { tr '\n' ' ' | tr -s ' '; }
section() { awk -v s="$1" -v e="$2" 'index($0, s) == 1 {f=1} index($0, e) == 1 {f=0} f' "$3" | flat; }

has() {
  local name="$1" text="$2" want="$3"
  if [ -z "$text" ]; then bad "$name — section not found"; return; fi
  [[ $text == *"$want"* ]] && ok "$name says: $want" || bad "$name — lost: $want"
}

GC="$(section '## Committing and pushing' '**Run it as a plain git line' "$ROOT/skills/git-commit/SKILL.md")"
has "git-commit" "$GC" 'How Watson splits that work into commits is his own judgment.'

OC="$(section '### Direct-mode work comes back uncommitted' '## Action routing' "$ROOT/skills/orchestrate/SKILL.md")"
has "orchestrate" "$OC" "read the tree itself, never only the report's file list"

DV="$(section '### Message format and hygiene' '## 6.' "$ROOT/skills/develop/SKILL.md")"
for want in \
  'Scan the diff and read every untracked file for credentials' \
  'Hold back a file with a secret, and tell the human.'; do
  has "develop §5" "$DV" "$want"
done
DP="$(section '**Scheduled pipeline → commit and push unattended.**' '### Message format and hygiene' "$ROOT/skills/develop/SKILL.md")"
has "develop pipeline lane" "$DP" 'Split the work into commits as you judge best.'

SCOPE_RE='(takes?|stages?|commits?|includes?) (the )?whole tree|single commit|(takes?|stages?|includes?|commits?) every file|whole[- ]tree commit|one commit (that )?takes|in one commit|every uncommitted file|(never|not|don.t) split[^.]{0,40}commit|(not|never|don.t) ask which files|several commits when|atomic commits?|commit (the [a-z]+ |each [a-z]+ |it )?separately|separate commits?'
for fixture in 'A commit takes the whole tree, in one commit.' 'One commit takes the whole tree, in every lane.' 'Never split the work into several commits.' 'Make atomic commits.' 'Commit each change separately.' 'Stage the whole tree with git add -A.' 'Watson makes a single commit per item.' 'Take every file in the tree.'; do
  [ -n "$(grep -oiE "$SCOPE_RE" <<<"$fixture")" ] && ok "the scope check flags: $fixture" || bad "the scope check misses: $fixture"
done
for fixture in 'The orchestrator takes the uncommitted tree from there.' 'Split the work into commits as you judge best.' 'Hold back a file with a secret, and tell the human.'; do
  [ -z "$(grep -oiE "$SCOPE_RE" <<<"$fixture")" ] && ok "the scope check passes: $fixture" || bad "the scope check flags a clean line: $fixture"
done

scan() {
  local rel="$1" text="$2" hit
  while IFS= read -r hit; do
    [ -n "$hit" ] && bad "$rel — prescribes commit scope: $hit"
  done < <(grep -oiE \
    -e "$SCOPE_RE" \
    -e '(remove|delete|strip) (it|the (secret|credential|file)) before (staging|committing)' \
    -e '(secret|credential)[^.]{0,40}(remove|delete) it' \
    <<<"$text")
}

rules_text() {
  awk '
    /^export const RULES = `/ { f = 1; sub(/^export const RULES = `/, "") }
    f && /[^\\]`$/ { sub(/`$/, ""); print; found = 1; exit }
    f { print }
    END { exit !found }' "$ROOT/hooks/mods/session-rules.ts" | sed 's/\\`/`/g' | flat
}

before=$FAIL
while IFS= read -r -d '' f; do
  scan "${f#"$ROOT"/}" "$(flat < "$f")"
done < <(find "$ROOT/agents" "$ROOT/references" "$ROOT/skills" "$ROOT/commands" "$ROOT/scheduled-tasks" \( -name '*.md' -o -name '*.txt' \) -print0; find "$ROOT" -maxdepth 1 \( -name '*.md' -o -name '*.txt' \) -print0)
if RULES_TEXT="$(set -o pipefail; rules_text)" && [ -n "$RULES_TEXT" ]; then
  scan "session rules" "$RULES_TEXT"
else
  bad "hooks/mods/session-rules.ts — no closed RULES template literal found"
fi
[ "$FAIL" -eq "$before" ] && ok "no shipped Markdown, text block, or session rule prescribes how a commit is scoped"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
