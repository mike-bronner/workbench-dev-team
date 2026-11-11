#!/usr/bin/env bash
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }

mkdir -p "$WORK/bin" "$WORK/gh"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH/calls"
jqf=
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
key="${args[0]}-${args[1]}"
case "$key" in
  repo-clone) [ -e "$FAKE_GH/clone-fails" ] && exit 1; mkdir -p "${args[3]}"; exit 0 ;;
  pr-checkout) [ -e "$FAKE_GH/checkout-fails" ] && exit 1; pwd > "$FAKE_GH/checked-out-in"; exit 0 ;;
  api-*)
    key=api
    for a in "${args[@]:1}"; do
      case "$a" in
        -*) ;;
        *) p="api_$(printf '%s' "${a%%\?*}" | tr '/' '_')"
           { [ -e "$FAKE_GH/$p.json" ] || [ -e "$FAKE_GH/$p.404" ] || [ -e "$FAKE_GH/$p.fail" ]; } && key=$p
           break ;;
      esac
    done ;;
esac
[ -e "$FAKE_GH/$key.fail" ] && exit 1
[ -e "$FAKE_GH/$key.404" ] && { echo '{"message":"Not Found","status":"404"}'; exit 1; }
json=$(cat "$FAKE_GH/$key.json" 2>/dev/null || echo '{}')
if [ -n "$jqf" ]; then jq -r "$jqf" <<< "$json"; else printf '%s\n' "$json"; fi
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" FAKE_GH="$WORK/gh"

fake() { printf '%s' "$2" > "$FAKE_GH/$1.json"; }
apikey() { printf 'api_%s' "$(printf '%s' "$1" | tr '/' '_')"; }
fake_api() { fake "$(apikey "$1")" "$2"; }
missing_api() { touch "$FAKE_GH/$(apikey "$1").404"; }
failing_api() { touch "$FAKE_GH/$(apikey "$1").fail"; }
codeowners_file() { jq -cn --arg t "$1" '{type: "file", content: ($t | @base64 | .[0:8] + "\n" + .[8:])}'; }
reset() { rm -rf "$FAKE_GH"; mkdir -p "$FAKE_GH"; }

echo "── holmes-find-pr.sh ────────────────────────────────────────────────────"
reset
fake issue-view '{"closedByPullRequestsReferences":[{"number":7},{"number":9}]}'
fake pr-list '[{"number":420,"headRefName":"feat/420-x"}]'
expect "the newest linked PR wins" "$(bash "$HERE/holmes-find-pr.sh" o/r 42)" 9
reset
fake issue-view '{"closedByPullRequestsReferences":[]}'
fake pr-list '[{"number":420,"headRefName":"feat/420-other"},{"number":8,"headRefName":"fix/42-thing"}]'
expect "with no link, Watson's branch for #42 is found and #420's is not" "$(bash "$HERE/holmes-find-pr.sh" o/r 42)" 8
reset
fake issue-view '{"closedByPullRequestsReferences":[]}'
fake pr-list '[{"number":420,"headRefName":"feat/420-other"},{"number":5,"headRefName":"feat/x-42"}]'
out=$(bash "$HERE/holmes-find-pr.sh" o/r 42); rc=$?
expect "#420 and a branch that only mentions 42 resolve to no PR" "$rc:$out" "1:"
bash "$HERE/holmes-find-pr.sh" 'o/r;x' 42 >/dev/null 2>&1
expect "a malformed repo is refused" "$?" 2
reset; touch "$FAKE_GH/issue-view.fail"
bash "$HERE/holmes-find-pr.sh" o/r 42 >/dev/null 2>&1
expect "a failed gh call exits 2, not 'no PR'" "$?" 2

echo "── holmes-strike-count.sh ───────────────────────────────────────────────"
review() { printf '{"user":%s,"state":"%s","submitted_at":"%s"}' "$1" "$2" "$3"; }
holmes='{"login":"mr-sherlock-holmes[bot]","type":"Bot"}'
reset
fake pr-view '{"comments":[],"reviews":[]}'
fake api '[]'
fake_api repos/o/r/pulls/3/reviews "[$(review "$holmes" CHANGES_REQUESTED 2026-01-01T00:00:00Z),
  $(review '{"login":"coderabbitai[bot]","type":"Bot"}' CHANGES_REQUESTED 2026-01-01T01:00:00Z),
  $(review '{"login":"mr-sherlock-holmes","type":"User"}' CHANGES_REQUESTED 2026-01-01T02:00:00Z),
  $(review '{"login":"Mr-Sherlock-Holmes[bot]","type":"Bot"}' CHANGES_REQUESTED 2026-01-01T02:30:00Z)]
[$(review '{"login":"mr-sherlock-holmes[bot]","type":"User"}' CHANGES_REQUESTED 2026-01-01T03:00:00Z),
  $(review '{"login":"stranger","type":"User"}' CHANGES_REQUESTED 2026-01-01T04:00:00Z),
  $(review "$holmes" COMMENTED 2026-01-01T05:00:00Z),
  $(review "$holmes" CHANGES_REQUESTED 2026-01-02T00:00:00Z)]"
expect "only the Holmes App's change-requests count, as a Bot with its exact login, on every page" \
  "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 2
expect "the reviews are read on every page of the REST endpoint" \
  "$(grep -c '^api --paginate repos/o/r/pulls/3/reviews?per_page=100$' "$FAKE_GH/calls")" 1
fake pr-view '{"comments":[{"author":{"login":"mikebronner"},"createdAt":"2026-01-01T12:00:00Z"}],"reviews":[]}'
expect "a conversation comment from Mike resets the window" "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 1
fake pr-view '{"comments":[],"reviews":[{"author":{"login":"mikebronner"},"submittedAt":"2026-01-01T12:00:00Z"}]}'
expect "a review from Mike resets the window" "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 1
fake pr-view '{"comments":[],"reviews":[]}'
fake api '[{"user":{"login":"mikebronner"},"created_at":"2026-01-04T00:00:00Z"}]'
expect "an inline review comment from Mike resets the window too" "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 0
fake api '[{"user":{"login":"stranger"},"created_at":"2026-01-01T12:00:00Z"}]
[{"user":{"login":"mikebronner"},"created_at":"2026-01-04T00:00:00Z"}]'
expect "an inline comment from Mike on a later page resets the window" "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 0
expect "the inline comments are read on every page of the REST endpoint" \
  "$(grep 'pulls/3/comments' "$FAKE_GH/calls" | sort -u)" 'api --paginate repos/o/r/pulls/3/comments?per_page=100'
fake api '[]
{"message":"Not Found"}'
bash "$HERE/holmes-strike-count.sh" o/r 3 >/dev/null 2>&1
expect "an inline-comment page that is not a comment list exits 2" "$?" 2
touch "$FAKE_GH/api.fail"
bash "$HERE/holmes-strike-count.sh" o/r 3 >/dev/null 2>&1
expect "a failed inline-comment read exits 2" "$?" 2
rm "$FAKE_GH/api.fail"
fake_api repos/o/r/pulls/3/reviews '{"message":"Not Found"}'
bash "$HERE/holmes-strike-count.sh" o/r 3 >/dev/null 2>&1
expect "a review page that is not a review list exits 2" "$?" 2
failing_api repos/o/r/pulls/3/reviews
bash "$HERE/holmes-strike-count.sh" o/r 3 >/dev/null 2>&1
expect "a failed review read exits 2" "$?" 2

echo "── holmes-decision-request.sh ───────────────────────────────────────────"
reset
ask() { printf '[{"user":%s,"created_at":"2026-01-01T00:00:00Z","body":"%s"}]' "$1" "${2:-<!-- watson-blocked: tactical -->\nQ}"; }
fake pr-view '{"additions":1,"deletions":2}'
fake api "$(ask '{"login":"dr-john-h-watson[bot]","type":"Bot"}')"
expect "a Watson App marker and under 5 changed lines is a decision request" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" decision-request
expect "every page of the PR's REST comments is requested" \
  "$(grep -c '^api --paginate repos/o/r/issues/3/comments?per_page=100$' "$FAKE_GH/calls")" 1
for user in '{"login":"dr-john-h-watson","type":"User"}' '{"login":"dr-john-h-watson[bot]","type":"User"}' \
  '{"login":"mikebronner","type":"User"}' '{"login":"mr-sherlock-holmes[bot]","type":"Bot"}' \
  '{"login":"dr-john-h-watson-fake[bot]","type":"Bot"}' '{"login":"dr-john-h-watson[bot]"}' null; do
  fake api "$(ask "$user")"
  expect "a marker by $user on a small PR is a review" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" review
done
fake api "$(ask '{"login":"dr-john-h-watson[bot]","type":"Bot"}' 'Q\n<!-- watson-blocked: tactical -->')"
expect "a Watson App comment that does not start with the marker is a review" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" review
fake pr-view '{"additions":4,"deletions":1}'
fake api "$(ask '{"login":"dr-john-h-watson[bot]","type":"Bot"}')"
expect "5 changed lines is a review" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" review
fake pr-view '{"additions":0,"deletions":0}'
fake api "$(ask '{"login":"dr-john-h-watson[bot]","type":"Bot"}' 'no marker')"
expect "no marker is a review" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" review
touch "$FAKE_GH/api.fail"
bash "$HERE/holmes-decision-request.sh" o/r 3 >/dev/null 2>&1
expect "a failed comment read exits 2" "$?" 2
reset
touch "$FAKE_GH/pr-view.fail"
fake api "$(ask '{"login":"dr-john-h-watson[bot]","type":"Bot"}')"
bash "$HERE/holmes-decision-request.sh" o/r 3 >/dev/null 2>&1
expect "a failed PR read exits 2" "$?" 2

echo "── app-comments.sh ──────────────────────────────────────────────────────"
reset
fake api '[{"user":{"login":"dr-john-h-watson[bot]","type":"Bot"},"created_at":"2026-01-01T00:00:00Z","body":"<!-- m --> one"},
  {"user":{"login":"mr-sherlock-holmes[bot]","type":"Bot"},"created_at":"2026-01-02T00:00:00Z","body":"<!-- m --> holmes"},
  {"user":{"login":"dr-john-h-watson[bot]","type":"Bot"},"created_at":"2026-01-02T12:00:00Z","body":"unmarked"},
  {"user":{"login":"dr-john-h-watson[bot]","type":"Bot"},"created_at":"2026-01-02T18:00:00Z","body":"quotes <!-- m --> later"},
  {"user":{"login":"Dr-John-H-Watson[bot]","type":"Bot"},"created_at":"2026-01-02T20:00:00Z","body":"<!-- m --> another case"}]
[{"user":{"login":"dr-john-h-watson","type":"User"},"created_at":"2026-01-03T00:00:00Z","body":"<!-- m --> user"},
  {"user":{"login":"dr-john-h-watson[bot]","type":"Bot"},"created_at":"2026-01-04T00:00:00Z","body":"<!-- m --> two"}]'
expect "only the named App's comments that start with the marker are kept, from every page, oldest first" \
  "$(bash "$HERE/app-comments.sh" o/r 5 '<!-- m -->' dr-john-h-watson | jq -c 'map(.body)')" '["<!-- m --> one","<!-- m --> two"]'
expect "every page of the issue's REST comments is requested" \
  "$(grep -c '^api --paginate repos/o/r/issues/5/comments?per_page=100$' "$FAKE_GH/calls")" 1
bash "$HERE/app-comments.sh" o/r 5 '<!-- m -->' >/dev/null 2>&1
expect "no App named is refused" "$?" 2
bash "$HERE/app-comments.sh" o/r 5 '' dr-john-h-watson >/dev/null 2>&1
expect "an empty marker is refused" "$?" 2
fake api '{"message":"Not Found"}'
bash "$HERE/app-comments.sh" o/r 5 '<!-- m -->' dr-john-h-watson >/dev/null 2>&1
expect "a page that is not a comment list exits 2" "$?" 2
touch "$FAKE_GH/api.fail"
bash "$HERE/app-comments.sh" o/r 5 '<!-- m -->' dr-john-h-watson >/dev/null 2>&1
expect "a failed comment read exits 2" "$?" 2

echo "── trusted-comments.sh ──────────────────────────────────────────────────"
no_codeowners() { for f in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do missing_api "repos/o/r/contents/$f"; done; }
opened_by() { fake_api repos/o/r/issues/7 "$1"; }
authors() { bash "$HERE/trusted-comments.sh" o/r 7 "$@" | jq -c 'map(.body)'; }
mixed='[{"user":{"login":"mikebronner","type":"User"},"created_at":"2026-01-01T00:00:00Z","body":"mike"},
  {"user":{"login":"MikeBronner","type":"User"},"created_at":"2026-01-01T01:00:00Z","body":"mike in another case"},
  {"user":{"login":"mikebronner","type":"Bot"},"created_at":"2026-01-01T02:00:00Z","body":"mike as a bot"},
  {"user":{"login":"mr-sherlock-holmes[bot]","type":"Bot"},"created_at":"2026-01-01T03:00:00Z","body":"holmes"},
  {"user":{"login":"mr-sherlock-holmes[bot]","type":"User"},"created_at":"2026-01-01T04:00:00Z","body":"holmes as a user"},
  {"user":{"login":"Mr-Sherlock-Holmes[bot]","type":"Bot"},"created_at":"2026-01-01T04:30:00Z","body":"holmes in another case"},
  {"user":{"login":"dr-john-h-watson[bot]","type":"Bot"},"created_at":"2026-01-01T05:00:00Z","body":"watson"}]
[{"user":{"login":"alice","type":"User"},"created_at":"2026-01-02T00:00:00Z","body":"alice"},
  {"user":{"login":"Bob-B","type":"User"},"created_at":"2026-01-02T01:00:00Z","body":"bob"},
  {"user":{"login":"dave","type":"User"},"created_at":"2026-01-02T02:00:00Z","body":"dave"},
  {"user":{"login":"alice","type":"Bot"},"created_at":"2026-01-02T03:00:00Z","body":"alice as a bot"},
  {"user":{"login":"mallory","type":"User"},"created_at":"2026-01-02T04:00:00Z","body":"mallory"},
  {"user":{"login":"eve","type":"User"},"created_at":"2026-01-02T05:00:00Z","body":"eve"},
  {"user":{"login":"carol","type":"User"},"created_at":"2026-01-02T06:00:00Z","body":"carol"},
  {"user":null,"body":"ghost"},{"body":"no author"}]'
reset
opened_by '{"user":{"login":"frank","type":"User"}}'
no_codeowners
fake api "$mixed"
expect "with no CODEOWNERS and no App named, only mikebronner as a User counts" "$(authors)" '["mike"]'
expect "a named App counts only as a Bot with its exact login, on every page" "$(authors mr-sherlock-holmes)" '["mike","holmes"]'
expect "the default branch's CODEOWNERS is read at all three places, with no ref, in GitHub's order" \
  "$(grep '^api repos/o/r/contents/' "$FAKE_GH/calls" | sort -u | tr '\n' ' ')" \
  "api repos/o/r/contents/.github/CODEOWNERS api repos/o/r/contents/CODEOWNERS api repos/o/r/contents/docs/CODEOWNERS "
expect "no read names a PR branch or a ref" "$(grep -c 'ref=\|pulls' "$FAKE_GH/calls")" 0
reset
opened_by '{"user":{"login":"frank","type":"User"}}'
no_codeowners
fake api '[{"user":{"login":"pr-author","type":"User"},"created_at":"2026-01-01T00:00:00Z","body":"pr author"}]'
expect "a User who is not mikebronner, not the issue's author and not in a default-branch CODEOWNERS counts for nothing" "$(authors)" '[]'
reset
no_codeowners
opened_by '{"user":{"login":"alice","type":"User"}}'
fake api "$mixed
[{\"user\":{\"login\":\"Alice\",\"type\":\"User\"},\"created_at\":\"2026-01-03T00:00:00Z\",\"body\":\"alice in another case\"}]"
expect "the issue's author counts as a User with that exact login, and another User on the same issue does not" "$(authors)" '["mike","alice"]'
expect "the issue is read once, from the REST API" "$(grep -c '^api repos/o/r/issues/7$' "$FAKE_GH/calls")" 1
expect "with --no-issue-author, the issue's author counts for nothing" "$(authors --no-issue-author)" '["mike"]'
expect "with --no-issue-author, the issue is not read again" "$(grep -c '^api repos/o/r/issues/7$' "$FAKE_GH/calls")" 1
expect "--no-issue-author leaves the named Apps trusted" "$(authors --no-issue-author mr-sherlock-holmes)" '["mike","holmes"]'
bash "$HERE/trusted-comments.sh" o/r 7 --no-issue-autor >/dev/null 2>&1
expect "a misspelled flag exits 2 rather than read as an App" "$?" 2
bash "$HERE/trusted-comments.sh" o/r 7 mr-sherlock-holmes --no-issue-author >/dev/null 2>&1
expect "--no-issue-author after an App slug exits 2" "$?" 2
opened_by '{"user":{"login":"alice","type":"Bot"}}'
expect "an issue a Bot opened grants its author nothing" "$(authors)" '["mike"]'
opened_by '{"user":{"login":"alice","type":"User"},"pull_request":{"url":"x"}}'
expect "a PR's author is not trusted as an issue's author" "$(authors)" '["mike"]'
opened_by '{"user":null}'
expect "an issue with no author grants nothing" "$(authors)" '["mike"]'
opened_by '[]'
bash "$HERE/trusted-comments.sh" o/r 7 >/dev/null 2>&1
expect "an issue read that is not an issue exits 2" "$?" 2
failing_api repos/o/r/issues/7
bash "$HERE/trusted-comments.sh" o/r 7 >/dev/null 2>&1
expect "a failed issue read exits 2" "$?" 2
reset
opened_by '{"user":{"login":"frank","type":"User"}}'
fake_api repos/o/r/contents/.github/CODEOWNERS "$(codeowners_file '# @eve owns nothing
* @alice @Org/Core # @mallory
docs/ @bob-b carol@example.com
/build/')"
fake_api orgs/org/teams/core/members '[{"login":"Dave"}]'
fake api "$mixed"
expect "user and team code owners count as Users, any case, and comments and emails grant nothing" \
  "$(authors)" '["mike","alice","bob","dave"]'
expect "the team's members are read on every page" \
  "$(grep -c '^api --paginate orgs/org/teams/core/members?per_page=100 ' "$FAKE_GH/calls")" 1
expect "the first CODEOWNERS found is the only one read" "$(grep -c 'contents/CODEOWNERS\|contents/docs/' "$FAKE_GH/calls")" 0
failing_api orgs/org/teams/core/members
expect "a team whose members cannot be read counts for nobody" "$(authors 2>/dev/null)" '["mike","alice","bob"]'
reset
opened_by '{"user":{"login":"frank","type":"User"}}'
missing_api repos/o/r/contents/.github/CODEOWNERS
fake_api repos/o/r/contents/CODEOWNERS "$(codeowners_file '* @alice')"
fake_api repos/o/r/contents/docs/CODEOWNERS "$(codeowners_file '* @mallory')"
fake api "$mixed"
expect "the root CODEOWNERS wins over docs/" "$(authors)" '["mike","alice"]'
opened_by '{"user":{"login":"alice","type":"User"}}'
expect "with --no-issue-author, an issue author who is a code owner still counts" "$(authors --no-issue-author)" '["mike","alice"]'
reset
opened_by '{"user":{"login":"frank","type":"User"}}'
failing_api repos/o/r/contents/.github/CODEOWNERS
fake api "$mixed"
bash "$HERE/trusted-comments.sh" o/r 7 >/dev/null 2>&1
expect "a CODEOWNERS read that fails other than Not Found exits 2" "$?" 2
reset
opened_by '{"user":{"login":"frank","type":"User"}}'
fake_api repos/o/r/contents/.github/CODEOWNERS '[{"type":"file"}]'
fake api "$mixed"
bash "$HERE/trusted-comments.sh" o/r 7 >/dev/null 2>&1
expect "a CODEOWNERS path that is not a file exits 2" "$?" 2
reset
opened_by '{"user":{"login":"frank","type":"User"}}'
no_codeowners
fake api '{"message":"Not Found"}'
bash "$HERE/trusted-comments.sh" o/r 7 >/dev/null 2>&1
expect "a page that is not a comment list exits 2" "$?" 2
touch "$FAKE_GH/api.fail"
bash "$HERE/trusted-comments.sh" o/r 7 >/dev/null 2>&1
expect "a failed comment read exits 2" "$?" 2
bash "$HERE/trusted-comments.sh" 'o/r;x' 7 >/dev/null 2>&1
expect "a malformed repo is refused" "$?" 2

echo "── holmes-read-ac.sh ────────────────────────────────────────────────────"
reset
fake issue-view '{"body":"## Acceptance Criteria\n- [ ] from body"}'
fake api '[{"user":{"login":"inspector-g-lestrade[bot]","type":"Bot"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] old"}]
[{"user":{"login":"inspector-g-lestrade[bot]","type":"Bot"},"body":"mentions <!-- acceptance-criteria --> later"},
  {"user":{"login":"inspector-g-lestrade[bot]","type":"Bot"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] newest"}]'
expect "the newest marked comment on any page wins, marker stripped, body ignored" "$(bash "$HERE/holmes-read-ac.sh" o/r 1)" "## Acceptance Criteria
- [ ] newest"
for login in inspector-g-lestrade mr-sherlock-holmes dr-john-h-watson; do
  fake api '[{"user":{"login":"'"$login"'[bot]","type":"Bot"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] by '"$login"'"}]'
  expect "a marked comment by the $login App is read" "$(bash "$HERE/holmes-read-ac.sh" o/r 1)" "## Acceptance Criteria
- [ ] by $login"
done
fake api '[{"user":{"login":"dr-john-h-watson[bot]","type":"Bot"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] trusted"},
  {"user":{"login":"inspector-g-lestrade","type":"User"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] user with a trusted login"},
  {"user":{"login":"Inspector-G-Lestrade[bot]","type":"Bot"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] other case"},
  {"user":{"login":"mr-sherlock-holmes[bot]","type":"User"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] bot login on a user"},
  {"user":{"login":"inspector-g-lestrade-fake[bot]","type":"Bot"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] lookalike App"},
  {"user":{"login":"someone-else","type":"User"},"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] forged"},
  {"user":null,"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] ghost"},
  {"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] no author"}]'
expect "newer marked comments not by a dev-team App are ignored, the older App comment is read" "$(bash "$HERE/holmes-read-ac.sh" o/r 1)" "## Acceptance Criteria
- [ ] trusted"
fake issue-view '{"body":"Intro\n## Acceptance Criteria\n- [ ] from body\n## Notes\nnot AC"}'
for user in '{"login":"inspector-g-lestrade","type":"User"}' '{"login":"mr-sherlock-holmes[bot]","type":"User"}' \
  '{"login":"DR-JOHN-H-WATSON[bot]","type":"Bot"}' '{"login":"inspector-g-lestrade-fake[bot]","type":"Bot"}' \
  '{"login":"mr-sherlock-holmes[bot]"}' '{"login":"someone-else","type":"User"}' null; do
  fake api '[{"user":'"$user"',"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] untrusted"}]'
  expect "a marked comment by $user alone is ignored, and the body section is read" "$(bash "$HERE/holmes-read-ac.sh" o/r 1)" "## Acceptance Criteria
- [ ] from body"
done
fake issue-view '{"body":"Intro\n## Acceptance Criteria\n- [ ] from body\n### sub\n- [ ] kept\n## Notes\nnot AC"}'
fake api '[{"user":{"login":"inspector-g-lestrade[bot]","type":"Bot"},"body":"x <!-- acceptance-criteria -->"}]'
expect "with no marked comment, the body section is read up to the next section" "$(bash "$HERE/holmes-read-ac.sh" o/r 1)" "## Acceptance Criteria
- [ ] from body
### sub
- [ ] kept"
fake issue-view '{"body":"no criteria"}'
fake api '[]'
bash "$HERE/holmes-read-ac.sh" o/r 1 >/dev/null 2>&1
expect "no criteria anywhere exits 1" "$?" 1
touch "$FAKE_GH/api.fail"
bash "$HERE/holmes-read-ac.sh" o/r 1 >/dev/null 2>&1
expect "a failed comment read exits 2, not a fallback to the body" "$?" 2
reset
touch "$FAKE_GH/issue-view.fail"
fake api '[]'
bash "$HERE/holmes-read-ac.sh" o/r 1 >/dev/null 2>&1
expect "a failed issue read exits 2" "$?" 2

echo "── holmes-checkout.sh ───────────────────────────────────────────────────"
reset
export HOME="$WORK/home"
ROOT="$WORK/home/Developer/scratchpad"
mkdir -p "$ROOT" "$WORK/elsewhere/holmes.ab-c12" "$WORK/elsewhere/holmes.abc123" "$ROOT/holmes.ab-c12" "$ROOT/notmine"
dir=$(bash "$HERE/holmes-checkout.sh" open o/r 12 "$ROOT" 2>/dev/null)
case "$dir" in "$ROOT/holmes."??????) ok "open makes a holmes.XXXXXX folder under the scratch root" ;; *) bad "open printed '$dir'" ;; esac
expect "the PR is checked out inside that folder" "$(cd "$(cat "$FAKE_GH/checked-out-in" 2>/dev/null)" 2>/dev/null && pwd -P)" "$(cd "$dir" 2>/dev/null && pwd -P)"
bash "$HERE/holmes-checkout.sh" close "$dir"
expect "close removes it" "$([ -e "$dir" ] && echo left || echo gone)" gone
for target in "$ROOT/notmine" "$ROOT/holmes.ab-c12" "$WORK/elsewhere/holmes.ab-c12" "$WORK/elsewhere/holmes.abc123"; do
  bash "$HERE/holmes-checkout.sh" close "$target" 2>/dev/null
  expect "close refuses ${target#"$WORK"/} and keeps it" "$?:$([ -d "$target" ] && echo kept)" "2:kept"
done
out=$(bash "$HERE/holmes-checkout.sh" open o/r 12 "$WORK/elsewhere" 2>/dev/null); rc=$?
expect "open refuses a root that is not a scratch root, and makes nothing" "$rc:$out:$(find "$WORK/elsewhere" -maxdepth 1 -name 'holmes.??????' | wc -l | tr -d ' ')" "2::2"
touch "$FAKE_GH/checkout-fails"
out=$(bash "$HERE/holmes-checkout.sh" open o/r 12 "$ROOT" 2>/dev/null); rc=$?
expect "a failed checkout exits 1, prints nothing and leaves no folder" "$rc:$out:$(find "$ROOT" -maxdepth 1 -name 'holmes.??????' | wc -l | tr -d ' ')" "1::1"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
