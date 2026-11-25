#!/usr/bin/env bash
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }

RESULT="$WORK/logs/watson-acme+shop+5-20260101T000000.result.json"
mkdir -p "$WORK/logs"
CLAIM="$WORK/logs/watson-acme+shop+5-20260101T000000.result.claim"
running() { rmdir "$CLAIM" 2>/dev/null; printf '%s\n' '{"state":"running","prUrl":null,"review":null,"error":null}' > "$RESULT"; }
result() { env -u CLAUDE_CODE_AGENT WORKBENCH_DEV_TEAM_EXTERNAL=1 WORKBENCH_DEV_TEAM_RESULT="$RESULT" bash "$HERE/external-result.sh" "$@"; }
leftovers() { find "$WORK/logs" -name '*.result.json.*' | wc -l | tr -d ' '; }

echo "── external-result.sh ───────────────────────────────────────────────────"
running
result draft_pr https://github.com/acme/shop.js/pull/12
expect "draft_pr exits 0" "$?" 0
expect "...and writes the state and the PR URL, with no review and no error" "$(jq -c . "$RESULT")" \
  '{"state":"draft_pr","prUrl":"https://github.com/acme/shop.js/pull/12","review":null,"error":null}'
expect "...and leaves no temporary file" "$(leftovers)" 0

result needs_mike 'too late' 2>/dev/null
expect "a second final state is refused: exit 2" "$?" 2
expect "...and the first one stands" "$(jq -r .state "$RESULT")" draft_pr
expect "...and the claim the first one took stays beside the result" "$([ -d "$CLAIM" ] && echo claimed)" claimed

running; mkdir "$CLAIM"
out=$(result needs_mike 'the second caller' 2>&1); code=$?
expect "a caller that finds the claim taken while the file still holds running is refused: exit 2" "$code" 2
expect "...says another call claimed the final state" "$(printf '%s' "$out" | grep -c 'already claimed the final state')" 1
expect "...and writes nothing" "$(jq -c . "$RESULT")" '{"state":"running","prUrl":null,"review":null,"error":null}'
running
printf 'x' | result review_drafted 2>/dev/null
expect "a call refused for its arguments takes no claim" "$([ -d "$CLAIM" ] && echo claimed || echo free)" free

running
result needs_mike 'The issue touches stored data.'
expect "needs_mike exits 0" "$?" 0
expect "...and puts the reason in error" "$(jq -c . "$RESULT")" \
  '{"state":"needs_mike","prUrl":null,"review":null,"error":"The issue touches stored data."}'

running
printf '%s' '{"event":"REQUEST_CHANGES","body":"## Issues Found\n- a bug","comments":[{"path":"src/a.php","line":12,"body":"here","side":"RIGHT"}],"extra":1}' | result review_drafted
expect "review_drafted exits 0" "$?" 0
expect "...and keeps only event, body and each comment's path, line and body" "$(jq -c . "$RESULT")" \
  '{"state":"review_drafted","prUrl":null,"review":{"event":"REQUEST_CHANGES","body":"## Issues Found\n- a bug","comments":[{"path":"src/a.php","line":12,"body":"here"}]},"error":null}'
running
printf '%s' '{"event":"APPROVE","body":"## Review Summary"}' | result review_drafted
expect "an APPROVE draft with no comments carries no comments key" "$(jq -c .review "$RESULT")" '{"event":"APPROVE","body":"## Review Summary"}'
running
printf '%s' '{"event":"APPROVE","body":"ok","comments":[]}' | result review_drafted
expect "...and an empty comments list is left out too" "$(jq -c .review "$RESULT")" '{"event":"APPROVE","body":"ok"}'

while IFS='|' read -r label review; do
  running
  printf '%s' "$review" | result review_drafted 2>/dev/null
  expect "a review with $label is refused: exit 2" "$?" 2
  expect "...and the file still holds running" "$(jq -r .state "$RESULT")" running
done <<'CASES'
the event COMMENT|{"event":"COMMENT","body":"x"}
a lowercase event|{"event":"approve","body":"x"}
no event|{"body":"x"}
no body|{"event":"APPROVE"}
a blank body|{"event":"APPROVE","body":"  \n "}
a body that is not text|{"event":"APPROVE","body":3}
comments that are not a list|{"event":"APPROVE","body":"x","comments":{}}
a comment with no path|{"event":"APPROVE","body":"x","comments":[{"line":1,"body":"y"}]}
a comment with line 0|{"event":"APPROVE","body":"x","comments":[{"path":"a","line":0,"body":"y"}]}
a comment with a fractional line|{"event":"APPROVE","body":"x","comments":[{"path":"a","line":1.5,"body":"y"}]}
a comment with a line in quotes|{"event":"APPROVE","body":"x","comments":[{"path":"a","line":"3","body":"y"}]}
a comment with a blank body|{"event":"APPROVE","body":"x","comments":[{"path":"a","line":3,"body":" "}]}
a list, not an object|[{"event":"APPROVE","body":"x"}]
two values|{"event":"APPROVE","body":"x"} {"event":"APPROVE","body":"y"}
text that is not JSON|not json
nothing at all|
CASES

while IFS='|' read -r label args; do
  running
  read -ra argv <<< "$args"
  result ${argv[@]+"${argv[@]}"} </dev/null >/dev/null 2>&1
  expect "$label is refused: exit 2" "$?" 2
  expect "...and the file still holds running" "$(jq -r .state "$RESULT")" running
done <<'CASES'
the state running|running
the state failed|failed
an unknown state|done
no state|
draft_pr with no URL|draft_pr
draft_pr with an issue URL|draft_pr https://github.com/acme/shop/issues/5
draft_pr with a URL on another host|draft_pr https://example.test/acme/shop/pull/5
draft_pr with PR number zero|draft_pr https://github.com/acme/shop/pull/0
draft_pr with a trailing path|draft_pr https://github.com/acme/shop/pull/5/files
draft_pr with two URLs|draft_pr https://github.com/acme/shop/pull/5 https://github.com/acme/shop/pull/6
needs_mike with no reason|needs_mike
review_drafted with an argument|review_drafted APPROVE
CASES
running
result needs_mike '   ' 2>/dev/null
expect "needs_mike with a blank reason is refused: exit 2" "$?" 2

running
WORKBENCH_DEV_TEAM_RESULT="$RESULT" env -u WORKBENCH_DEV_TEAM_EXTERNAL bash "$HERE/external-result.sh" needs_mike x 2>/dev/null
expect "outside an external run it exits 2" "$?" 2
expect "...and writes nothing" "$(jq -r .state "$RESULT")" running
for bad_path in '' relative.result.json /tmp/not-a-result.json; do
  WORKBENCH_DEV_TEAM_EXTERNAL=1 WORKBENCH_DEV_TEAM_RESULT="$bad_path" bash "$HERE/external-result.sh" needs_mike x 2>/dev/null
  expect "a result path of '$bad_path' is refused: exit 2" "$?" 2
done
rm -f "$RESULT"
result needs_mike x 2>/dev/null
expect "a result file the dispatcher never wrote is refused: exit 2" "$?" 2
expect "...and is not created" "$([ -e "$RESULT" ] && echo present || echo absent)" absent
printf 'not json' > "$RESULT"
result needs_mike x 2>/dev/null
expect "a result file that is not JSON is refused: exit 2" "$?" 2

running
mkdir -p "$WORK/nomktemp"
printf '#!/bin/sh\nexit 1\n' > "$WORK/nomktemp/mktemp"; chmod +x "$WORK/nomktemp/mktemp"
PATH="$WORK/nomktemp:$PATH" result needs_mike x 2>/dev/null
expect "a temporary file that cannot be made exits 1" "$?" 1
expect "...and the file still holds running" "$(jq -r .state "$RESULT")" running

echo "── external-gh.sh ───────────────────────────────────────────────────────"
mkdir -p "$WORK/bin" "$WORK/gh"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH/calls"
jqf= post=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift 2 ;;
    --method) [ "$2" = POST ] && post=1; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$post" = 1 ]; then
  cat > "$FAKE_GH/posted.json"
  [ -e "$FAKE_GH/post.fail" ] && exit 1
  json=$(cat "$FAKE_GH/post.json")
else
  [ -e "$FAKE_GH/get.fail" ] && exit 1
  json=$(cat "$FAKE_GH/get.json")
fi
if [ -n "$jqf" ]; then jq -r "$jqf" <<< "$json"; else printf '%s\n' "$json"; fi
GH
chmod +x "$WORK/bin/gh"
export FAKE_GH="$WORK/gh"
reset() { rm -rf "$FAKE_GH"; mkdir -p "$FAKE_GH"; : > "$FAKE_GH/calls"; printf '%s' '{"default_branch":"main"}' > "$FAKE_GH/get.json"; }
ghx() { env -u CLAUDE_CODE_AGENT PATH="$WORK/bin:$PATH" WORKBENCH_DEV_TEAM_EXTERNAL=1 bash "$HERE/external-gh.sh" "$@"; }
export WORKBENCH_DEV_TEAM_EXTERNAL_TARGET='acme/shop#5'
posted_body() { jq -r .body "$FAKE_GH/posted.json" 2>/dev/null; }
posts() { grep -c -- '--method POST' "$FAKE_GH/calls"; }

reset
printf '%s' '{"html_url":"https://github.com/acme/shop/issues/5#issuecomment-1"}' > "$FAKE_GH/post.json"
out=$(printf '\n\n<!-- acceptance-criteria -->\n- [ ] A test covers an empty cart.\n\n' | ghx comment acme/shop 5 lestrade)
expect "a comment exits 0 and prints its URL" "$?:$out" "0:https://github.com/acme/shop/issues/5#issuecomment-1"
expect "...posts to the issue's comments endpoint" "$(head -1 "$FAKE_GH/calls")" "api --method POST repos/acme/shop/issues/5/comments --input - --jq .html_url"
expect "...with the purpose marker still first, then a blank line, the agent's marker and the footer last" "$(posted_body)" \
  "<!-- acceptance-criteria -->
- [ ] A test covers an empty cart.

<!-- workbench:lestrade -->
🤖 Generated with Claude Code"
expect "...so the marker is never the first line" "$(posted_body | head -1)" "<!-- acceptance-criteria -->"
expect "...and the last line is the footer" "$(posted_body | tail -1)" "🤖 Generated with Claude Code"
printf '%s' 'One line from Watson.' | ghx comment acme/shop 5 watson >/dev/null
expect "a Watson comment carries Watson's marker" "$(posted_body | grep -c '^<!-- workbench:watson -->$')" 1

while IFS='|' read -r label agent body; do
  reset
  printf '%b' "$body" | ghx comment acme/shop 5 "$agent" >/dev/null 2>&1
  expect "a comment with $label is refused: exit 2" "$?" 2
  expect "...and nothing is posted" "$(posts)" 0
done <<'CASES'
an empty body|watson|
a blank body|watson|  \n\n
a marker of its own|watson|text\n<!-- workbench:watson -->
another agent's marker|watson|text\n<!-- workbench:lestrade -->
a spaced marker|watson|text\n<!--  workbench:holmes -->
the footer already in it|watson|text\n🤖 Generated with Claude Code
Holmes as the agent|holmes|a review
an unknown agent|mycroft|text
CASES

reset
for args in "comment acme/shop 0 watson" "comment acme/shop 05 watson" "comment acme/shop 5" "comment acme 5 watson" \
            "comment acme/shop;x 5 watson" "comment acme/shop 5 watson extra" "post acme/shop 5 watson" ""; do
  read -ra argv <<< "$args"
  printf 'body' | ghx ${argv[@]+"${argv[@]}"} >/dev/null 2>&1
  expect "'$args' is refused: exit 2" "$?" 2
done
expect "...and none of them posts" "$(posts)" 0

reset
printf 'body' | env -u WORKBENCH_DEV_TEAM_EXTERNAL PATH="$WORK/bin:$PATH" bash "$HERE/external-gh.sh" comment acme/shop 5 watson >/dev/null 2>&1
expect "outside an external run a comment is refused: exit 2" "$?" 2
printf 'body' | PATH="$WORK/bin:$PATH" WORKBENCH_DEV_TEAM_EXTERNAL=1 CLAUDE_CODE_AGENT=workbench-dev-team:holmes-external \
  bash "$HERE/external-gh.sh" comment acme/shop 5 watson >/dev/null 2>&1
expect "a Holmes run is refused, whatever agent it names: exit 2" "$?" 2
expect "...and neither posts" "$(posts)" 0
printf 'body' | PATH="$WORK/bin:$PATH" WORKBENCH_DEV_TEAM_EXTERNAL=1 CLAUDE_CODE_AGENT=workbench-dev-team:watson-external \
  bash "$HERE/external-gh.sh" comment acme/shop 5 lestrade >/dev/null 2>&1
expect "Lestrade inside a Watson run posts" "$?:$(posts)" "0:1"
reset; touch "$FAKE_GH/post.fail"
printf 'body' | ghx comment acme/shop 5 watson >/dev/null 2>&1
expect "a failed post exits non-zero" "$([ $? -ne 0 ] && echo nonzero)" nonzero

reset
printf '%s' '{"draft":true,"html_url":"https://github.com/acme/shop/pull/9"}' > "$FAKE_GH/post.json"
out=$(printf 'Adds the empty-cart check.\n\nFixes #5\n' | ghx pr acme/shop feature/5-empty-cart 'Check for an empty cart')
expect "a PR exits 0 and prints its URL" "$?:$out" "0:https://github.com/acme/shop/pull/9"
expect "...reads the default branch first" "$(head -1 "$FAKE_GH/calls")" "api repos/acme/shop --jq .default_branch"
expect "...posts to the pulls endpoint" "$(sed -n 2p "$FAKE_GH/calls")" "api --method POST repos/acme/shop/pulls --input - --jq [.draft, .html_url] | @tsv"
expect "...as a draft, from the head to the default branch" "$(jq -c '{title, head, base, draft}' "$FAKE_GH/posted.json")" \
  '{"title":"Check for an empty cart","head":"feature/5-empty-cart","base":"main","draft":true}'
expect "...with Watson's marker and the footer after the body" "$(posted_body)" "Adds the empty-cart check.

Fixes #5

<!-- workbench:watson -->
🤖 Generated with Claude Code"
reset
printf '%s' '{"draft":true,"html_url":"https://github.com/acme/shop/pull/10"}' > "$FAKE_GH/post.json"
printf 'body' | ghx pr acme/shop mike-b:feature/5-x 'A title' >/dev/null
expect "a head on a fork keeps its owner" "$(jq -r .head "$FAKE_GH/posted.json")" "mike-b:feature/5-x"

reset
printf '%s' '{"draft":false,"html_url":"https://github.com/acme/shop/pull/11"}' > "$FAKE_GH/post.json"
printf 'body' | ghx pr acme/shop feature/5-x 'A title' >/dev/null 2>&1
expect "a PR GitHub did not open as a draft exits 1" "$?" 1

reset; touch "$FAKE_GH/post.fail"
out=$(printf 'body' | ghx pr acme/shop feature/5-x 'A title' 2>/dev/null); code=$?
expect "a PR whose POST GitHub rejects exits non-zero" "$([ "$code" -ne 0 ] && echo nonzero)" nonzero
expect "...and prints no URL" "$out" ""
expect "...after the one POST it tried" "$(posts)" 1

while IFS='|' read -r label target verb repo arg; do
  reset
  printf '%s' '{"draft":true,"html_url":"https://github.com/x/y/pull/1"}' > "$FAKE_GH/post.json"
  if [ "$verb" = comment ]; then
    out=$(printf 'body' | WORKBENCH_DEV_TEAM_EXTERNAL_TARGET="$target" ghx comment "$repo" "$arg" watson 2>&1); code=$?
  else
    out=$(printf 'body' | WORKBENCH_DEV_TEAM_EXTERNAL_TARGET="$target" ghx pr "$repo" "$arg" 'A title' 2>&1); code=$?
  fi
  expect "$label is refused: exit 2" "$code" 2
  expect "...and nothing is read or posted" "$(wc -l < "$FAKE_GH/calls" | tr -d ' ')" 0
done <<'CASES'
a comment on another repo|acme/shop#5|comment|other/shop|5
a comment on another owner's repo of the same name|acme/shop#5|comment|evil/shop|5
a comment on another issue of the target repo|acme/shop#5|comment|acme/shop|6
a PR on another repo|acme/shop#5|pr|other/shop|feature/5-x
a PR on a repo of one dot|acme/.#5|pr|acme/.|feature/5-x
a PR on a repo of two dots|acme/..#5|pr|acme/..|feature/5-x
a comment under an owner of two dots|../shop#5|comment|../shop|5
a comment under an owner of one dot|./shop#5|comment|./shop|5
a run with no target|  |comment|acme/shop|5
a run whose target has no number|acme/shop|comment|acme/shop|5
a run whose target has a trailing word|acme/shop#5 x|comment|acme/shop|5
CASES
reset
printf '%s' '{"html_url":"https://github.com/Acme/Shop/issues/5#issuecomment-2"}' > "$FAKE_GH/post.json"
printf 'body' | WORKBENCH_DEV_TEAM_EXTERNAL_TARGET='Acme/Shop#5' ghx comment acme/shop 5 watson >/dev/null
expect "the target's repo matches in any case" "$?:$(posts)" "0:1"

for head in main mike-b:main; do
  reset
  printf 'body' | ghx pr acme/shop "$head" 'A title' >/dev/null 2>&1
  expect "a PR from the default branch as $head is refused: exit 2" "$?" 2
  expect "...and nothing is posted" "$(posts)" 0
done
reset; printf '%s' '{"default_branch":""}' > "$FAKE_GH/get.json"
printf 'body' | ghx pr acme/shop feature/5-x 'A title' >/dev/null 2>&1
expect "a repo with no default branch named is refused: exit 2" "$?:$(posts)" "2:0"
reset; touch "$FAKE_GH/get.fail"
printf 'body' | ghx pr acme/shop feature/5-x 'A title' >/dev/null 2>&1
expect "a failed default-branch read exits 2, and nothing is posted" "$?:$(posts)" "2:0"
while IFS='|' read -r label head title body; do
  reset
  printf '%b' "$body" | ghx pr acme/shop "$head" "$(printf '%b' "$title")" >/dev/null 2>&1
  expect "a PR with $label is refused: exit 2" "$?" 2
  expect "...and nothing is posted" "$(posts)" 0
done <<'CASES'
an empty body|feature/5-x|A title|
a marker in its body|feature/5-x|A title|text\n<!-- workbench:watson -->
a blank title|feature/5-x|   |body
a title of two lines|feature/5-x|one\ntwo|body
a head with a space|feature/5 x|A title|body
a head with a shell character|feature/5;x|A title|body
CASES

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
