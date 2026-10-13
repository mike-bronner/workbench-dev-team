#!/usr/bin/env bash
# ── The Index, without MCP ───────────────────────────────────────────────────
#
# The Index has no REST API. Its POST /mcp endpoint is stateless: laravel/mcp
# answers a bare JSON-RPC tools/call, with no initialize and no session header,
# as a plain HTTP 200 JSON body. The tool's own JSON is the text of
# .result.content[0], and .result.isError marks a tool failure. Every filter and
# sort runs on the server.
#
# ── The token ────────────────────────────────────────────────────────────────
#
# The bearer token is minted with the client_credentials grant from the client
# id and secret in the Keychain (service the-index-mcp, accounts client-id and
# client-secret), and cached with its expiry in a file only the user can read.
# Each mint adds a token row to The Index, so a mint happens only when the cache
# is missing or expired.
# No secret is printed, logged or put on a command line: curl reads the client
# secret and the bearer header from a config on its standard input.
#
# Environment read, for tests only:
#   DISPATCH_INDEX_URL, DISPATCH_TOKEN_URL   The Index endpoints
#   DISPATCH_TOKEN_CACHE                     the token cache file
set -u

case "$#:${1:-}" in
  1:--board) ;;
  *) echo "usage: $(basename "$0") --board" >&2; exit 2 ;;
esac
# Board mode's stdout is its JSON alone, on fd 3. Every message goes to stderr.
exec 3>&1 1>&2

INDEX_URL="${DISPATCH_INDEX_URL:-https://the-index.mikebronner.dev/mcp}"
TOKEN_URL="${DISPATCH_TOKEN_URL:-https://the-index.mikebronner.dev/oauth/token}"
TOKEN_CACHE="${DISPATCH_TOKEN_CACHE:-$HOME/.claude-workbench/the-index-token.json}"

EXPIRY_MARGIN=3600
FALLBACK_LIFETIME=86400

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is not on PATH, so the board cannot be fetched." >&2
    exit 1
  fi
done

# ── The token ────────────────────────────────────────────────────────────────

# One value as a quoted string for a curl config: backslash and quote escaped.
curl_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# The cached token, when the cache holds one that has not expired. Prints
# nothing, and fails, otherwise.
cached_token() {
  [ -f "$TOKEN_CACHE" ] || return 1
  jq -er --argjson now "$(date +%s)" --argjson margin "$EXPIRY_MARGIN" '
    select((.expires_at | type) == "number" and .expires_at - $margin > $now)
    | .access_token | strings | select(length > 0)' "$TOKEN_CACHE" 2>/dev/null
}

# post <url> <curl config on stdin> [curl options…]: one POST. Sets STATUS to
# the HTTP code (000 when curl failed) and BODY to the reply. curl's own
# messages are dropped: one about the config could quote a line of it.
post() {
  local url="$1" reply
  shift
  reply=$(curl -q -sS -K - -w '\n%{http_code}' "$@" "$url" 2>/dev/null) || { STATUS=000; BODY=; return; }
  STATUS=${reply##*$'\n'}
  BODY=${reply%$'\n'*}
}

# Whether STATUS says The Index could not be reached: no answer, or a 5xx.
is_down() { [ "${STATUS:-000}" = 000 ] || [ "${STATUS:0:1}" = 5 ]; }

# Mints a token and writes the cache. Sets TOKEN, or prints why it could not and
# returns 1 (credentials, or a refusal) or 2 (The Index unreachable).
MINTED=0
mint_token() {
  MINTED=1
  local id secret token lifetime
  id=$(security find-generic-password -s the-index-mcp -a client-id -w 2>/dev/null) || id=
  secret=$(security find-generic-password -s the-index-mcp -a client-secret -w 2>/dev/null) || secret=
  if [ -z "$id" ] || [ -z "$secret" ]; then
    echo "The Keychain has no the-index-mcp client-id or client-secret, so no Index token could be minted. Run /workbench-dev-team:setup."
    return 1
  fi
  post "$TOKEN_URL" --max-time 30 < <(
    printf 'data-urlencode = %s\n' "$(curl_quote 'grant_type=client_credentials')"
    printf 'data-urlencode = %s\n' "$(curl_quote "client_id=$id")"
    printf 'data-urlencode = %s\n' "$(curl_quote "client_secret=$secret")"
    printf 'data-urlencode = %s\n' "$(curl_quote 'scope=index.mcp.read index.mcp.write')"
  )
  secret=
  if is_down; then
    echo "The Index could not be reached."
    return 2
  fi
  if [ "$STATUS" != 200 ]; then
    # The body is not printed: an OAuth error body can echo the request.
    echo "The Index refused the token request (HTTP $STATUS). Check the the-index-mcp client in the Keychain."
    return 1
  fi
  token=$(printf '%s' "$BODY" | jq -er '.access_token | strings | select(length > 0)' 2>/dev/null) || token=
  if [ -z "$token" ]; then
    echo "The Index answered the token request with no access_token."
    return 1
  fi
  lifetime=$(printf '%s' "$BODY" | jq -er '.expires_in | numbers | floor | select(. > 0)' 2>/dev/null) || lifetime=$FALLBACK_LIFETIME
  mkdir -p "$(dirname "$TOKEN_CACHE")"
  # Written whole and renamed into place, readable by the user alone.
  if ! ( umask 077
         jq -n --arg t "$token" --argjson at "$(( $(date +%s) + lifetime ))" '{access_token: $t, expires_at: $at}' > "$TOKEN_CACHE.$$" \
           && mv -f "$TOKEN_CACHE.$$" "$TOKEN_CACHE" ); then
    echo "Could not write the token cache at $TOKEN_CACHE."
    return 1
  fi
  TOKEN=$token
  echo "minted a new Index token"
  return 0
}

TOKEN=$(cached_token) || TOKEN=
if [ -z "$TOKEN" ]; then
  mint_token || exit 1
fi

# ── Calling a tool ───────────────────────────────────────────────────────────

RPC_ID=0
# call <tool> <arguments JSON>. On success sets RESULT to the tool's own JSON
# (the text of .result.content[0], parsed when it is JSON) and returns 0.
# Otherwise sets FAILURE and returns:
#   1  the tool answered with isError (FAILURE is its text)
#   2  The Index could not be reached
#   3  the token was refused
#   4  a reply that is not a stateless JSON-RPC result
call() {
  local name="$1" args="$2" request text
  RPC_ID=$((RPC_ID + 1))
  RESULT=; FAILURE=
  request=$(jq -nc --arg name "$name" --argjson args "$args" --argjson id "$RPC_ID" \
    '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $name, arguments: $args}}')
  post "$INDEX_URL" --max-time 120 -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary "$request" < <(printf 'header = %s\n' "$(curl_quote "Authorization: Bearer $TOKEN")")
  if is_down; then
    FAILURE="unreachable"
    return 2
  fi
  if [ "$STATUS" = 401 ]; then
    if [ "$MINTED" = 0 ]; then
      mint_token
      case $? in
        0) call "$name" "$args"; return ;;
        *) FAILURE=; return 3 ;;
      esac
    fi
    FAILURE="The Index refused a newly minted token (HTTP 401). Check the the-index-mcp client in the Keychain."
    return 3
  fi
  local protocol="The board client posts a bare tools/call with no initialize and no session, and expects a plain JSON reply. The Index's MCP server has accepted that so far. If it now needs a session or streams its replies, the board client must change."
  if [ "$STATUS" != 200 ]; then
    FAILURE="The Index answered $name with HTTP $STATUS. $protocol"
    return 4
  fi
  if ! printf '%s' "$BODY" | jq -e '.jsonrpc == "2.0" and ((.result | type) == "object" or (.error | type) == "object")' >/dev/null 2>&1; then
    FAILURE="The Index answered $name with a body that is not a JSON-RPC reply. $protocol"
    return 4
  fi
  if printf '%s' "$BODY" | jq -e '.error | type == "object"' >/dev/null; then
    FAILURE="The Index refused $name with JSON-RPC error $(printf '%s' "$BODY" | jq -r '"\(.error.code // "?"): \(.error.message // "no message")"' | tr '\n' ' '). $protocol"
    return 4
  fi
  text=$(printf '%s' "$BODY" | jq -r '.result.content[0].text // empty')
  if printf '%s' "$BODY" | jq -e '.result.isError == true' >/dev/null; then
    FAILURE=$(printf '%s' "${text:-no error text}" | tr '\n' ' ')
    return 1
  fi
  if printf '%s' "$text" | jq -e . >/dev/null 2>&1; then
    RESULT=$(printf '%s' "$text" | jq -c .)
  else
    RESULT=$(jq -nc --arg t "$text" '$t')
  fi
  return 0
}

# ── Board mode ───────────────────────────────────────────────────────────────

board_lane() {
  local tool="$1" limit="$2" extra="${3:-}" args rc
  [ -n "$extra" ] || extra='{}'
  args=$(jq -nc --argjson limit "$limit" --argjson extra "$extra" '$extra + {limit: $limit}')
  call "$tool" "$args"
  rc=$?
  case "$rc" in
    0) ;;
    1) LANE=$(jq -nc --arg e "$FAILURE" '{error: $e}'); return 0 ;;
    2) echo "The Index could not be reached." >&2; return 1 ;;
    *) [ -z "$FAILURE" ] || printf '%s\n' "$FAILURE" >&2; return 1 ;;
  esac
  LANE=$(printf '%s' "$RESULT" | jq -c --argjson limit "$limit" '
    if (.items | type) == "array" then
      {limit: $limit, items: [.items[] | objects | {id, number: (.issue_number // .pr_number),
        isPr: (.issue_number == null and .pr_number != null), repo, title, claimedAt: .in_flight_at}]}
    else {error: "answered with no items list"} end' 2>/dev/null) \
    || LANE=$(jq -nc '{error: "answered with no items list"}')
}

board_lane list_unrefined_items 25 || exit 1
UNREFINED=$LANE
board_lane list_review_items 25 || exit 1
REVIEW=$LANE
board_lane list_development_items 25 '{"include_claimed": true}' || exit 1
DEVELOPMENT=$LANE
jq -nc --argjson u "$UNREFINED" --argjson r "$REVIEW" --argjson d "$DEVELOPMENT" \
  '{lanes: {unrefined: $u, review: $r, development: $d}}' >&3
