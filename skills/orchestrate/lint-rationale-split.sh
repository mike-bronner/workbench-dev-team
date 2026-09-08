#!/bin/bash
# Guards the split that keeps the orchestrate skill's reasoning off the dispatch
# path, and its rules stated once. Run directly: ./lint-rationale-split.sh
#
# A LINTER, not a test: every check below is a grep over English sentences in
# shipped Markdown. It executes none of the plugin's shell logic, so the `lint-`
# prefix keeps it out of the suite's test loop and out of what the suite claims
# to guarantee about behaviour.
#
# The skill loads in full on every orchestration; the reference does not load at
# all until a rule is challenged. That saving is the whole reason the reasoning
# moved, and it evaporates the moment an author explains a rule in place again.
# Each of the four relocated arguments is pinned by a phrase belonging to it
# alone: present in the reference, absent from the skill.
#
# One rule stated twice is the same failure in slower motion — two copies drift
# into two rules — so the de-duplicated delegation gate is pinned by count.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$DIR/SKILL.md"
REFERENCE="$DIR/references/brief-rationale.md"
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

# The delegation gate, described once. It was described twice, and two copies of
# one rule drift into two rules.
gate_count="$(grep -cF 'NotebookEdit' "$SKILL")"
gate=()
[ "$gate_count" = 1 ] || gate+=("the delegation gate is described $gate_count times; want exactly 1")
report "gate — the delegation gate is described once" ${gate[@]+"${gate[@]}"}

[ -f "$REFERENCE" ] || { report "reference — references/brief-rationale.md exists" "the file is missing"; echo; echo "$PASS passed, $FAIL failed"; exit 1; }

# Each relocated argument, pinned by a phrase belonging to it alone. Present in
# the reference, absent from the skill — checked both ways, because a phrase
# deleted from both files would otherwise pass as a successful move.
split=()
check_moved() {
  local what="$1" phrase="$2"
  grep -Fq "$phrase" "$REFERENCE" \
    || split+=("$what: the reference no longer carries \"$phrase\"")
  grep -Fq "$phrase" "$SKILL" \
    && split+=("$what: the reasoning is inlined in the skill again (\"$phrase\")")
  return 0
}
check_moved "fan-out exemption"      "622 dispatches"
check_moved "no length limit"        "proxy for prescriptiveness"
check_moved "gate never classifies"  "barely a quarter of the cases"
check_moved "Constraints vs Context" "the token senders reach for by default"
report "split — all four arguments live in the reference, none in the skill" ${split[@]+"${split[@]}"}

# A reference nothing points at is a file nobody reads. Every section of
# reasoning must be reachable from the rule it explains, so the count is read off
# the reference's own headings rather than hard-coded: a section added there
# without a pointer beside its rule reddens, and so does a pointer deleted from
# the skill. No number to bump when the next argument moves out.
sections="$(grep -c '^## ' "$REFERENCE")"
pointers="$(grep -cF 'references/brief-rationale.md' "$SKILL")"
ptr=()
[ "$pointers" -ge "$sections" ] \
  || ptr+=("the skill points at the reference $pointers times for $sections sections of reasoning; every stripped rule needs its pointer")
report "pointers — every stripped rule points at its reasoning" ${ptr[@]+"${ptr[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
