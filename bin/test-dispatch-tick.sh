#!/usr/bin/env bash
# Test for bin/dispatch-tick.sh.
#
# Runs the real tick against tests/fake-index.py, a local HTTP server that
# answers as The Index's MCP endpoint and token endpoint do. Nothing reaches the
# real Index, the real Keychain, or a real agent:
#   - `security` is a stub on PATH that answers fixed fake credentials
#   - the dispatcher is a stub that prints scripted first lines
#   - `claude` is a stub on PATH that records any call, to prove a tick makes none
#   - `curl` is a shim on PATH that records its arguments, then runs the real
#     curl, to prove no secret ever reaches a command line
#
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

mkdir -p "$WORK/home" "$WORK/stub" "$WORK/plan"
export HOME="$WORK/home"
LOG="$WORK/index.log"
CACHE="$WORK/home/token.json"
SECRET='s3cret-"quoted"\back'
CLIENT='client-42'

# ── Stubs ────────────────────────────────────────────────────────────────────

cat > "$WORK/stub/security" <<'EOF'
#!/usr/bin/env bash
# Answers find-generic-password for the-index-mcp from FAKE_* variables.
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

# The dispatcher stub. Its answer to `<agent> <target>` is the file
# plan/<agent>-<target> (a slash in the target read as _), and its exit code
# plan/<…>.rc. With no file it prints a normal dispatched line, and --check
# prints DISPATCH. Every call is appended to the Index log, so the order of
# board writes and dispatcher calls reads from one file.
cat > "$WORK/dispatcher.sh" <<EOF
#!/usr/bin/env bash
printf '{"dispatcher":"%s"}\n' "\$*" >> "$LOG"
case "\$1" in
  --check) key="check-\$3"; default=DISPATCH ;;
  --mark-escalated) echo "marked \$2-\$3 escalated"; exit 0 ;;
  *) key="\$1-\$(printf '%s' "\$2" | tr / _)"; default="dispatched \$1 pid=1 log=/x" ;;
esac
if [ -f "$WORK/plan/\$key" ]; then cat "$WORK/plan/\$key"; else echo "\$default"; fi
exit "\$(cat "$WORK/plan/\$key.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$WORK/stub/"* "$WORK/dispatcher.sh"

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

# reset <scenario JSON>: a fresh log and plan, and the scenario in place.
reset() {
  : > "$LOG"; : > "$WORK/curl.argv"; rm -f "$WORK/claude.calls" "$WORK/plan/"*
  printf '%s' "$1" > "$WORK/scenario.json"
}

# plan <key> <output> [exit code]
plan() { printf '%s\n' "$2" > "$WORK/plan/$1"; [ -n "${3:-}" ] && printf '%s' "$3" > "$WORK/plan/$1.rc"; return 0; }

# tick [url]: one run of the real tick. Sets OUT (stdout and stderr) and RC.
tick() {
  OUT=$(DISPATCH_INDEX_URL="${1:-$URL}/mcp" DISPATCH_TOKEN_URL="${1:-$URL}/oauth/token" \
    DISPATCH_TOKEN_CACHE="$CACHE" DISPATCH_AGENT="$WORK/dispatcher.sh" \
    FAKE_CLIENT_ID="${FAKE_CLIENT_ID-$CLIENT}" FAKE_CLIENT_SECRET="${FAKE_CLIENT_SECRET-$SECRET}" \
    PATH="$WORK/stub:$PATH" bash "$SCRIPT" 2>&1)
  RC=$?
}

# The tools/call requests the tick made, one `<name> <arguments>` per line.
calls() { jq -r 'select(.body) | "\(.body.params.name) \(.body.params.arguments | tojson)"' "$LOG"; }
# Every line in the log, board calls and dispatcher calls in order.
trail() { jq -r 'if .dispatcher then "dispatcher \(.dispatcher)" elif .body then "\(.body.params.name) \(.body.params.arguments | tojson)" else "mint" end' "$LOG"; }
mints() { jq -r 'select(.path == "/oauth/token") | "mint"' "$LOG" | wc -l | tr -d ' '; }
items() { jq -nc --argjson items "$1" '{result: {count: ($items | length), items: $items}}'; }
item()  { jq -nc --argjson id "$1" --argjson n "$2" --arg repo "$3" --arg flight "${4:-}" \
            '{id: $id, issue_number: $n, repo: $repo, in_flight_at: (if $flight == "" then null else $flight end)}'; }

VALID='"valid_tokens": ["tok-1"]'

# ── The idle tick ────────────────────────────────────────────────────────────
echo "— an idle tick"
seed_cache
reset "{$VALID}"
tick
expect_eq   "exit 0" 0 "$RC"
expect_has  "prints idle" "idle — nothing to dispatch" "$OUT"
expect_lacks "prints no counts line when idle" "across 3 lanes" "$OUT"
expect_eq   "polls the three lanes, the stale-claim sweep included, and nothing else" \
"list_unrefined_items {}
list_review_items {}
list_development_items {\"include_claimed\":true,\"limit\":25}
list_development_items {\"limit\":1}" "$(calls)"
expect_eq   "no dispatcher call" "" "$(trail | grep '^dispatcher' || true)"
expect_eq   "no claude call: an idle tick runs no model" "" "$(cat "$WORK/claude.calls" 2>/dev/null)"
expect_eq   "the cached token is used, no mint" 0 "$(mints)"
expect_has "a clean tick ends with its tick ok line" "tick ok " "$(printf '%s\n' "$OUT" | tail -1)"
expect_eq   "every call is a bare tools/call, with no initialize and no session" \
  "tools/call" "$(jq -r 'select(.body) | .body.method' "$LOG" | sort -u)"

# ── Lane 1 ───────────────────────────────────────────────────────────────────
echo "— lane 1: lestrade per item, then one sweep per distinct repo"
reset "{$VALID, \"tools\": {\"list_unrefined_items\": $(items "[$(item 11 101 o/a), $(item 12 102 o/b), $(item 13 103 o/a)]")}}"
tick
expect_eq "lestrade on each item by its project_items.id, then a sweep per distinct repo, in order" \
"dispatcher lestrade 11
dispatcher lestrade 12
dispatcher lestrade 13
dispatcher lestrade o/a
dispatcher lestrade o/b" "$(trail | grep '^dispatcher')"
expect_has "a dispatch line names the issue and repo" "→ lestrade #101 (o/a)" "$OUT"
expect_has "a sweep line" "→ lestrade sweep (o/b)" "$OUT"
expect_has "the counts line counts the sweeps as dispatches" "dispatched 5, reprieved 0, skipped 0, escalated 0 across 3 lanes" "$OUT"
expect_eq "no claude call" "" "$(cat "$WORK/claude.calls" 2>/dev/null)"

echo "— lane 1: a sweep target that is not owner/name is never passed on"
reset "{$VALID, \"tools\": {\"list_unrefined_items\": $(items "[$(item 14 104 'o/a;rm')]")}}"
tick
expect_eq "only the item dispatch reached the dispatcher" "dispatcher lestrade 14" "$(trail | grep '^dispatcher')"
expect_has "the bad repo is logged" "is not owner/name" "$OUT"

# ── Lane 2 ───────────────────────────────────────────────────────────────────
echo "— lane 2: holmes per item"
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 21 201 o/r), $(item 22 202 o/r)]")}}"
tick
expect_eq "holmes on each item" "dispatcher holmes 21
dispatcher holmes 22" "$(trail | grep '^dispatcher')"
expect_has "a holmes line" "→ holmes #202 (o/r)" "$OUT"
expect_lacks "no sweep for lane 2" "sweep" "$OUT"

# ── Lane 3 ───────────────────────────────────────────────────────────────────
echo "— lane 3: the stale-claim sweep"
reset "{$VALID, \"tools\": {\"list_development_items#claimed\": $(items "[$(item 31 301 o/w 2026-10-08T01:00:00Z), $(item 32 302 o/w 2026-10-08T02:00:00Z), $(item 33 303 o/w)]")}}"
plan check-31 "SKIP	a run dispatched on this item is still alive (pid 9)"
tick
expect_eq "each claimed item is checked, the unclaimed one is not" \
"dispatcher --check watson 31
dispatcher --check watson 32" "$(trail | grep '^dispatcher')"
expect_eq "only the dead owner's claim is released" 'release_item {"id":32}' "$(calls | grep '^release_item')"
expect_has "the release is logged" "↺ released the stale claim on #302 (o/w)" "$OUT"
expect_lacks "a live run's claim stays" "#301" "$OUT"

echo "— lane 3: a check that cannot run keeps the claim"
reset "{$VALID, \"tools\": {\"list_development_items#claimed\": $(items "[$(item 34 304 o/w 2026-10-08T01:00:00Z)]")}}"
plan check-34 "usage: …" 2
tick
expect_eq "no release" "" "$(calls | grep '^release_item' || true)"
expect_has "the failed check is logged" "claim check on #304 (o/w) failed (exit 2)" "$OUT"

echo "— lane 3: one Watson per tick"
reset "{$VALID, \"tools\": {\"list_development_items\": $(items "[$(item 35 305 o/w), $(item 36 306 o/w)]")}}"
tick
expect_eq "the pick asks for one item" 'list_development_items {"limit":1}' "$(calls | grep '"limit":1}' )"
expect_eq "only the first item is dispatched, even if more come back" "dispatcher watson 35" "$(trail | grep '^dispatcher')"
expect_has "a watson line" "→ watson #305 (o/w)" "$OUT"

# ── The dispatcher's first line ──────────────────────────────────────────────
echo "— first lines: SKIP, REPRIEVE, and one this router does not know"
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 41 401 o/r), $(item 42 402 o/r), $(item 43 403 o/r)]")}}"
plan holmes-41 "SKIP	a run dispatched on this item is still alive (pid 7)"
plan holmes-42 "REPRIEVE	human re-activated a previously-escalated item
dispatched holmes pid=8 log=/x"
plan holmes-43 "Something else"
tick
expect_has "SKIP is a skip" "⏸ skipped #401 (o/r) — run still alive" "$OUT"
expect_has "REPRIEVE is a reprieve" "♻️ reprieved #402 (o/r) — human re-activated, raised budget" "$OUT"
expect_has "an unknown first line is logged, not counted" "the dispatcher's first line was not one this router knows, in lane 2: Something else" "$OUT"
expect_has "counts" "dispatched 0, reprieved 1, skipped 1, escalated 0 across 3 lanes" "$OUT"
expect_eq "no board write follows SKIP, REPRIEVE or an unknown line" "" "$(calls | grep -v '^list_' || true)"

echo "— a dispatcher that exits non-zero is logged, and the lane goes on"
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 44 404 o/r), $(item 45 405 o/r)]")}}"
plan holmes-44 "dispatch-agent.sh: could not create a run folder" 1
tick
expect_has "the exit code and the lane are logged" "✗ holmes #404 (o/r) — the dispatcher exited 1 in lane 2: dispatch-agent.sh: could not create a run folder" "$OUT"
expect_has "the next item still goes" "→ holmes #405 (o/r)" "$OUT"
expect_eq "exit 0" 0 "$RC"

echo "— an id that is not a positive integer is never passed on"
reset "{$VALID, \"tools\": {\"list_review_items\": {\"result\": {\"items\": [{\"id\": \"5; rm\", \"issue_number\": 9, \"repo\": \"o/r\"}, {\"id\": 0, \"repo\": \"o/r\"}]}}}}"
tick
expect_eq "no dispatcher call" "" "$(trail | grep '^dispatcher' || true)"
expect_has "logged" "returned an id that is not a positive integer" "$OUT"

# ── The escalation ───────────────────────────────────────────────────────────
echo "— ESCALATE: move, comment, mark, release, in that order"
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 51 501 o/r)]")}}"
plan holmes-51 "ESCALATE	3 consecutive runs died with the same fatal error: API Error: 500 ~~~ boom"
tick
expect_eq "the sequence" \
'dispatcher holmes 51
move {"agent":"holmes","column":"Escalated","id":51}
add_comment
dispatcher --mark-escalated holmes 51
release_item {"id":51}' "$(trail | grep -v '^list_' | sed 's/^add_comment .*/add_comment/')"
BODY=$(jq -r 'select(.body.params.name == "add_comment") | .body.params.arguments.body' "$LOG")
expect_has "the comment names the agent" "stopped the holmes runs on this item" "$BODY"
expect_has "the comment quotes the reason in a fenced block, with its fence marker taken out" \
$'~~~text\n3 consecutive runs died with the same fatal error: API Error: 500  boom\n~~~' "$BODY"
expect_has "the comment says how to re-run it" "move the item back to its lane" "$BODY"
expect_lacks "a non-budget escalation has no budget paragraph" "budget cap" "$BODY"
expect_lacks "no template comment reaches the board" "<!--" "$BODY"
expect_lacks "no placeholder is left" "{{" "$BODY"
expect_has "the line" "⛔ escalated #501 (o/r) — repeated fatal error" "$OUT"
expect_has "counts" "dispatched 0, reprieved 0, skipped 0, escalated 1 across 3 lanes" "$OUT"

echo "— ESCALATE for the budget: the comment names the budget setting"
reset "{$VALID, \"tools\": {\"list_development_items\": $(items "[$(item 52 502 o/w)]")}}"
plan watson-52 "ESCALATE	3 consecutive runs were killed by the USD budget cap without reaching review"
tick
BODY=$(jq -r 'select(.body.params.name == "add_comment") | .body.params.arguments.body' "$LOG")
expect_has "the budget paragraph names the agent's row" 'raise the `watsonMaxBudgetUsd` setting' "$BODY"
expect_has "the short reason" "⛔ escalated #502 (o/w) — budget cap" "$OUT"
expect_eq "the comment is signed by the agent that was stopped" "watson" "$(jq -r 'select(.body.params.name == "add_comment") | .body.params.arguments.agent' "$LOG")"

echo "— ESCALATE whose move fails: no comment and no mark, the claim still released"
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 53 503 o/r)]"), \"move\": {\"isError\": \"GitHub refused the move\"}}}"
plan holmes-53 "ESCALATE	output blocked by the content filtering policy"
tick
expect_eq "move, then release, and nothing between" \
'dispatcher holmes 53
move {"agent":"holmes","column":"Escalated","id":53}
release_item {"id":53}' "$(trail | grep -v '^list_')"
expect_has "the failure is logged" "✗ escalation of #503 (o/r) failed — the move to Escalated was refused: GitHub refused the move" "$OUT"
expect_lacks "not counted as an escalation" "escalated 1" "$OUT"

echo "— ESCALATE whose comment fails still marks and releases"
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 54 504 o/r)]"), \"add_comment\": {\"isError\": \"comment refused\"}}}"
plan holmes-54 "ESCALATE	output blocked by the content filtering policy"
tick
expect_has "marked" "dispatcher --mark-escalated holmes 54" "$(trail)"
expect_has "released" 'release_item {"id":54}' "$(trail)"
expect_has "the comment failure is logged" "escalation comment for #504 (o/r) not posted: comment refused" "$OUT"
expect_has "the short reason" "— content filter" "$OUT"

echo "— every escalation comment the tick posts passes the comms-style check"
CHECK="$HERE/../tests/comms-check.py"
# The check itself first, so a check that finds nothing cannot pass the comments.
for sample in \
  'The breaker stopped it — twice.' \
  'The breaker stopped it; then it moved.' \
  'See ~/Developer/scratchpad/notes for the reason.' \
  'Read bin/dispatch-agent.sh for the rule.' \
  'The breaker did not move it, it'"'"'s stuck.' \
  'The run cannot finish and we'"'"'re out of retries.' \
  'This is a robust fix.' \
  'One two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four twenty-five twenty-six.'
do
  if printf '%s\n' "$sample" | python3 "$CHECK" >/dev/null; then bad "the check passes bad prose: $sample"; else ok "the check catches: ${sample:0:40}"; fi
done
printf '%s\n' 'The reason stays in a fence.' '' '~~~text' 'a; b — c ~/x.md' '~~~' '' 'Set `a/b; c` in `/config`.' \
  | python3 "$CHECK" >/dev/null && ok "fenced and inline code are left out" || bad "the check reads code as prose"
reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 91 901 o/r), $(item 92 902 o/r), $(item 93 903 o/r)]")}}"
plan holmes-91 "ESCALATE	output blocked by the content filtering policy — a required deliverable trips the output content filter; no retry helps"
plan holmes-92 "ESCALATE	the run hit the configured USD budget cap before completing — raise holmesMaxBudgetUsd"
plan holmes-93 "ESCALATE	3 consecutive runs died with the same fatal error: Error: ~/x.md; boom"
tick
expect_eq "three comments posted" 3 "$(jq -r 'select(.body.params.name == "add_comment") | .body.params.arguments.id' "$LOG" | wc -l | tr -d ' ')"
while IFS= read -r body; do
  body=$(printf '%s' "$body" | jq -r .)
  found=$(printf '%s\n' "$body" | python3 "$CHECK")
  expect_eq "comms-style clean: $(printf '%s' "$body" | grep -o 'content filtering\|USD budget\|fatal error' | head -1)" "" "$found"
done < <(jq -c 'select(.body.params.name == "add_comment") | .body.params.arguments.body' "$LOG")

# A direct render, outside any tick, through the script's own render_comment,
# lifted out of it unchanged. The reason is neutral and plain, so every finding
# comes from the template's own prose, and both the plain and the budget
# variants are read, so a slip in any part of the template fails here even
# when no tick fixture reaches it.
RENDER="$WORK/render.sh"
sed -n '/^render_comment() {/,/^}/p' "$SCRIPT" > "$RENDER"
if [ ! -s "$RENDER" ]; then
  bad "could not lift render_comment out of $SCRIPT"
else
  for reason in 'The runs stopped early' 'The runs hit the USD budget cap'; do
    direct=$(TEMPLATE="$HERE/escalation-comment.md" bash -c '. "$1"; render_comment watson "$2"' _ "$RENDER" "$reason")
    expect_eq "direct render ($reason): comms-style clean" "" "$(printf '%s\n' "$direct" | python3 "$CHECK")"
    expect_lacks "direct render ($reason): no placeholder left" "{{" "$direct"
    expect_lacks "direct render ($reason): no template comment left" "<!--" "$direct"
    expect_has "direct render ($reason): the reason is in it" "$reason" "$direct"
  done
  expect_has "the budget render carries the budget paragraph" 'raise the `watsonMaxBudgetUsd` setting' \
    "$(TEMPLATE="$HERE/escalation-comment.md" bash -c '. "$1"; render_comment watson "$2"' _ "$RENDER" 'The runs hit the USD budget cap')"
fi

# ── Lane failures ────────────────────────────────────────────────────────────
echo "— a list that fails skips its lane only"
reset "{$VALID, \"tools\": {\"list_review_items\": {\"isError\": \"GraphQL timeout\"}, \"list_unrefined_items\": $(items "[$(item 61 601 o/a)]"), \"list_development_items\": $(items "[$(item 62 602 o/w)]")}}"
tick
expect_has "the failed lane is logged" "✗ lane 2: list_review_items failed, so the lane is skipped this tick: GraphQL timeout" "$OUT"
expect_lacks "a tick with a failed lane prints no tick ok line" "tick ok " "$OUT"
expect_has "it ends by saying a lane could not list" "tick incomplete " "$(printf '%s\n' "$OUT" | tail -1)"
expect_has "lane 1 still runs" "→ lestrade #601 (o/a)" "$OUT"
expect_has "lane 3 still runs" "→ watson #602 (o/w)" "$OUT"
expect_eq "exit 0" 0 "$RC"

echo "— a list with no items array skips its lane"
reset "{$VALID, \"tools\": {\"list_review_items\": {\"result\": {\"count\": 0}}}}"
tick
expect_has "logged" "list_review_items answered with no items list" "$OUT"
expect_lacks "a tick whose lane had no items list prints no tick ok line" "tick ok " "$OUT"

echo "— The Index unreachable"
reset "{$VALID}"
tick "http://127.0.0.1:9"
expect_has "the skip line" "the-index unreachable — skipping this tick" "$OUT"
expect_eq "exit 0" 0 "$RC"
expect_eq "no dispatcher call" "" "$(trail | grep '^dispatcher' || true)"

echo "— a 5xx reads as unreachable, and stops the tick"
reset "{$VALID, \"tools\": {\"list_unrefined_items\": {\"status\": 502, \"raw\": \"bad gateway\"}}}"
tick
expect_has "the skip line" "the-index unreachable — skipping this tick" "$OUT"
expect_eq "no other lane is polled" "list_unrefined_items {}" "$(calls)"

echo "— a stateless-protocol failure is named, and stops the tick"
for case in \
  'JSON-RPC error|{"rpcError": {"code": -32600, "message": "Missing Mcp-Session-Id"}}|JSON-RPC error -32600: Missing Mcp-Session-Id' \
  'HTTP 400|{"status": 400, "raw": "{\"message\": \"Bad Request\"}"}|answered list_unrefined_items with HTTP 400' \
  'a streamed reply|{"status": 200, "raw": "event: message\ndata: {}", "contentType": "text/event-stream"}|a body that is not a JSON-RPC reply'
do
  IFS='|' read -r label answer needle <<< "$case"
  reset "{$VALID, \"tools\": {\"list_unrefined_items\": $answer}}"
  tick
  expect_has "$label: names the failure" "$needle" "$OUT"
  expect_has "$label: names the stateless call as the likely cause" "no initialize and no session" "$OUT"
  expect_eq "$label: exit 1" 1 "$RC"
  expect_eq "$label: no further call" "list_unrefined_items {}" "$(calls)"
done

echo "— lines already acted on still print when the tick stops"
reset "{$VALID, \"tools\": {\"list_unrefined_items\": $(items "[$(item 71 701 o/a)]"), \"list_review_items\": {\"rpcError\": {\"code\": -32601, \"message\": \"Method not found\"}}}}"
tick
expect_has "the lane 1 dispatch" "→ lestrade #701 (o/a)" "$OUT"
expect_has "then the failure" "JSON-RPC error -32601" "$OUT"

# ── The token ────────────────────────────────────────────────────────────────
echo "— no cache: one mint, then the cache is used"
rm -f "$CACHE"
reset "{$VALID}"
tick
expect_eq "one mint" 1 "$(mints)"
expect_eq "the mint is a client_credentials grant for the Keychain client" \
  "client_credentials $CLIENT index.mcp.read index.mcp.write" \
  "$(jq -r 'select(.form) | "\(.form.grant_type) \(.form.client_id) \(.form.scope)"' "$LOG")"
expect_eq "the secret reaches The Index intact" "$SECRET" "$(jq -r 'select(.form) | .form.client_secret' "$LOG")"
expect_eq "the minted token is the one sent" "Bearer tok-1" "$(jq -r 'select(.body) | .auth' "$LOG" | sort -u)"
expect_eq "the cache holds the token" "tok-1" "$(jq -r .access_token "$CACHE")"
expect_eq "the cache is readable by the user alone" "600" "$(stat -f %Lp "$CACHE" 2>/dev/null || stat -c %a "$CACHE")"
LEFT=$(( $(jq -r .expires_at "$CACHE") - $(date +%s) ))
[ "$LEFT" -gt 31535000 ] && [ "$LEFT" -le 31536000 ] && ok "the expiry is expires_in from now" || bad "the expiry is $LEFT seconds away"
: > "$LOG"
tick
expect_eq "a second tick mints nothing" 0 "$(mints)"
expect_eq "and still calls the lanes" 4 "$(calls | wc -l | tr -d ' ')"

echo "— an expired cache, or one inside the margin, mints"
seed_cache -10
reset "{$VALID}"
tick
expect_eq "expired: one mint" 1 "$(mints)"
seed_cache 600
reset "{$VALID}"
tick
expect_eq "ten minutes left: one mint" 1 "$(mints)"
printf 'not json' > "$CACHE"
reset "{$VALID}"
tick
expect_eq "unreadable: one mint" 1 "$(mints)"

echo "— a token reply with no expires_in is cached for a day"
rm -f "$CACHE"
reset "{$VALID, \"token\": {\"status\": 200, \"body\": {\"access_token\": \"tok-1\"}}}"
tick
LEFT=$(( $(jq -r .expires_at "$CACHE") - $(date +%s) ))
[ "$LEFT" -gt 86000 ] && [ "$LEFT" -le 86400 ] && ok "cached for a day" || bad "cached for $LEFT seconds"

echo "— a 401 drops the cache and stops the tick, and the next tick mints once"
printf '{"access_token":"tok-revoked","expires_at":%s}' "$(( $(date +%s) + 86400 ))" > "$CACHE"
reset "{$VALID}"
tick
expect_has "the refusal is named" "refused the cached token (HTTP 401)" "$OUT"
expect_eq "no mint in that tick" 0 "$(mints)"
[ -f "$CACHE" ] && bad "the cache is still there" || ok "the cache is dropped"
expect_eq "no further call" "list_unrefined_items {}" "$(calls)"
: > "$LOG"
tick
expect_eq "the next tick mints once" 1 "$(mints)"
expect_has "and runs" "idle — nothing to dispatch" "$OUT"

echo "— missing Keychain credentials"
rm -f "$CACHE"
reset "{$VALID}"
FAKE_CLIENT_SECRET='' tick
expect_has "named" "the Keychain has no the-index-mcp client-id or client-secret" "$OUT"
expect_eq "exit 1" 1 "$RC"
expect_eq "no request at all" "" "$(cat "$LOG")"

echo "— a refused token request does not print the reply"
rm -f "$CACHE"
reset "{$VALID, \"token\": {\"status\": 401, \"body\": {\"error\": \"invalid_client\", \"echo\": \"$CLIENT\"}}}"
tick
expect_has "named" "refused the token request (HTTP 401)" "$OUT"
expect_lacks "the reply body is not printed" "invalid_client" "$OUT"
expect_eq "exit 1" 1 "$RC"
[ -f "$CACHE" ] && bad "a cache was written" || ok "no cache written"

echo "— the token endpoint unreachable"
rm -f "$CACHE"
reset "{$VALID}"
tick "http://127.0.0.1:9"
expect_has "the skip line" "the-index unreachable — skipping this tick" "$OUT"
expect_eq "exit 0" 0 "$RC"

echo "— no secret is printed or put on a command line"
rm -f "$CACHE"
reset "{$VALID, \"tools\": {\"list_development_items\": $(items "[$(item 81 801 o/w)]")}}"
plan watson-81 "ESCALATE	output blocked by the content filtering policy"
tick
ARGV=$(cat "$WORK/curl.argv")
expect_eq "curl ran for the mint and every call" 8 "$(wc -l < "$WORK/curl.argv" | tr -d ' ')"
expect_lacks "no client secret on curl's command line" "s3cret" "$ARGV"
expect_lacks "no bearer token on curl's command line" "tok-1" "$ARGV"
expect_lacks "no client secret in the output" "s3cret" "$OUT"
expect_lacks "no token in the output" "tok-1" "$OUT"

# ── Setup's proof step, against this tick's real output ─────────────────────
# Setup Step 7c-bis kickstarts the job and passes only a tick whose own last
# line, `tick ok <start time>`, reaches the log. Here launchctl is a stub whose
# kickstart runs this real tick against the fake Index and appends its output
# to the log, as launchd would. So every failure path is the tick's own output,
# idle line and all, never a fixture of it.
echo "— setup's proof step passes a clean tick and no other"
PROVE="$WORK/launchd-prove.sh"
awk '/# >>> launchd-prove >>>/{f=1;next} /# <<< launchd-prove <<</{f=0} f' "$HERE/../commands/setup.md" > "$PROVE"
LSTUB="$WORK/lstub"; mkdir -p "$LSTUB"
cat > "$LSTUB/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  kickstart) bash "$SCRIPT" >> "\$HOME/.claude-workbench/dev-team-logs/dispatch-tick.log" 2>&1 ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$LSTUB/sleep"
chmod +x "$LSTUB/launchctl" "$LSTUB/sleep"
TICKLOG="$HOME/.claude-workbench/dev-team-logs/dispatch-tick.log"
# proof [url]: the real proof block, with a job file in LaunchAgents, no proven
# set, and an empty bin.before snapshot, as on a first install. Sets OUT and RC.
proof() {
  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$TICKLOG")" "$HOME/.claude-workbench/bin.before"
  printf 'JOB\n' > "$HOME/Library/LaunchAgents/dev.workbench.dev-team-dispatch.plist"
  : > "$HOME/.claude-workbench/bin.before/manifest"
  # Each case starts as a first install, with no proven set from the last one.
  rm -rf "$HOME/.claude-workbench/bin.proven"
  # 7b leaves the install marked unfinished, and 7c proves only such an install.
  printf 'installing\n' > "$HOME/.claude-workbench/dispatch-install.state"
  # The scripts a passed proof records as the proven set.
  mkdir -p "$HOME/.claude-workbench/bin"
  cp "$SCRIPT" "$HERE/dispatch-agent.sh" "$HERE/escalation-comment.md" "$HOME/.claude-workbench/bin/"
  OUT=$(DISPATCH_INDEX_URL="${1:-$URL}/mcp" DISPATCH_TOKEN_URL="${1:-$URL}/oauth/token" \
    DISPATCH_TOKEN_CACHE="$CACHE" DISPATCH_AGENT="$WORK/dispatcher.sh" \
    FAKE_CLIENT_ID="$CLIENT" FAKE_CLIENT_SECRET="$SECRET" \
    PATH="$LSTUB:$WORK/stub:$PATH" bash "$PROVE" 2>&1)
  RC=$?
}
if [ ! -s "$PROVE" ]; then
  bad "could not extract the launchd-prove block from commands/setup.md"
else
  seed_cache; reset "{$VALID}"; proof
  expect_eq "a clean idle tick passes" 0 "$RC"
  expect_eq "and records the scripts as the proven set" "yes" "$(cmp -s "$SCRIPT" "$HOME/.claude-workbench/bin.proven/dispatch-tick.sh" && echo yes)"
  expect_has "with its tick ok line" "tick ok " "$OUT"
  seed_cache; reset "{$VALID, \"tools\": {\"list_review_items\": $(items "[$(item 95 905 o/r)]")}}"; proof
  expect_eq "a clean busy tick passes" 0 "$RC"
  expect_has "with its dispatch" "→ holmes #905 (o/r)" "$OUT"
  # label | cache | scenario | url
  for case in \
    "unreachable, cached token|cached|{$VALID}|http://127.0.0.1:9" \
    "5xx, cached token|cached|{$VALID, \"tools\": {\"list_unrefined_items\": {\"status\": 503, \"raw\": \"down\"}}}|" \
    "401, cached token|revoked|{$VALID}|" \
    "protocol error, cached token|cached|{$VALID, \"tools\": {\"list_unrefined_items\": {\"rpcError\": {\"code\": -32600, \"message\": \"Missing session\"}}}}|" \
    "unreachable, no cache|none|{$VALID}|http://127.0.0.1:9" \
    "token endpoint 5xx, no cache|none|{$VALID, \"token\": {\"status\": 502, \"body\": {}}}|" \
    "token refused, no cache|none|{$VALID, \"token\": {\"status\": 401, \"body\": {}}}|" \
    "5xx after a mint|none|{$VALID, \"tools\": {\"list_unrefined_items\": {\"status\": 500, \"raw\": \"x\"}}}|" \
    "401 after a mint|none|{\"valid_tokens\": [\"another\"]}|" \
    "protocol error after a mint|none|{$VALID, \"tools\": {\"list_unrefined_items\": {\"status\": 400, \"raw\": \"{}\"}}}|" \
    "every list answers isError|cached|{$VALID, \"tools\": {\"list_unrefined_items\": {\"isError\": \"validation failed\"}, \"list_review_items\": {\"isError\": \"validation failed\"}, \"list_development_items\": {\"isError\": \"validation failed\"}}}|" \
    "every list answers with no items list|cached|{$VALID, \"tools\": {\"list_unrefined_items\": {\"result\": {\"data\": []}}, \"list_review_items\": {\"result\": {\"data\": []}}, \"list_development_items\": {\"result\": {\"data\": []}}}}|" \
    "one lane answers isError|cached|{$VALID, \"tools\": {\"list_review_items\": {\"isError\": \"not authorized\"}}}|" \
    "only the stale-claim list fails|cached|{$VALID, \"tools\": {\"list_development_items#claimed\": {\"result\": {\"data\": []}}}}|"
  do
    IFS='|' read -r label cache scenario url <<< "$case"
    case "$cache" in
      cached) seed_cache ;;
      revoked) printf '{"access_token":"tok-revoked","expires_at":%s}' "$(( $(date +%s) + 86400 ))" > "$CACHE" ;;
      none) rm -f "$CACHE" ;;
    esac
    reset "$scenario"
    proof "$url"
    expect_eq "$label: the proof fails" 1 "$RC"
    expect_lacks "$label: the tick wrote no tick ok line" "tick ok " "$OUT"
    expect_has "$label: and the job is rolled back" "This is a first install" "$OUT"
  done
  # The shape Holmes found, pinned: a cached-token failure prints the idle
  # line before its reason, and still fails the proof.
  seed_cache; reset "{$VALID}"; proof "http://127.0.0.1:9"
  expect_has "an unreachable tick with a cached token prints the idle line" "idle — nothing to dispatch" "$OUT"
  expect_eq "and still fails the proof" 1 "$RC"
fi

echo
echo "dispatch-tick: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
