#!/bin/bash
# Guards Holmes's Local mode. Run directly: ./lint-holmes-local-mode.sh
#
# A LINTER, not a test: every check below is a grep over English prose and
# Markdown structure in the shipped files. It executes none of the plugin's
# shell logic, so the `lint-` prefix keeps it out of the suite's test loop and
# out of what the suite claims to guarantee about behaviour.
#
# Holmes used to take `Item ID: <n>` and nothing else, so work Watson handed
# back from Direct mode — an uncommitted working tree — had no review path at
# all. Local mode closes that loop, and it is held together by prose in four
# files at once: the mode detection and the limits in agents/holmes.md, the
# replaced steps in the reference, the sub-agent prompt skeletons in
# review-phases.md that the reference rewrites by quoting them, and the routing
# in the orchestrate skill that an orchestrating session reads before it picks an
# agent. A rule dropped from any one of them breaks the mode while the other
# three still describe it, so all four are checked here rather than in four
# linters that each stay green.
#
# A fifth file joins them without being checked for prose: the guard hook at
# hooks/scripts/local-review-guard.sh enforces the no-write limit at the harness
# level. It is the answer to a lens sub-agent that ran `chmod` against the
# human's tree with the prohibition sitting verbatim in its own prompt. This
# linter calls the guard's `--classify` mode rather than re-describing what it
# refuses, so the prose and the enforcement cannot drift apart. The guard's own
# behaviour is tested in hooks/scripts/test-local-review-guard.sh, which is a
# test and says so.
#
# What is pinned, and why each one:
#   1. Local mode is the DEFAULT and ambiguous prose resolves to it. The cheap
#      error is a throwaway report; the expensive one posts an App-signed verdict
#      onto somebody else's PR. A flip here is silent otherwise.
#   2. The three limits — no Index call, no GitHub write, no write to the tree.
#   3. The rubric is the brief's Goal and Done when, and is never amended.
#   4. Every board-coupled Index step has a stated local answer. "Documented end
#      to end" is the requirement; a reference that quietly drops the CI step
#      leaves an agent to invent one.
#   5. No destructive command inside any fenced block in the reference, and the
#      prohibition reaches every sub-agent Local mode dispatches. Index mode §4b
#      opens with `rm -rf "$CLONE"`, and the local target is the human's live
#      tree — a copied command there deletes the work under review. What counts
#      as destructive is not decided here: the fenced blocks are fed to the
#      shipped guard's own classifier, so the documentation is held to the rule
#      the harness enforces rather than to a second copy of it that can drift.
#   5c. The fallback path has a local replacement. `§4-fallback` in
#      review-phases.md is the one path no substitution row reaches, and its own
#      prose sends a local reviewer to a checkout and to acceptance criteria
#      that do not exist. Unlike a missed skeleton row — a harmless no-op that
#      leaves a correct prompt standing — a missed fallback leaves a wrong
#      instruction standing.
#   5b. Every prompt skeleton in review-phases.md words its evidence-room line
#      identically, so the reference's one substitution row reaches all of them.
#      A skeleton worded its own way is one the substitution misses, and that
#      sub-agent reads the live tree under a clone path Local mode never makes.
#   6. The local vault note never touches the top-lessons digest, and its path is
#      keyed on something a local review can supply rather than a PR number.
#   7. The Index-mode workflow still exists, unscathed. Local mode was added
#      beside it, never on top of it — the scheduled pipeline is the only review
#      path the board has.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
HOLMES="$DIR/holmes.md"
LOCAL="$ROOT/skills/holmes-review/references/local-review.md"
PHASES="$ROOT/skills/holmes-review/references/review-phases.md"
ORCH="$ROOT/skills/orchestrate/SKILL.md"
GUARD="$ROOT/hooks/scripts/local-review-guard.sh"
PASS=0
FAIL=0

# The one evidence-room line every prompt skeleton carries, written once here.
# The reference substitutes it for the human's workdir by matching this literal
# text, so the check below holds the skeletons and the substitution row to the
# same string rather than to two hand-kept copies of it.
EVIDENCE='Checkout (already prepared, do not re-clone): /tmp/holmes-<issue_number>'

report() {
  local label="$1"; shift
  if [ "$#" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  ✅ $label"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $label"; for m in "$@"; do echo "       • $m"; done
  fi
}

for f in "$HOLMES" "$LOCAL" "$PHASES" "$ORCH" "$GUARD"; do
  [ -f "$f" ] || { echo "  ❌ missing file: $f"; exit 1; }
done

# Sections are joined into one string before grepping. Prose in these files wraps
# at 80 columns, so a line-scoped grep for a phrase reddens on the wrap and
# teaches the next author to fight the formatter instead of keeping the rule.
section() { awk -v h="$1" '$0 ~ h {f=1; next} f && /^## /{exit} f' "$2" | tr '\n' ' '; }

# ── 1. Mode detection: Local by default, Index only on the token ──────────────
mode="$(section '^## Mode detection' "$HOLMES")"
detect=()
[ -n "$mode" ] || detect+=("no '## Mode detection' section in holmes.md")
printf '%s' "$mode" | grep -Fq '**Local mode is the default.**' \
  || detect+=("mode detection no longer declares Local mode the default")
printf '%s' "$mode" | grep -Fq 'Ambiguous prose resolves to Local mode' \
  || detect+=("ambiguous prose is no longer resolved to Local mode")
printf '%s' "$mode" | grep -Fq 'Item ID: <n>' \
  || detect+=("the 'Item ID: <n>' token that enters Index mode is not named")
printf '%s' "$mode" | grep -Eq 'Ambiguous prose resolves to (The )?Index mode|Default to The Index mode' \
  && detect+=("the direction is inverted: ambiguous prose resolves to the board")
report "detection — Local mode is the default, Index mode needs the token" ${detect[@]+"${detect[@]}"}

# ── 2. The three limits, stated where a local run reads them ──────────────────
localsec="$(section '^## Local mode' "$HOLMES")"
limits=()
[ -n "$localsec" ] || limits+=("no '## Local mode' section in holmes.md")
printf '%s' "$localsec" | grep -Fq 'No `mcp__the-index__` call of any kind' \
  || limits+=("the no-Index-call limit is gone: a guessed id writes to a live board item")
printf '%s' "$localsec" | grep -Fq 'No GitHub write of any kind' \
  || limits+=("the no-GitHub-write limit is gone: nothing posts under the human's identity unasked")
# The no-write limit is pinned as the CLASS it now states, never as one verb.
# A roster of spellings is what let `git restore` — the modern replacement for
# `git checkout --`, and the single most destructive command available here —
# sit unnamed in all five places that enumerated the others, and a file-mode
# change go unnamed in every one of them while being what the first real breach
# actually used. Two clauses carry the class, and both are pinned: git is
# read-only with every other verb refused, and nothing changes a file's content,
# location, existence, or metadata.
printf '%s' "$localsec" | grep -Fq '**Git is read-only here**' \
  || limits+=("the no-write limit no longer states git as read-only, so it is a roster again")
printf '%s' "$localsec" | grep -Fq '**every other git verb is refused**' \
  || limits+=("the git rule no longer refuses every verb outside the read-only set")
printf '%s' "$localsec" | grep -Fq "content, location, existence, or metadata" \
  || limits+=("the no-write limit no longer covers file metadata, which is what the first breach changed")
printf '%s' "$localsec" | grep -Fq 'restore' \
  || limits+=("the most destructive command available locally, git restore, is not named")
printf '%s' "$localsec" | grep -Fq 'references/local-review.md' \
  || limits+=("the Local-mode section no longer routes to its reference")
# The harness-level backstop, named where a local run reads its limits. Prose
# alone was measured failing on this mode's first exercise.
printf '%s' "$localsec" | grep -Fq 'local-review-guard.sh' \
  || limits+=("the Local-mode section no longer names the hook that enforces the no-write limit")
report "limits — no Index call, no GitHub write, no write to the tree" ${limits[@]+"${limits[@]}"}

# ── 3. The rubric is the brief, and Holmes never amends it ────────────────────
# Same line he never crosses on acceptance criteria. Without it the agent that
# cannot make the tree pass rewrites the target instead of reporting the dispute.
# The declaring sentence, not merely the token pair — the pair also appears in
# the section's list of what the reference carries, which would hold this green
# with the rule itself deleted.
rubric=()
printf '%s' "$localsec" | grep -Fq '**The rubric is the brief.**' \
  || rubric+=("holmes.md no longer declares the brief to be the local rubric")
printf '%s' "$localsec" | grep -Fq '`Goal:` and `Done when:`' \
  || rubric+=("holmes.md no longer names the brief's Goal and Done when as the local rubric")
# Each clause is pinned where it is DECLARED. A bare 'never amend' grep is
# satisfied by the section's own pointer list and by the substitution table, both
# of which restate the rule — so it survives the rule being struck from the two
# sentences that impose it.
printf '%s' "$localsec" | grep -Fq '**you never amend them**' \
  || rubric+=("holmes.md no longer forbids amending the local rubric")
grep -Fq '## §L4a — the rubric is the brief, and you never amend it' "$LOCAL" \
  || rubric+=("the reference's §L4a no longer forbids amending the local rubric")
grep -Fq 'Never paraphrase them, never widen them' "$LOCAL" \
  || rubric+=("the reference no longer blocks the quiet narrowing that makes a failing tree pass")
grep -Fq 'Paste both slots **verbatim**' "$LOCAL" \
  || rubric+=("the rubric is no longer pasted verbatim into the lens prompts")
report "rubric — the brief's Goal and Done when, never amended" ${rubric[@]+"${rubric[@]}"}

# ── 4. Every board-coupled step has a stated local answer ─────────────────────
# "Documented end to end" is the requirement. A reference that silently drops one
# step leaves the agent to invent an answer for it at review time.
steps=()
for step in \
  '§1 fetch the item' '§2 find the PR' '§2.5 decision request' '§3 strike count' \
  '§4a read the issue and AC' '§4b check out the PR' '§4c CI status' \
  '§5 verdict' '§5.5 learnings'; do
  grep -Fq "$step" "$LOCAL" || steps+=("no local answer stated for Index-mode $step")
done
for anchor in '§L3' '§L4a' '§L4b' '§L4c' '§L4-fallback' '§L5' '§L5.5'; do
  grep -Fq "## $anchor" "$LOCAL" || steps+=("the reference has no $anchor section")
done
grep -Fq 'review-phases.md' "$LOCAL" \
  || steps+=("the reference never hands off to review-phases.md, so Phases B-D are unreachable")
report "steps — every board-coupled step has a local replacement" ${steps[@]+"${steps[@]}"}

# ── 5. No destructive command inside any fenced block in the reference ────────
# EVERY fence, not just ```bash ones. The reference's sub-agent prompt, its
# verdict body, and its vault-write call are all untagged fences, and a `rm -rf`
# pasted into one of those deletes the human's tree exactly as fast as one in a
# bash fence. A check that stays green while the hazard is present is worse than
# no check: it tells the next author the danger was considered and handled.
#
# WHAT COUNTS AS DESTRUCTIVE IS NOT DECIDED HERE. The blocks are fed to the
# shipped guard's own `--classify` mode, which is the same classifier that
# refuses these commands at the harness level. A second copy of the rule living
# in this file is exactly how the old one rotted: it listed stash, checkout,
# reset, clean, commit, and push, and so it never saw `git restore` — the modern
# spelling of the most destructive thing available here — or a `chmod`, which is
# what the mode's first real breach used. The guard states the rule by
# inversion: git's reading verbs are enumerated and every other verb is refused,
# so a verb git ships next year is caught on the day it ships.
#
# What keeps that from reddening on the prohibition itself: the classifier
# anchors at a COMMAND POSITION — the start of a line or of a shell segment.
# Prose that merely names the verbs names them mid-sentence ("every other git
# verb is forbidden. That includes restore, stash..."), which is never a command
# position, so the warning text stays legal and nobody is taught to delete it to
# get green. Index mode's §4b opens with `rm -rf "$CLONE"`; copied here that
# deletes the work under review.
fenced="$(awk '/^```/{f=!f; next} f' "$LOCAL")"
destructive=()
if ! classified="$(printf '%s\n' "$fenced" | bash "$GUARD" --classify 2>&1)"; then
  while IFS= read -r line; do
    [ -n "$line" ] && destructive+=("a fenced block runs: $line")
  done <<< "$classified"
fi
# And the prohibition itself reaches the sub-agents, which read the same live
# tree and are the half the parent's own posture does not cover. Naming the
# panel roles is the point: Local mode always takes Phase C's panel track, so
# the attacker, the defender, and the auditor are the only verifiers it ever
# dispatches — a prohibition addressed to "lenses and verifiers" left all three
# of them out, because none of their skeletons calls itself a verifier.
#
# Scoped to §L4, where the prohibition is stated, never the whole file: §L3
# names the same three roles when it explains which Phase C track a local review
# takes, and a file-wide grep would hold this green with the prohibition itself
# addressed to nobody.
subagents="$(section '^## §L4 —' "$LOCAL")"
printf '%s' "$subagents" | grep -Fq 'every other git verb is forbidden' \
  || destructive+=("the sub-agent prompt no longer forbids mutating the human's tree")
printf '%s' "$subagents" | grep -Fq 'content, location, existence, or metadata' \
  || destructive+=("the sub-agent prompt no longer forbids a file-metadata change, which is what the first breach used")
# The skeptic is in the loop even though §L3 puts every local review on the
# panel track and so never dispatches one. The line is addressed to whoever a
# track reaches, and a role left out of the address is a sub-agent reading the
# human's tree with no prohibition in its prompt — which is the whole failure.
for role in attacker defender auditor skeptic; do
  printf '%s' "$subagents" | grep -Fq "$role" \
    || destructive+=("the no-write line is not addressed to the $role, a verifier a Local-mode track can reach")
done
report "safety — no fenced block mutates the working tree" ${destructive[@]+"${destructive[@]}"}

# ── 5b. One evidence-room wording, so one substitution row reaches every role ──
# The reference rewrites the skeletons by quoting them literally. When the five
# skeletons word that line five ways, the row reaches only the one it was quoted
# from and the rest keep a scratch-clone path Local mode never creates.
phases=()
total="$(grep -c '^Checkout (' "$PHASES")"
same="$(grep -cFx "$EVIDENCE" "$PHASES")"
[ "$total" -gt 0 ] \
  || phases+=("no prompt skeleton in review-phases.md states a checkout line at all")
[ "$total" = "$same" ] \
  || phases+=("$((total - same)) of $total skeleton checkout lines are worded differently — the substitution row reaches only the ones that match it")
grep -Fq "\`$EVIDENCE\`" "$LOCAL" \
  || phases+=("the reference's substitution row no longer quotes the skeletons' checkout line verbatim")
# Same failure, other half: the lens reading discipline used to say a bare
# `gh pr diff`, which no substitution row covers, so a local lens was told to
# read a pull request it has not got.
grep -n 'gh pr diff' "$PHASES" | grep -vq '<PR_NUM>' \
  && phases+=("review-phases.md says a bare 'gh pr diff' somewhere — no substitution row covers that form")
report "skeletons — one evidence-room wording, reachable by one substitution" ${phases[@]+"${phases[@]}"}

# ── 5c. The fallback path has a local replacement, not a substitution ─────────
# §4-fallback is the one path in review-phases.md that NO substitution row
# reaches: it words neither the evidence room nor the rubric the way the prompt
# skeletons do, so its own prose stands — and its own prose sends the reviewer
# to a checkout and judges against acceptance criteria, neither of which a local
# review has. It is reachable whenever `fanout` is false or a dispatch errors,
# so it is a live path.
#
# This is deliberately NOT the same complaint as 5b, which an adversarial
# verifier refuted and was right to: on the phase skeletons an unmatched
# substitution is a harmless no-op that leaves a correct prompt standing. Here
# it leaves a wrong instruction standing.
fallback=()
grep -Fq '## §L4-fallback' "$LOCAL" \
  || fallback+=("the reference has no §L4-fallback, so the inline path keeps review-phases.md's wording")
fb="$(section '^## §L4-fallback' "$LOCAL")"
printf '%s' "$fb" | grep -Fq '`Workdir:`' \
  || fallback+=("§L4-fallback does not send the inline reviewer to the workdir — review-phases.md sends it to a checkout")
printf '%s' "$fb" | grep -Fq '`Goal:` and `Done when:`' \
  || fallback+=("§L4-fallback does not name the brief as the inline reviewer's rubric — review-phases.md names the AC")
printf '%s' "$subagents" | grep -Fq 'replaced, not substituted' \
  || fallback+=("§L4 no longer records that the fallback is replaced rather than substituted")
report "fallback — the inline path carries instructions a local review can follow" ${fallback[@]+"${fallback[@]}"}

# ── 6. The vault note: own key, and the shared digest left alone ──────────────
# The digest ranks rejection categories by frequency to derive prevention rules,
# and local reviews are a different population whose counts would skew it. The
# note path is keyed on a PR number in Index mode, which a local review has not
# got, so a key it can actually supply is part of the contract.
note="$(section '^## §L5.5' "$LOCAL")"
vault=()
[ -n "$note" ] || vault+=("no '## §L5.5' learnings section in the reference")
printf '%s' "$note" | grep -Fq 'Do not read, increment, or write `dev-team/top-lessons.md`' \
  || vault+=("the reference no longer forbids touching the top-lessons digest")
# The write target, not every mention: the note's own body cites the digest by
# name to record that it is not counted there, and that sentence must stay legal.
printf '%s\n' "$fenced" | grep -Fq 'path: "dev-team/top-lessons.md"' \
  && vault+=("a write block targets the top-lessons digest from a local review")
printf '%s\n' "$fenced" | grep -Fq 'pr<pr_num>' \
  && vault+=("the local note path is still keyed on a PR number, which a local review has not got")
printf '%s\n' "$fenced" | grep -Fq -- '-local-<yyyy-mm-dd>-<hhmm>.md' \
  || vault+=("the local note path no longer uses a key a local review can supply")
printf '%s\n' "$fenced" | grep -Fq '"local-review"' \
  || vault+=("the local-review tag is gone, so the two populations stop being separable")
report "vault — a local note with its own key, the digest untouched" ${vault[@]+"${vault[@]}"}

# ── 7. The Index-mode workflow survives intact ────────────────────────────────
# Local mode was added beside the pipeline, never on top of it. The board has no
# other review path, so a regression here breaks every scheduled tick.
index=()
grep -Fq '## The Index-mode workflow' "$HOLMES" \
  || index+=("the Index-mode workflow heading is gone from holmes.md")
for call in 'mcp__the-index__get_item(' 'mcp__the-index__submit_review(' 'mcp__the-index__move('; do
  grep -Fq "$call" "$HOLMES" || index+=("the Index path no longer calls $call")
done
for step in '### 1. Fetch the item' '### 3. Compute the strike count' \
            '### 5. Submit your verdict' '### 5.5. Record review learnings'; do
  grep -Fq "$step" "$HOLMES" || index+=("the Index workflow lost '$step'")
done
report "index — the board review path is unchanged and complete" ${index[@]+"${index[@]}"}

# ── 8. The orchestrate skill dispatches the mode it now describes ─────────────
# This is the file an orchestrating session reads before choosing an agent. A
# stale "Index mode only" there means the new mode is never dispatched at all.
routing=()
grep -Fq '**Index mode only**' "$ORCH" \
  && routing+=("the team table still calls Holmes Index-mode only")
grep -Fq 'Lestrade and Holmes are coupled to The Index board' "$ORCH" \
  && routing+=("the skill still says Holmes is board-coupled")
grep -F 'workbench-dev-team:holmes' "$ORCH" | grep -Fq 'Local mode' \
  || routing+=("the team table's Holmes row does not offer Local mode")
grep -Fq '**Holmes** Local mode' "$ORCH" \
  || routing+=("the routing table has no row sending local review work to Holmes")
report "routing — the orchestrate skill offers and routes Local mode" ${routing[@]+"${routing[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
