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
watson|skills/watson-pipeline/references/index-mode-pipeline.md|### 6. Implement|Index mode (step 6)
holmes|agents/holmes.md|### 2.5. Decision request?|answer mode (§2.5)
holmes|agents/holmes.md|##### 4a.5. Search `feedback/`|Index review (§4a.5)
holmes|skills/holmes-review/references/local-review.md|## §L4a|Local mode (§L4a)
lestrade|agents/lestrade.md|### 2.5. Scope kickback|scope-kickback sharpen (step 2.5)
lestrade|agents/lestrade.md|### 4. Generate acceptance criteria|Item mode (step 4)
lestrade|skills/lestrade-triage/references/sweep-mode.md|### 4. Consolidate|Sweep mode (step 4)
EOF

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
