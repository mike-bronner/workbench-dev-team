#!/bin/bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

PIPELINE="$ROOT/references/watson/external-mode-pipeline.md"
LOCAL="$ROOT/references/holmes/local-review.md"
FILES=("$DIR/watson-external.md" "$DIR/holmes-external.md" "$DIR/lestrade-external.md" "$PIPELINE")
WRITE_VERB='gh (pr (create|ready|merge|review|comment|edit|close|reopen)|issue (comment|create|edit|close|reopen|delete)|api [^`]*(-X|--method)[ =]?(POST|PUT|PATCH|DELETE)|api [^`]*(-f|-F|--field|--raw-field|--input) )'

for file in "${FILES[@]}"; do
  name="${file#"$ROOT"/}"
  if [ ! -f "$file" ]; then
    bad "$name is missing"
    continue
  fi
  if grep -q 'mcp__the-index' "$file"; then
    bad "$name names a tool of The Index: $(grep -n 'mcp__the-index' "$file" | head -1)"
  else
    ok "$name names no tool of The Index"
  fi
  verbs="$(grep -nE "$WRITE_VERB" "$file" | grep -viE 'never|refuses' || true)"
  if [ -n "$verbs" ]; then
    bad "$name tells an agent to run a gh write: $(printf '%s' "$verbs" | head -1)"
  else
    ok "$name runs no gh write verb and no writing gh api"
  fi
done

probe() {
  if printf '%s\n' "$2" | grep -qE "$WRITE_VERB"; then got=caught; else got=passed; fi
  if [ "$got" = "$3" ]; then ok "write-verb probe: $1"; else bad "write-verb probe: $1 ($got)"; fi
}
probe "a POST through gh api" 'gh api --method POST repos/o/r/issues/1/comments --input -' caught
probe "a field through gh api" 'gh api repos/o/r/issues/1/comments -f body=x' caught
probe "a pr create" 'gh pr create --draft' caught
probe "a GET through gh api" 'gh api repos/o/r --jq .default_branch' passed

expect() {
  local name="${1#"$ROOT"/}"
  if grep -qF -- "$2" "$1"; then got=present; else got=absent; fi
  if [ "$got" = "$3" ]; then ok "$name: $4"; else bad "$name: $4 ($2 is $got)"; fi
}

expect "$DIR/watson-external.md" 'external-gh.sh' present "Watson writes to GitHub through external-gh.sh"
expect "$PIPELINE" '/bin/external-gh.sh" pr ' present "the pipeline opens the PR through external-gh.sh"
expect "$DIR/lestrade-external.md" '/bin/external-gh.sh" comment ' present "Lestrade posts the criteria through external-gh.sh"
expect "$DIR/holmes-external.md" 'external-gh.sh' absent "Holmes never names the posting script"
expect "$PIPELINE" '/bin/external-result.sh" draft_pr ' present "the pipeline ends on draft_pr through external-result.sh"
expect "$PIPELINE" '/bin/external-result.sh" needs_mike ' present "the pipeline stops at needs_mike through external-result.sh"
expect "$DIR/holmes-external.md" '/bin/external-result.sh" review_drafted' present "Holmes writes review_drafted through external-result.sh"
expect "$DIR/holmes-external.md" 'external-result.sh needs_mike' present "Holmes stops at needs_mike through external-result.sh"
expect "$DIR/lestrade-external.md" 'external-result.sh' absent "Lestrade never writes the result file"
expect "$DIR/lestrade-external.md" '<!-- acceptance-criteria -->' present "Lestrade's comment starts with the criteria marker"
expect "$DIR/watson-external.md" 'never copy text from the issue' present "Watson never copies untrusted text into a marked write"
expect "$DIR/lestrade-external.md" 'never copy text from the issue' present "Lestrade never copies untrusted text into a marked write"

brief="$(awk '/^### 5\./{f=1} /^### 6\./{f=0} f' "$PIPELINE" | grep '^Workdir:')"
if [ "$(printf '%s\n' "$brief" | grep -c .)" = 1 ] && [[ $brief == *'range: '* ]] && [[ $brief != *'pr:'* ]]; then
  ok "the step 5 brief names a range and no pr:, so Local mode takes the branch as never pushed"
else
  bad "the step 5 brief must name one Workdir: with a range and no pr: (got: $brief)"
fi
early="$(awk '/^### 6\./{exit} /^```/{fence=!fence; next} fence' "$PIPELINE" | grep -E 'git -C [^ ]+ push' || true)"
if [ -z "$early" ]; then
  ok "no push runs before step 6, so the branch is unpushed when Holmes reviews it"
else
  bad "a push runs before step 6: $early"
fi
expect "$PIPELINE" 'If Holmes stops with no verdict' present "step 5 stops at needs_mike when Holmes returns no verdict"
expect "$PIPELINE" 'If the push is denied or fails, stop at `needs_mike`' present "a push that fails stops at needs_mike"
expect "$LOCAL" 'A branch that was never pushed has no head to compare' present "Local mode takes an unpushed branch's HEAD as its head"
pushes="$(grep -oE 'git -C <clone path> push [^`]*' "$PIPELINE" | grep -v ' origin ' || true)"
if [ -z "$pushes" ]; then
  ok "every push in the pipeline goes to origin, whose HEAD ref the clone set"
else
  bad "a push goes to a remote other than origin: $pushes"
fi

added="$(grep -nE 'git -C [^ ]+ remote add' "$PIPELINE" || true)"
if [ -z "$added" ]; then
  ok "the pipeline adds no remote, since gh repo clone of a fork already adds upstream"
else
  bad "the pipeline adds a remote that gh repo clone of a fork already made: $added"
fi
expect "$PIPELINE" 'git -C <clone path> remote get-url upstream' present "the fork route checks the upstream remote gh added"
branches="$(grep -E 'git -C <clone path> checkout .*-b [^ ]+ [^ ]+$' "$PIPELINE" || true)"
untracked="$(printf '%s\n' "$branches" | grep -vc -- '--no-track' || true)"
if [ -n "$branches" ] && [ "$untracked" = 0 ] \
  && printf '%s\n' "$branches" | grep -q 'upstream/<base>$' && printf '%s\n' "$branches" | grep -q 'origin/<headRefName>$'; then
  ok "every branch made from a remote ref, step 3's upstream/<base> and step 7's origin/<headRefName>, takes --no-track"
else
  bad "a branch made from a remote ref lacks --no-track, or one of the two is missing: $branches"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
