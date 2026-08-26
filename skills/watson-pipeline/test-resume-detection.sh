#!/usr/bin/env bash
# Test for Dr. Watson's step-3 resume detection and branch provenance, and for
# the once-per-branch guard on the `HANDS-OFF` comment that follows it.
#
# It extracts the *real* snippets from references/index-mode-pipeline.md (the
# blocks between the `watson-resume-detection` and `watson-handsoff-comment`
# sentinel markers) and runs them against fixture repos served by a stub `gh`,
# so the test can never drift from the shipped logic.
#
# Run: bash skills/watson-pipeline/test-resume-detection.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/references/index-mode-pipeline.md"
SNIPPET=$(mktemp)
SNIPPET2=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -rf "$SNIPPET" "$SNIPPET2" "$WORK"' EXIT

# Pull each snippet out from between its markers (exclusive of the marker lines).
awk '/# >>> watson-resume-detection >>>/{f=1;next} /# <<< watson-resume-detection <<</{f=0} f' \
  "$SRC" > "$SNIPPET"
if [ ! -s "$SNIPPET" ]; then
  echo "FAIL: could not extract watson-resume-detection block from $SRC"; exit 1
fi
awk '/# >>> watson-handsoff-comment >>>/{f=1;next} /# <<< watson-handsoff-comment <<</{f=0} f' \
  "$SRC" > "$SNIPPET2"
if [ ! -s "$SNIPPET2" ]; then
  echo "FAIL: could not extract watson-handsoff-comment block from $SRC"; exit 1
fi

# --- stub `gh` -------------------------------------------------------------
# Serves three calls from $FIXTURE:
#   gh api --paginate repos/<repo>/branches --jq …   -> $FIXTURE/branches
#   gh api repos/<repo>/compare/<base>...<branch> …  -> $FIXTURE/compare/<slug>  (absent => exit 1)
#   gh pr list -R <repo> --head <branch> … --jq …    -> $FIXTURE/pr/<slug>       (absent => no PR)
#   gh api --paginate repos/<repo>/issues/<n>/comments --jq …
#                                                    -> $FIXTURE/comments/<n>   (absent => empty thread)
# A slug is the branch name with `/` replaced by `_`.
# Both paginated endpoints page at 30, so the stub returns only the first 30 records unless
# `--paginate` is passed — that is what makes the flag testable rather than decorative. Comment
# fixtures model one comment per line (a multi-line body simply occupies several lines).
# $FIXTURE/comments-fail makes the comments read error out, standing in for a failed API call.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
slug() { printf '%s' "$1" | tr '/' '_'; }
case "${1:-}" in
  api)
    paginate=0
    for a in "$@"; do [ "$a" = --paginate ] && paginate=1; done
    for a in "$@"; do
      case "$a" in
        */branches)
          if [ "$paginate" = 1 ]; then cat "$FIXTURE/branches" 2>/dev/null
          else head -30 "$FIXTURE/branches" 2>/dev/null; fi
          exit 0 ;;
        */compare/*)
          f="$FIXTURE/compare/$(slug "${a##*...}")"
          [ -f "$f" ] || exit 1        # simulates a compare call that fails / unknown provenance
          cat "$f"; exit 0 ;;
        */comments)
          [ -f "$FIXTURE/comments-fail" ] && exit 1   # simulates a comments read that fails
          n="${a%/comments}"; n="${n##*/}"            # the issue number out of the URL path
          f="$FIXTURE/comments/$n"
          [ -f "$f" ] || exit 0                       # no comments on this issue yet
          if [ "$paginate" = 1 ]; then cat "$f"
          else head -30 "$f"; fi
          exit 0 ;;
      esac
    done
    exit 1 ;;
  pr)
    head=; jqexpr=
    while [ $# -gt 0 ]; do
      case "$1" in
        --head) head=$2; shift ;;
        --jq)   jqexpr=$2; shift ;;
      esac
      shift
    done
    f="$FIXTURE/pr/$(slug "$head")"
    [ -f "$f" ] || exit 0              # no PR for this branch
    read -r num state < "$f"
    case "$jqexpr" in
      *number*) printf '%s\n' "$num" ;;
      *state*)  printf '%s\n' "$state" ;;
    esac
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$WORK/bin/gh"

# --- fixture + assertion helpers ------------------------------------------
pass=0; fail=0
CASE=

# newcase <name> -> makes $WORK/<name> the current fixture repo
newcase() { CASE="$WORK/$1"; mkdir -p "$CASE/compare" "$CASE/pr" "$CASE/comments"; : > "$CASE/branches"; }
# branch <name> -> the repo has this branch
branch() { printf '%s\n' "$1" >> "$CASE/branches"; }
# watson_commits <branch> [subject] -> branch carries Watson's provenance trailer (or a given subject)
watson_commits() {
  local b="$1" issue="${2:-}"
  { echo "chore: some earlier work."
    if [ -n "$issue" ]; then printf '%s\n' "$issue"
    else echo "chore: start work on #$ISSUE"; echo; echo "Watson-Branch: #$ISSUE"; fi
  } > "$CASE/compare/$(printf '%s' "$b" | tr '/' '_')"
}
# human_commits <branch> -> branch carries ordinary human commits, no Watson mark
human_commits() {
  printf '%s\n' "fix: 🐛 Make the locale consistent." "test: ✅ Cover the regression." \
    > "$CASE/compare/$(printf '%s' "$1" | tr '/' '_')"
}
# pr <branch> <number> <STATE>
pr() { printf '%s %s\n' "$2" "$3" > "$CASE/pr/$(printf '%s' "$1" | tr '/' '_')"; }
# comment <issue> <line> [line…] -> appends one comment body to that issue's thread
comment() { local n="$1"; shift; printf '%s\n' "$@" >> "$CASE/comments/$n"; }
# handsoff_comment <issue> <branch> -> the thread already carries Watson's notice for that branch
handsoff_comment() {
  comment "$1" "<!-- watson-hands-off: $2 -->" \
    "Branch \`$2\` is already open against this issue, and I did not create it."
}
# comments_fail -> the comments read errors out
comments_fail() { : > "$CASE/comments-fail"; }
# run -> echoes the verdict line for the current fixture
run() { FIXTURE="$CASE" PATH="$WORK/bin:$PATH" REPO=owner/repo ISSUE="$ISSUE" BASE=main bash "$SNIPPET"; }
# run_comment <branch> -> echoes POST or SKIP for the hands-off comment on that branch
run_comment() { FIXTURE="$CASE" PATH="$WORK/bin:$PATH" REPO=owner/repo ISSUE="$ISSUE" BRANCH="$1" bash "$SNIPPET2"; }
# expect <name> <expected verdict line> <actual>
expect() {
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; pass=$((pass+1))
  else echo "  FAIL — $1: expected '$2' got '$3'"; fail=$((fail+1)); fi
}
tab=$(printf '\t')

echo "Testing Watson resume detection ($SNIPPET):"

# 1. No branch at all -> FRESH.
ISSUE=317; newcase c1
branch main; branch fix/999-unrelated
expect "no branch for the issue -> fresh" "FRESH${tab}-${tab}-" "$(run)"

# 2. Watson's branch, trailer present, no PR yet (crash between push and PR create) -> RESUME.
ISSUE=317; newcase c2
branch chore/317-harden-mutex-poisoning-recovery
watson_commits chore/317-harden-mutex-poisoning-recovery
expect "watson branch, no PR -> resume" \
  "RESUME${tab}chore/317-harden-mutex-poisoning-recovery${tab}-" "$(run)"

# 3. Watson's branch with an OPEN PR -> RESUME, carrying the PR number.
ISSUE=317; newcase c3
branch chore/317-harden-mutex-poisoning-recovery
watson_commits chore/317-harden-mutex-poisoning-recovery
pr chore/317-harden-mutex-poisoning-recovery 401 OPEN
expect "watson branch, open PR -> resume" \
  "RESUME${tab}chore/317-harden-mutex-poisoning-recovery${tab}401" "$(run)"

# 4. Watson's branch whose PR already merged -> DRIFT (repair status, do not redo the work).
ISSUE=317; newcase c4
branch chore/317-harden-mutex-poisoning-recovery
watson_commits chore/317-harden-mutex-poisoning-recovery
pr chore/317-harden-mutex-poisoning-recovery 401 MERGED
expect "watson branch, merged PR -> drift" \
  "DRIFT${tab}chore/317-harden-mutex-poisoning-recovery${tab}401" "$(run)"

# 5. Same, closed unmerged -> DRIFT.
ISSUE=317; newcase c5
branch chore/317-harden-mutex-poisoning-recovery
watson_commits chore/317-harden-mutex-poisoning-recovery
pr chore/317-harden-mutex-poisoning-recovery 401 CLOSED
expect "watson branch, closed PR -> drift" \
  "DRIFT${tab}chore/317-harden-mutex-poisoning-recovery${tab}401" "$(run)"

# 6. Legacy `watson/` prefix with no trailer (pre-provenance branch) -> RESUME on the prefix alone.
ISSUE=83; newcase c6
branch watson/83-something
expect "legacy watson/ prefix, no trailer -> resume" "RESUME${tab}watson/83-something${tab}-" "$(run)"

# 7. Pre-trailer Watson commit subject (branch in flight when provenance shipped) -> RESUME.
ISSUE=400; newcase c7
branch feature/400-in-flight
watson_commits feature/400-in-flight "chore: start work on #400"
expect "pre-trailer watson subject -> resume" "RESUME${tab}feature/400-in-flight${tab}-" "$(run)"

# 8. THE HIJACK BUG (zed-laravel #288 / PR #294): a human's `fix/288-…` branch matched the old
#    pattern and Watson pushed onto their open PR. Must hand off now.
ISSUE=288; newcase c8
branch fix/288-locale-consistency
human_commits fix/288-locale-consistency
pr fix/288-locale-consistency 294 OPEN
expect "human fix/ branch with open PR -> hands off" \
  "HANDS-OFF${tab}fix/288-locale-consistency${tab}294" "$(run)"

# 9. THE DUPLICATE-PR BUG (zed-laravel #292 / PR #300): a human's `ci/…` branch was invisible to the
#    old pattern, so Watson opened PR #307 beside it. Must be seen, and handed off.
ISSUE=292; newcase c9
branch ci/292-os-matrix
human_commits ci/292-os-matrix
pr ci/292-os-matrix 300 MERGED
expect "human ci/ branch (old pattern missed it) -> hands off" \
  "HANDS-OFF${tab}ci/292-os-matrix${tab}300" "$(run)"

# 10. A human branch with no PR yet is still theirs.
ISSUE=288; newcase c10
branch refactor/288-extract-loader
human_commits refactor/288-extract-loader
expect "human branch, no PR -> hands off" "HANDS-OFF${tab}refactor/288-extract-loader${tab}-" "$(run)"

# 11. Watson's branch AND a human's branch on the same issue -> the human wins, whatever the order.
ISSUE=292; newcase c11
branch chore/292-os-matrix-support
watson_commits chore/292-os-matrix-support
pr chore/292-os-matrix-support 307 OPEN
branch ci/292-os-matrix
human_commits ci/292-os-matrix
pr ci/292-os-matrix 300 OPEN
expect "watson branch listed first, human second -> hands off" \
  "HANDS-OFF${tab}ci/292-os-matrix${tab}300" "$(run)"

# 12. Same pair, human listed first -> still hands off (no ordering dependency).
ISSUE=292; newcase c12
branch ci/292-os-matrix
human_commits ci/292-os-matrix
pr ci/292-os-matrix 300 OPEN
branch chore/292-os-matrix-support
watson_commits chore/292-os-matrix-support
pr chore/292-os-matrix-support 307 OPEN
expect "human branch listed first -> hands off" \
  "HANDS-OFF${tab}ci/292-os-matrix${tab}300" "$(run)"

# 13. Provenance undeterminable (the compare call fails) -> fail closed to HANDS-OFF.
ISSUE=288; newcase c13
branch fix/288-locale-consistency        # no compare fixture => stub `gh api compare` exits 1
pr fix/288-locale-consistency 294 OPEN
expect "compare call fails -> hands off (fail closed)" \
  "HANDS-OFF${tab}fix/288-locale-consistency${tab}294" "$(run)"

# 14. A longer issue number must NOT match: `fix/2881-…` is not issue 288.
ISSUE=288; newcase c14
branch fix/2881-different-issue
human_commits fix/2881-different-issue
expect "fix/2881- does not match issue 288 -> fresh" "FRESH${tab}-${tab}-" "$(run)"

# 15. Nor a shorter one: issue 2881 must not adopt `fix/288-…`.
ISSUE=2881; newcase c15
branch fix/288-locale-consistency
human_commits fix/288-locale-consistency
expect "fix/288- does not match issue 2881 -> fresh" "FRESH${tab}-${tab}-" "$(run)"

# 16. A branch with the bare number and no slug still matches (`ci/292`), so no duplicate gets opened.
ISSUE=292; newcase c16
branch ci/292
human_commits ci/292
expect "bare ci/292 (no slug) -> hands off" "HANDS-OFF${tab}ci/292${tab}-" "$(run)"

# 17. Every widened type prefix is detected. The old pattern knew only fix|feature|chore|watson,
#     and each prefix it missed was one duplicate PR waiting to happen.
ISSUE=500
for p in build chore ci docs feat feature fix perf refactor revert style test; do
  newcase "c17-$p"
  branch "$p/500-some-work"
  human_commits "$p/500-some-work"
  expect "$p/ prefix detected -> hands off" "HANDS-OFF${tab}$p/500-some-work${tab}-" "$(run)"
done

# 18. An unknown prefix is NOT matched — the list is deliberate, not a wildcard.
ISSUE=500; newcase c18
branch wip/500-some-work
human_commits wip/500-some-work
expect "unknown wip/ prefix -> fresh" "FRESH${tab}-${tab}-" "$(run)"

# 19. A trailer for a DIFFERENT issue does not confer provenance on this one.
ISSUE=288; newcase c19
branch fix/288-locale-consistency
watson_commits fix/288-locale-consistency "Watson-Branch: #999"
pr fix/288-locale-consistency 294 OPEN
expect "trailer for another issue -> hands off" \
  "HANDS-OFF${tab}fix/288-locale-consistency${tab}294" "$(run)"

# 20. A trailer mentioned inside prose, not standing alone on its line, is not the mark.
ISSUE=288; newcase c20
branch fix/288-locale-consistency
watson_commits fix/288-locale-consistency "fix: 🐛 Follow up on Watson-Branch: #288 as discussed."
expect "trailer text inside a subject line -> hands off" \
  "HANDS-OFF${tab}fix/288-locale-consistency${tab}-" "$(run)"

# 21. Two human branches: the FIRST match is reported, so the hands-off comment names a stable
#     branch on every run rather than whichever one the scan happened to end on.
ISSUE=288; newcase c21
branch fix/288-locale-consistency
human_commits fix/288-locale-consistency
pr fix/288-locale-consistency 294 OPEN
branch test/288-locale-coverage
human_commits test/288-locale-coverage
pr test/288-locale-coverage 295 OPEN
expect "two human branches -> reports the first, deterministically" \
  "HANDS-OFF${tab}fix/288-locale-consistency${tab}294" "$(run)"

# 22. The branches endpoint pages at 30. A match on page 2 must still be found: without
#     `--paginate` it is invisible, and Watson opens a duplicate PR on a busy repo.
ISSUE=288; newcase c22
for i in $(seq 1 30); do branch "chore/9$i-filler"; done
branch fix/288-locale-consistency
human_commits fix/288-locale-consistency
pr fix/288-locale-consistency 294 OPEN
expect "match past the first branches page -> found, hands off" \
  "HANDS-OFF${tab}fix/288-locale-consistency${tab}294" "$(run)"

# 23. Two of Watson's own branches: the FIRST is resumed, for the same determinism as case 21 —
#     a later branch must not silently redirect the run onto different work.
ISSUE=317; newcase c23
branch chore/317-harden-mutex-poisoning-recovery
watson_commits chore/317-harden-mutex-poisoning-recovery
pr chore/317-harden-mutex-poisoning-recovery 401 MERGED
branch fix/317-second-attempt
watson_commits fix/317-second-attempt
pr fix/317-second-attempt 402 OPEN
expect "two watson branches -> resumes the first, deterministically" \
  "DRIFT${tab}chore/317-harden-mutex-poisoning-recovery${tab}401" "$(run)"

echo
echo "Testing the HANDS-OFF comment guard ($SNIPPET2):"

# 24. An untouched thread -> POST. The first tick that finds a human's branch must speak up.
ISSUE=288; newcase h24
expect "empty thread -> post" "POST" "$(run_comment fix/288-locale-consistency)"

# 25. A thread with ordinary conversation but no marker -> POST.
ISSUE=288; newcase h25
comment 288 "I picked this one up — going with the loader rewrite."
comment 288 "Sounds right, ship it."
expect "thread without a marker -> post" "POST" "$(run_comment fix/288-locale-consistency)"

# 26. THE COMMENT-SPAM BUG: the notice for this branch is already on the issue, so every later
#     tick (one every 20 minutes for the whole life of the human's PR) must stay silent.
ISSUE=288; newcase h26
handsoff_comment 288 fix/288-locale-consistency
expect "notice already posted for this branch -> skip" "SKIP" "$(run_comment fix/288-locale-consistency)"

# 27. The marker is keyed on the BRANCH: a second person's branch on the same issue is a situation
#     Watson has not reported yet, so it earns its own comment rather than being swallowed.
ISSUE=288; newcase h27
handsoff_comment 288 fix/288-locale-consistency
expect "marker for a different branch -> post" "POST" "$(run_comment test/288-locale-coverage)"

# 28. Both markers present -> silent again for the branch already reported.
ISSUE=288; newcase h28
handsoff_comment 288 fix/288-locale-consistency
handsoff_comment 288 test/288-locale-coverage
expect "marker among several -> skip" "SKIP" "$(run_comment test/288-locale-coverage)"

# 29. The PR number is deliberately NOT part of the key. A branch is pushed before its PR exists,
#     so the tick that first sees the branch posts, and the tick after the PR opens must not post
#     the same notice about the same work again.
ISSUE=288; newcase h29
handsoff_comment 288 fix/288-locale-consistency        # posted when the branch had no PR yet
pr fix/288-locale-consistency 294 OPEN                 # the human opened their PR since
expect "PR opened since the notice -> still skip" "SKIP" "$(run_comment fix/288-locale-consistency)"

# 30. A branch name is not a regular expression. `fix/288-v1.2` must not be silenced by a marker
#     left for `fix/288-v1x2` — that is grep -F, and grep -E would swallow the new branch.
ISSUE=288; newcase h30
handsoff_comment 288 fix/288-v1x2
expect "metacharacter must not match another branch -> post" "POST" "$(run_comment fix/288-v1.2)"

# 31. The marker is scoped to this item by living on its thread: an identical marker on a
#     different issue must not silence this one.
ISSUE=288; newcase h31
handsoff_comment 999 fix/288-locale-consistency
expect "same marker on another issue -> post" "POST" "$(run_comment fix/288-locale-consistency)"

# 32. The comments endpoint pages at 30. On a long thread the marker sits past page one; without
#     `--paginate` it is invisible and the spam starts over.
ISSUE=288; newcase h32
for i in $(seq 1 30); do comment 288 "Chiming in ($i)."; done   # a full page of conversation…
handsoff_comment 288 fix/288-locale-consistency                 # …and the marker only after it
expect "marker past the first comments page -> skip" "SKIP" "$(run_comment fix/288-locale-consistency)"

# 33. A failed read posts. This path does NOT fail closed, deliberately: a duplicate notice costs
#     one comment, a suppressed one costs the human their only warning.
ISSUE=288; newcase h33
handsoff_comment 288 fix/288-locale-consistency
comments_fail
expect "comments read fails -> post anyway" "POST" "$(run_comment fix/288-locale-consistency)"

echo
echo "resume-detection + hands-off comment: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
