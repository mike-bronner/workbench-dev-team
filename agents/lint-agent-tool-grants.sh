#!/bin/bash
# Guards agent tool grants. Run directly: ./lint-agent-tool-grants.sh
#
# A LINTER, not a test: it reads the shipped Markdown and compares frontmatter
# against prose. It executes none of the plugin's shell logic, so the `lint-`
# prefix keeps it out of the suite's test loop and out of what the suite claims
# to guarantee about behaviour.
#
# A subagent's frontmatter `tools:` line is a STRICT allowlist — a tool the body
# instructs the agent to call but the allowlist omits is silently unavailable at
# runtime, so the instruction dies at the harness with nothing logged. v0.18.0
# shipped `create_issue` prose for Holmes and Watson without granting the tool;
# this catches that whole class. For every agents/*.md, each mcp__ tool cited in
# the body must appear in that file's frontmatter `tools:` list, and each
# /workbench-dev-team skill the body says the agent follows must be preloaded
# through its frontmatter `skills:` list.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

for file in "$DIR"/*.md; do
  agent="$(basename "$file" .md)"

  # Frontmatter = lines between the first two `---` fences; body = everything after.
  frontmatter="$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$file")"
  body="$(awk 'b{print} $0=="---"{n++; if(n==2)b=1}' "$file")"

  # Granted: the mcp__ tools on the frontmatter `tools:` line, one per line.
  granted="$(printf '%s\n' "$frontmatter" | grep -E '^tools:' \
    | sed 's/^tools://' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -E '^mcp__' || true)"

  # Referenced: mcp__ tool tokens the body cites (server may hold hyphens; tool is snake_case).
  referenced="$(printf '%s\n' "$body" \
    | grep -oE 'mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_]+' | sort -u || true)"

  missing=""
  while IFS= read -r tool; do
    [ -z "$tool" ] && continue
    if ! printf '%s\n' "$granted" | grep -Fqx "$tool"; then
      missing="$missing $tool"
    fi
  done <<EOF
$referenced
EOF

  count="$(printf '%s\n' "$referenced" | grep -c . || true)"
  if [ -z "$missing" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ $agent — all $count referenced index tools granted"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $agent — body calls tools absent from frontmatter tools:"
    for m in $missing; do echo "       • $m"; done
  fi

  # Skills the body says the agent FOLLOWS must be preloaded through the
  # frontmatter `skills:` line. An agent with no Skill tool and no path cannot
  # load one on its own, so "follows /x" with no preload is an instruction the
  # agent has no way to carry out. Each preloaded skill must also exist here,
  # or the harness only logs "specified in frontmatter was not found".
  preloaded="$(printf '%s\n' "$frontmatter" | grep -E '^skills:' \
    | sed 's/^skills://' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . || true)"
  # Joined into one line first: prose wraps, and "follows" often ends the line
  # before the skill name starts the next.
  followed="$(printf '%s\n' "$body" | tr '\n' ' ' \
    | grep -oiE 'follows?[^.]{0,40}/workbench-dev-team:[a-z-]+' \
    | grep -oE '/workbench-dev-team:[a-z-]+' | sed 's#^/##' | sort -u || true)"
  unloaded=""
  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    printf '%s\n' "$preloaded" | grep -Fqx "$skill" || unloaded="$unloaded $skill"
  done <<EOF
$followed
EOF
  absent=""
  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    [ -f "$DIR/../skills/${skill#workbench-dev-team:}/SKILL.md" ] || absent="$absent $skill"
  done <<EOF
$preloaded
EOF
  if [ -z "$unloaded" ] && [ -z "$absent" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ $agent — every followed skill is preloaded, and every preload exists"
  else
    FAIL=$((FAIL + 1))
    for m in $unloaded; do echo "  ❌ $agent — follows $m but its frontmatter skills: does not preload it"; done
    for m in $absent; do echo "  ❌ $agent — preloads $m, which is not a skill in this plugin"; done
  fi
done

# Mike ruled that all three agents search the vault's feedback/ folder before
# they work: Watson before building, Holmes before judging or answering, and
# Lestrade before writing AC. His corrections bind every stage, and a stage that
# never reads them never catches a violation. The rule needs two halves, and each
# can go missing alone: the frontmatter has to grant the search tool, or the
# instruction dies at the harness, and every run path has to tell the agent to
# search. A mention anywhere in the agent is not enough: Holmes's answer mode
# and Lestrade's Sweep mode both exit before the section that held it.
for agent in watson holmes lestrade; do
  frontmatter="$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$DIR/$agent.md")"
  if printf '%s\n' "$frontmatter" | grep -E '^tools:' | grep -q 'mcp__plugin_workbench-core_memory__search'; then
    PASS=$((PASS + 1))
    echo "  ✅ $agent — is granted memory search"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $agent — its frontmatter tools: does not grant memory search"
  fi
done

# section <file> <heading prefix> — the body under the heading line that starts
# with the prefix, through the line before the next heading at the same or a
# higher level. The heading line itself is left out: Holmes's §4a.5 heading says
# "Search `feedback/`", so a match against it passed whatever the body said.
# Lines inside a code fence are never headings, so a `# comment` there cannot end
# it.
section() {
  awk -v prefix="$2" '
    /^```/ { fence = !fence }
    !fence && /^#+ / {
      level = length($0) - length(substr($0, index($0, " ")))
      if (on && level <= depth) exit
      if (!on && index($0, prefix) == 1) { on = 1; depth = level; next }
    }
    on { print }
  ' "$1"
}

# instructs_search — true when one sentence of the text on stdin tells the agent
# to search feedback/: it names both a search and feedback. A mention of the
# folder alone, such as "corrections live under feedback/", is not an
# instruction. Sentences end at a full stop and a space, so `§4a.5` holds.
instructs_search() {
  tr '\n' ' ' | awk '{ gsub(/\. /, ".\n"); print }' | grep -i 'search' | grep -q 'feedback'
}

# One row per run path that decides, answers, or writes something Mike's rules
# bind: <agent>|<file under the plugin root>|<heading prefix>|<path name>.
while IFS='|' read -r agent rel heading label; do
  [ -n "$agent" ] || continue
  text="$(section "$DIR/../$rel" "$heading")"
  if [ -z "$text" ]; then
    FAIL=$((FAIL + 1))
    echo "  ❌ $agent — $label: no section in $rel starts with \"$heading\""
  elif printf '%s\n' "$text" | instructs_search; then
    PASS=$((PASS + 1))
    echo "  ✅ $agent — $label searches feedback/"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $agent — $label never tells it to search the vault's feedback/ folder"
  fi
done <<'EOF'
watson|agents/watson.md|## Direct mode|Direct mode
watson|skills/develop/SKILL.md|## 2. Plan before coding|/develop §2, which Direct mode follows
watson|references/watson/index-mode-pipeline.md|### 6. Implement|Index mode (step 6)
holmes|agents/holmes.md|### 2.5. Decision request?|answer mode (§2.5)
holmes|agents/holmes.md|##### 4a.5. Search `feedback/`|Index review (§4a.5)
holmes|references/holmes/local-review.md|## §L4a|Local mode (§L4a)
lestrade|agents/lestrade.md|### 2.5. Scope kickback|scope-kickback sharpen (step 2.5)
lestrade|agents/lestrade.md|### 4. Generate acceptance criteria|Item mode (step 4)
lestrade|references/lestrade/sweep-mode.md|### 4. Consolidate|Sweep mode (step 4)
EOF

# ── Each mode file holds every tool its mode calls for ───────────────────────
# bin/compose-agents.sh gives each mode file its own `tools:` line, so a mode
# loses any tool its recipe leaves out, even one the public file grants. The
# loss is silent: the instruction dies at the harness. Round 2 of Phase 3 left
# lestrade-sweep without the memory search its reference requires and without
# the Read its own text names. So each composed mode file is held two ways.
#
# 1. Detection. Every tool the mode's text calls for must be on its `tools:`
#    line. The text is the mode file's body, each skill its frontmatter
#    preloads, and every reference file any of those reads, followed
#    transitively: Holmes's Local mode is held to review-phases.md, which
#    local-review.md sends it to, and Watson to /develop and its references.
#    A text calls for a tool when it has:
#      - an mcp__ name
#      - a built-in in backticks, or after "use" or "call" ("use the Read
#        tool"); "the Agent tool that spawns you" and "dispatched through the
#        Agent tool" describe, and call for nothing
#      - `subagent_type`, which only the Agent tool takes
#      - a ```bash fence, or a backticked `git`, `gh`, `jq` or `rg` command,
#        which only the Bash tool runs
#      - a sentence that tells it to search `feedback/` (the memory search) or
#        to read `top-lessons.md` (the memory read)
#      - a sentence that tells it to use, follow, load or format via a
#        /plugin:skill it does not preload, which only the Skill tool loads
#    A clause that forbids a write tool ("no `Write`", "never give a sub-agent
#    a write tool") is struck out before the text is read, and the rest of its
#    line still counts.
# 2. The recipe's stated set. Some needs no prose spells out: a development mode
#    writes files with Write and Edit whether or not a sentence says so. Each
#    recipe's `requires:` line names the built-ins its mode needs. Every one
#    must be on the mode file's `tools:` line, and every built-in on the
#    `tools:` line must be in `requires:`. A recipe without one fails.
BUILTINS='Read|Write|Edit|Grep|Glob|Bash|Agent|Skill'

# The reference files a text reads, one path per line, from the plugin root:
# ${CLAUDE_PLUGIN_ROOT}/references/... anywhere, and `references/...` in
# backticks, which in a skill's SKILL.md or in a file of its references/ folder
# names that skill's own references/ folder. A full skills/... path is cited for
# its reasons, never read, so it is not one.
refs_of() {
  local file="$1" base="references"
  case "$file" in
    */skills/*) base="skills/$(printf '%s' "$file" | sed 's|.*/skills/\([^/]*\)/.*|\1|')/references" ;;
  esac
  grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/references/[A-Za-z0-9_./-]+\.md' "$file" | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||'
  grep -oE '`references/[A-Za-z0-9_./-]+\.md' "$file" | sed "s|^\`references/|$base/|"
  return 0
}

# A clause that forbids a write tool, struck out of a line so the rest of the
# line still counts: a negation word, then the forbidden tool within the same
# clause. The clause ends at punctuation or a backtick, so "If the file does not
# exist, use `Write` to create it" keeps its call.
#
# POSIX ERE only, because macOS runs this under BSD sed and CI under GNU sed. BSD
# sed has no \b, so a \b here strikes nothing on a Mac and strikes in CI. The
# word boundary is spelled as a non-letter or the line start, kept by \1.
FORBID='(^|[^A-Za-z])([Nn]o|[Nn]ever|[Nn]ot|[Ww]ithout)[[:space:]][^.,;:!?`]{0,30}(`?(Write|Edit|NotebookEdit)`?(/`?(Write|Edit)`?)?|write tool)'

# The tools the text on stdin calls for, one per line. $1 is the mode's
# preloaded skills, one per line, which need no Skill tool.
tools_called() {
  local text sentences preloaded="$1"
  text="$(sed -E "s#$FORBID#\\1#g")"
  sentences="$(printf '%s\n' "$text" | tr '\n' ' ' | awk '{ gsub(/\. /, ".\n"); print }')"
  printf '%s\n' "$text" | grep -oE 'mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_]+' || true
  printf '%s\n' "$text" | grep -oE "\`($BUILTINS)\`|(use|using|call|calling) the ($BUILTINS) tool" \
    | grep -oE "$BUILTINS" || true
  printf '%s\n' "$text" | grep -q 'subagent_type' && echo Agent
  printf '%s\n' "$text" | grep -qE '^```bash|`(git|gh|jq|rg) [^`]+`' && echo Bash
  printf '%s\n' "$text" | instructs_search && echo mcp__plugin_workbench-core_memory__search
  printf '%s\n' "$sentences" | grep -i 'read' | grep -q 'top-lessons' && echo mcp__plugin_workbench-core_memory__read
  printf '%s\n' "$sentences" | grep -iE '(^|[^a-z])(use|uses|using|via|follow|follows|invoke|load|format|formatted)([^a-z]|$)' \
    | grep -oE '/[a-z][a-z0-9-]*:[a-z][a-z0-9-]*' | sed 's|^/||' | sort -u \
    | while IFS= read -r skill; do
        printf '%s\n' "$preloaded" | grep -Fqx "$skill" || echo Skill
      done
  return 0
}

# The forbid strike, probed on whichever sed runs this: BSD sed on a Mac, GNU
# sed in CI. Each probe line pins one reading, and the verdicts must be the same
# under both.
#   1. A tool named beside a prohibition still counts (Holmes's Agent grant).
#   2. A backticked forbidden tool is struck, so it is not counted.
#   3. A real call after an unrelated negation, past a comma, survives.
forbid_probe() { # forbid_probe <label> <line> <tool> <want: counted|struck>
  local got
  if printf '%s\n' "$2" | tools_called '' | grep -qx "$3"; then got=counted; else got=struck; fi
  if [ "$got" = "$4" ]; then
    PASS=$((PASS + 1)); echo "  ✅ forbid strike: $1"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ forbid strike: $1 — $3 is $got, want $4"
  fi
}
forbid_probe "a tool beside a prohibition still counts" \
  '- `Agent` — dispatch the lenses. Never give a sub-agent a write tool. You have no Write/Edit.' Agent counted
forbid_probe "a backticked forbidden tool is struck" 'You have no `Write`.' Write struck
forbid_probe "a backticked pair after a negation is struck" 'It is never `Write`/`Edit` here.' Edit struck
forbid_probe "a real call after an unrelated negation survives" \
  'If the file does not exist, use `Write` to create it.' Write counted

modes=0
for file in "$DIR"/*.md; do
  grep -q '^# Composed by bin/compose-agents.sh' "$file" || continue
  modes=$((modes + 1))
  mode="$(basename "$file" .md)"
  frontmatter="$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$file")"
  granted="$(printf '%s\n' "$frontmatter" | grep -E '^tools:' | sed 's/^tools://' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  preloaded="$(printf '%s\n' "$frontmatter" | grep -E '^skills:' | sed 's/^skills://' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . || true)"

  # The body, then each preloaded skill and every reference, transitively.
  called="$(awk 'b{print} $0=="---"{n++; if(n==2)b=1}' "$file" | tools_called "$preloaded")"
  queue="$(refs_of "$file"; printf '%s\n' "$preloaded" | sed -n 's|^workbench-dev-team:\(.*\)|skills/\1/SKILL.md|p')"
  seen=""
  while [ -n "$queue" ]; do
    ref="$(printf '%s\n' "$queue" | head -1)"
    queue="$(printf '%s\n' "$queue" | sed 1d)"
    case " $seen " in *" $ref "*) continue ;; esac
    seen="$seen $ref"
    if [ ! -f "$DIR/../$ref" ]; then
      FAIL=$((FAIL + 1)); echo "  ❌ $mode — reads $ref, which does not exist"; continue
    fi
    called="$called
$(tools_called "$preloaded" < "$DIR/../$ref")"
    queue="$(printf '%s\n%s\n' "$queue" "$(refs_of "$DIR/../$ref" | sed "s|^$DIR/../||")" | grep . || true)"
  done

  # The recipe's stated set of built-ins.
  recipe="$(sed -n 's|^# Composed by bin/compose-agents.sh from agents/[a-z-]*\.md and \([^ ]*\.recipe\)\..*|\1|p' "$file")"
  required="$(sed -n 's/^requires://p' "$DIR/../$recipe" 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . || true)"
  if [ -z "$required" ]; then
    FAIL=$((FAIL + 1)); echo "  ❌ $mode — its recipe ${recipe:-(none found)} states no requires: line"
  fi

  # Every built-in on the tools line must be in requires:, so no tool there is
  # protected by detection alone, which finds no Write or Edit for Watson and no
  # built-in outside BUILTINS. Dropping a tool takes an edit of both lines.
  unrequired=""
  while IFS= read -r tool; do
    case "$tool" in ''|mcp__*) continue ;; esac
    printf '%s\n' "$required" | grep -Fqx "$tool" || unrequired="$unrequired $tool"
  done <<EOF
$granted
EOF
  if [ -n "$unrequired" ]; then
    FAIL=$((FAIL + 1))
    echo "  ❌ $mode — its tools: line holds built-ins its recipe's requires: line does not name:"
    for m in $unrequired; do echo "       • $m"; done
  fi

  missing=""
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    printf '%s\n' "$granted" | grep -Fqx "$tool" || missing="$missing $tool"
  done <<EOF
$(printf '%s\n%s\n' "$called" "$required" | sort -u)
EOF
  if [ -z "$missing" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ $mode — holds every tool its recipe requires and its text, skills and references ($(printf '%s' "$seen" | wc -w | tr -d ' ')) call for"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $mode — its recipe requires, or its text calls for, tools its tools: line lacks:"
    for m in $missing; do echo "       • $m"; done
  fi
done
if [ "$modes" -ge 6 ]; then
  PASS=$((PASS + 1)); echo "  ✅ $modes composed mode files checked"
else
  FAIL=$((FAIL + 1)); echo "  ❌ only $modes composed mode files found, want 6"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
