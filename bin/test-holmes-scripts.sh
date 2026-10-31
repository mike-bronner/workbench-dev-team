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
  api-*) key=api ;;
esac
[ -e "$FAKE_GH/$key.fail" ] && exit 1
json=$(cat "$FAKE_GH/$key.json" 2>/dev/null || echo '{}')
if [ -n "$jqf" ]; then jq -r "$jqf" <<< "$json"; else printf '%s\n' "$json"; fi
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" FAKE_GH="$WORK/gh"

fake() { printf '%s' "$2" > "$FAKE_GH/$1.json"; }
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
reset
fake pr-view '{"comments":[],"reviews":[
  {"author":{"login":"holmes[bot]"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01T00:00:00Z"},
  {"author":{"login":"holmes[bot]"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-02T00:00:00Z"},
  {"author":{"login":"holmes[bot]"},"state":"COMMENTED","submittedAt":"2026-01-03T00:00:00Z"}]}'
fake api '[]'
expect "with no input from Mike, every change-request counts" "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 2
fake pr-view '{"comments":[{"author":{"login":"mikebronner"},"createdAt":"2026-01-02T12:00:00Z"}],"reviews":[
  {"author":{"login":"holmes[bot]"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01T00:00:00Z"},
  {"author":{"login":"holmes[bot]"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-03T00:00:00Z"}]}'
expect "a conversation comment from Mike resets the window" "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 1
fake pr-view '{"comments":[],"reviews":[
  {"author":{"login":"holmes[bot]"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01T00:00:00Z"},
  {"author":{"login":"holmes[bot]"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-03T00:00:00Z"}]}'
fake api '[{"user":{"login":"mikebronner"},"created_at":"2026-01-04T00:00:00Z"}]'
expect "an inline review comment from Mike resets the window too" "$(bash "$HERE/holmes-strike-count.sh" o/r 3)" 0
touch "$FAKE_GH/api.fail"
bash "$HERE/holmes-strike-count.sh" o/r 3 >/dev/null 2>&1
expect "a failed inline-comment read exits 2" "$?" 2

echo "── holmes-decision-request.sh ───────────────────────────────────────────"
reset
fake pr-view '{"additions":1,"deletions":2,"comments":[{"body":"Q\n<!-- watson-blocked: tactical -->"}]}'
expect "a marker and under 5 changed lines is a decision request" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" decision-request
fake pr-view '{"additions":4,"deletions":1,"comments":[{"body":"<!-- watson-blocked: tactical -->"}]}'
expect "5 changed lines is a review" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" review
fake pr-view '{"additions":0,"deletions":0,"comments":[{"body":"no marker"}]}'
expect "no marker is a review" "$(bash "$HERE/holmes-decision-request.sh" o/r 3)" review

echo "── holmes-read-ac.sh ────────────────────────────────────────────────────"
reset
fake issue-view '{"body":"## Acceptance Criteria\n- [ ] from body","comments":[
  {"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] old"},
  {"body":"mentions <!-- acceptance-criteria --> later"},
  {"body":"<!-- acceptance-criteria -->\n## Acceptance Criteria\n- [ ] newest"}]}'
expect "the newest marked comment wins, marker stripped, body ignored" "$(bash "$HERE/holmes-read-ac.sh" o/r 1)" "## Acceptance Criteria
- [ ] newest"
fake issue-view '{"body":"Intro\n## Acceptance Criteria\n- [ ] from body\n### sub\n- [ ] kept\n## Notes\nnot AC","comments":[{"body":"x <!-- acceptance-criteria -->"}]}'
expect "with no marked comment, the body section is read up to the next section" "$(bash "$HERE/holmes-read-ac.sh" o/r 1)" "## Acceptance Criteria
- [ ] from body
### sub
- [ ] kept"
fake issue-view '{"body":"no criteria","comments":[]}'
bash "$HERE/holmes-read-ac.sh" o/r 1 >/dev/null 2>&1
expect "no criteria anywhere exits 1" "$?" 1

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
