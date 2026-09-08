#!/bin/bash
# Guards the orchestrate skill's workspace check. Run directly: ./lint-workspace-check.sh
#
# A LINTER, not a test: every check below is a grep over English sentences in
# shipped Markdown. It executes none of the plugin's shell logic, so the `lint-`
# prefix keeps it out of the suite's test loop and out of what the suite claims
# to guarantee about behaviour.
#
# The orchestrator was creating branches and worktrees on its own initiative.
# Three separate things in this one file pushed that way — both worked examples
# finish at "a PR is open", worktree isolation was a standing rule with no
# counterweight, and the harness itself says to branch first on the default
# branch — so a check covering only one of the three cases restores the behaviour
# through the other two. Each case is pinned here.
#
# The policy is to ASK, never to refuse. Branches and worktrees are the wanted
# outcome of most dev work, so a rewrite into a prohibition would be wrong about
# the policy and would simply get ignored. That direction is checked too.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$DIR/SKILL.md"
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

# Ahead of the dispatch protocol, because a check read after the dispatch rules
# is a check read after the dispatch. Line numbers, not just presence.
placement=()
ws_line="$(grep -n '^## Check the workspace before you dispatch' "$SKILL" | cut -d: -f1)"
dp_line="$(grep -n '^## Dispatch protocol' "$SKILL" | cut -d: -f1)"
[ -n "$ws_line" ] || placement+=("no '## Check the workspace before you dispatch' section")
[ -n "$dp_line" ] || placement+=("no '## Dispatch protocol' section to place it ahead of")
[ -n "$ws_line" ] && [ -n "$dp_line" ] && [ "$ws_line" -gt "$dp_line" ] \
  && placement+=("the workspace check sits after the dispatch protocol, at line $ws_line vs $dp_line")
report "placement — the workspace check comes before the dispatch protocol" ${placement[@]+"${placement[@]}"}

# The section itself. Joined into one string: prose here wraps at 80 columns, so
# a line-scoped grep for a phrase reddens on the wrap and teaches the next
# author to fight the formatter.
section="$(awk '/^## Check the workspace before you dispatch/{f=1;next} f && /^## /{exit} f' "$SKILL" | tr '\n' ' ')"

cases=()
[ -n "$section" ] || cases+=("the section is empty")
printf '%s' "$section" | grep -Fq '`main`, `master`, or `trunk`' \
  || cases+=("no default-branch case: the harness's own 'branch first' goes unqualified")
printf '%s' "$section" | grep -Fq 'feature branch already carrying unrelated work' \
  || cases+=("no case for a feature branch already carrying somebody else's work")
printf '%s' "$section" | grep -Fq 'Inside a worktree' \
  || cases+=("no case for a worktree that is not the one meant for this task")
printf '%s' "$section" | grep -Fq 'isolation: "worktree"' \
  || cases+=("the two-Watsons worktree rule is not stated here, where its counterweight is")
report "cases — all three workspace cases, plus the worktree-isolation rule" ${cases[@]+"${cases[@]}"}

# Asks, never forbids. The human creates branches and worktrees routinely, so a
# section that reads as a prohibition is wrong about the policy.
tone=()
printf '%s' "$section" | grep -Fq 'each ending in a question' \
  || tone+=("the section no longer says every case ends in a question")
printf '%s' "$section" | grep -Fq 'None of the three refuses a dispatch' \
  || tone+=("the section no longer says a case refuses nothing")
printf '%s' "$section" | grep -Eiq 'never create a (new )?(branch|worktree)|do not create a (branch|worktree)' \
  && tone+=("the check has been rewritten as a prohibition, which is not the policy")
report "tone — the check asks the human, and refuses nothing" ${tone[@]+"${tone[@]}"}

# The answer lands in Workdir:, which is why no sixth slot was added. A brief
# whose Workdir carries a bare path must stay valid — most dispatches decide no
# workspace at all — so the allowance is pinned beside the rule.
slot=()
printf '%s' "$section" | grep -Fq 'Record the answer in `Workdir:`' \
  || slot+=("the section never says where the human's answer is recorded")
printf '%s' "$section" | grep -Fq 'A bare path' \
  || slot+=("the bare-path allowance is gone: a Workdir with no branch must stay valid")
report "slot — the answer is recorded in Workdir:, and a bare path stays valid" ${slot[@]+"${slot[@]}"}

# One statement of the worktree-isolation rule, in the section that supplies its
# counterweight. A second copy elsewhere is the standing-rule-with-no-answer
# shape that caused this in the first place.
iso_count="$(grep -cF 'isolation: "worktree"' "$SKILL")"
iso=()
[ "$iso_count" = 1 ] || iso+=("'isolation: \"worktree\"' appears $iso_count times; want exactly 1, inside the workspace check")
report "isolation — the worktree rule is stated once, beside its counterweight" ${iso[@]+"${iso[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
