#!/bin/bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$DIR/SKILL.md"
REFERENCE="$DIR/../develop/references/pull-requests.md"
PASS=0
FAIL=0

report() {
  local label="$1"; shift
  if [ "$#" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  ✅ $label"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $label"; for m in "$@"; do echo "       • $m"; done
  fi
}

[ -f "$SKILL" ] || { echo "  ❌ no SKILL.md beside this linter"; exit 1; }

section="$(awk '/^## Opening a PR$/{f=1;next} f && /^## /{exit} f' "$SKILL" | tr -s '[:space:]' ' ')"

owner=()
[ -n "$section" ] || owner+=("no '## Opening a PR' section")
printf '%s' "$section" | grep -Fq 'You open the pull request for Direct-mode work.' \
  || owner+=("the section no longer says the orchestrator opens the PR for Direct-mode work")
report "owner — the orchestrator opens Direct-mode PRs" ${owner[@]+"${owner[@]}"}

reads=()
printf '%s' "$section" | grep -Fq 'Before you draft the body, read `skills/develop/references/pull-requests.md`' \
  || reads+=("the section no longer sends the orchestrator to the develop PR reference before it drafts the body")
printf '%s' "$section" | grep -Fq "and the repo's PR template." \
  || reads+=("the section no longer sends the orchestrator to the repo's PR template")
[ -f "$REFERENCE" ] || reads+=("skills/develop/references/pull-requests.md, which the section names, does not exist")
report "reads — the develop PR reference and the repo's template, before the body" ${reads[@]+"${reads[@]}"}

headings=()
printf '%s' "$section" | grep -Fq "The body follows the template's headings" \
  || headings+=("the section no longer says the body follows the template's headings")
report "headings — the body follows the template" ${headings[@]+"${headings[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
