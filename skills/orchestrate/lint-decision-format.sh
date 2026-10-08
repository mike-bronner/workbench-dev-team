#!/bin/bash
# Every decision that reaches Mike is a graded table, every one that comes back
# into a session reaches him through AskUserQuestion, and a commit offer never
# leads with "Commit it" before his review is done.
# Run directly: bash skills/orchestrate/lint-decision-format.sh
#
# A LINTER, not a test: it greps English prose in the shipped Markdown and runs
# none of the plugin's shell logic.
#
# Why: Mike reads sessions in an 80x50 terminal. One heading per option, or a
# numbered pros/cons list, scrolled the grades a decision depended on off the
# screen, and a decision relayed as prose left him to scroll back for it. The
# Clear output style (workbench-core rules 4 and 6) asks for one table with the
# columns Option, Pros, Cons, and Grade, and for AskUserQuestion on every
# decision. A commit offer is the exception to "recommended first": a "Commit
# it" click offered as review starts would approve a tree Mike has not finished
# reading, so the vault rule that approval follows his review is pinned here.
#
# Checks:
#   1. No shipped Markdown carries a per-option heading or a pros/cons list
#      (numbered, bulleted, or bold-labelled).
#   2. Holmes's AC dispute and Lestrade's oversized-unit escalation post the
#      table and the recommendation after it, keep their HTML marker, and still
#      take a numbered reply. Each section must end at its own end marker, so a
#      section that runs on into unrelated text fails instead of passing.
#   3. Holmes's Local-mode rubric dispute uses the table and the
#      recommendation, and is written for AskUserQuestion.
#   4. Watson's blocked-fork comment uses the table and a recommendation.
#   5. The develop skill puts the recommendation after the table.
#   6. The orchestrate skill brings every returned fork, rubric dispute,
#      human-only question, and commit offer home through AskUserQuestion, and
#      no longer relays them untouched.
#   7. The commit offer: asked alone, "Not yet" or the Holmes review first until
#      the review is done, "Commit it" last, and its description confirms the
#      review. No shipped text lists "Commit it" ahead of another option.
#   8. Every commit-approval line uses one wording: a "Commit it" pick in
#      AskUserQuestion, and never a typed message in chat. The boundary holds:
#      a sub-agent never commits or pushes, and the prompt is the backstop.
#  8a. A sub-agent never asks to commit, and no report template invites one.
#  8b. Index-mode development never asks, offers, or waits for approval to
#      commit or push.
#   9. The README names every lint script, with the right count.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
has() { [[ $1 == *"$2"* ]]; }
check() { if has "$1" "$2"; then ok "$3"; else bad "$4"; fi; }
TABLE='| Option | Pros | Cons | Grade |'
APPROVAL='a "Commit it" pick in `AskUserQuestion`, once the human says their review is done'

# The text from the line holding $2 up to the line holding $3, joined into one
# line with comment leaders and runs of spaces collapsed, because prose wraps.
# Empty when the end marker never appears, so a section cannot silently run on.
between() {
  awk -v a="$2" -v b="$3" '
    !f && index($0, a) { f = 1 }
    f && index($0, b) && !index($0, a) { found = 1; exit }
    f { buf = buf $0 "\n" }
    END { if (found) printf "%s", buf }' "$ROOT/$1" | sed -E 's/^[[:space:]]*# ?//' | tr '\n' ' ' | tr -s ' '
}
section() { # $1 file, $2 start, $3 end, $4 label
  s="$(between "$1" "$2" "$3")"
  [ -n "$s" ] || bad "$4 — no section from '$2' to '$3' in $1"
}
# Shipped files, NUL-separated so a path with a space or newline stays whole.
shipped() { (cd "$ROOT" && git ls-files -z -co --exclude-standard -- "$@"); }

# 1. The old formats, anywhere in shipped Markdown.
old="$(shipped '*.md' | (cd "$ROOT" && xargs -0 perl -ne '
  print "$ARGV:$.: $_" if
       /^#{1,6}\s.*\bOption\s+(?:[A-C]|\d+)\b/i
    || /^\s*(?:\d+[.)]|[-*])\s.*\bpros\b\**:.*\bcons\b/i
    || /^\s*(?:[-*]\s+)?(?:\*\*|\*)?(?:Pros|Cons)(?:\*\*|\*)?\s*:/i
    || /\*\*(?:Pros|Cons):?\*\*|\*(?:pros|cons):\*/i;
  close ARGV if eof'))"
if [ -z "$old" ]; then ok "no per-option heading or pros/cons list in shipped Markdown"; else bad "old option format still shipped: $old"; fi

# 2. GitHub escalations: table, recommendation, marker, reply by number.
section agents/holmes.md '#### 🛑 ESCALATE' 'The PR waits for Mike to pick an option' holmes
if [ -n "$s" ]; then
  check "$s" "$TABLE" "holmes AC dispute posts the graded table" "holmes — the AC dispute comment lost the Option | Pros | Cons | Grade table"
  check "$s" 'then one or two sentences naming your recommendation' "holmes AC dispute puts the recommendation after the table" "holmes — the AC dispute lost the recommendation after the table"
  check "$s" '<!-- holmes-ac-dispute -->' "holmes AC dispute keeps its marker" "holmes — the AC dispute comment lost <!-- holmes-ac-dispute -->"
  check "$s" 'reply with just the option number' "holmes AC dispute still takes a numbered reply" "holmes — the AC dispute no longer lets Mike reply with a number"
fi

section agents/lestrade.md '**If step 4.5 flagged' '### 8. Report' lestrade
if [ -n "$s" ]; then
  check "$s" "$TABLE" "lestrade oversized unit posts the graded table" "lestrade — the oversized-unit comment lost the Option | Pros | Cons | Grade table"
  check "$s" 'then one or two sentences naming your recommendation' "lestrade oversized unit puts the recommendation after the table" "lestrade — the oversized-unit escalation lost the recommendation after the table"
  check "$s" '<!-- lestrade-oversized-unit -->' "lestrade oversized unit keeps its marker" "lestrade — the oversized-unit comment lost <!-- lestrade-oversized-unit -->"
  check "$s" 'reply with a number' "lestrade oversized unit still takes a numbered reply" "lestrade — the oversized-unit escalation no longer lets Mike reply with a number"
fi

# 3. Local-mode rubric dispute.
section references/holmes/local-review.md '**🛑 Rubric dispute**' '**Follow-ups are reported' local-review
if [ -n "$s" ]; then
  check "$s" 'Option, Pros, Cons, and Grade' "local rubric dispute uses the graded table" "local-review — the rubric dispute no longer uses the Option, Pros, Cons, and Grade table"
  check "$s" 'then one or two sentences naming your recommendation' "local rubric dispute puts the recommendation after the table" "local-review — the rubric dispute lost the recommendation after the table"
  check "$s" 'through `AskUserQuestion`' "local rubric dispute is written for AskUserQuestion" "local-review — the rubric dispute no longer names AskUserQuestion"
fi

# 4. Watson's blocked-fork comment in the pipeline.
section references/watson/index-mode-pipeline.md '#### If a fork blocks you' 'Then move the item' index-mode-pipeline
if [ -n "$s" ]; then
  check "$s" 'one graded table (Option, Pros, Cons, Grade)' "watson blocked fork uses the graded table" "index-mode-pipeline — the blocked-fork comment lost the graded table"
  check "$s" 'then a short recommendation' "watson blocked fork carries a recommendation" "index-mode-pipeline — the blocked-fork comment lost its recommendation"
fi

# 5. The develop skill's format section.
section skills/develop/SKILL.md '**Format when presenting options.**' '**What happens next depends on your lane.**' develop
if [ -n "$s" ]; then
  check "$s" 'After the table, one or two sentences name the recommendation, its grade, and its reason' "develop puts the recommendation after the table" "develop — the format lost the recommendation after the table"
fi

# 6. Orchestrate brings every returned decision home through AskUserQuestion.
section skills/orchestrate/SKILL.md '**Decisions come home through' '- **You never do the work' orchestrate
if [ -n "$s" ]; then
  check "$s" 'Put each one to the human through `AskUserQuestion`' "orchestrate puts each decision through AskUserQuestion" "orchestrate — the decisions bullet no longer routes them through AskUserQuestion"
  for kind in 'fork' 'rubric dispute' 'questions only the human can settle' 'commit offer' 'never as prose' 'grade' 'warning' 'recommended option first'; do
    check "$s" "$kind" "orchestrate decisions bullet names: $kind" "orchestrate — the decisions bullet lost: $kind"
  done
fi
if grep -Fq 'Relay them to the user untouched' "$ROOT/skills/orchestrate/SKILL.md"; then
  bad "orchestrate — forks are relayed untouched as prose again"
else
  ok "orchestrate no longer relays forks as prose"
fi

# 7. The commit offer's timing and ordering.
section skills/git-commit/SKILL.md '## Committing and pushing' '**Run it as a plain git line' git-commit
gc="$s"
section skills/orchestrate/SKILL.md '### Direct-mode work comes back uncommitted' '## Action routing' orchestrate
oc="$s"
for pair in "git-commit:$gc" "orchestrate:$oc"; do
  name="${pair%%:*}"; t="${pair#*:}"
  [ -n "$t" ] || continue
  check "$t" 'Offer the commit through `AskUserQuestion`' "$name offers the commit through AskUserQuestion" "$name — the commit offer no longer goes through AskUserQuestion"
  check "$t" 'alone' "$name asks the commit question alone" "$name — the commit question is no longer asked alone"
  check "$t" 'the recommended first option is "Not yet" or' "$name leads with Not yet until the review is done" "$name — the commit offer no longer leads with Not yet before the review is done"
  check "$t" '"Commit it" goes last' "$name puts Commit it last before the review is done" "$name — Commit it is no longer last before the review is done"
  check "$t" '"Picking this confirms you have reviewed the whole tree."' "$name's Commit it description confirms the review" "$name — the Commit it description no longer confirms the review"
  check "$t" 'Do not offer the commit before then. If an offer does reach the human early, "Not yet" leads.' "$name forbids an early offer" "$name — lost 'Do not offer the commit before then'"
done
[ -n "$gc" ] && check "$gc" 'Never bundle' "git-commit forbids bundling the commit question" "git-commit — lost 'Never bundle' for the commit question"
# "Commit it" ahead of "Not yet" in one sentence, or in one block of list items
# (bullets, numbered items, or table rows), in any shipped Markdown or script.
early="$(shipped '*.md' '*.sh' | (cd "$ROOT" && xargs -0 perl -0777 -ne '
  next if $ARGV =~ m{lint-decision-format\.sh$|/testdata/};
  my $ahead = qr/\bCommit\s+it\b.*?\bNot\s+yet\b/s;
  for my $block (/((?:^[ \t]*(?:[-*+]\s|\d+[.)]\s|\|)[^\n]*\n?)+)/mg) { print "$ARGV: list\n" if $block =~ $ahead }
  (my $t = $_) =~ s/\s+/ /g;
  for my $s (split /(?<=[.!?])\s+/, $t) { print "$ARGV: $s\n" if $s =~ $ahead }
  close ARGV'))"
if [ -z "$early" ]; then ok "no shipped text lists Commit it ahead of another option"; else bad "Commit it listed first in: $early"; fi

# 8. One approval wording, and the boundary it must not move.
for f in skills/git-commit/SKILL.md skills/orchestrate/SKILL.md skills/develop/SKILL.md agents/watson.md README.md session-warmup.md commands/setup.md hooks/mods/commit-guard.ts; do
  joined="$(sed -E 's/^[[:space:]]*(#|\/\/) ?//' "$ROOT/$f" | tr '\n' ' ' | tr -s ' ')"
  check "$joined" "$APPROVAL" "$f uses the shared approval wording" "$f — no line carries: $APPROVAL"
done
# A sentence that pairs a commit approval with chat lets a typed message stand
# as approval, unless the sentence is the one saying it does not count.
stale="$(shipped '*.md' '*.sh' '*.json' | (cd "$ROOT" && xargs -0 perl -0777 -ne '
  next if $ARGV =~ m{lint-decision-format\.sh$|/testdata/};
  (my $t = $_) =~ s/\n\s*#?\s*/ /g;
  for my $sentence (split /(?<=[.!?])\s+/, $t) {
    next unless $sentence =~ /\bin chat\b/i;
    next unless $sentence =~ /commit it|approv\w* (?:a |the )?commit|commit approval/i;
    next if $sentence =~ /does not count|not a typed/i;
    print "$ARGV: $sentence\n";
  }
  close ARGV'))"
if [ -z "$stale" ]; then ok "no text lets a chat message stand as commit approval"; else bad "chat counts as commit approval in: $stale"; fi
for f in skills/git-commit/SKILL.md skills/orchestrate/SKILL.md skills/develop/SKILL.md README.md session-warmup.md; do
  joined="$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')"
  check "$joined" 'typed "commit it" in chat' "$f says a typed message does not count" "$f — no longer says a typed \"commit it\" in chat does not count"
done
[ -n "$gc" ] && check "$gc" 'A sub-agent does not commit or push, and never asks to.' "git-commit still bars a sub-agent from committing or asking to" "git-commit — lost 'A sub-agent does not commit or push, and never asks to.'"

# 8a. A sub-agent never asks to commit, and no report template invites one.
check "$(tr '\n' ' ' < "$ROOT/agents/watson.md" | tr -s ' ')" 'Your report never asks to commit and never invites a commit' "watson's Direct-mode report never invites a commit" "watson — the Direct-mode report no longer says it never invites a commit"
check "$(tr '\n' ' ' < "$ROOT/skills/develop/SKILL.md" | tr -s ' ')" 'The report never asks to commit and never invites a commit' "develop's sub-agent report never invites a commit" "develop — the sub-agent hand-back no longer says it never invites a commit"
check "$(tr '\n' ' ' < "$ROOT/session-warmup.md" | tr -s ' ')" 'does not commit, merge, or push, and never asks to.' "session-warmup bars a sub-agent from asking to commit" "session-warmup — lost 'and never asks to.' for sub-agents"
invite="$(shipped 'agents/*.md' 'skills/*.md' | (cd "$ROOT" && xargs -0 perl -0777 -ne '
  (my $t = $_) =~ s/\s+/ /g;
  print "$ARGV: $1\n" while $t =~ /((?:shall|should|may|can) I commit|want me to commit|ready to (?:be )?commit|say the word and I\S* commit)/gi;
  close ARGV'))"
if [ -z "$invite" ]; then ok "no agent or skill text invites a commit"; else bad "text invites a commit: $invite"; fi

# 8b. Index-mode development never asks about committing or pushing.
for f in skills/git-commit/SKILL.md session-warmup.md README.md; do
  check "$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')" 'never asks about committing or pushing' "$f: Index mode never asks about committing or pushing" "$f — no longer says Index mode never asks about committing or pushing"
done
check "$(tr '\n' ' ' < "$ROOT/skills/develop/SKILL.md" | tr -s ' ')" 'The pipeline never asks about committing or pushing, and never waits for approval' "develop: the pipeline never asks or waits" "develop — the pipeline lane no longer says it never asks or waits"
index_text="$(cat "$ROOT/references/watson/index-mode-pipeline.md"; awk '/^## The Index mode/{f=1} /^## Rules/{f=0} f' "$ROOT/agents/watson.md")"
if printf '%s' "$index_text" | grep -Eqi 'AskUserQuestion|Commit it|approval to (commit|push)|wait for .*approv'; then
  bad "an Index-mode path asks, offers, or waits for commit or push approval"
else
  ok "no Index-mode path asks, offers, or waits for commit or push approval"
fi
[ -n "$gc" ] && check "$gc" 'mechanical backstop, not the' "git-commit keeps the permission prompt as the backstop" "git-commit — the permission prompt is no longer the backstop"
[ -n "$oc" ] && check "$oc" 'Never send the agent back to commit' "orchestrate still keeps the commit away from the sub-agent" "orchestrate — lost 'Never send the agent back to commit'"

# 9. The README names every lint script, with the right count.
lints=()
while IFS= read -r -d '' p; do lints+=("$p"); done < <(shipped '*lint-*.sh')
words=(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen)
n=${#lints[@]}
# Scoped to the lint bullet: other README paragraphs name some lints too, and
# would hide a script dropped from the list.
section README.md '**`lint-*.sh`**' 'Every script sandboxes itself' README
if [ -n "$s" ]; then
  check "$s" "**\`lint-*.sh\`** — ${words[$n]:-$n} scripts" "README counts $n lint scripts" "README — the lint count is not '${words[$n]:-$n} scripts'"
  for p in "${lints[@]}"; do
    check "$s" "\`$p\`" "README lint list names $p" "README — the lint list does not name $p"
  done
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
