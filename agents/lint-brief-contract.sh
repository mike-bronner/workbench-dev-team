#!/bin/bash
# Guards both halves of the brief contract. Run directly: ./lint-brief-contract.sh
#
# A LINTER, not a test: every check below is a grep over English sentences in
# the shipped Markdown. It executes none of the plugin's shell logic, so the
# `lint-` prefix keeps it out of the suite's test loop and out of what the
# suite claims to guarantee about behaviour.
#
# The sending rule lives in skills/orchestrate/SKILL.md, and a sending rule the
# receiver never checks is the design that already failed. Over 14 days of real
# main-agent traffic, 101 dispatches went to generic sub-agents against 71 to
# Watson, and 70 Direct-mode briefs ran to a 4,788-character median with 64 of
# them carrying a literal shell command. All of that satisfied the prose while
# ignoring it. So every agents/*.md carries the receiving rules, and this test is
# what a *fourth* agent inherits — add an agent file without the contract block
# and the suite goes red on that file alone.
#
# Checks, per agent file:
#   1. The `## The brief contract` section exists.
#   2. It names all five slots, in order, read off the fenced template.
#   3. It states the refusal, and the two fixed-token exemptions.
#   4. `Constraints:` may read "none" and `Context:` may not. The pair was
#      stated the other way round once, and a flip back is silent otherwise.
#   5. It states the ask-back rule, and the bar that stops it firing on
#      everything.
# Then Watson's mode default, and a sweep over the sending docs: the template
# governs every handoff, that rule carries its fan-out exemption in the same
# section, and no length figure survives anywhere near the brief.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PASS=0
FAIL=0

fail_file() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; shift; for m in "$@"; do echo "       • $m"; done; }

for file in "$DIR"/*.md; do
  agent="$(basename "$file" .md)"

  # The contract section: `## The brief contract` up to the next `## ` heading.
  section="$(awk '/^## The brief contract/{f=1} f && /^## /&& !/^## The brief contract/{exit} f{print}' "$file")"

  if [ -z "$section" ]; then
    fail_file "$agent — no '## The brief contract' section" \
      "every dev-team agent refuses an incomplete brief, including one with no prose mode yet"
    continue
  fi

  # Slots are read off the fenced template, never off the surrounding prose —
  # prose mentions every slot name while explaining which ones take "none", so
  # a prose-level grep stays green after a slot is dropped from the template.
  # Reading the template also gets slot ORDER checked for free.
  template="$(printf '%s\n' "$section" | awk '/^```/{f=!f; next} f')"
  order="$(printf '%s\n' "$template" \
    | grep -oE '^(Workdir|Goal|Context|Constraints|Done when):' | tr -d ':' | paste -sd, -)"

  missing=()
  [ "$order" = "Workdir,Goal,Context,Constraints,Done when" ] \
    || missing+=("template slots are '${order:-none}', want 'Workdir,Goal,Context,Constraints,Done when'")

  printf '%s\n' "$section" | grep -Fq 'is not work you start' \
    || missing+=("no refusal: the section never says an incomplete brief is not started")
  printf '%s\n' "$section" | grep -Fq 'Item ID:' \
    || missing+=("no exemption for the 'Item ID: <n>' dispatch token")
  printf '%s\n' "$section" | grep -Fq 'Repo sweep:' \
    || missing+=("no exemption for the 'Repo sweep: <owner/repo>' dispatch token")

  # Which slot may say "none", and which may not. An accepted "none" in
  # `Context:` becomes the default token and rebuilds the bare instruction the
  # template exists to kill, so the allowance belongs to `Constraints:` alone.
  printf '%s\n' "$section" | grep -Fq '`Constraints:` may read "none"' \
    || missing+=("'Constraints:' is never allowed to read \"none\"")
  printf '%s\n' "$section" | grep -Fq '`Context:` may not' \
    || missing+=("'Context:' is not held to carrying a reason the task exists")
  printf '%s\n' "$section" | grep -Eq '`Context:`( is the one slot that)? may (be empty|read "none")' \
    && missing+=("the pair is back to front: 'Context:' is allowed to be empty or \"none\"")

  # Ask-back, and its bar. Refusal and ask-back answer two different failures,
  # and the bar is what keeps the second one from firing on every dispatch.
  printf '%s\n' "$section" | grep -Fq 'send your questions back to the orchestrator' \
    || missing+=("no ask-back: a complete brief the agent cannot finish is never returned")
  printf '%s\n' "$section" | grep -Fq 'blocking uncertainty' \
    || missing+=("no bar on ask-back: an agent that asks about everything never works")

  if [ ${#missing[@]} -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✅ $agent — five slots, refusal, ask-back with its bar, both token exemptions"
  else
    fail_file "$agent — brief contract incomplete" "${missing[@]}"
  fi
done

# Watson's mode default. Prose-only, so a grep is the whole guard: the marker
# line was dropped from every brief on the strength of this default, and a
# revert here silently routes ambiguous prose back onto the board.
watson="$DIR/watson.md"
mode_problems=()
grep -Fq '**Direct mode is the default.**' "$watson" \
  || mode_problems+=("mode detection no longer declares Direct mode the default")
grep -Fq 'Ambiguous prose resolves to Direct mode' "$watson" \
  || mode_problems+=("ambiguous prose is no longer resolved to Direct mode")
grep -Fq 'Default to The Index mode' "$watson" \
  && mode_problems+=("stale wording is back: 'Default to The Index mode'")

if [ ${#mode_problems[@]} -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  ✅ watson — Direct mode is the default, no stale Index-mode default wording"
else
  fail_file "watson — mode default" "${mode_problems[@]}"
fi

# ── The sending half: every doc that describes the brief ──────────────────────
BRIEF_DOCS=("$ROOT/skills/orchestrate/SKILL.md" "$ROOT/README.md" "$ROOT/session-warmup.md" "$DIR"/*.md)

# Scope of the template. Requiring it on read-only research too is what lets the
# companion hook stop guessing whether a dispatch is code work, so a doc that
# narrows the rule back to work ending in a changed file breaks the hook's
# premise without touching the hook.
handoff_problems=()
for doc in "${BRIEF_DOCS[@]}"; do
  grep -qiF 'every handoff' "$doc" \
    || handoff_problems+=("$(basename "$doc") no longer says the template governs every handoff")
done

if [ ${#handoff_problems[@]} -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  ✅ scope — every brief doc states the template governs every handoff"
else
  fail_file "brief scope narrowed to code work" "${handoff_problems[@]}"
fi

# The exemption that keeps the rule above honest, checked in the same section
# the rule is stated in. A specialist's dispatch to its own workers is not a
# handoff: the template governs the orchestrator boundary, and the parent holds
# every fact those workers need. Unguarded, that carve-out is the half of the
# pair nothing watches — a reader who meets "every handoff" with no exemption
# beside it converts a lens prompt to slots and regresses the spend those
# prompts are tuned for.
#
# Sectioned, never whole-file, and both halves are required. A whole-file grep
# for "fan-out" is satisfied by holmes.md's review prose, which discusses one at
# length and would hold this green with the exemption deleted. "orchestrator
# boundary" is checked alongside it because a carve-out written as two agent
# names is one a fourth agent does not inherit. A section runs from a heading of
# any level to the next; fenced blocks are skipped so a `# ` comment inside one
# cannot pose as a heading, and frontmatter — everything above the first heading
# — is a summary, not a place a carve-out belongs.
#
# Each section is matched as one joined string rather than line by line. Prose
# here wraps at 80 columns, so a line-scoped grep for a two-word phrase reddens
# on the wrap and teaches the next author to fight the formatter.
exempt_problems=()
for doc in "${BRIEF_DOCS[@]}"; do
  while IFS= read -r problem; do
    [ -n "$problem" ] && exempt_problems+=("$(basename "$doc") — $problem")
  done < <(awk '
    /^```/ { fence = !fence; next }
    fence  { next }
    /^#+ / { head = $0; sub(/^#+ +/, "", head) }
    head == "" { next }
    { line = tolower($0); sub(/^[ \t]+/, "", line); body[head] = body[head] " " line }
    END {
      for (h in body) {
        if (!index(body[h], "every handoff")) continue
        if (!index(body[h], "fan-out"))
          print "§ " h " states the every-handoff rule with no fan-out exemption beside it"
        else if (!index(body[h], "orchestrator boundary"))
          print "§ " h " exempts a fan-out without the orchestrator boundary that scopes it"
      }
    }' "$doc")
done

if [ ${#exempt_problems[@]} -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  ✅ exemption — the fan-out carve-out sits with the rule, scoped to the orchestrator boundary"
else
  fail_file "the fan-out exemption is missing where the rule is stated" "${exempt_problems[@]}"
fi

# No length figure, anywhere near the brief. Length was only ever a proxy for
# prescriptiveness: `Context:` is prose and outruns any figure worth setting, so
# a stated ceiling only ever pressured senders to cut the why. The must-omit
# list carries that job alone now. Scoped to lines that talk about the brief, so
# Holmes's vault-note ceiling and Lestrade's one-PR ceiling stay untouched.
ceiling_problems=()
while IFS= read -r hit; do
  [ -n "$hit" ] && ceiling_problems+=("$hit")
done < <(grep -HnE 'brief|slot|template|Goal:|Context:|Constraints:|Done when:' "${BRIEF_DOCS[@]}" \
  | grep -oE '^[^:]*:[0-9]+:.*([0-9][0-9,]*[- ]characters?|ceiling)' \
  | cut -c1-120)

if [ ${#ceiling_problems[@]} -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  ✅ length — no character ceiling stated on the brief"
else
  fail_file "a length ceiling is back on the brief" "${ceiling_problems[@]}"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
