#!/usr/bin/env bash
# One Dispatch tick: poll The Index's three lanes and dispatch each item through
# bin/dispatch-agent.sh. No model runs here, so a tick with nothing to dispatch
# costs no tokens. A launchd job (bin/dispatch-tick.plist, installed by
# /workbench-dev-team:setup) runs it on the configured cadence.
#
# It replaces the scheduled Claude task that ran the same routing as a model
# prompt. What it reproduces from that prompt:
#
#   Lane 1  list_unrefined_items: one `lestrade <id>` dispatch per item, then one
#           `lestrade <owner/repo>` sweep per distinct repo the lane returned.
#   Lane 2  list_review_items: one `holmes <id>` dispatch per item.
#   Lane 3  the stale-claim sweep first: list_development_items with
#           include_claimed and limit 25, and for each item with in_flight_at
#           set, `dispatch-agent.sh --check watson <id>`. A first line starting
#           SKIP means the run is alive and the claim stays. Anything else
#           releases the claim. Then list_development_items with limit 1, and
#           one `watson <id>` dispatch. One Watson per tick.
#
#   The dispatcher's first line decides what happened:
#     dispatched …        a dispatch
#     SKIP<TAB>…          a live run holds the item; nothing to do
#     REPRIEVE<TAB>…      a human re-activated an escalated item; a fresh run
#                         went out at a raised budget
#     ESCALATE<TAB><why>  the item is wedged. The tick moves it to Escalated,
#                         posts the escalation comment, runs --mark-escalated
#                         only when the move succeeded, and releases the claim.
#
# The circuit breaker, the budgets, the reprieve and the model all live in
# dispatch-agent.sh. This script only routes.
#
# ── The Index, without MCP ───────────────────────────────────────────────────
#
# The Index has no REST API. Its POST /mcp endpoint is stateless: laravel/mcp
# answers a bare JSON-RPC tools/call, with no initialize and no session header,
# as a plain HTTP 200 JSON body. The tool's own JSON is the text of
# .result.content[0], and .result.isError marks a tool failure. Every filter and
# sort runs on the server.
#
# That statelessness is the one thing this script depends on that The Index
# does not promise. So any reply that is not a JSON-RPC result (a JSON-RPC
# error, a 4xx other than 401, a body that is not JSON-RPC) stops the tick with
# a message that names the stateless call as the likely cause.
#
# ── The token ────────────────────────────────────────────────────────────────
#
# The bearer token is minted with the client_credentials grant from the client
# id and secret in the Keychain (service the-index-mcp, accounts client-id and
# client-secret), and cached with its expiry in a file only the user can read.
# Each mint adds a token row to The Index, so a mint happens only when the cache
# is missing or expired. A 401 drops the cache, so the next tick mints once.
# No secret is printed, logged or put on a command line: curl reads the client
# secret and the bearer header from a config on its standard input.
#
# ── Output ───────────────────────────────────────────────────────────────────
#
# One line per action, then a counts line, or `idle — nothing to dispatch`.
# A tick in which every list call returned an items list then ends with
# `tick ok <start time>`, a line no early stop and no skipped lane prints,
# which setup's proof step waits for. A
# list that fails skips its lane. A dispatcher that exits non-zero is logged and
# the next item goes on. An Index that cannot be reached prints
# `the-index unreachable — skipping this tick` and exits 0.
#
# Exit codes: 0 for a tick that ran or skipped cleanly, 1 when the tick could
# not run (a missing tool, missing credentials, a refused protocol).
#
# Environment read, for tests only (the launchd job sets none of them):
#   DISPATCH_INDEX_URL, DISPATCH_TOKEN_URL   The Index endpoints
#   DISPATCH_TOKEN_CACHE                     the token cache file
#   DISPATCH_AGENT                           the dispatcher script
#   DISPATCH_ESCALATION_TEMPLATE             the escalation comment template
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
INDEX_URL="${DISPATCH_INDEX_URL:-https://the-index.mikebronner.dev/mcp}"
TOKEN_URL="${DISPATCH_TOKEN_URL:-https://the-index.mikebronner.dev/oauth/token}"
TOKEN_CACHE="${DISPATCH_TOKEN_CACHE:-$HOME/.claude-workbench/the-index-token.json}"
DISPATCHER="${DISPATCH_AGENT:-$HERE/dispatch-agent.sh}"
TEMPLATE="${DISPATCH_ESCALATION_TEMPLATE:-$HERE/escalation-comment.md}"

# A token is treated as expired this long before The Index says it is, so a
# tick never starts a lane on a token that runs out partway.
EXPIRY_MARGIN=3600
# A reply with no expires_in is cached this long. A wrong guess costs one 401
# and one mint; no cache at all would cost a mint on every tick.
FALLBACK_LIFETIME=86400

UNREACHABLE='the-index unreachable — skipping this tick'

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "dispatch-tick: $tool is not on PATH; nothing dispatched" >&2
    exit 1
  fi
done
if [ ! -f "$DISPATCHER" ]; then
  echo "dispatch-tick: the dispatcher is missing at $DISPATCHER; nothing dispatched" >&2
  exit 1
fi

TICK_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "── tick $TICK_START ──"

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
  reply=$(curl -sS -K - -w '\n%{http_code}' "$@" "$url" 2>/dev/null) || { STATUS=000; BODY=; return; }
  STATUS=${reply##*$'\n'}
  BODY=${reply%$'\n'*}
}

# Whether STATUS says The Index could not be reached: no answer, or a 5xx.
is_down() { [ "${STATUS:-000}" = 000 ] || [ "${STATUS:0:1}" = 5 ]; }

# Mints a token and writes the cache. Sets TOKEN, or prints why it could not and
# returns 1 (credentials, or a refusal) or 2 (The Index unreachable).
mint_token() {
  local id secret token lifetime
  id=$(security find-generic-password -s the-index-mcp -a client-id -w 2>/dev/null) || id=
  secret=$(security find-generic-password -s the-index-mcp -a client-secret -w 2>/dev/null) || secret=
  if [ -z "$id" ] || [ -z "$secret" ]; then
    echo "dispatch-tick: the Keychain has no the-index-mcp client-id or client-secret. Run /workbench-dev-team:setup. Nothing dispatched."
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
    echo "$UNREACHABLE"
    return 2
  fi
  if [ "$STATUS" != 200 ]; then
    # The body is not printed: an OAuth error body can echo the request.
    echo "dispatch-tick: The Index refused the token request (HTTP $STATUS). Check the the-index-mcp client in the Keychain. Nothing dispatched."
    return 1
  fi
  token=$(printf '%s' "$BODY" | jq -er '.access_token | strings | select(length > 0)' 2>/dev/null) || token=
  if [ -z "$token" ]; then
    echo "dispatch-tick: The Index answered the token request with no access_token. Nothing dispatched."
    return 1
  fi
  lifetime=$(printf '%s' "$BODY" | jq -er '.expires_in | numbers | floor | select(. > 0)' 2>/dev/null) || lifetime=$FALLBACK_LIFETIME
  mkdir -p "$(dirname "$TOKEN_CACHE")"
  # Written whole and renamed into place, readable by the user alone.
  if ! ( umask 077
         jq -n --arg t "$token" --argjson at "$(( $(date +%s) + lifetime ))" '{access_token: $t, expires_at: $at}' > "$TOKEN_CACHE.$$" \
           && mv -f "$TOKEN_CACHE.$$" "$TOKEN_CACHE" ); then
    echo "dispatch-tick: could not write the token cache at $TOKEN_CACHE. Nothing dispatched."
    return 1
  fi
  TOKEN=$token
  echo "minted a new Index token (the cache was missing or expired)"
  return 0
}

TOKEN=$(cached_token) || TOKEN=
if [ -z "$TOKEN" ]; then
  mint_token
  case $? in
    0) ;;
    2) exit 0 ;;
    *) exit 1 ;;
  esac
fi

# ── Calling a tool ───────────────────────────────────────────────────────────

RPC_ID=0
# call <tool> <arguments JSON>. On success sets RESULT to the tool's own JSON
# (the text of .result.content[0], parsed when it is JSON) and returns 0.
# Otherwise sets FAILURE and returns:
#   1  the tool answered with isError (FAILURE is its text)
#   2  The Index could not be reached
#   3  the token was refused (the cache is dropped)
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
    rm -f -- "$TOKEN_CACHE"
    FAILURE="The Index refused the cached token (HTTP 401). The cache is dropped, so the next tick mints a new one."
    return 3
  fi
  local protocol="This router posts a bare tools/call with no initialize and no session, and expects a plain JSON reply. The Index's MCP server has accepted that so far. If it now needs a session or streams its replies, the router must change."
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

# ── The summary ──────────────────────────────────────────────────────────────

ACTIONS=()
# Cleared when any list call does not return an items list, so `tick ok` is
# never printed for a tick in which a lane could not list.
LISTED_ALL=1
DISPATCHED=0; REPRIEVED=0; SKIPPED=0; ESCALATED=0

action() { ACTIONS+=("$1"); }

summary() {
  local line
  if [ ${#ACTIONS[@]} -eq 0 ]; then
    echo "idle — nothing to dispatch"
    return
  fi
  for line in "${ACTIONS[@]}"; do printf '%s\n' "$line"; done
  echo "dispatched $DISPATCHED, reprieved $REPRIEVED, skipped $SKIPPED, escalated $ESCALATED across 3 lanes"
}

# Ends the tick early: the actions so far, then why.
stop() {
  summary
  printf '%s\n' "$1"
  exit "$2"
}

# The answer to a call that failed for a reason every later call shares.
# Returns when the failure was the tool's own, so the caller skips its lane.
fatal_unless_tool() {
  case "$1" in
    1) return 0 ;;
    2) stop "$UNREACHABLE" 0 ;;
    3) stop "$FAILURE" 0 ;;
    *) stop "dispatch-tick: $FAILURE" 1 ;;
  esac
}

# The label a line names an item by: its issue or pull request number and repo.
label() {
  printf '%s' "$1" | jq -r '"#\(.issue_number // .pr_number // "item \(.id)") (\(.repo // "unknown repo"))"'
}

# A project_items.id the dispatcher accepts: a positive integer. The Index is
# trusted, but an id goes on a command line, so its shape is checked anyway.
is_id() { case "$1" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }
# An owner/repo the dispatcher takes as a sweep target.
is_repo() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; }

# ── The escalation ───────────────────────────────────────────────────────────

# The escalation comment, from the checked-in template. The reason is quoted in
# a fenced block, since it is the dispatcher's own text, with any fence marker
# taken out so it cannot close the block. The budget paragraph stays only for a
# budget escalation.
render_comment() {
  local agent="$1" reason="$2" budget=0
  case "$reason" in *'USD budget'*) budget=1 ;; esac
  AGENT="$agent" REASON="$(printf '%s' "$reason" | tr '\n\r' '  ' | sed 's/~~~//g; s/```//g')" BUDGET="$budget" \
  BUDGET_ROW="${agent}MaxBudgetUsd" awk '
    /^<!-- budget -->$/   { inbudget = 1; next }
    /^<!-- \/budget -->$/ { inbudget = 0; next }
    /^<!--.*-->$/         { next }
    inbudget && ENVIRON["BUDGET"] != "1" { next }
    {
      line = $0
      gsub(/\{\{agent\}\}/, ENVIRON["AGENT"], line)
      gsub(/\{\{budget_row\}\}/, ENVIRON["BUDGET_ROW"], line)
      if (line == "{{reason}}") { print ENVIRON["REASON"]; next }
      print line
    }' "$TEMPLATE"
}

# escalate <agent> <item JSON> <reason>
escalate() {
  local agent="$1" item="$2" reason="$3" id lbl body moved=0 short rc
  id=$(printf '%s' "$item" | jq -r '.id')
  lbl=$(label "$item")
  case "$reason" in
    *'content filtering'*) short='content filter' ;;
    *'USD budget'*) short='budget cap' ;;
    *) short='repeated fatal error' ;;
  esac
  call move "$(jq -nc --arg agent "$agent" --argjson id "$id" '{agent: $agent, column: "Escalated", id: $id}')"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    moved=1
  else
    fatal_unless_tool "$rc"
    action "✗ escalation of $lbl failed — the move to Escalated was refused: $FAILURE"
  fi
  # The comment says the item was moved, so it is posted only after a move.
  if [ "$moved" = 1 ]; then
    body=$(render_comment "$agent" "$reason")
    if [ -z "$body" ]; then
      action "✗ escalation comment for $lbl not posted — the template at $TEMPLATE could not be read"
    else
      call add_comment "$(jq -nc --arg agent "$agent" --argjson id "$id" --arg body "$body" '{agent: $agent, id: $id, body: $body}')"
      rc=$?
      [ "$rc" -eq 0 ] || { fatal_unless_tool "$rc"; action "✗ escalation comment for $lbl not posted: $FAILURE"; }
    fi
    # Only a real escalation is recorded, so only it can be reprieved.
    bash "$DISPATCHER" --mark-escalated "$agent" "$id" >/dev/null 2>&1 \
      || action "✗ could not record the escalation of $lbl, so moving it back will not raise its budget"
    ESCALATED=$((ESCALATED + 1))
    action "⛔ escalated $lbl — $short"
  fi
  # An escalated item has left its lane, and a claim left behind would hide it
  # from list_development_items once a human moves it back.
  call release_item "$(jq -nc --argjson id "$id" '{id: $id}')"
  rc=$?
  [ "$rc" -eq 0 ] || { fatal_unless_tool "$rc"; action "✗ could not release the claim on $lbl: $FAILURE"; }
}

# ── Dispatching ──────────────────────────────────────────────────────────────

# dispatch <lane> <agent> <item JSON>: one item, acted on by the first line.
dispatch() {
  local lane="$1" agent="$2" item="$3" id lbl out rc first
  id=$(printf '%s' "$item" | jq -r '.id // empty')
  lbl=$(label "$item")
  if ! is_id "$id"; then
    action "✗ $agent $lbl skipped — lane $lane returned an id that is not a positive integer"
    return
  fi
  out=$(bash "$DISPATCHER" "$agent" "$id" 2>&1)
  rc=$?
  first=$(printf '%s\n' "$out" | head -1)
  if [ "$rc" -ne 0 ]; then
    action "✗ $agent $lbl — the dispatcher exited $rc in lane $lane: $first"
    return
  fi
  case "$first" in
    "dispatched $agent "*) DISPATCHED=$((DISPATCHED + 1)); action "→ $agent $lbl" ;;
    SKIP$'\t'*) SKIPPED=$((SKIPPED + 1)); action "⏸ skipped $lbl — run still alive" ;;
    REPRIEVE$'\t'*) REPRIEVED=$((REPRIEVED + 1)); action "♻️ reprieved $lbl — human re-activated, raised budget" ;;
    ESCALATE$'\t'*) escalate "$agent" "$item" "${first#ESCALATE$'\t'}" ;;
    *) action "✗ $agent $lbl — the dispatcher's first line was not one this router knows, in lane $lane: $first" ;;
  esac
}

# sweep <owner/repo>: one Lestrade blocker sweep. No pre-flight runs for it.
sweep() {
  local repo="$1" out rc
  if ! is_repo "$repo"; then
    action "✗ lestrade sweep skipped — lane 1 returned a repo that is not owner/name: $repo"
    return
  fi
  out=$(bash "$DISPATCHER" lestrade "$repo" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && case "$(printf '%s\n' "$out" | head -1)" in "dispatched lestrade "*) true ;; *) false ;; esac; then
    DISPATCHED=$((DISPATCHED + 1))
    action "→ lestrade sweep ($repo)"
  else
    action "✗ lestrade sweep ($repo) — the dispatcher exited $rc in lane 1: $(printf '%s\n' "$out" | head -1)"
  fi
}

# list <lane> <tool> <arguments>: sets ITEMS to the lane's items, one compact
# JSON object per line. A tool failure logs and returns 1 so the lane is skipped.
list() {
  local lane="$1" tool="$2" rc
  ITEMS=
  call "$tool" "$3"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fatal_unless_tool "$rc"
    LISTED_ALL=0
    action "✗ lane $lane: $tool failed, so the lane is skipped this tick: $FAILURE"
    return 1
  fi
  if [ "$(printf '%s' "$RESULT" | jq -r '.items | type' 2>/dev/null)" != array ]; then
    LISTED_ALL=0
    action "✗ lane $lane: $tool answered with no items list, so the lane is skipped this tick"
    return 1
  fi
  ITEMS=$(printf '%s' "$RESULT" | jq -c '.items[] | objects')
  return 0
}

# ── Lane 1: Inspector Lestrade (triage) ──────────────────────────────────────

if list 1 list_unrefined_items '{}'; then
  while IFS= read -r item; do
    [ -n "$item" ] && dispatch 1 lestrade "$item"
  done <<< "$ITEMS"
  # One sweep per distinct repo across the items the lane returned. An idle
  # lane sweeps nothing.
  while IFS= read -r repo; do
    [ -n "$repo" ] && sweep "$repo"
  done < <(printf '%s\n' "$ITEMS" | jq -r '.repo // empty' 2>/dev/null | awk '!seen[$0]++')
fi

# ── Lane 2: Sherlock Holmes (review) ─────────────────────────────────────────

if list 2 list_review_items '{}'; then
  while IFS= read -r item; do
    [ -n "$item" ] && dispatch 2 holmes "$item"
  done <<< "$ITEMS"
fi

# ── Lane 3: Dr. Watson (development) ─────────────────────────────────────────

# The stale-claim sweep. A Watson killed outright never reaches its own
# cleanup, so its claim outlives it and would hide the item forever.
if list 3 list_development_items '{"include_claimed": true, "limit": 25}'; then
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ "$(printf '%s' "$item" | jq -r '.in_flight_at // empty')" != "" ] || continue
    id=$(printf '%s' "$item" | jq -r '.id // empty')
    is_id "$id" || continue
    verdict=$(bash "$DISPATCHER" --check watson "$id" 2>/dev/null)
    vrc=$?
    # A check that could not run says nothing about the run, so the claim stays.
    [ "$vrc" -eq 0 ] && [ -n "$verdict" ] || { action "✗ claim check on $(label "$item") failed (exit $vrc), so the claim stays"; continue; }
    case "$verdict" in SKIP*) continue ;; esac
    call release_item "$(jq -nc --argjson id "$id" '{id: $id}')"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      action "↺ released the stale claim on $(label "$item") — its run is not alive"
    else
      fatal_unless_tool "$rc"
      action "✗ could not release the stale claim on $(label "$item"): $FAILURE"
    fi
  done <<< "$ITEMS"
fi

if list 3 list_development_items '{"limit": 1}'; then
  item=$(printf '%s\n' "$ITEMS" | head -1)
  [ -n "$item" ] && dispatch 3 watson "$item"
fi

summary
# The last line, printed only when every list call returned an items list:
# stop() exits before it, so does every early exit above, and a lane that
# could not list clears LISTED_ALL. Setup's proof step reads it, because a
# failed tick can still print the idle line before its reason. A tick that
# skipped a lane says so instead, and setup reads that as a failure.
if [ "$LISTED_ALL" = 1 ]; then
  echo "tick ok $TICK_START"
else
  echo "tick incomplete $TICK_START — a lane could not list, see the lines above"
fi
exit 0
