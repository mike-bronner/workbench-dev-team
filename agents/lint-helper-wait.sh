#!/bin/bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

check_paragraph() {
  local rel="$1" helper="$2" paragraph phrase missing=()
  paragraph="$(awk -v RS= '/^\*\*After you dispatch/' "$ROOT/$rel" | tr '\n' ' ' | tr -s ' ')"
  if [ -z "$paragraph" ]; then
    bad "$rel — no paragraph starts with '**After you dispatch'"
    return
  fi
  for phrase in \
    "Never end your turn while a $helper has not reported." \
    "A sub-agent receives a $helper's notice only during its own tool calls, and nothing wakes it after it ends its turn." \
    'First do any work that does not need' \
    "keep making short tool calls until every $helper has reported" \
    'Never wait with a long `sleep`' \
    "never poll a $helper's output file"; do
    [[ $paragraph == *"$phrase"* ]] || missing+=("$phrase")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    ok "$rel states the wait rule and its reason"
  else
    for m in "${missing[@]}"; do bad "$rel — the wait paragraph lacks: $m"; done
  fi
}
check_paragraph references/holmes/review-phases.md helper
check_paragraph references/lestrade/ac-verification-lenses.md lens

stale="$(cd "$ROOT" && grep -rn -i -E 'or end your turn|end your turn:|harness starts your next turn|starts your next turn when a (helper|lens)' \
  agents references skills commands scheduled-tasks hooks --include='*.md' --include='*.ts' --include='*.txt' --include='*.recipe')"
if [ -z "$stale" ]; then
  ok "no shipped text tells an agent to end its turn while helpers run"
else
  while IFS= read -r line; do bad "end-your-turn wording ships: $line"; done <<< "$stale"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
