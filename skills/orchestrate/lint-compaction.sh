#!/bin/bash
# Guards what survives compaction in the orchestrate and develop skills, and
# what orchestrate costs every session. Run directly: ./lint-compaction.sh
#
# A LINTER, not a test: every check below measures or greps shipped Markdown. It
# executes none of the plugin's shell logic, so the `lint-` prefix keeps it out
# of the suite's test loop and out of what the suite claims to guarantee about
# behaviour.
#
# Two harness facts drive it (Phase S of the 2026-10-05 plan):
#   - Every skill's description and when_to_use load into every session. The
#     orchestrate description was 1,028 bytes; it is held at 300.
#   - After compaction, only the first 5,000 tokens of a skill come back. Before
#     Phase S, orchestrate's roster, action routing, and commit rules sat past
#     that point, so a compacted session lost them. That was a correctness bug.
#     develop's commit hygiene, PR, and when-stuck rules sat past it too.
#
# The token limit is checked in bytes, because no tokenizer ships with the
# suite. The skills measure about 3.9 bytes per token, so 18,000 bytes is about
# 4,600 tokens, against a limit of 5,000: a margin of about 8 %. "The line"
# below means byte 18,000 of a file.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SKILL="$DIR/SKILL.md"
DEVELOP="$ROOT/skills/develop/SKILL.md"
SURVIVE_BYTES=18000
COMBINED_BYTES=90000
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
[ -f "$DEVELOP" ] || { echo "  ❌ no skills/develop/SKILL.md"; exit 1; }

FAMILY=("$SKILL")
for f in "$ROOT"/skills/orchestrate-*/SKILL.md; do [ -f "$f" ] && FAMILY+=("$f"); done
TOPICS=("${FAMILY[@]:1}")
skill_name() { basename "$(dirname "$1")"; }

family=()
[ "${#TOPICS[@]}" -ge 2 ] && [ "${#TOPICS[@]}" -le 3 ] \
  || family+=("${#TOPICS[@]} topic skills under skills/orchestrate-*; want two or three beside the core")
for t in "${TOPICS[@]}"; do
  name="$(skill_name "$t")"
  grep -q "^name: $name\$" "$t" || family+=("$name: the frontmatter does not say name: $name")
done
report "family — the core orchestrate skill and two or three topic skills" ${family[@]+"${family[@]}"}

# Under 500 lines each, the limit the skills docs set.
lines=()
for f in "${FAMILY[@]}" "$DEVELOP"; do
  n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -lt 500 ] || lines+=("${f#"$ROOT"/} is $n lines; want fewer than 500")
done
report "lines — every orchestrate skill and develop stay under 500 lines" ${lines[@]+"${lines[@]}"}

# A short description, with the trigger detail in when_to_use. The byte count
# reads the description's own line only, so a description written over more
# than one line fails here rather than escape the limit. Three checks cover
# every shape. First, the description key occurs once, and every key is plain.
# A parser keeps one of two duplicate keys, PyYAML the last. The byte count
# and the third check read every "description: " line, but the second check
# sees only the first value's opener. A key spelled with ? ! & * a quote, or a
# bracket could be a second description that no count here sees, so a line
# that opens with one fails, whatever its key. Second, the value after
# "description: " opens as a quote that closes on its own line, or as a plain
# value. Anything else fails: more whitespace, a tag, an anchor, an alias, a
# block scalar, a flow collection. So a quoted continuation that looks like a
# key fails, whatever comes before the quote. Third, any line between
# description: and the next top-level key counts as more, blank lines
# included, so every other continuation fails.
dq_closed='^"([^"\\]|\\.)*"[[:space:]]*(#.*)?$'
sq_closed="^'([^']|'')*'[[:space:]]*(#.*)?\$"
# A plain value opens on a byte no YAML indicator claims, or on - ? : with a
# non-space after it. Whitespace, a tag, an anchor, an alias, a block scalar,
# and a flow collection all fail it.
plain_open='^([^]!&*|>%@`{}#,"'\''?:[[:space:]-]|[?:-][^[:space:]])'
listing=()
for f in "${FAMILY[@]}"; do
  who="$(skill_name "$f")"
  frontmatter="$(awk 'NR==1 && /^---$/{f=1;next} f && /^---$/{exit} f' "$f")"
  desc_keys="$(printf '%s\n' "$frontmatter" | grep -c '^description[[:space:]]*:')"
  odd_keys="$(printf '%s\n' "$frontmatter" | grep -c '^[?!&*"'\''[{]')"
  desc="$(printf '%s\n' "$frontmatter" | sed -n 's/^description: //p')"
  desc_more="$(printf '%s\n' "$frontmatter" | awk 'f && !/^[A-Za-z0-9_-]+:([[:space:]]|$)/ { n++; next } { f = /^description:/ } END { print n + 0 }')"
  wtu="$(printf '%s\n' "$frontmatter" | sed -n 's/^when_to_use: //p')"
  [ "$desc_keys" -le 1 ] || listing+=("$who: $desc_keys description keys in the frontmatter; a parser keeps only one of them, and maybe not the one counted here, so write exactly one")
  [ "$odd_keys" -eq 0 ] || listing+=("$who: $odd_keys frontmatter line(s) open with ? ! & * a quote or a bracket; write every key plain, so a second description cannot hide in another spelling")
  if [ -z "$desc" ]; then
    listing+=("$who: no description")
  else
    case "$desc" in
      '"'*) [[ "$desc" =~ $dq_closed ]] || listing+=("$who: the description's double quotes do not close on its line; write it on one line, so its bytes can be counted") ;;
      "'"*) [[ "$desc" =~ $sq_closed ]] || listing+=("$who: the description's single quotes do not close on its line; write it on one line, so its bytes can be counted") ;;
      *) [[ "$desc" =~ $plain_open ]] || listing+=("$who: the description opens with '${desc:0:1}', not a plain value or a quote; write one space after description:, then a plain or quoted value, so its bytes can be counted") ;;
    esac
  fi
  [ "$desc_more" -eq 0 ] || listing+=("$who: $desc_more more line(s) follow the description before the next key; write it on one line, so its bytes can be counted")
  desc_bytes="$(printf '%s' "$desc" | wc -c | tr -d ' ')"
  [ "$desc_bytes" -le 300 ] || listing+=("$who: the description is $desc_bytes bytes; want 300 or fewer")
  [ -n "$wtu" ] || listing+=("$who: no when_to_use: the trigger detail has nowhere to go but the description")
done
report "listing — every orchestrate skill has a short description, the triggers in when_to_use" ${listing[@]+"${listing[@]}"}

section_end() { # <file> <heading prefix>
  LC_ALL=C awk -v want="$2" '
    found && /^##+ / { exit }
    !found && index($0, want) == 1 { found = 1 }
    { off += length($0) + 1 }
    END { print (found ? off : -1) }
  ' "$1"
}

# The byte offset where <phrase> ends in <file>, or -1 when it is absent. Prose
# wraps at 80 columns, so each space in the phrase matches any run of
# whitespace, line breaks and list indents included. The first match counts,
# so each phrase below is one only its rule carries.
phrase_end() { # <file> <phrase>
  LC_ALL=C awk -v want="$2" '
    { text = text $0 "\n" }
    END {
      re = want
      gsub(/[][\\.^$*+?(){}|\/]/, "\\\\&", re)
      gsub(/ /, "[[:space:]]+", re)
      print (match(text, re) ? RSTART + RLENGTH - 1 : -1)
    }
  ' "$1"
}

survive=()
for f in "${FAMILY[@]}" "$DEVELOP"; do
  bytes="$(wc -c < "$f" | tr -d ' ')"
  [ "$bytes" -le "$SURVIVE_BYTES" ] || survive+=("${f#"$ROOT"/}: the file is $bytes bytes; want $SURVIVE_BYTES or less, so no rule sits past the line")
done

while IFS='|' read -r kind which want; do
  [ -n "$kind" ] || continue
  case "$which" in
    orchestrate) file="$SKILL" ;;
    develop) file="$DEVELOP" ;;
    orchestrate-*) file="$ROOT/skills/$which/SKILL.md"; [ -f "$file" ] || { survive+=("no skills/$which/SKILL.md"); continue; } ;;
    *) survive+=("unknown file '$which'"); continue ;;
  esac
  if [ "$kind" = section ]; then end="$(section_end "$file" "$want")"; else end="$(phrase_end "$file" "$want")"; fi
  if [ "$end" = -1 ]; then
    survive+=("$which: no $kind '$want'")
  elif [ "$end" -gt "$SURVIVE_BYTES" ]; then
    survive+=("$which: $kind '$want' ends at byte $end; want $SURVIVE_BYTES or less")
  fi
done <<'EOF'
section|orchestrate|## Topic skills
section|orchestrate|## The team
section|orchestrate|## Agent choice
section|orchestrate|## Dispatch in parallel
section|orchestrate|## Check the workspace before you dispatch
section|orchestrate|## Dispatch protocol
section|orchestrate|### Direct-mode work comes back uncommitted
section|orchestrate|## The brief
section|orchestrate|### Must omit
section|orchestrate|### When a brief comes back
section|orchestrate|### The companion gate
section|orchestrate|## Roster
section|orchestrate|## When NOT to orchestrate
section|orchestrate-github|## Action routing
section|orchestrate-github|### 1. Whose voice does the action carry?
section|orchestrate-github|### 2. Is the repo governed by The Index?
section|orchestrate-github|### Routing table
section|orchestrate-github|### Passing a gh body
section|orchestrate-github|## Issue creation, two identities
section|orchestrate-github|## Opening a PR
section|orchestrate-modes|## Holmes can review Direct-mode work first
section|orchestrate-modes|## The team's modes
section|orchestrate-modes|## Watson's Index-mode dispatch
section|orchestrate-modes|## What the dispatcher does
section|orchestrate-modes|## Model and effort come from the config, never from you
phrase|orchestrate|Units that share files run one at a time, the short unit first.
phrase|orchestrate|land it with `git merge --no-ff` on the feature branch, never a cherry-pick, rebase or reset
phrase|orchestrate|Ask before each landing, one question each. A catch-up merge that brings a branch up to date runs unasked.
phrase|orchestrate|A merge into the default branch and every push still ask the human.
phrase|orchestrate|Never merge two units into one brief
phrase|orchestrate|**Cut the task into its smallest units before the first dispatch,** one brief per unit
phrase|orchestrate|Unit: <optional: this dispatch's one step>
phrase|orchestrate|`Unit: 2 of 4, the focus ring. Meets AC3, AC4.` The full criteria list may stay in `Acceptance:` for context.
phrase|orchestrate|There is no length limit on the reasoning in `Context:`
phrase|orchestrate|It does not cover how much work one brief asks for
phrase|orchestrate|**New work gets its own dispatch.** Never SendMessage new work to a running agent
phrase|orchestrate|A brief is an investigation or a bounded change, never both.
phrase|orchestrate-modes|A first line of `SKIP`
phrase|orchestrate-modes|means nothing was spawned: relay it to the human rather than retrying
phrase|orchestrate-modes|Track a spawned run from its log rather than from a completion notification
phrase|orchestrate-modes|check the log for `Permission denied:` lines
phrase|orchestrate|**The full suite runs once, last.**
phrase|orchestrate|No sub-agent runs the full suite: it hands back.
phrase|orchestrate|ask the human through `AskUserQuestion` whether they run the full suite or Holmes does. On the Holmes pick, dispatch Holmes on a brief whose `Goal:` begins `Final suite run:`.
phrase|orchestrate|On an Index-mode PR, CI is that final run, and Holmes adds none.
phrase|orchestrate|No brief slot asks for a test run outside this timeline
phrase|orchestrate|Never run the full suite yourself.
phrase|orchestrate|workbench-core's Full-suite gate enforces this rule
phrase|orchestrate|Do not route around it: ask the human who runs it.
phrase|orchestrate|A deny from the gate means the rule worked.
phrase|orchestrate|minus any that asks for a test run outside the test timeline
phrase|orchestrate-github|body in a quoted heredoc or a file
phrase|orchestrate-github|Never write a multi-line body in double quotes
phrase|orchestrate|**Refused** — a slot is missing
phrase|orchestrate|**Questions** — every slot is there
phrase|orchestrate|Never start a fresh agent on the old brief
phrase|orchestrate|A refusal means the rule worked. Report it, then re-dispatch.
phrase|orchestrate|Never route around a gate — only the human lifts one.
phrase|orchestrate|or a PR with no board item, reviewed as its committed range.
phrase|orchestrate-github|**Holmes** Local mode on the PR branch's committed range
phrase|orchestrate-github|range: origin/<base>...HEAD, pr: <n>)`. First check out the PR at its current head, as `gh pr checkout <n>` does, and bring `origin/<base>` up to date, asking the user as the gates require
phrase|orchestrate-github|Holmes moves no ref, checks the head against PR `<n>`, and stops on a stale base or head. The verdict comes back as prose
phrase|orchestrate-github|Never unwind commits to fake an uncommitted tree
phrase|develop|the existing tests that cover the files you changed, never the full suite.**
phrase|develop|A sub-agent hands back when one is due. In a workbench plugin repo, name the test files to the runner: `claude plugin test .` runs every file.
phrase|develop|**Run no mutation testing of any kind.**
phrase|orchestrate|The dev-team mod's no-mutation gate refuses one without it.
phrase|orchestrate|A CI-only failure's brief rules out Docker, a VM or a CI-like local environment, and never asks for a local reproduction on another platform.
phrase|develop|**Create nothing on your own initiative that you cannot remove yourself.**
phrase|develop|**Never mimic CI or another platform locally** with Docker, a VM or a source build.
phrase|develop|**Investigation not converging?** When three hypotheses in a row are ruled out with no confirmed cause, stop.
EOF
for gone in 'also through a script' 'One test file, a filter, or one case still runs'; do
  for f in "${FAMILY[@]}"; do
    [ "$(phrase_end "$f" "$gone")" = -1 ] || survive+=("$(skill_name "$f"): '$gone' restates the Full-suite gate's scope, which the skill names rather than restates")
  done
done
report "survive — every orchestrate skill and develop fit inside the line whole, and each pinned section and phrase is in its skill" ${survive[@]+"${survive[@]}"}

combined=()
total="$(cat "${FAMILY[@]}" "$DEVELOP" | wc -c | tr -d ' ')"
[ "$total" -le "$COMBINED_BYTES" ] || combined+=("the orchestrate skills and develop total $total bytes; want $COMBINED_BYTES or fewer, the combined 25,000 tokens that compaction brings back across skills")
report "combined — the orchestrate skills and develop fit the 25,000-token budget across skills" ${combined[@]+"${combined[@]}"}

topics=()
map="$(awk '/^## Topic skills/{f=1;next} f && /^## /{exit} f' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
for t in "${TOPICS[@]}"; do
  name="$(skill_name "$t")"
  printf '%s' "$map" | grep -Fq "\`/workbench-dev-team:$name\` — " \
    || topics+=("the core's Topic skills section does not name /workbench-dev-team:$name")
done
pinned=" "
while IFS='|' read -r name when; do
  [ -n "$name" ] || continue
  pinned="$pinned$name "
  printf '%s' "$map" | grep -Fq "\`/workbench-dev-team:$name\` — $when" \
    || topics+=("the core's Topic skills entry for $name no longer says when to load it: '$when'")
done <<'EOF'
orchestrate-github|any GitHub action: a PR review, a comment, an issue, a merge, triage, a status check, or opening a PR.
orchestrate-modes|an `Item ID: <n>` or `Repo sweep: <owner/repo>` dispatch, Holmes on Direct-mode work or a committed range, or the dispatcher, a mode, the model or the effort.
EOF
for t in "${TOPICS[@]}"; do
  name="$(skill_name "$t")"
  [[ "$pinned" == *" $name "* ]] || topics+=("no when-to-load phrase is pinned for $name; pin one from its Topic skills entry")
done
report "topics — the core names each topic skill and when to load it" ${topics[@]+"${topics[@]}"}

# The parallel-dispatch rule: stated ahead of the dispatch protocol, with no
# count cap on local work and the Index pipeline still bounded.
parallel=()
par_line="$(grep -n '^## Dispatch in parallel' "$SKILL" | cut -d: -f1)"
dp_line="$(grep -n '^## Dispatch protocol' "$SKILL" | cut -d: -f1)"
if [ -z "$par_line" ] || [ -z "$dp_line" ]; then
  parallel+=("no '## Dispatch in parallel' or '## Dispatch protocol' section")
elif [ "$par_line" -gt "$dp_line" ]; then
  parallel+=("the parallel rule sits after the dispatch protocol, at line $par_line vs $dp_line")
fi
section="$(awk '/^## Dispatch in parallel/{f=1;next} f && /^## /{exit} f' "$SKILL" | tr '\n' ' ')"
for phrase in 'Dispatch every independent unit at once' 'Never serialize out of habit' \
              'Local work has no count cap' 'one Watson per' 'every Index-mode cap stays' \
              'Only for units you dispatched' 'commit each in its own tree' \
              'remove its worktree and database'; do
  printf '%s' "$section" | grep -Fq "$phrase" || parallel+=("the parallel rule no longer says '$phrase'")
done
report "parallel — independent units go out at once, local work has no count cap" ${parallel[@]+"${parallel[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
