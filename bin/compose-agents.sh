#!/usr/bin/env bash
# Compose the mode agents from the public agent files.
#
# Each dev-team agent ships twice. agents/<agent>.md is the public type
# (workbench-dev-team:watson and the others), which holds every mode and stays
# the file a person edits. agents/<mode>.md is one mode of it, such as
# watson-index, and is generated here from the public file and its recipe,
# references/agent-modes/<mode>.recipe. A dispatch runs only one mode, so a mode
# file leaves the other mode's sections out, and its prompt is smaller.
#
# Why files and not $.agent.register: `claude -p --agent <type>` resolves the
# type before any hooks module loads, so a type a mod registers is "not found"
# there (measured on Claude Code 2.1.291). bin/dispatch-agent.sh starts every
# scheduled run that way, so its mode types must be agent files. The dev-team
# mod (hooks/register.ts) routes an interactive dispatch of a public type to the
# same files.
#
# A recipe is one directive per line. `#` starts a comment line.
#
#   name: <mode>            the mode type's name; must match the file name
#   source: <agent>         the public agent file the sections come from
#   description: <text>     the mode type's frontmatter description
#   tools: <list>           its frontmatter tools (default: the source's)
#   requires: <list>        the built-in tools the mode needs whether or not its
#                           prose names them; agents/lint-agent-tool-grants.sh
#                           holds the tools line to it, and nothing is composed
#   section: <heading>      copy that heading line of the source and the text
#                           under it, up to the next heading of any level
#   skip: <heading>         leave that heading out of this mode, on purpose
#   text: <line>            one literal line (`text:` alone is a blank line)
#
# The output follows the recipe's order. skills, model and effort are copied
# from the source's frontmatter, so each value is written in one place.
#
# Fails closed. A source heading the recipe neither copies nor skips, a heading
# named twice or absent from the source, and a heading the source holds twice
# all stop the run with nothing written. A new section in a public file
# therefore reddens the suite until each of its mode recipes decides about it.
# Headings inside a fenced block are text, never headings.
#
# Usage:
#   compose-agents.sh                 write every agents/<mode>.md
#   compose-agents.sh --check         exit 1 when any agents/<mode>.md is stale
#   compose-agents.sh --out <dir>     write the mode files into <dir> instead
#   compose-agents.sh --print <mode>  print one composed mode file
#
# The output is a pure function of the two input files: the same bytes on every
# run, which keeps each mode prompt cache-stable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECIPES="$ROOT/references/agent-modes"

MODE="write"
OUT="$ROOT/agents"
ONLY=
case "${1:-}" in
  --check) MODE=check ;;
  --out) MODE="write"; OUT="${2:-}"; [ -n "$OUT" ] || { echo "usage: $0 --out <dir>" >&2; exit 2; } ;;
  --print) MODE=print; ONLY="${2:-}"; [ -n "$ONLY" ] || { echo "usage: $0 --print <mode>" >&2; exit 2; } ;;
  '') ;;
  *) echo "usage: $0 [--check | --out <dir> | --print <mode>]" >&2; exit 2 ;;
esac

# compose <recipe>: the mode file on stdout, or a reason on stderr and exit 1.
compose() {
  local recipe="$1" mode source
  mode="$(basename "$recipe" .recipe)"
  source="$(sed -n 's/^source: *//p' "$recipe" | head -1)"
  [ -n "$source" ] || { echo "$recipe: no source: line" >&2; return 1; }
  [ -f "$ROOT/agents/$source.md" ] || { echo "$recipe: no agents/$source.md" >&2; return 1; }
  awk -v mode="$mode" -v source="$source" -v recipe="${recipe#"$ROOT"/}" '
    function fail(msg) { print recipe ": " msg > "/dev/stderr"; failed = 1; exit 1 }
    function front(key,   v) { v = fm[key]; return v }

    # Pass 1, the source: frontmatter keys, then each heading and its block.
    FNR == NR {
      if (FNR == 1 && $0 == "---") { infm = 1; next }
      if (infm) {
        if ($0 == "---") { infm = 0; next }
        k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*: */, "", v); fm[k] = v
        next
      }
      if ($0 ~ /^```/) fence = !fence
      if (!fence && $0 ~ /^#+ /) {
        if ($0 in block) fail("agents/" source ".md holds the heading \"" $0 "\" twice")
        cur = $0; order[++nh] = cur; block[cur] = $0; next
      }
      if (cur != "") block[cur] = block[cur] "\n" $0
      next
    }

    # Pass 2, the recipe.
    /^#/ || /^[ \t]*$/ { next }
    {
      key = $0; sub(/:.*/, "", key); val = $0; sub(/^[^:]*:/, "", val); sub(/^ /, "", val)
      if (key == "name") { if (val != mode) fail("name: " val " does not match the file name " mode); name = val; next }
      if (key == "source") next
      if (key == "description") { desc = val; next }
      if (key == "tools") { tools = val; next }
      if (key == "requires") next
      if (key == "section" || key == "skip") {
        if (!(val in block)) fail("agents/" source ".md has no heading \"" val "\"")
        if (val in seen) fail("names the heading \"" val "\" twice")
        seen[val] = 1
        if (key == "section") { out[++no] = "S" val }
        next
      }
      if (key == "text") { out[++no] = "T" val; next }
      fail("unknown directive \"" key "\"")
    }

    END {
      if (failed) exit 1
      if (name == "") fail("no name: line")
      if (desc == "") fail("no description: line")
      for (i = 1; i <= nh; i++) if (!(order[i] in seen)) fail("neither copies nor skips \"" order[i] "\"")
      if (tools == "") tools = front("tools")

      print "---"
      print "name: " name
      print "# Composed by bin/compose-agents.sh from agents/" source ".md and " recipe ". Edit those, then run the script."
      print "description: " desc
      if (tools != "") print "tools: " tools
      if (front("skills") != "") print "skills: " front("skills")
      if (front("model") != "") print "model: " front("model")
      if (front("effort") != "") print "effort: " front("effort")
      print "---"

      # One blank line between blocks. Consecutive text lines form one block.
      prev = ""
      for (i = 1; i <= no; i++) {
        kind = substr(out[i], 1, 1); val = substr(out[i], 2)
        if (kind == "S") {
          b = block[val]; sub(/\n+$/, "", b)
          print ""; print b
        } else {
          if (prev != "T") print ""
          print val
        }
        prev = kind
      }
    }
  ' "$ROOT/agents/$source.md" "$recipe"
}

shopt -s nullglob
recipes=("$RECIPES"/*.recipe)
[ ${#recipes[@]} -gt 0 ] || { echo "$0: no recipes in $RECIPES" >&2; exit 1; }

if [ "$MODE" = print ]; then
  [ -f "$RECIPES/$ONLY.recipe" ] || { echo "$0: no recipe for $ONLY" >&2; exit 1; }
  compose "$RECIPES/$ONLY.recipe"
  exit
fi

# Every recipe composes before anything is written, so a failure leaves every
# mode file as it was.
status=0
declare -a texts=()
for recipe in "${recipes[@]}"; do
  if ! text="$(compose "$recipe")"; then
    status=1
    continue
  fi
  texts+=("$text")
done
[ "$status" = 0 ] || exit 1

stale=0
for i in "${!recipes[@]}"; do
  mode="$(basename "${recipes[$i]}" .recipe)"
  if [ "$MODE" = check ]; then
    if ! printf '%s\n' "${texts[$i]}" | cmp -s - "$ROOT/agents/$mode.md"; then
      echo "stale: agents/$mode.md — run bin/compose-agents.sh" >&2
      stale=1
    fi
  else
    mkdir -p "$OUT" && printf '%s\n' "${texts[$i]}" > "$OUT/$mode.md" || exit 1
    echo "composed $OUT/$mode.md"
  fi
done
exit "$stale"
