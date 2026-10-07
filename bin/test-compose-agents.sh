#!/usr/bin/env bash
# Test for bin/compose-agents.sh, the composer of the mode agents.
#
# The shipped half runs the real script against the real tree: every committed
# mode file must be what the script composes now, and each must be smaller than
# the public agent it was cut from. The fixture half runs a copy of the script in
# a sandbox tree, so every fail-closed path can be driven without touching the
# repository.
#
# Run: bash bin/test-compose-agents.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$HERE/compose-agents.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }

echo "── the shipped tree ─────────────────────────────────────────────────────"

if bash "$SCRIPT" --check >/dev/null 2>&1; then
  ok "every agents/<mode>.md is what the script composes now"
else
  bad "a mode file is stale: run bin/compose-agents.sh ($(bash "$SCRIPT" --check 2>&1 | tr '\n' ' '))"
fi

# Determinism: the bytes are a function of the two inputs, so two runs agree.
bash "$SCRIPT" --out "$WORK/one" >/dev/null 2>&1
bash "$SCRIPT" --out "$WORK/two" >/dev/null 2>&1
if diff -r "$WORK/one" "$WORK/two" >/dev/null 2>&1 && [ -n "$(ls "$WORK/one")" ]; then
  ok "two runs compose identical bytes"
else
  bad "two runs differ, so a mode prompt is not cache-stable"
fi

# Every recipe names a mode that lands as a file, and each mode is smaller than
# its public agent. That is the reason the modes exist.
recipes=0
for recipe in "$ROOT"/references/agent-modes/*.recipe; do
  recipes=$((recipes + 1))
  mode=$(basename "$recipe" .recipe)
  source=$(sed -n 's/^source: *//p' "$recipe")
  mode_size=$(wc -c < "$ROOT/agents/$mode.md" | tr -d ' ')
  source_size=$(wc -c < "$ROOT/agents/$source.md" | tr -d ' ')
  if [ "$mode_size" -lt "$source_size" ]; then
    ok "$mode ($mode_size bytes) is smaller than $source ($source_size bytes)"
  else
    bad "$mode ($mode_size bytes) is not smaller than $source ($source_size bytes)"
  fi
  head -2 "$ROOT/agents/$mode.md" | grep -qx "name: $mode" || bad "$mode.md does not name itself $mode"
  model_src=$(sed -n 's/^model: //p' "$ROOT/agents/$source.md" | head -1)
  model_mode=$(sed -n 's/^model: //p' "$ROOT/agents/$mode.md" | head -1)
  expect "$mode takes its model from $source" "$model_mode" "$model_src"
done
expect "six mode recipes ship" "$recipes" 6

echo "── the composer, in a sandbox ───────────────────────────────────────────"

# fixture: a tree with the script, one public agent and one recipe.
fixture() {
  local dir="$WORK/$1"
  mkdir -p "$dir/bin" "$dir/agents" "$dir/references/agent-modes"
  cp "$SCRIPT" "$dir/bin/compose-agents.sh"
  cat > "$dir/agents/pub.md" <<'EOF'
---
name: pub
description: Public.
tools: Read, Bash
skills: workbench-dev-team:comms-style
model: claude-opus-5-5[1m]
effort: medium
---

# Pub

Intro.

## Shared

Shared text.

```bash
## not a heading, a comment in a fence
```

## Mode A

A only.

## Mode B

B only.
EOF
  cat > "$dir/references/agent-modes/pub-a.recipe" <<'EOF'
# a comment
name: pub-a
source: pub
description: Pub in mode A.
requires: Read, Bash
section: # Pub
section: ## Shared
text: ## Literal
text:
text: A literal line.
section: ## Mode A
skip: ## Mode B
EOF
  printf '%s' "$dir"
}

D=$(fixture ok)
bash "$D/bin/compose-agents.sh" >/dev/null 2>&1
expect "a valid recipe composes" "$?" 0
OUT="$D/agents/pub-a.md"
cat > "$WORK/want" <<'EOF'
---
name: pub-a
# Composed by bin/compose-agents.sh from agents/pub.md and references/agent-modes/pub-a.recipe. Edit those, then run the script.
description: Pub in mode A.
tools: Read, Bash
skills: workbench-dev-team:comms-style
model: claude-opus-5-5[1m]
effort: medium
---

# Pub

Intro.

## Shared

Shared text.

```bash
## not a heading, a comment in a fence
```

## Literal

A literal line.

## Mode A

A only.
EOF
if cmp -s "$OUT" "$WORK/want"; then
  ok "the output is the recipe's sections in order, fences kept whole, frontmatter from the source, requires: left out"
else
  bad "the output differs from the expected file: $(diff "$WORK/want" "$OUT" | head -5 | tr '\n' ' ')"
fi
bash "$D/bin/compose-agents.sh" --check >/dev/null 2>&1
expect "--check passes on a fresh composition" "$?" 0
printf '\nedited by hand\n' >> "$OUT"
bash "$D/bin/compose-agents.sh" --check >/dev/null 2>&1
expect "--check fails on a hand-edited mode file" "$?" 1

# Each fail-closed path: the run exits 1 and writes nothing.
refuse() { # refuse <label> <sed expression on the recipe | 'source:<awk>'>
  local d; d=$(fixture "$1")
  case "$2" in
    source:*) printf '%s\n' "${2#source:}" >> "$d/agents/pub.md" ;;
    *) sed -i.bak "$2" "$d/references/agent-modes/pub-a.recipe" ;;
  esac
  local err; err=$(bash "$d/bin/compose-agents.sh" 2>&1 >/dev/null); local rc=$?
  if [ "$rc" = 1 ] && [ ! -e "$d/agents/pub-a.md" ]; then
    ok "refused, nothing written: $1 ($err)"
  else
    bad "$1: expected exit 1 and no file, got exit $rc"
  fi
}
refuse "a source heading the recipe neither copies nor skips" '/^skip: ## Mode B/d'
refuse "a heading the source does not hold" 's/^skip: ## Mode B/skip: ## Mode C/'
refuse "a heading named twice" 's/^skip: ## Mode B/section: ## Mode A/'
refuse "a name that does not match the file" 's/^name: pub-a/name: pub-b/'
refuse "an unknown directive" 's/^text: A literal line./txet: A literal line./'
refuse "no description" '/^description:/d'
refuse "a heading the source holds twice" 'source:## Shared'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
