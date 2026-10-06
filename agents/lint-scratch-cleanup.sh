#!/bin/bash
# Every dev-team agent makes scratch in the same places and deletes it itself.
# Run directly: bash agents/lint-scratch-cleanup.sh
#
# A LINTER, not a test: it greps English prose in the shipped Markdown and runs
# none of the plugin's shell logic.
#
# Why: on 2026-09-30 a Holmes lens made a probe copy with a bare `mktemp -d`,
# which lands in macOS $TMPDIR, and never deleted it. Its delete had been
# refused, most likely because it named the folder through a variable, and the
# report told Mike to run `! rm -r` himself. Mike's rule is that scratch lives in
# the session scratchpad or ~/Developer/scratchpad, one folder per run, and that
# an agent deletes its own scratch, with the path spelled out, before it reports.
# Each agent reads only its own file, so the rule lives in all of them.
#
# Checks:
#   1. Every agents/*.md has a `## Scratch folders` section that names both
#      roots, a per-run mktemp template carrying the agent's own name, the
#      literal-path delete as its own command, the respell-and-retry rule, the
#      ban on handing the human a `!` command, the defect report, and the
#      branches-and-stashes carve-out.
#   2. No Markdown instruction under agents/ or skills/ makes scratch with a
#      bare `mktemp -d`. A line that says `mktemp -d` must carry an XXXXXX
#      template, or be the line that forbids the bare form.
#   3. Every helper skeleton in review-phases.md carries the same probe-copy
#      block, which makes the folder under a scratch root and deletes it. One
#      skeleton worded its own way is a helper that leaks its copy again.
#   4. The review guard's deny text sends a probe to a scratch root, not to a
#      bare `mktemp -d`.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PHASES="$ROOT/references/holmes/review-phases.md"
GUARD="$ROOT/hooks/scripts/local-review-guard.sh"
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
    '**The session scratchpad**' \
    '**`~/Developer/scratchpad`**, when your environment names none' \
    "\`mktemp -d <scratch root>/$agent.XXXXXX\`" \
    'Never make scratch with a bare `mktemp -d`, in `$TMPDIR`, or in `/tmp`.' \
    'Never touch another run'"'"'s folder' \
    '**Delete every folder you made before you report,** on every exit path' \
    'run the delete as a command of its own' \
    '**If a guard refuses the delete of your own scratch, respell it and retry.**' \
    'Never ask the human to delete your scratch, and never hand them a `!` command' \
    'name the path in your report as a defect' \
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

# ── 2. No bare mktemp -d in any agent or skill instruction ────────────────────
bare="$(cd "$ROOT" && grep -rn --include='*.md' 'mktemp -d' agents skills | grep -v 'XXXXXX' | grep -v 'bare `mktemp -d`')"
if [ -z "$bare" ]; then
  ok "no Markdown instruction makes scratch with a bare mktemp -d"
else
  while IFS= read -r line; do bad "bare mktemp -d: $line"; done <<< "$bare"
fi

# ── 3. One probe-copy block, in every helper skeleton ─────────────────────────
PROBE='in your own scratch folder, and you change only that copy. Make the folder with
`mktemp -d` and a `holmes-lens.XXXXXX` name under your session scratchpad, or
under ~/Developer/scratchpad when your environment names none. Before you
report, delete it with `rm -rf` and the literal path, as its own command.'
skeletons="$(grep -c '^Checkout (' "$PHASES")"
blocks="$(python3 -c 'import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))' "$PHASES" "$PROBE")"
if [ "$skeletons" -gt 0 ] && [ "$skeletons" = "$blocks" ]; then
  ok "all $skeletons helper skeletons carry the same probe-copy block"
else
  bad "$blocks of $skeletons helper skeletons carry the probe-copy block word for word"
fi

# ── 4. The guard's deny text points a probe at a scratch root ─────────────────
if grep -Fq 'under the session scratchpad or ~/Developer/scratchpad, and deleted' "$GUARD"; then
  ok "the review guard's deny text sends a probe copy to a scratch root"
else
  bad "the review guard's deny text no longer sends a probe copy to a scratch root"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
