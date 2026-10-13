#!/usr/bin/env bash
# Run: bash bin/test-dispatch-tick.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/dispatch-tick.sh"
FAKE="$HERE/../tests/fake-index.py"
WORK=$(mktemp -d)
SERVER=
cleanup() {
  if [ -n "$SERVER" ]; then kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

for need in python3 curl jq; do
  command -v "$need" >/dev/null 2>&1 || { echo "FAIL: $need is required"; exit 1; }
done

mkdir -p "$WORK/home" "$WORK/stub"
export HOME="$WORK/home"
LOG="$WORK/index.log"
CACHE="$WORK/home/token.json"
SECRET='s3cret-"quoted"\back'
CLIENT='client-42'

# ── Stubs ────────────────────────────────────────────────────────────────────

cat > "$WORK/stub/security" <<'EOF'
#!/usr/bin/env bash
# Answers find-generic-password for the-index-mcp from FAKE_* variables, and
# records each call in SECURITY_CALLS when that is set.
[ -n "${SECURITY_CALLS:-}" ] && printf '%s\n' "$*" >> "$SECURITY_CALLS"
account=
while [ $# -gt 0 ]; do case "$1" in -a) account="$2"; shift ;; esac; shift; done
case "$account" in
  client-id)     [ -n "${FAKE_CLIENT_ID:-}" ] && { printf '%s\n' "$FAKE_CLIENT_ID"; exit 0; } ;;
  client-secret) [ -n "${FAKE_CLIENT_SECRET:-}" ] && { printf '%s\n' "$FAKE_CLIENT_SECRET"; exit 0; } ;;
esac
exit 44
EOF

cat > "$WORK/stub/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >> "$WORK/claude.calls"
EOF

REAL_CURL=$(command -v curl)
cat > "$WORK/stub/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/curl.argv"
exec "$REAL_CURL" "\$@"
EOF

chmod +x "$WORK/stub/"*

# ── The fake Index ───────────────────────────────────────────────────────────

echo '{}' > "$WORK/scenario.json"
python3 "$FAKE" "$WORK/scenario.json" "$LOG" "$WORK/port" &
SERVER=$!
for _ in $(seq 1 100); do [ -s "$WORK/port" ] && break; sleep 0.05; done
[ -s "$WORK/port" ] || { echo "FAIL: the fake Index did not start"; exit 1; }
URL="http://127.0.0.1:$(cat "$WORK/port")"

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }
expect_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
expect_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: expected to contain [$2] in [$3]" ;; esac; }
expect_lacks() { case "$3" in *"$2"*) bad "$1: expected NOT to contain [$2] in [$3]" ;; *) ok "$1" ;; esac; }

# A valid cached token, so a case that is not about the token mints nothing.
seed_cache() { printf '{"access_token":"tok-1","expires_at":%s}' "$(( $(date +%s) + ${1:-86400} ))" > "$CACHE"; }

reset() {
  : > "$LOG"; : > "$WORK/curl.argv"; rm -f "$WORK/claude.calls"
  printf '%s' "$1" > "$WORK/scenario.json"
}

trail() { jq -r 'if .body then "\(.body.params.name) \(.body.params.arguments | tojson)" else "mint" end' "$LOG"; }
mints() { jq -r 'select(.path == "/oauth/token") | "mint"' "$LOG" | wc -l | tr -d ' '; }
items() { jq -nc --argjson items "$1" '{result: {count: ($items | length), items: $items}}'; }
item()  { jq -nc --argjson id "$1" --argjson n "$2" --arg repo "$3" --arg flight "${4:-}" \
            '{id: $id, issue_number: $n, repo: $repo, in_flight_at: (if $flight == "" then null else $flight end)}'; }

VALID='"valid_tokens": ["tok-1"]'

# ── Board mode ───────────────────────────────────────────────────────────────
# board [url] [arguments…]: one run of the real script in board mode. Sets BOUT
# (stdout), BERR (stderr) and RC.
board() {
  local url="${1:-$URL}"
  [ $# -gt 0 ] && shift
  [ $# -gt 0 ] || set -- --board
  BOUT=$(DISPATCH_INDEX_URL="$url/mcp" DISPATCH_TOKEN_URL="$url/oauth/token" \
    DISPATCH_TOKEN_CACHE="$CACHE" \
    FAKE_CLIENT_ID="$CLIENT" FAKE_CLIENT_SECRET="${FAKE_CLIENT_SECRET-$SECRET}" SECURITY_CALLS="$WORK/security.calls" \
    PATH="$WORK/stub:$PATH" bash "$SCRIPT" "$@" 2>"$WORK/board.err")
  RC=$?
  BERR=$(cat "$WORK/board.err")
  cat "$WORK/board.err" >> "$WORK/board-all.err"
  # The pane shows the last line on stderr as the reason.
  BREASON=$(printf '%s\n' "$BERR" | awk 'NF { last = $0 } END { print last }')
}
keychain_reads() { [ -e "$WORK/security.calls" ] && wc -l < "$WORK/security.calls" | tr -d ' ' || echo 0; }

echo "— with no argument it refuses, and routes, dispatches and writes nothing"
seed_cache
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 95 905 o/r)]")}}"
sleep 1
touch "$WORK/before-none"
OUT=$(DISPATCH_INDEX_URL="$URL/mcp" DISPATCH_TOKEN_URL="$URL/oauth/token" DISPATCH_TOKEN_CACHE="$CACHE" \
  FAKE_CLIENT_ID="$CLIENT" FAKE_CLIENT_SECRET="$SECRET" PATH="$WORK/stub:$PATH" bash "$SCRIPT" 2>&1)
RC=$?
expect_eq "exit 2" 2 "$RC"
expect_eq "prints the usage alone" "usage: dispatch-tick.sh --board" "$OUT"
expect_eq "calls nothing" "" "$(cat "$LOG")"
expect_eq "starts no agent" "no" "$([ -e "$WORK/claude.calls" ] && echo yes || echo no)"
expect_eq "writes nothing under HOME" "" "$(find "$HOME" -newer "$WORK/before-none" -print)"

echo "— the mint: a client_credentials grant, with the secret intact, cached for expires_in"
rm -f "$CACHE"
reset "{$VALID}"
board
expect_eq "the mint is a client_credentials grant for the Keychain client" \
  "client_credentials $CLIENT index.mcp.read index.mcp.write" \
  "$(jq -r 'select(.form) | "\(.form.grant_type) \(.form.client_id) \(.form.scope)"' "$LOG")"
expect_eq "the secret reaches The Index intact" "$SECRET" "$(jq -r 'select(.form) | .form.client_secret' "$LOG")"
LEFT=$(( $(jq -r .expires_at "$CACHE") - $(date +%s) ))
[ "$LEFT" -gt 31535000 ] && [ "$LEFT" -le 31536000 ] && ok "the expiry is expires_in from now" || bad "the expiry is $LEFT seconds away"
expect_lacks "no client secret on curl's command line" "s3cret" "$(cat "$WORK/curl.argv")"
expect_lacks "no bearer token on curl's command line" "tok-1" "$(cat "$WORK/curl.argv")"
rm -f "$CACHE"
reset "{$VALID, \"token\": {\"status\": 200, \"body\": {\"access_token\": \"tok-1\"}}}"
board
LEFT=$(( $(jq -r .expires_at "$CACHE") - $(date +%s) ))
[ "$LEFT" -gt 86000 ] && [ "$LEFT" -le 86400 ] && ok "a reply with no expires_in is cached for a day" || bad "cached for $LEFT seconds"
rm -f "$CACHE"
reset "{$VALID, \"token\": {\"status\": 200, \"body\": {\"token_type\": \"Bearer\"}}}"
board
expect_eq "a reply with no access_token: exit 1" 1 "$RC"
expect_eq "and the reason says so" "The Index answered the token request with no access_token." "$BREASON"
rm -f "$WORK/security.calls"

echo "— board mode on a valid cache: the three list tools, one JSON object, nothing else"
seed_cache
BOARD_SCENARIO=$(jq -nc --argjson u "$(items "[$(item 11 101 o/a), $(item 12 102 o/b)]")" \
  --argjson r "$(jq -nc '{result: {count: 1, items: [{id: 21, issue_number: null, pr_number: 7, repo: "o/a", title: "Fix it", in_flight_at: null}]}}')" \
  --argjson d "$(items "[$(item 31 301 o/a 2026-10-08T10:00:00+00:00), $(item 32 302 o/b)]")" \
  '{valid_tokens: ["tok-1"], tools: {list_unrefined_items: $u, list_review_items: $r, "list_development_items#claimed": $d}}')
reset "$BOARD_SCENARIO"
touch "$WORK/before-board"
board
expect_eq "exit 0" 0 "$RC"
expect_eq "prints nothing on stderr" "" "$BERR"
expect_eq "calls the three list tools, each with its limit, and nothing else" \
'list_unrefined_items {"limit":25}
list_review_items {"limit":25}
list_development_items {"include_claimed":true,"limit":25}' "$(trail)"
expect_eq "mints nothing on a valid cache" 0 "$(mints)"
expect_eq "reads no Keychain item" 0 "$(keychain_reads)"
expect_eq "starts no agent" "no" "$([ -e "$WORK/claude.calls" ] && echo yes || echo no)"
expect_eq "stdout is one JSON object with the three lanes" "unrefined review development" \
  "$(printf '%s' "$BOUT" | jq -r '.lanes | keys_unsorted | join(" ")')"
expect_eq "each lane carries its limit and its items" "25:2 25:1 25:2" \
  "$(printf '%s' "$BOUT" | jq -r '[.lanes[] | "\(.limit):\(.items | length)"] | join(" ")')"
expect_eq "an item keeps its id, number, repo and claim, and nothing else" \
  '{"id":31,"number":301,"isPr":false,"repo":"o/a","title":null,"claimedAt":"2026-10-08T10:00:00+00:00"}' \
  "$(printf '%s' "$BOUT" | jq -c '.lanes.development.items[0]')"
expect_eq "a pull request item is marked as one" '7 true' "$(printf '%s' "$BOUT" | jq -r '.lanes.review.items[0] | "\(.number) \(.isPr)"')"
expect_lacks "no token in the JSON" "tok-1" "$BOUT"
expect_lacks "no token on a curl command line" "tok-1" "$(cat "$WORK/curl.argv")"
expect_eq "writes nothing under HOME" "" "$(find "$HOME" -newer "$WORK/before-board" -print)"

echo "— board mode mints once, caches, and fetches, when no cached token is valid"
for state in missing expired near-expiry unreadable; do
  case "$state" in
    missing) rm -f "$CACHE" ;;
    expired) seed_cache -10 ;;
    near-expiry) seed_cache 600 ;;
    unreadable) printf 'not json' > "$CACHE" ;;
  esac
  reset "$BOARD_SCENARIO"
  rm -f "$WORK/security.calls"
  sleep 1
  touch "$WORK/before-board"
  board
  expect_eq "$state cache: exit 0" 0 "$RC"
  expect_eq "$state cache: one mint, then the three lists" \
'mint
list_unrefined_items {"limit":25}
list_review_items {"limit":25}
list_development_items {"include_claimed":true,"limit":25}' "$(trail)"
  expect_eq "$state cache: the mint reads the Keychain client" 2 "$(keychain_reads)"
  expect_eq "$state cache: the minted token is the one sent" "Bearer tok-1" "$(jq -r 'select(.body) | .auth' "$LOG" | sort -u)"
  expect_eq "$state cache: the cache holds the minted token" "tok-1" "$(jq -r .access_token "$CACHE")"
  expect_eq "$state cache: readable by the user alone" "600" "$(stat -c %a "$CACHE" 2>/dev/null || stat -f %Lp "$CACHE")"
  expect_eq "$state cache: the cache is the only file written" "$CACHE" "$(find "$HOME" -newer "$WORK/before-board" -type f -print)"
  expect_eq "$state cache: the board is printed" "25:2 25:1 25:2" \
    "$(printf '%s' "$BOUT" | jq -r '[.lanes[] | "\(.limit):\(.items | length)"] | join(" ")')"
  : > "$LOG"
  board
  expect_eq "$state cache: the next fetch mints nothing" "0 0" "$RC $(mints)"
done

echo "— board mode: a 401 mints once and retries that call once"
printf '{"access_token":"tok-revoked","expires_at":%s}' "$(( $(date +%s) + 86400 ))" > "$CACHE"
reset "$BOARD_SCENARIO"
board
expect_eq "a refused cached token: exit 0" 0 "$RC"
expect_eq "the call, one mint, the same call again, then the rest" \
'list_unrefined_items {"limit":25}
mint
list_unrefined_items {"limit":25}
list_review_items {"limit":25}
list_development_items {"include_claimed":true,"limit":25}' "$(trail)"
expect_eq "the cache holds the new token" "tok-1" "$(jq -r .access_token "$CACHE")"
expect_eq "the board is printed" "unrefined review development" "$(printf '%s' "$BOUT" | jq -r '.lanes | keys_unsorted | join(" ")')"

REFUSED_NEW="The Index refused a newly minted token (HTTP 401). Check the the-index-mcp client in the Keychain."
printf '{"access_token":"tok-revoked","expires_at":%s}' "$(( $(date +%s) + 86400 ))" > "$CACHE"
reset '{"valid_tokens": ["another"]}'
board
expect_eq "a refused fresh token: exit 1" 1 "$RC"
expect_eq "one mint and one retry, never a loop" \
'list_unrefined_items {"limit":25}
mint
list_unrefined_items {"limit":25}' "$(trail)"
expect_eq "the reason names the refused fresh token" "$REFUSED_NEW" "$BREASON"
expect_eq "nothing on stdout" "" "$BOUT"

rm -f "$CACHE"
reset '{"valid_tokens": ["another"]}'
board
expect_eq "a token minted on a miss, then refused: exit 1" 1 "$RC"
expect_eq "no second mint" \
'mint
list_unrefined_items {"limit":25}' "$(trail)"
expect_eq "and the reason names the refused fresh token" "$REFUSED_NEW" "$BREASON"

echo "— board mode: a mint that fails, in pane wording"
rm -f "$CACHE"
reset "$BOARD_SCENARIO"
FAKE_CLIENT_SECRET='' board
expect_eq "no Keychain client: exit 1" 1 "$RC"
expect_eq "the reason names the Keychain" "The Keychain has no the-index-mcp client-id or client-secret, so no Index token could be minted. Run /workbench-dev-team:setup." "$BREASON"
expect_eq "no request at all" "" "$(cat "$LOG")"
rm -f "$CACHE"
reset "{$VALID, \"token\": {\"status\": 401, \"body\": {\"error\": \"invalid_client\"}}}"
board
expect_eq "a refused token request: exit 1" 1 "$RC"
expect_eq "the reason names it" "The Index refused the token request (HTTP 401). Check the the-index-mcp client in the Keychain." "$BREASON"
expect_lacks "the reply body is not printed" "invalid_client" "$BERR"
[ -f "$CACHE" ] && bad "a cache was written" || ok "no cache written"
expect_eq "no Index call" "mint" "$(trail)"
printf '{"access_token":"tok-revoked","expires_at":%s}' "$(( $(date +%s) + 86400 ))" > "$CACHE"
reset "{$VALID, \"token\": {\"status\": 401, \"body\": {}}}"
board
expect_eq "a 401, then a refused token request: exit 1" 1 "$RC"
expect_eq "the reason is printed once" 1 "$(printf '%s\n' "$BERR" | grep -c -F 'The Index refused the token request (HTTP 401).')"
expect_eq "the reason names the token request" "The Index refused the token request (HTTP 401). Check the the-index-mcp client in the Keychain." "$BREASON"
expect_eq "no retry after a failed mint" \
'list_unrefined_items {"limit":25}
mint' "$(trail)"
rm -f "$CACHE"
reset "{$VALID}"
board "http://127.0.0.1:9"
expect_eq "an unreachable token endpoint: exit 1" 1 "$RC"
expect_eq "the reason says The Index could not be reached" "The Index could not be reached." "$BREASON"

echo "— board mode reads no ~/.curlrc"
printf 'trace-ascii = "%s"\nproxy = "http://127.0.0.1:9"\n' "$WORK/curl-trace.txt" > "$HOME/.curlrc"
rm -f "$CACHE"
reset "$BOARD_SCENARIO"
board
rm -f "$HOME/.curlrc"
expect_eq "a curlrc that traces and breaks every request: exit 0" 0 "$RC"
expect_eq "the mint and the three lists still go out" 4 "$(jq -s length "$LOG")"
expect_eq "no trace file is written" no "$([ -e "$WORK/curl-trace.txt" ] && echo yes || echo no)"

echo "— board mode never prints a token or a secret, or puts one on a command line"
expect_lacks "no token on stderr" "tok-1" "$(cat "$WORK/board-all.err")"
expect_lacks "no secret on stderr" "s3cret" "$(cat "$WORK/board-all.err")"
expect_lacks "no secret on a curl command line" "s3cret" "$(cat "$WORK/curl.argv")"

echo "— board mode: each failure's reason is the last line on stderr"
seed_cache
reset "$BOARD_SCENARIO"
board "http://127.0.0.1:9"
expect_eq "an unreachable Index exits 1" 1 "$RC"
expect_eq "and the reason says so" "The Index could not be reached." "$BREASON"
expect_lacks "with no tick wording" "skipping this tick" "$BERR"
reset "{$VALID, \"tools\": {\"list_unrefined_items\": {\"status\": 404, \"raw\": \"nope\"}}}"
board
expect_eq "a reply that is not a JSON-RPC result exits 1" 1 "$RC"
expect_has "and the reason names the HTTP status" "The Index answered list_unrefined_items with HTTP 404." "$BREASON"
reset "{$VALID, \"tools\": {\"list_review_items\": {\"rpcError\": {\"code\": -32601, \"message\": \"no such method\"}}}}"
board
expect_eq "a JSON-RPC error exits 1" 1 "$RC"
expect_has "and the reason names it" "The Index refused list_review_items with JSON-RPC error -32601: no such method" "$BREASON"
seed_cache
reset "{$VALID, \"tools\": {\"list_review_items\": {\"isError\": \"review lane down\"}}}"
board
expect_eq "a tool error is the lane's own: exit 0" 0 "$RC"
expect_eq "the lane carries the error" "review lane down" "$(printf '%s' "$BOUT" | jq -r '.lanes.review.error')"
expect_eq "the other lanes still list" "25 25" "$(printf '%s' "$BOUT" | jq -r '[.lanes.unrefined.limit, .lanes.development.limit] | join(" ")')"
reset "{$VALID, \"tools\": {\"list_unrefined_items\": {\"result\": {\"data\": []}}}}"
board
expect_eq "a lane with no items list is an error of its own" "answered with no items list" "$(printf '%s' "$BOUT" | jq -r '.lanes.unrefined.error')"

echo "— board mode: a missing curl or jq, in pane wording"
# A PATH in this test's own folder holding only what the script runs before its
# tool check, and one of the two tools.
for missing in curl jq; do
  MINPATH="$WORK/minpath-$missing"
  mkdir -p "$MINPATH"
  for t in dirname basename date curl jq; do
    [ "$t" = "$missing" ] || ln -sf "$(command -v "$t")" "$MINPATH/$t"
  done
  OUT=$(DISPATCH_TOKEN_CACHE="$CACHE" PATH="$MINPATH" "$(command -v bash)" "$SCRIPT" --board 2>"$WORK/board.err")
  RC=$?
  BERR=$(cat "$WORK/board.err"); cat "$WORK/board.err" >> "$WORK/board-all.err"
  expect_eq "board, $missing missing: exit 1" 1 "$RC"
  expect_eq "board, $missing missing: the reason is pane wording" "$missing is not on PATH, so the board cannot be fetched." "$BERR"
  expect_eq "board, $missing missing: nothing on stdout" "" "$OUT"
done

echo "— no line board mode printed carries the tick prefix or speaks of dispatching"
expect_lacks "no tick prefix" "dispatch-tick" "$(cat "$WORK/board-all.err")"
expect_lacks "nothing about dispatching" "dispatched" "$(cat "$WORK/board-all.err")"
expect_lacks "no tick wording" "this tick" "$(cat "$WORK/board-all.err")"
expect_eq "the board lines were collected" yes "$([ -s "$WORK/board-all.err" ] && echo yes || echo no)"

echo "— any other argument is refused before anything runs"
for args in "--boards" "--board extra" "board"; do
  reset "$BOARD_SCENARIO"
  # shellcheck disable=SC2086
  board "$URL" $args
  expect_eq "'$args' exits 2" 2 "$RC"
  expect_has "'$args' prints the usage" "usage:" "$BERR"
  expect_eq "'$args' calls nothing" "" "$(trail)"
done

echo
echo "dispatch-tick: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
