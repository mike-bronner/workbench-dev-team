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
for want in \
  'A commit takes the whole tree, in one commit.' \
  'This holds in every lane, the scheduled pipeline and Index mode included.' \
  'one message that covers the whole set' \
  'tracked changes and untracked files alike' \
  "a sub-agent's changes, the human's own edits, and files that appeared during the session" \
  'Never leave a file out because a sub-agent did not make it' \
  'Never split the work into several commits' \
  'never ask which files to include' \
  'content that must never ship' \
  'tell the human about it in one sentence' \
  'Never leave a file out silently' \
  'It does not change who approves a commit or when' \
  'every file the commit will take' \
  'Check the tree again right before you stage it.' \
  'stage the whole tree with `git add -A`' \
  'do not drop a file to make the commit match the list' \
  'Show the human the new or changed files, and ask the commit question again'; do
  has "git-commit" "$GC" "$want"
done

OC="$(section '### Direct-mode work comes back uncommitted' '## Action routing' "$ROOT/skills/orchestrate/SKILL.md")"
for want in \
  "One commit takes the whole tree, in every lane, not only the agent's change." \
  'every file the commit takes' \
  'If the tree changes after it, ask it again, and drop no file.' \
  'Leave out only what must never ship, and tell the human in one sentence.'; do
  has "orchestrate" "$OC" "$want"
done

DV="$(section '### Message format and hygiene' '## 6.' "$ROOT/skills/develop/SKILL.md")"
for want in \
  'One commit takes the whole tree, in every lane.' \
  'Never split it unasked or ask which files go in.' \
  'The commit question lists every file.' \
  'If the tree changes after it, ask again, and drop no file.' \
  'Leave out only what must never ship, and tell the human in one sentence.' \
  'Scan the diff and read every untracked file for credentials' \
  'Hold back a file with a secret, and tell the human.'; do
  has "develop §5" "$DV" "$want"
done
has "git-commit" "$GC" 'Read each untracked file on the list for a secret first'

IM="$(section '- **One logical change at a time.**' "- **Don't add dependencies" "$ROOT/skills/develop/references/implementation.md")"
has "implementation.md" "$IM" 'That is an order of work, not a commit boundary.'
has "implementation.md" "$IM" 'The commit still takes the whole tree in one commit, in every lane'

before=$FAIL
while IFS= read -r -d '' f; do
  rel="${f#"$ROOT"/}"
  text="$(flat < "$f")"
  for gone in \
    'confirm it is the tree the human approved' \
    'how to split the commits' \
    "Don't bundle" \
    'differs from what the human saw'; do
    [[ $text == *"$gone"* ]] && bad "$rel — still says: $gone"
  done
  while IFS= read -r hit; do
    [ -n "$hit" ] && bad "$rel — narrows or splits the commit: $hit"
  done < <(grep -oiE \
    -e 'atomic commits?' \
    -e 'commit (the [a-z]+ |each [a-z]+ |it )?separately' \
    -e 'separate commits?' \
    -e '(foreground|direct[- ]mode|sub-agent|pipeline|index[- ]mode)( session)? commits? takes?' \
    -e 'whole[- ]tree (commit|rule)[^.]{0,40}(foreground|direct[- ]mode|human-approved)' \
    -e '(in|outside) the (scheduled )?pipeline[^.]{0,40}(split|separately|several commits)' \
    -e '(only|just) in the foreground[^.]{0,60}(one|whole|single) commit' \
    -e '(remove|delete|strip) (it|the (secret|credential|file)) before (staging|committing)' \
    -e '(secret|credential)[^.]{0,40}(remove|delete) it' \
    <<<"$text")
done < <(find "$ROOT/agents" "$ROOT/references" "$ROOT/skills" "$ROOT/commands" "$ROOT/scheduled-tasks" -name '*.md' -print0; find "$ROOT" -maxdepth 1 -name '*.md' -print0)
[ "$FAIL" -eq "$before" ] && ok "no shipped Markdown splits a commit or limits the one-commit rule to a lane"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
