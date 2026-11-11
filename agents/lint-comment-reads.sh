#!/bin/bash

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

for rel in agents/holmes.md agents/holmes-index.md; do
  file="$ROOT/$rel"
  [ -f "$file" ] || { bad "$rel — missing"; continue; }
  reads=$(grep -c 'gh api --paginate' "$file")
  [ "$reads" -ge 1 ] && ok "$rel has $reads paginated gh reads" || bad "$rel — no paginated gh read found"
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*[A-Z_]+=\$\(gh\ api\ --paginate\ \"[^\"]*\"\)\ \|\|\ exit\ 2$ ]] \
      && ok "$rel captures and checks: ${line#"${line%%[![:space:]]*}"}" \
      || bad "$rel — a paginated read is not captured with '|| exit 2' before it is filtered: $line"
  done < <(grep 'gh api --paginate' "$file")
  filters=$(grep -c '<<< "\$[A-Z_]*_PAGES"' "$file")
  [ "$filters" -eq "$reads" ] && ok "$rel filters each of its $reads captured reads" \
    || bad "$rel — $reads paginated reads but $filters filters of captured pages"
  while IFS= read -r line; do
    [[ $line == *'|| exit 2' ]] && ok "$rel filters captured pages and stops on a bad page" \
      || bad "$rel — a filter of captured pages does not end in '|| exit 2': $line"
  done < <(grep '<<< "\$[A-Z_]*_PAGES"' "$file")
  grep -q 'If the read exits 2, gh failed on some page' "$file" \
    && ok "$rel says what the bounce read does after a failure" \
    || bad "$rel — the bounce read does not say what Holmes does when it exits 2"
  grep -q 'A failed read does not mean the PR has no strikes' "$file" \
    && ok "$rel says a failed strike read is not zero strikes" \
    || bad "$rel — the strike read does not say a failed read is not zero strikes"
done

pipeline="$ROOT/references/watson/index-mode-pipeline.md"
calls=$(grep -c 'bin/trusted-comments.sh" <repo> <issue_number>' "$pipeline")
[ "$calls" -ge 1 ] && ok "the pipeline reads trusted issue comments ($calls calls)" \
  || bad "the pipeline has no trusted-comments.sh call on the issue"
while IFS= read -r line; do
  [[ $line == *'bin/trusted-comments.sh" <repo> <issue_number> --no-issue-author'* ]] \
    && ok "the architecture-answer read gives the issue's author no trust" \
    || bad "the pipeline's trusted-comments.sh call lacks --no-issue-author: $line"
done < <(grep 'bin/trusted-comments.sh" <repo> <issue_number>' "$pipeline")
bullet="$(awk '/^- \*\*Architecture:\*\*/{f=1} f && /^- \*\*Tactical:\*\*/{exit} f{print}' "$pipeline" | tr '\n' ' ' | tr -s ' ')"
[[ $bullet == *'Take the newest comment in that list whose `created_at` is later than your own escalation comment.'* ]] \
  && ok "the Architecture bullet takes the newest trusted reply after the escalation" \
  || bad "the Architecture bullet does not say which trusted reply wins"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
