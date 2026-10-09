#!/bin/bash
# Every dev-team agent makes scratch the same way, and the dev-team mod deletes it.
# Run directly: bash agents/lint-scratch-cleanup.sh
#
# A LINTER, not a test: it greps English prose in the shipped Markdown and runs
# none of the plugin's shell logic. tests/scratch.test.ts holds the mod that
# carries the rule out.
#
# Why: on 2026-09-30 a Holmes lens made a probe copy with a bare `mktemp -d`,
# which lands in macOS $TMPDIR, and never deleted it. Its delete had been
# refused, most likely because it named the folder through a variable, and the
# report told Mike to run `! rm -r` himself. Mike's rule is that scratch lives in
# the session scratchpad or ~/Developer/scratchpad, one folder per run, and is
# deleted without the human. Since 2026-10-08 the dev-team mod carries that out
# (hooks/mods/scratch.ts): it points a dev-team agent's bare mktemp at a folder
# of its own under a scratch root, and deletes the folder when the run ends.
# Each agent reads only its own file, so the rule lives in all of them.
#
# Checks:
#   1. Every agents/*.md has a `## Scratch folders` section that names the bare
#      mktemp, both roots, the mod's delete at the run's end, the touch-only-
#      your-own rule, the fallback when the mod is not running, the ban on
#      handing the human a `!` command, and the branches-and-stashes carve-out.
#   2. No Markdown instruction under agents/ or skills/ makes scratch with a
#      `<scratch root>` template, except the three shared clones, each of which
#      its own step deletes: the Watson Index pipeline's, Holmes's Index-mode PR
#      checkout, which his helpers read while his turn may have ended, and
#      Lestrade's Item-mode clone.
#   3. Every helper skeleton in review-phases.md carries the same validation
#      block: run the existing tests in place, and copy nothing into scratch.
#      One skeleton worded its own way is a helper that makes a copy again.
#   4. The review guard's deny text sends a reviewer to the tests in place, and
#      never to a copy in scratch (Mike, 2026-10-09: reviews work in place).

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PHASES="$ROOT/references/holmes/review-phases.md"
GUARD="$ROOT/hooks/mods/review-guard.ts"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── 1. The section, in every agent file ───────────────────────────────────────
n=0
for file in "$DIR"/*.md; do
  agent="$(basename "$file" .md)"; n=$((n + 1))
  section="$(awk '/^## Scratch folders/{f=1; next} f && /^## /{exit} f{print}' "$file" | tr '\n' ' ' | tr -s ' ')"
  if [ -z "$section" ]; then
    bad "$agent — no '## Scratch folders' section"
    continue
  fi
  missing=()
  for phrase in \
    'Make every temporary folder with a bare `mktemp -d`' \
    'The dev-team mod points a bare `mktemp` at a folder of your own under a scratch root' \
    'the session scratchpad, or `~/Developer/scratchpad` when the session has none' \
    'It deletes that folder when your run ends' \
    'Touch only what your own `mktemp` made.' \
    'Never touch another run'"'"'s folder' \
    'If `mktemp` prints a path outside both scratch roots, the mod is not running' \
    'with `rm -rf` and its literal path, as a command of its own' \
    'Never ask the human to delete your scratch, and never hand them a `!` command' \
    'Leave git branches and stashes where they are'; do
    [[ $section == *"$phrase"* ]] || missing+=("$phrase")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    ok "$agent states the scratch rule in full"
  else
    for m in "${missing[@]}"; do bad "$agent — the section lacks: $m"; done
  fi
done
[ "$n" -ge 4 ] && ok "$n agent files checked" || bad "only $n agent files found in $DIR"

# ── 2. No <scratch root> template outside the Watson pipeline's clone ──────────
templated="$(cd "$ROOT" && grep -rn --include='*.md' 'mktemp -d <scratch root>' agents skills references \
  | grep -v '^references/watson/index-mode-pipeline.md:' \
  | grep -Ev '^agents/(holmes|holmes-index|lestrade|lestrade-item)\.md:[0-9]+:mktemp -d <scratch root>/(holmes|lestrade)\.XXXXXX ')"
if [ -z "$templated" ]; then
  ok "no Markdown instruction makes scratch from a <scratch root> template outside the three shared clones"
else
  while IFS= read -r line; do bad "templated mktemp: $line"; done <<< "$templated"
fi

# ── 3. One validation block, in every helper skeleton ─────────────────────────
VALIDATE='even to undo it after. Validate by running the existing tests in that tree and
reading them. Write no probe script, copy no repository, change no code, and
trim no test file. Run mutation testing only through the project'"'"'s own runner
that mutates in place without editing a file, such as `pest --mutate`. Report a
hole no test covers as a finding that names the missing test.'
skeletons="$(grep -c '^Checkout (' "$PHASES")"
blocks="$(python3 -c 'import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))' "$PHASES" "$VALIDATE")"
if [ "$skeletons" -gt 0 ] && [ "$skeletons" = "$blocks" ]; then
  ok "all $skeletons helper skeletons carry the same validation block"
else
  bad "$blocks of $skeletons helper skeletons carry the validation block word for word"
fi

# ── 4. The guard's deny text sends a reviewer to the tests in place ───────────
if grep -Fq "'Validate by running the existing tests in place and reading them." "$GUARD" \
  && ! grep -Eq 'runs on a copy|probe copy' "$GUARD"; then
  ok "the review guard's deny text sends a reviewer to the tests in place, never to a copy"
else
  bad "the review guard's deny text no longer sends a reviewer to the tests in place, or still offers a copy"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
