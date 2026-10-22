#!/bin/bash
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
# decision.
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
# The dev-team session rules (hooks/mods/session-rules.ts) as the model reads
# them: the RULES template literal, its backticks unescaped, joined into one
# line. It fails, under pipefail, when the literal is not found or never
# closes, and the text is then emptied so every check on it fails too.
rules_text() {
  awk '
    /^export const RULES = `/ { f = 1; sub(/^export const RULES = `/, "") }
    f && /[^\\]`$/ { sub(/`$/, ""); print; found = 1; exit }
    f { print }
    END { exit !found }' "$ROOT/hooks/mods/session-rules.ts" | sed 's/\\`/`/g' | tr '\n' ' ' | tr -s ' '
}
if ! RULES_TEXT="$(set -o pipefail; rules_text)" || [ -z "$RULES_TEXT" ]; then
  bad "hooks/mods/session-rules.ts — no closed RULES template literal found"
  RULES_TEXT=""
fi
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
  check "$s" 'Show the table in the reply first, even a sub-agent'"'"'s, whose hand-back the human never sees' "develop shows a relayed table in the reply first" "develop — a relayed table no longer goes in the reply before the question"
  check "$s" 'Never name an option the reply does not show' "develop bans a label for options the reply does not show" "develop — lost 'Never name an option the reply does not show'"
fi

# 6. Orchestrate brings every returned decision home through AskUserQuestion.
section skills/orchestrate/SKILL.md '**Decisions come home through' '- **You never do the work' orchestrate
if [ -n "$s" ]; then
  check "$s" 'Put each one to the human through `AskUserQuestion`' "orchestrate puts each decision through AskUserQuestion" "orchestrate — the decisions bullet no longer routes them through AskUserQuestion"
  check "$s" 'show it in the reply, just above the call' "orchestrate shows the agent's table in the reply before the call" "orchestrate — the agent's options table no longer goes in the reply before the call"
  check "$s" 'with its grades and recommendation' "orchestrate shows the table with its grades and recommendation" "orchestrate — the shown table lost its grades and recommendation"
  check "$s" 'Never ask with a label for options the reply does not show' "orchestrate bans a label for options the reply does not show" "orchestrate — lost 'Never ask with a label for options the reply does not show'"
  for kind in 'fork' 'rubric dispute' 'questions only the human can settle' 'never as prose' 'grade' 'warning' 'recommended option first'; do
    check "$s" "$kind" "orchestrate decisions bullet names: $kind" "orchestrate — the decisions bullet lost: $kind"
  done
fi
if grep -Fq 'Relay them to the user untouched' "$ROOT/skills/orchestrate/SKILL.md"; then
  bad "orchestrate — forks are relayed untouched as prose again"
else
  ok "orchestrate no longer relays forks as prose"
fi

section skills/git-commit/SKILL.md '## Committing and pushing' '**Run it as a plain git line' git-commit
gc="$s"
section skills/orchestrate/SKILL.md '### Direct-mode work comes back uncommitted' '## Action routing' orchestrate
oc="$s"
APPROVAL_PL='
  next if $ARGV =~ m{/testdata/};
  (my $t = $_) =~ s/\s+/ /g;
  for my $s (split /(?<=[.!?])\s+/, $t) {
    print "$ARGV: $s\n" if $s =~ /"Commit it"|\bCommit it\b.*\bpick\b|"Not yet"|approves exactly those actions|typed prompts? (?:count|approves?)|never approves a release|only prompt for its commit|commit question|\b(?:the|a) commit offer|\bapprov\w*\b[^.]*\b(?:covers?|includes?|extends? to)\b[^.]*\bpush|\b(?:typed|types|prompt)\b[^.]*\bapproves?\b|\bapproves? (?:(?:a|the|one|each|every|its|that) )?(?:commit|push|release)|\bpick\b[^.]*\b(?:approv|cover)\w*[^.]*\bpush|\bpush of (?:that|its|the) commit/i;
  }
  close ARGV'
for fixture in 'A "Commit it" pick approves one commit.' 'A pick approves the commit and the push of that commit.' 'A prompt the human types that names commit approves exactly those actions.' 'Ask the commit question alone.' 'Only the human'"'"'s own typed prompts count.' 'A pick never approves a release.' 'A commit approval also covers the push.' 'A typed request approves a release.' 'A prompt the human types approves a commit.'; do
  [ -n "$(printf '%s' "$fixture" | perl -0777 -ne "$APPROVAL_PL")" ] && ok "the approval check flags: $fixture" || bad "the approval check misses: $fixture"
done
for fixture in 'The orchestrator takes the uncommitted tree from there.' 'Index-mode development commits and pushes unattended.' 'The human picks them.' 'Holmes approves the PR when every criterion is met.' 'Pick a branch, then push it.' 'The pipeline never waits for approval: board dispatch is the approval.'; do
  [ -z "$(printf '%s' "$fixture" | perl -0777 -ne "$APPROVAL_PL")" ] && ok "the approval check passes: $fixture" || bad "the approval check flags a clean line: $fixture"
done
restated="$(shipped '*.md' '*.txt' | (cd "$ROOT" && xargs -0 perl -0777 -ne "$APPROVAL_PL"))"
restated="$restated$(printf '%s' "$RULES_TEXT" | perl -0777 -ne "$APPROVAL_PL" | sed 's|^-: |session rules: |')"
if [ -z "$restated" ]; then ok "no shipped text or session rule restates core's commit approval"; else bad "core's commit approval is restated in: $restated"; fi

for f in agents/watson.md agents/watson-direct.md; do
  joined="$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')"
  check "$joined" 'the full `git status --short --untracked-files=all` output of the tree' "$f hands back the whole status list" "$f — the hand-back no longer carries the full git status list"
  check "$joined" 'never trimmed to your own file list' "$f hands back the status list untrimmed" "$f — no longer says the status list is never trimmed to its own file list"
  check "$joined" 'The orchestrator takes the uncommitted tree from there.' "$f leaves the tree to the orchestrator" "$f — no longer says the orchestrator takes the uncommitted tree"
done
[ -n "$oc" ] && check "$oc" "read the tree itself, never only the report's file list" "orchestrate reads the tree, not the report's file list" "orchestrate — no longer reads the tree itself rather than the report's file list"
check "$RULES_TEXT" 'The orchestrator takes the uncommitted tree from there.' "the session rules leave the tree to the orchestrator" "session rules — no longer say the orchestrator takes the uncommitted tree"

GC_ALL="$(tr '\n' ' ' < "$ROOT/skills/git-commit/SKILL.md" | tr -s ' ')"
check "$GC_ALL" 'A push that forces or deletes remote refs (`--force`, `-f`, a `+` refspec, `--mirror`, `--delete`, `-d`, a `:branch` refspec, `--prune`) is refused outright.' "git-commit keeps force push blocked in every lane" "git-commit — lost the rule that a push that forces or deletes is refused outright"
NOPATH_PL='
  my $t = $_;
  my @cmds;
  push @cmds, $1 while $t =~ /`([^`\n]+)`/g;
  push @cmds, split /\n/, $1 while $t =~ /^[ \t]*```[^\n]*\n(.*?)^[ \t]*```/msg;
  for my $c (@cmds) {
    for my $seg (split /\s*(?:&&|\|\||;|\|)\s*/, $c) {
      next unless $seg =~ /^\s*git((?:\s+-[Cc]\s+\S+|\s+--?[\w-]+(?:=\S+)?)*)\s+commit(?=\s|$)(.*)$/;
      my @w = $2 =~ /(<[A-Za-z][^<>]*>|"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27|\S+)/g;
      my $bad = "";
      for (my $i = 0; $i < @w && !$bad; $i++) {
        my $a = $w[$i];
        next if $a eq "*" || $a =~ /^\d*[<>]/ && $a !~ /^<[A-Za-z]/;
        if ($a eq "--" || $a =~ /^--(?:only|include|patch|pathspec-from-file)(?:=|$)/) { $bad = $a; last }
        if ($a =~ /^--(?:message|file|reuse-message|reedit-message|author|date|cleanup|fixup|squash|trailer|template)$/) { $i++; next }
        next if $a =~ /^--/;
        if ($a =~ /^-(\w+)$/) {
          my @l = split //, $1;
          for my $k (0 .. $#l) {
            if ($l[$k] =~ /[poi]/) { $bad = $a; last }
            if ($l[$k] =~ /[mFCct]/) { $i++ if $k == $#l; last }
          }
          next;
        }
        $bad = $a;
      }
      print "$ARGV: $seg\n" if $bad ne "";
    }
  }
  close ARGV'
for fixture in 'Run `git commit -m x src/a.ts`.' 'Run `git -C /r commit -- a.txt`.' 'Run `git commit -p`.' 'Run `git commit --only -m x a`.' "Run \`git commit -m 'x' ':(exclude)a'\`."; do
  [ -n "$(printf '%s' "$fixture" | perl -0777 -ne "$NOPATH_PL")" ] && ok "the no-path check flags: $fixture" || bad "the no-path check misses: $fixture"
done
for fixture in 'Run `git commit -m "fix: x."`.' 'Run `git -C <repo> commit -F <absolute path>`.' 'Run `git -c user.name=x commit -am x`.' 'Rule `git commit *`.'; do
  [ -z "$(printf '%s' "$fixture" | perl -0777 -ne "$NOPATH_PL")" ] && ok "the no-path check passes: $fixture" || bad "the no-path check flags a clean line: $fixture"
done
pathy="$(shipped '*.md' | (cd "$ROOT" && xargs -0 perl -0777 -ne "$NOPATH_PL"))"
pathy="$pathy$(printf '%s' "$RULES_TEXT" | perl -0777 -ne "$NOPATH_PL" | sed 's|^-: |session rules: |')"
if [ -z "$pathy" ]; then ok "no git commit command in shipped Markdown or the session rules names a path or picks hunks"; else bad "a git commit command names paths or picks hunks: $pathy"; fi
[ -n "$gc" ] && check "$gc" 'A sub-agent does not commit or push, and never asks to.' "git-commit still bars a sub-agent from committing or asking to" "git-commit — lost 'A sub-agent does not commit or push, and never asks to.'"

# 8a. A sub-agent never asks to commit, and no report template invites one.
check "$(tr '\n' ' ' < "$ROOT/agents/watson.md" | tr -s ' ')" 'Your report never asks to commit and never invites a commit' "watson's Direct-mode report never invites a commit" "watson — the Direct-mode report no longer says it never invites a commit"
check "$(tr '\n' ' ' < "$ROOT/skills/develop/SKILL.md" | tr -s ' ')" 'The report never asks to commit and never invites a commit' "develop's sub-agent report never invites a commit" "develop — the sub-agent hand-back no longer says it never invites a commit"
check "$RULES_TEXT" 'does not commit, merge, or push, and never asks to.' "the session rules bar a sub-agent from asking to commit" "session rules — lost 'and never asks to.' for sub-agents"
invite="$(shipped 'agents/*.md' 'skills/*.md' | (cd "$ROOT" && xargs -0 perl -0777 -ne '
  (my $t = $_) =~ s/\s+/ /g;
  print "$ARGV: $1\n" while $t =~ /((?:shall|should|may|can) I commit|want me to commit|ready to (?:be )?commit|say the word and I\S* commit)/gi;
  close ARGV'))"
if [ -z "$invite" ]; then ok "no agent or skill text invites a commit"; else bad "text invites a commit: $invite"; fi

# 8b. Index-mode development never asks about committing or pushing.
for f in skills/git-commit/SKILL.md README.md; do
  check "$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')" 'never asks about committing or pushing' "$f: Index mode never asks about committing or pushing" "$f — no longer says Index mode never asks about committing or pushing"
done
check "$RULES_TEXT" 'never asks about committing or pushing' "the session rules: Index mode never asks about committing or pushing" "session rules — no longer say Index mode never asks about committing or pushing"
check "$(tr '\n' ' ' < "$ROOT/skills/develop/SKILL.md" | tr -s ' ')" 'The pipeline never asks about committing or pushing, and never waits for approval' "develop: the pipeline never asks or waits" "develop — the pipeline lane no longer says it never asks or waits"
index_text="$(cat "$ROOT/references/watson/index-mode-pipeline.md"; awk '/^## The Index mode/{f=1} /^## Rules/{f=0} f' "$ROOT/agents/watson.md")"
if printf '%s' "$index_text" | grep -Eqi 'AskUserQuestion|Commit it|approval to (commit|push)|wait for .*approv'; then
  bad "an Index-mode path asks, offers, or waits for commit or push approval"
else
  ok "no Index-mode path asks, offers, or waits for commit or push approval"
fi
[ -n "$gc" ] && check "$gc" 'as the mechanical backstop' "git-commit keeps the permission prompt as the backstop" "git-commit — the permission prompt is no longer the backstop"
[ -n "$oc" ] && check "$oc" 'Never send the agent back to commit' "orchestrate still keeps the commit away from the sub-agent" "orchestrate — lost 'Never send the agent back to commit'"

# 9. The README names every lint script, with the right count.
lints=()
while IFS= read -r -d '' p; do lints+=("$p"); done < <(shipped '*lint-*.sh')
words=(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen)
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
