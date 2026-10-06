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
#
# What it checks:
#   1. lines — orchestrate's and develop's SKILL.md are each under 500 lines.
#   2. listing — orchestrate's description is on one line, is 300 bytes or
#      fewer, and its when_to_use is present. Only one line can be counted, so
#      a description written over more than one line fails: any line before the
#      next top-level key, blank lines included, and a quoted value that does
#      not close on its own line. The value must be a quote closed on its line
#      or a plain value, one space after the colon, so anything else fails
#      too: more whitespace, a tag, an anchor, an alias, a block scalar, or a
#      flow collection before or in place of the value. Only one description
#      can be counted too, so a second description key fails, with any space
#      before its colon. So does any frontmatter line that opens with ? ! & *
#      a quote, or a bracket, because that is how a key is spelled other than
#      plain.
#   3. survive — develop: the whole file is inside the line, so no rule in it
#      can sit past it. orchestrate: every must-survive section ends inside the
#      line, and so does every pinned phrase.
#   4. past the line — orchestrate's blocks past the line are exactly the ones
#      in compaction-late-blocks.txt, beside this linter. A block is a
#      paragraph, a list item, a table row, a heading, or a code fence. A block
#      wholly past the line is listed as its text, with its whitespace
#      collapsed. The check follows the text, not the headings: a
#      rule moved past the line, under any heading or appended to any block
#      already there, is a block the list does not hold, and the check fails.
#      A block that straddles the line is listed with its start byte and its
#      exact raw bytes before the line, whitespace included. Any net growth or
#      shrinkage above the block moves the start byte. Any change inside the
#      block before the line changes the raw bytes: a trailing space, an
#      indent, a rewrap, or blank space moved from after the line to before
#      it. Either way the check fails, however few bytes change. A block pushed
#      wholly past the line is not listed, and fails too. When the line falls
#      in blank space between blocks, nothing straddles it, and the first text
#      that crosses it fails the check. The list is the whole of what may sit
#      late. After a deliberate change above or past the line, review the
#      blocks and rewrite the list with
#      `./lint-compaction.sh --late-blocks > compaction-late-blocks.txt`.
#   5. parallel — Mike's parallel-dispatch rule (vault: feedback/2026-10-05-
#      parallel-subagents-within-guards.md) sits ahead of the dispatch protocol
#      and keeps its key phrases.
#
# Sections and phrases are pinned on top of check 4, so a missing or renamed
# rule is named. Detail that need not survive lives in each skill's references/
# folder, behind a short form of the same rule in SKILL.md.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SKILL="$DIR/SKILL.md"
DEVELOP="$ROOT/skills/develop/SKILL.md"
LATE_LIST="$DIR/compaction-late-blocks.txt"
SURVIVE_BYTES=18000
PASS=0
FAIL=0

# Every orchestrate block that ends past the line, in file order, one per line.
# A block is a paragraph, a list item, a table row, a heading, or a code fence.
# Bytes are 1-based, as phrase_end below counts them, and a block starts at the
# first byte of its first line, indent included. LC_ALL=C makes awk's length()
# and substr() count bytes, not characters.
#
# A block wholly past the line is its text, with every run of whitespace
# collapsed to one space, so a rewrap past the line changes nothing. A block
# that straddles the line, starting at or before it, is
#   @<start byte> "<its raw bytes up to the line>" <the rest, collapsed>
# The raw bytes are exact, whitespace included: a backslash, a double quote, a
# tab, a carriage return, and a line break are written \\ \" \t \r \n, and
# nothing else is changed. So the start byte pins any growth or shrinkage above
# the block, and the raw bytes pin any change inside it before the line.
late_blocks() {
  LC_ALL=C awk -v line="$SURVIVE_BYTES" '
    function collapse(s) { gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    function esc(s,   o, i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        o = o (c == "\\" ? "\\\\" : c == "\"" ? "\\\"" : c == "\t" ? "\\t" : c == "\r" ? "\\r" : c == "\n" ? "\\n" : c)
      }
      return o
    }
    function flush(   rest) {
      if (raw != "" && end > line) {
        if (start > line) print collapse(raw)
        else {
          rest = collapse(substr(raw, line - start + 2))
          print "@" start " \"" esc(substr(raw, 1, line - start + 1)) "\"" (rest == "" ? "" : " " rest)
        }
      }
      raw = ""
    }
    { line_start = off + 1; line_end = off + length($0); off += length($0) + 1 }
    fence { raw = raw "\n" $0; end = line_end; if ($0 ~ /^[[:space:]]*```/) { fence = 0; flush() }; next }
    /^[[:space:]]*```/ { flush(); fence = 1; raw = $0; start = line_start; end = line_end; next }
    /^[[:space:]]*$/ { flush(); next }
    /^#/ || /^\|/ || /^[[:space:]]*([-*]|[0-9]+\.) / { flush() }
    { if (raw == "") { raw = $0; start = line_start } else raw = raw "\n" $0; end = line_end }
    END { flush() }
  ' "$SKILL"
}

if [ "${1:-}" = --late-blocks ]; then late_blocks; exit 0; fi

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

# Under 500 lines each, the limit the skills docs set.
lines=()
for f in "$SKILL" "$DEVELOP"; do
  n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -lt 500 ] || lines+=("${f#"$ROOT"/} is $n lines; want fewer than 500")
done
report "lines — orchestrate and develop each stay under 500 lines" ${lines[@]+"${lines[@]}"}

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
frontmatter="$(awk 'NR==1 && /^---$/{f=1;next} f && /^---$/{exit} f' "$SKILL")"
desc_keys="$(printf '%s\n' "$frontmatter" | grep -c '^description[[:space:]]*:')"
odd_keys="$(printf '%s\n' "$frontmatter" | grep -c '^[?!&*"'\''[{]')"
desc="$(printf '%s\n' "$frontmatter" | sed -n 's/^description: //p')"
desc_more="$(printf '%s\n' "$frontmatter" | awk 'f && !/^[A-Za-z0-9_-]+:([[:space:]]|$)/ { n++; next } { f = /^description:/ } END { print n + 0 }')"
wtu="$(printf '%s\n' "$frontmatter" | sed -n 's/^when_to_use: //p')"
dq_closed='^"([^"\\]|\\.)*"[[:space:]]*(#.*)?$'
sq_closed="^'([^']|'')*'[[:space:]]*(#.*)?\$"
# A plain value opens on a byte no YAML indicator claims, or on - ? : with a
# non-space after it. Whitespace, a tag, an anchor, an alias, a block scalar,
# and a flow collection all fail it.
plain_open='^([^]!&*|>%@`{}#,"'\''?:[[:space:]-]|[?:-][^[:space:]])'
listing=()
[ "$desc_keys" -le 1 ] || listing+=("$desc_keys description keys in the frontmatter; a parser keeps only one of them, and maybe not the one counted here, so write exactly one")
[ "$odd_keys" -eq 0 ] || listing+=("$odd_keys frontmatter line(s) open with ? ! & * a quote or a bracket; write every key plain, so a second description cannot hide in another spelling")
if [ -z "$desc" ]; then
  listing+=("no description")
else
  case "$desc" in
    '"'*) [[ "$desc" =~ $dq_closed ]] || listing+=("the description's double quotes do not close on its line; write it on one line, so its bytes can be counted") ;;
    "'"*) [[ "$desc" =~ $sq_closed ]] || listing+=("the description's single quotes do not close on its line; write it on one line, so its bytes can be counted") ;;
    *) [[ "$desc" =~ $plain_open ]] || listing+=("the description opens with '${desc:0:1}', not a plain value or a quote; write one space after description:, then a plain or quoted value, so its bytes can be counted") ;;
  esac
fi
[ "$desc_more" -eq 0 ] || listing+=("$desc_more more line(s) follow the description before the next key; write it on one line, so its bytes can be counted")
desc_bytes="$(printf '%s' "$desc" | wc -c | tr -d ' ')"
[ "$desc_bytes" -le 300 ] || listing+=("the description is $desc_bytes bytes; want 300 or fewer")
[ -n "$wtu" ] || listing+=("no when_to_use: the trigger detail has nowhere to go but the description")
report "listing — a short description, the triggers in when_to_use" ${listing[@]+"${listing[@]}"}

# Every must-survive section ends inside the first SURVIVE_BYTES bytes of its
# file. A section ends where the next heading of any level starts, so a
# subsection that is not on the list is free to sit later. That is also why a
# section check alone is not enough: a rule split out of a listed section into a
# new one past the line leaves its old section passing. The past-the-line check
# below is what catches that move, under any heading.
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

# develop is inside the line whole, so every rule in it survives wherever it
# sits. The size limit is the whole check: any growth past the line fails.
survive=()
dev_bytes="$(wc -c < "$DEVELOP" | tr -d ' ')"
[ "$dev_bytes" -le "$SURVIVE_BYTES" ] || survive+=("develop: the file is $dev_bytes bytes; want $SURVIVE_BYTES or less, so no rule sits past the line")

# orchestrate is not, so its must-survive sections and phrases are pinned one
# row each: <section|phrase>|orchestrate|<heading or words>.
while IFS='|' read -r kind which want; do
  [ -n "$kind" ] || continue
  case "$which" in orchestrate) file="$SKILL" ;; *) survive+=("unknown file '$which'"); continue ;; esac
  if [ "$kind" = section ]; then end="$(section_end "$file" "$want")"; else end="$(phrase_end "$file" "$want")"; fi
  if [ "$end" = -1 ]; then
    survive+=("$which: no $kind '$want'")
  elif [ "$end" -gt "$SURVIVE_BYTES" ]; then
    survive+=("$which: $kind '$want' ends at byte $end; want $SURVIVE_BYTES or less")
  fi
done <<'EOF'
section|orchestrate|## The team
section|orchestrate|## Agent choice
section|orchestrate|## Dispatch in parallel
section|orchestrate|## Dispatch protocol
section|orchestrate|### Direct-mode work comes back uncommitted
section|orchestrate|## Action routing
section|orchestrate|### 1. Whose voice does the action carry?
section|orchestrate|### 2. Is the repo governed by The Index?
section|orchestrate|### Routing table
section|orchestrate|### Passing a gh body
section|orchestrate|## The brief
section|orchestrate|### Must omit
section|orchestrate|### When a brief comes back
phrase|orchestrate|A first line of `SKIP`
phrase|orchestrate|means nothing was spawned: relay it to the human rather than retrying
phrase|orchestrate|Track a spawned run from its log rather than from a completion notification
phrase|orchestrate|check the log for `Permission denied:` lines
phrase|orchestrate|body in a quoted heredoc or a file
phrase|orchestrate|Never write a multi-line body in double quotes
phrase|orchestrate|**Refused** — a slot is missing
phrase|orchestrate|**Questions** — every slot is there
phrase|orchestrate|Never start a fresh agent on the old brief
phrase|orchestrate|A refusal means the rule worked. Report it, then re-dispatch.
EOF
report "survive — develop fits inside the line whole, and orchestrate's must-survive sections and pinned phrases end inside it" ${survive[@]+"${survive[@]}"}

# orchestrate's blocks past the line are exactly the listed ones, compared as
# sorted lists so a duplicate block counts twice. A block past the line and not
# listed may be a must-survive rule that moved or was pushed there.
late=()
if [ ! -f "$LATE_LIST" ]; then
  late+=("no ${LATE_LIST#"$ROOT"/}")
else
  while IFS= read -r d; do
    case "$d" in
      '< '*) late+=("past the line, not listed: ${d:2:110}") ;;
      '> '*) late+=("listed, not past the line: ${d:2:110}") ;;
    esac
  done < <(diff <(late_blocks | LC_ALL=C sort) <(LC_ALL=C sort "$LATE_LIST"))
  [ "${#late[@]}" -eq 0 ] || late+=("if the change is deliberate, review the blocks and run: ./lint-compaction.sh --late-blocks > compaction-late-blocks.txt")
fi
report "past the line — only the listed orchestrate blocks sit past byte $SURVIVE_BYTES" ${late[@]+"${late[@]}"}

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
              'Never create a worktree'; do
  printf '%s' "$section" | grep -Fq "$phrase" || parallel+=("the parallel rule no longer says '$phrase'")
done
report "parallel — independent units go out at once, local work has no count cap" ${parallel[@]+"${parallel[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
