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
#      AskUserQuestion. The boundary holds:
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
TYPED='approves exactly those actions, for the turn that prompt opened'
NEGATED='A negated, deferred, or question-form prompt approves nothing'
OWN='own typed prompts count'

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
for f in skills/git-commit/SKILL.md skills/orchestrate/SKILL.md skills/develop/SKILL.md agents/watson.md README.md commands/setup.md; do
  joined="$(sed -E 's/^[[:space:]]*(#|\/\/) ?//' "$ROOT/$f" | tr '\n' ' ' | tr -s ' ')"
  check "$joined" "$APPROVAL" "$f uses the shared approval wording" "$f — no line carries: $APPROVAL"
done
check "$RULES_TEXT" "$APPROVAL" "the session rules use the shared approval wording" "session rules — no line carries: $APPROVAL"
STALE_PL='
  next if $ARGV =~ m{lint-decision-format\.sh$|/testdata/};
  (my $t = $_) =~ s/\n\s*(?:#|\/\/)?\s*/ /g;
  for my $sentence (split /(?<=[.!?])\s+/, $t) {
    next unless $sentence =~ /\btyped\b|\bin chat\b/i;
    next unless $sentence =~ /commit/i;
    next unless $sentence =~ /(?:does|do) not count|doesn.t count|not a typed/i;
    print "$ARGV: $sentence\n";
  }
  close ARGV'
stale="$(shipped '*.md' '*.sh' '*.json' '*.ts' | (cd "$ROOT" && xargs -0 perl -0777 -ne "$STALE_PL"))"
stale="$stale$(printf '%s' "$RULES_TEXT" | perl -0777 -ne "$STALE_PL" | sed 's|^-: |session rules: |')"
if [ -z "$stale" ]; then ok "no text says a typed request for a commit does not count"; else bad "a typed request still does not count in: $stale"; fi
for f in skills/git-commit/SKILL.md skills/orchestrate/SKILL.md skills/develop/SKILL.md README.md; do
  joined="$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')"
  check "$joined" "$TYPED" "$f scopes a typed request to its turn" "$f — no line carries: $TYPED"
  check "$joined" "$NEGATED" "$f says a negated or question prompt approves nothing" "$f — no line carries: $NEGATED"
  check "$joined" "$OWN" "$f counts only the human's own typed prompts" "$f — no line carries: $OWN"
done
for want in "$TYPED" "$NEGATED" "$OWN"; do
  check "$RULES_TEXT" "$want" "the session rules carry: $want" "session rules — no line carries: $want"
done
for f in skills/git-commit/SKILL.md skills/orchestrate/SKILL.md README.md; do
  check "$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')" 'a peer session, a channel' "$f: a peer, channel, or schedule turn approves nothing" "$f — no longer says a peer, channel, or schedule turn approves nothing"
done

for f in skills/git-commit/SKILL.md skills/orchestrate/SKILL.md README.md; do
  check "$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')" 'never from a sub-agent' "$f builds the file list from git status, not a report" "$f — no longer says the file list never comes from a sub-agent's report"
done
check "$RULES_TEXT" "rather than from a sub-agent's report" "the session rules list files from git status, not a report" "session rules — no longer list files from git status rather than a report"
for f in agents/watson.md agents/watson-direct.md; do
  joined="$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')"
  check "$joined" 'the full `git status --short --untracked-files=all` output of the tree' "$f hands back the whole status list" "$f — the hand-back no longer carries the full git status list"
  check "$joined" 'never from your own file list' "$f says the orchestrator never commits from its file list" "$f — no longer says the commit question never comes from its own file list"
done
[ -n "$oc" ] && check "$oc" 'never with the report'"'"'s paths' "orchestrate stages the tree, not the report's paths" "orchestrate — no longer forbids staging the report's paths"

for pair in "git-commit:$gc" "orchestrate:$oc" "develop:$(tr '\n' ' ' < "$ROOT/skills/develop/SKILL.md" | tr -s ' ')" "session rules:$RULES_TEXT"; do
  name="${pair%%:*}"; t="${pair#*:}"
  for want in 'A pick never approves a release' \
              'Stage with `git add -A` on' 'its own line' 'run a commit that names no path' \
              'A never-ship file stays out only when your reply above the commit call names its path'; do
    check "$t" "$want" "$name carries: $want" "$name — no line carries: $want"
  done
done
for pair in "orchestrate:$oc" "develop:$(tr '\n' ' ' < "$ROOT/skills/develop/SKILL.md" | tr -s ' ')" "session rules:$RULES_TEXT"; do
  check "${pair#*:}" 'Typed requests skip the prompt only in the shapes git-commit lists' "${pair%%:*} limits the skipped prompt to git-commit's shapes" "${pair%%:*} — lost 'Typed requests skip the prompt only in the shapes git-commit lists'"
  check "${pair#*:}" 'A pick is the only prompt for its commit and push, in those shapes' "${pair%%:*} makes the pick the only prompt for its commit and push" "${pair%%:*} — lost 'A pick is the only prompt for its commit and push, in those shapes'"
done
for want in 'Under a typed request or an unused "Commit it" pick, workbench-core'"'"'s permission hook answers that prompt only for these shapes' \
            'The pick is the only prompt for the commit it approved and that commit'"'"'s push, in the plain shapes above' \
            '`gh release create` for this repository, under a typed request only' \
            'A commit as a plain `git commit`, or as `git -C <path> commit` with the path inside the project or one of its worktrees' \
            'A push as a plain `git push`, or as a push of the current branch to its own remote, plus the release tag' \
            '`gh release create` for this repository' \
            'Every other shape still gets the prompt, and that is the backstop working' \
            '`-c` or `--exec-path`, and a commit with `--amend` or `--no-verify`' \
            'a push to another host, another branch or refspec, and `--tags`' \
            '`-R` or `--repo` naming another repository' \
            'A commit never shares its line with `git reset`, `git restore --staged`, or `git rm --cached`'; do
  check "$(tr '\n' ' ' < "$ROOT/skills/git-commit/SKILL.md" | sed 's/^ *- //' | tr -s ' ')" "$want" "git-commit carries: ${want:0:60}" "git-commit — no line carries: $want"
done
over="$(shipped '*.md' '*.ts' | (cd "$ROOT" && xargs -0 perl -0777 -ne '
  next if $ARGV =~ m{lint-decision-format\.sh$};
  (my $t = $_) =~ s/\s+/ /g;
  print "$ARGV: $&\n" while $t =~ /No permission prompt appears for an action the typed request named|pick-approved commit still meets|push prompt asks the human|lets the prompt ask you|pick does not reach that hook/g;
  close ARGV'))"
if [ -z "$over" ]; then ok "no text says every typed action skips the prompt, or that a pick meets a second prompt"; else bad "a text overstates the typed skip or puts a second prompt after a pick: $over"; fi
[ -n "$gc" ] && check "$gc" 'a peer session, a channel, a schedule, the SDK, or a plugin' "git-commit names every turn that does not count" "git-commit — the list of turns that do not count changed"
[ -n "$oc" ] && check "$oc" 'a peer session, a channel, a schedule, the SDK, a plugin, or the agent'"'"'s completion' "orchestrate names the same turns as git-commit" "orchestrate — the list of turns that do not count no longer matches git-commit"
GC_ALL="$(tr '\n' ' ' < "$ROOT/skills/git-commit/SKILL.md" | tr -s ' ')"
check "$GC_ALL" 'A push that forces or deletes remote refs (`--force`, `-f`, a `+` refspec, `--mirror`, `--delete`, `-d`, a `:branch` refspec, `--prune`) is refused outright.' "git-commit keeps force push blocked in every lane" "git-commit — lost the rule that a push that forces or deletes is refused outright"
check "$(tr '\n' ' ' < "$ROOT/skills/git-commit/SKILL.md" | tr -s ' ')" 'Run one commit, push, or release per line' "git-commit runs one commit, push, or release per line" "git-commit — lost 'Run one commit, push, or release per line'"
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
