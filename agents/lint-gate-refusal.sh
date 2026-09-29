#!/bin/bash
# Every dev-team agent is told never to disguise a command to get past a gate.
# Run directly: bash agents/lint-gate-refusal.sh
#
# A LINTER, not a test: it greps English prose in the shipped Markdown and runs
# none of the plugin's shell logic.
#
# Why: in a review on 2026-09-28, Holmes got past the installed commit gate by
# building the words "commit" and "push" from pieces at run time. Mike's rule is
# that a deny is the system working and is not routed around. Each agent reads
# only its own file, so the instruction lives in all of them, and a fourth agent
# file without it goes red here on that file alone.
#
# Checks, per agents/*.md:
#   1. A `## When a gate or guard refuses you` section exists.
#   2. It carries the instruction, word for word.
#   3. It names building a word from pieces, which is the case that happened.
#   4. It tells the agent to report the refusal.
#   5. It says that doing what the refusal asks is not routing around it, so the
#      commit guard's own "run it as a plain line" does not read as forbidden.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

RULE='Never reword, split, encode, or rebuild a command to get past a gate or guard.'
n=0
for file in "$DIR"/*.md; do
  agent="$(basename "$file" .md)"; n=$((n + 1))
  section="$(awk '/^## When a gate or guard refuses you/{f=1; next} f && /^## /{exit} f{print}' "$file" | tr '\n' ' ' | tr -s ' ')"
  if [ -z "$section" ]; then
    bad "$agent — no '## When a gate or guard refuses you' section"
    continue
  fi
  [[ $section == *"$RULE"* ]] && ok "$agent states the rule" || bad "$agent — the section lacks: $RULE"
  [[ $section == *"from pieces"* ]] && ok "$agent names building a word from pieces" || bad "$agent — the section does not name building a word from pieces"
  [[ $section == *"Report the refusal"* ]] && ok "$agent says to report the refusal" || bad "$agent — the section does not say to report the refusal"
  [[ $section == *"is not routing around it"* ]] && ok "$agent keeps the plain-line rewrite legal" || bad "$agent — the section does not say that doing what the refusal asks is allowed"
done
[ "$n" -ge 3 ] && ok "$n agent files checked" || bad "only $n agent files found in $DIR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
