#!/bin/bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

flat() { tr '\n' ' ' < "$ROOT/$1" | tr -s ' '; }

check() {
  local rel="$1" text phrase missing=()
  shift
  text="$(flat "$rel")"
  for phrase in "$@"; do
    [[ $text == *"$phrase"* ]] || missing+=("$phrase")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    ok "$rel states that bug, security and integrity findings block in the same PR"
  else
    for m in "${missing[@]}"; do bad "$rel — lacks: $m"; done
  fi
}

RULE='A bug, a security problem, or an integrity problem that the PR'"'"'s own repo can fix blocks, with changes requested in this same PR, wherever it lives in that repo.'
OTHER='A bug, security, or integrity finding that only another repo can fix goes to that repo'"'"'s owner, and does not hold the PR.'
OWNER_INDEX='In Index mode, open an issue on the owning repo through `create_issue(repo: <owning repo>)`'
OWNER_LOCAL='so the orchestrator sends it to that project'"'"'s session. It is never a note with nothing to track.'
WHERE='even when it predates the PR, and even outside the coherent unit or the PR'"'"'s scope'
NEVER='never goes to a follow-up issue, a `## 📋 Non-blocking follow-ups` entry, or a note with nothing to track'
NOT_HERE='When only another repo can fix it, it goes to that repo'"'"'s owner as an issue'

APPROVE="no hard defect this repo can fix, and the PR's own code"
check agents/holmes.md "$APPROVE" "$RULE" "$OTHER" "$OWNER_INDEX" "$OWNER_LOCAL" "$WHERE" "$NEVER" "$NOT_HERE"
check agents/holmes-index.md "$APPROVE" "$RULE" "$OTHER" "$OWNER_INDEX" "$OWNER_LOCAL" "$WHERE" "$NEVER" "$NOT_HERE"
check agents/holmes-local.md "$RULE" "$OTHER" "$OWNER_INDEX" "$OWNER_LOCAL" "$WHERE" "$NEVER"
check references/holmes/local-review.md \
  'an integrity problem that the workdir'"'"'s repo can fix is a hard defect wherever it lives in that repo' \
  'A finding that only another repo can fix does not hold the verdict.' \
  '## Findings for other projects - <bug, security, or integrity finding only another repo can fix' \
  'no hard defect this repo can fix, and the change' \
  'so the orchestrator sends it to that project'"'"'s session.' \
  'it blocks, latent or live, pre-existing or out of scope, when this repo can fix it, and it goes to the owning project'"'"'s session otherwise.'
check references/holmes/review-phases.md \
  'wherever it lives in this repo, or in code only another repo can fix, which Holmes routes to its owner)'

stale="$(cd "$ROOT" && grep -rn -i -E 'latent[- ]hazard|hazard/systemic|hazard or (systemic|debt)|clears the hazard' \
  agents references skills commands README.md --include='*.md' --include='*.txt' --include='*.recipe' --include='*.sh' \
  | grep -v '^agents/lint-holmes-blocking-findings\.sh:')"
if [ -z "$stale" ]; then
  ok "no shipped text routes a hazard to a follow-up issue or a note"
else
  while IFS= read -r line; do bad "hazard follow-up routing ships: $line"; done <<< "$stale"
fi

unscoped="$(cd "$ROOT" && grep -rn -i -E 'hard defect anywhere|blocks?[^.]{0,80}no matter where it lives|integrity (finding|problem)[^.]{0,40}wherever it lives[,.:]|finding wherever it lives' \
  agents references skills README.md --include='*.md' --include='*.txt' \
  | grep -i -E 'bug|security|integrity|hard defect anywhere')"
if [ -z "$unscoped" ]; then
  ok "no shipped text blocks on a finding the PR's repo cannot change"
else
  while IFS= read -r line; do bad "unscoped blocking wording ships: $line"; done <<< "$unscoped"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
