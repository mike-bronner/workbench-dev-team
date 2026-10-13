#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

rule_block() { awk 'BEGIN{RS=""} /Never request a reviewer/' | tr '\n' ' ' | tr -s ' '; }
section() { awk -v s="$1" -v e="$2" 'index($0, s) == 1 {f=1} index($0, e) == 1 {f=0} f' "$3"; }

check() {
  local name="$1" block="$2"
  if [ -z "$block" ]; then bad "$name — no 'Never request a reviewer' block"; return; fi
  ok "$name has the rule"
  [[ $block == *"Mike requests every review himself"* ]] && ok "$name says Mike requests reviews" || bad "$name — does not say Mike requests reviews himself"
  [[ $block == *"gh pr create --reviewer"* ]] && ok "$name names a reviewer at creation" || bad "$name — does not name gh pr create --reviewer"
  [[ $block == *"gh pr edit --add-reviewer"* ]] && ok "$name names a reviewer added later" || bad "$name — does not name gh pr edit --add-reviewer"
  [[ $block == *"requested_reviewers"* ]] && ok "$name names the reviewers API" || bad "$name — does not name the requested-reviewers API"
  [[ $block == *"comment that asks a bot or a person to review"* ]] && ok "$name names a review-request comment" || bad "$name — does not name a comment asking for review"
}

PIPE="$ROOT/references/watson/index-mode-pipeline.md"
SIX="$(section '## 6.' '## 7.' "$ROOT/skills/develop/SKILL.md" | rule_block)"
[[ $SIX == *"Mike requests every review himself"* && $SIX == *"references/pull-requests.md"* ]] \
  && ok "develop SKILL.md §6 has the rule and points at the routes" \
  || bad "develop SKILL.md §6 — no 'Never request a reviewer' rule that names Mike and points at pull-requests.md"
check "develop pull-requests.md" "$(rule_block < "$ROOT/skills/develop/references/pull-requests.md")"
check "Watson pipeline step 5" "$(section '### 5.' '### 6.' "$PIPE" | rule_block)"
[[ "$(section '### 7.' '### 8.' "$PIPE" | tr '\n' ' ')" == *"Request no reviewer when you mark it ready"* ]] \
  && ok "Watson pipeline step 7 forbids a reviewer when marking ready" \
  || bad "Watson pipeline step 7 — does not forbid a reviewer when marking ready"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
