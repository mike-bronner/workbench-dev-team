#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0
FAIL=0
CASE=0

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH, so the fallbacks cannot be tested"
  exit 1
fi
if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 18) ? 0 : 1)'; then
  echo "FAIL: node $(node --version) cannot strip TypeScript types; the fallbacks need 22.18 or later"
  exit 1
fi

echo "Node-process tier. Criteria:"
echo "  F1 SessionStart and SubagentStart send the module's own rules where the module would"
echo "  F2 SubagentStop holds and releases the turn end as the module's stopBlockOf does"
echo "  F3 a marker for this session keeps every fallback silent and inert, before any heavy module loads"
echo "  F4 hooks.json runs each fallback only with node on PATH, and always exits 0"
echo "  F5 the sweep deletes per-session files older than 7 days, and keeps newer ones"

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

fresh() {
  CASE=$((CASE + 1))
  SID="0f0e0d0c-1111-2222-3333-$(printf '%012d' "$CASE")"
  HOME_DIR="$SANDBOX/home-$CASE"
  mkdir -p "$HOME_DIR"
}

mark() { mkdir -p "$HOME_DIR/.claude-workbench/dev-team-mod-ran/$SID" && : > "$HOME_DIR/.claude-workbench/dev-team-mod-ran/$SID/$1"; }

run_in() {
  local root="$1" entry="$2" payload="$3"
  shift 3
  printf '%s' "$payload" | env -u WORKBENCH_SKIP_WARMUP HOME="$HOME_DIR" "$@" node "$root/hooks/fallback/$entry.ts" 2>"$SANDBOX/stderr"
}
run() { run_in "$ROOT" "$@"; }

module() { (cd "$ROOT" && node --input-type=module -e "$1" -- "${@:2}"); }

start_payload() { printf '{"session_id":"%s","source":"startup","hook_event_name":"SessionStart"}' "$SID"; }
agent_payload() { printf '{"session_id":"%s","agent_id":"a1","agent_type":"%s","hook_event_name":"SubagentStart"}' "$SID" "$1"; }
stop_payload() { printf '{"session_id":"%s","agent_id":"%s","agent_type":"workbench-dev-team:watson-direct","hook_event_name":"SubagentStop","stop_hook_active":false,"background_tasks":%s}' "$SID" "${2:-a1}" "${1:-[]}"; }

context_json() {
  module 'const { RULES } = await import("./hooks/mods/session-rules.ts"); process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: process.argv[1], additionalContext: RULES } }))' "$1"
}

SNAPSHOT_DIR() { printf '%s' "$HOME_DIR/.claude-workbench/dev-team-helper-wait/$SID"; }

write_snapshot() {
  module '
const { snapshotOf } = await import("./hooks/mods/helper-wait.ts")
const { waitFileOf } = await import("./hooks/mods/fallback.ts")
const { mkdirSync, writeFileSync } = await import("node:fs")
const [, home, sid, agents, started, activity] = process.argv
const file = waitFileOf(home, sid, "a1", "snapshot")
mkdirSync(file.slice(0, file.lastIndexOf("/")), { recursive: true })
const seen = JSON.parse(activity)
writeFileSync(file, JSON.stringify(snapshotOf("a1", JSON.parse(agents), JSON.parse(started), id => seen[id])))' "$HOME_DIR" "$SID" "$1" "$2" "$3"
}

expected_outputs() {
  module '
const { stopBlockOf } = await import("./hooks/mods/helper-wait.ts")
const [, agents, started, tasks, plan] = process.argv
const watches = new Map()
for (const call of JSON.parse(plan)) {
  const progress = { helper: id => call.activity[id], outputSize: path => call.sizes[path] }
  const block = stopBlockOf("a1", JSON.parse(agents), JSON.parse(started), JSON.parse(tasks), progress, watches)
  process.stdout.write(`${block === undefined ? "" : JSON.stringify({ decision: "block", reason: block })}\n`)
}' "$1" "$2" "$3" "$4"
}

plan_field() { module 'const [, plan, i, field] = process.argv; process.stdout.write(JSON.stringify(JSON.parse(plan)[Number(i)][field]))' "$1" "$2" "$3"; }
size_of() { module 'const [, sizes, path] = process.argv; process.stdout.write(String(JSON.parse(sizes)[path] ?? ""))' "$1" "$2"; }

stop_scenario() {
  local label="$1" agents="$2" started="$3" tasks="$4" plan="$5" count i expected actual sizes output size
  fresh
  expected="$(expected_outputs "$agents" "$started" "$tasks" "$plan")"
  count="$(module 'process.stdout.write(String(JSON.parse(process.argv[1]).length))' "$plan")"
  for ((i = 0; i < count; i++)); do
    write_snapshot "$agents" "$started" "$(plan_field "$plan" "$i" activity)"
    sizes="$(plan_field "$plan" "$i" sizes)"
    for output in "$SANDBOX/b1.output" "$SANDBOX/b2.output"; do
      size="$(size_of "$sizes" "$output")"
      rm -f "$output"
      [ -n "$size" ] && head -c "$size" /dev/zero > "$output"
    done
    actual="$(run subagent-stop "$(stop_payload "$tasks")")"
    check "node F2: $label, call $((i + 1))" "$actual" "$(printf '%s\n' "$expected" | sed -n "$((i + 1))p")"
  done
}

fresh
EXPECTED="$(context_json SessionStart)"
case "$EXPECTED" in *"## Development workflow"*"## Dev-team delegation"*) ok "node F1: the expected text comes from session-rules.ts" ;; *) bad "node F1: the expected text comes from session-rules.ts" "$EXPECTED" ;; esac
check "node F1: a session the module never marked gets the rules as SessionStart context" "$(run session-start "$(start_payload)")" "$EXPECTED"
check "node F1: a WORKBENCH_SKIP_WARMUP=1 session gets no rules" "$(run session-start "$(start_payload)" WORKBENCH_SKIP_WARMUP=1)" ""
check "node F1: another WORKBENCH_SKIP_WARMUP value still gets them" "$(run session-start "$(start_payload)" WORKBENCH_SKIP_WARMUP=0)" "$EXPECTED"
check "node F1: a payload with no session id prints nothing" "$(run session-start '{"source":"startup"}')" ""
check "node F1: a payload that is not JSON prints nothing" "$(run session-start 'not json')" ""
check "node F1: a session id that could name another folder prints nothing" "$(run session-start '{"session_id":"../x"}')" ""

EXPECTED="$(context_json SubagentStart)"
check "node F1: a general-purpose sub-agent gets the rules as SubagentStart context" "$(run subagent-start "$(agent_payload general-purpose)")" "$EXPECTED"
check "node F1: a dev-team sub-agent gets them too" "$(run subagent-start "$(agent_payload workbench-dev-team:watson-direct)")" "$EXPECTED"
check "node F1: a fork gets none" "$(run subagent-start "$(agent_payload fork)")" ""
OMITS="$(module 'const { OMITS_CLAUDE_MD } = await import("./hooks/mods/session-rules.ts"); process.stdout.write([...OMITS_CLAUDE_MD].join("\n"))')"
while IFS= read -r type; do
  check "node F1: $type, which leaves CLAUDE.md out, gets none" "$(run subagent-start "$(agent_payload "$type")")" ""
done <<< "$OMITS"
check "node F1: a WORKBENCH_SKIP_WARMUP=1 session gives its sub-agents none" "$(run subagent-start "$(agent_payload general-purpose)" WORKBENCH_SKIP_WARMUP=1)" ""
check "node F1: a payload with no agent type prints nothing" "$(run subagent-start "$(printf '{"session_id":"%s"}' "$SID")")" ""

HELPER='[{"id":"h1","type":"workbench-dev-team:holmes-lens","status":"running","parentId":"a1","description":"lens one"}]'
TWO='[{"id":"h1","type":"workbench-dev-team:holmes-lens","status":"running","parentId":"a1","description":"lens one"},{"id":"h2","type":"Explore","status":"pending","parentId":"a1","description":"lens two"},{"id":"x","type":"Explore","status":"running","parentId":"other","description":"not ours"}]'
STILL='{"activity":{"h1":{"ticks":3,"inFlight":0}},"sizes":{}}'
stop_scenario "a helper that makes no progress holds twice, is released and named, and then lets the turn end" "$HELPER" '[]' '[]' "[$STILL,$STILL,$STILL,$STILL]"
stop_scenario "a helper that keeps stepping holds every time" "$HELPER" '[]' '[]' \
  '[{"activity":{"h1":{"ticks":1,"inFlight":0}},"sizes":{}},{"activity":{"h1":{"ticks":2,"inFlight":0}},"sizes":{}},{"activity":{"h1":{"ticks":3,"inFlight":0}},"sizes":{}},{"activity":{"h1":{"ticks":4,"inFlight":0}},"sizes":{}}]'
stop_scenario "a helper with a request under way is never stuck" "$HELPER" '[]' '[]' \
  '[{"activity":{"h1":{"ticks":1,"inFlight":1}},"sizes":{}},{"activity":{"h1":{"ticks":1,"inFlight":1}},"sizes":{}},{"activity":{"h1":{"ticks":1,"inFlight":1}},"sizes":{}}]'
stop_scenario "two outstanding helpers are both named, and another agent's is not" "$TWO" '[]' '[]' '[{"activity":{},"sizes":{}}]'
stop_scenario "a finished helper holds nothing" '[{"id":"h1","type":"Explore","status":"completed","parentId":"a1","description":"done"}]' '[]' '[]' '[{"activity":{},"sizes":{}}]'
STARTED="[{\"id\":\"b1\",\"output\":\"$SANDBOX/b1.output\"}]"
TASK='[{"id":"b1","type":"shell","status":"running","description":"sleep 600","command":"sleep 600"}]'
stop_scenario "a background command whose output grows holds every time" '[]' "$STARTED" "$TASK" \
  "[{\"activity\":{},\"sizes\":{\"$SANDBOX/b1.output\":1}},{\"activity\":{},\"sizes\":{\"$SANDBOX/b1.output\":2}},{\"activity\":{},\"sizes\":{\"$SANDBOX/b1.output\":3}}]"
stop_scenario "a background command whose output stays the same is released after two holds" '[]' "$STARTED" "$TASK" \
  "[{\"activity\":{},\"sizes\":{\"$SANDBOX/b1.output\":5}},{\"activity\":{},\"sizes\":{\"$SANDBOX/b1.output\":5}},{\"activity\":{},\"sizes\":{\"$SANDBOX/b1.output\":5}},{\"activity\":{},\"sizes\":{\"$SANDBOX/b1.output\":5}}]"
stop_scenario "a background command that finished holds nothing" '[]' "$STARTED" '[]' '[{"activity":{},"sizes":{}}]'
stop_scenario "another loop's background command holds nothing" '[]' '[]' '[{"id":"b2","type":"shell","status":"running","description":"sleep 9","command":"sleep 9"}]' '[{"activity":{},"sizes":{}}]'

fresh
write_snapshot "$HELPER" '[]' '{}'
OUT="$(run subagent-stop "$(stop_payload)")"
case "$OUT" in *'"decision":"block"'*'🛑 Blocked: you cannot end your turn'*'- helper h1 (holmes-lens, running): lens one'*) ok "node F2: the hold is a block decision with the module's reason" ;; *) bad "node F2: the hold is a block decision with the module's reason" "$OUT" ;; esac

fresh
check "node F2: with no snapshot (no dev-team agent) the turn ends, and nothing is written" "$(run subagent-stop "$(stop_payload)")$([ -e "$(SNAPSHOT_DIR)" ] && echo written)" ""
fresh
mkdir -p "$(SNAPSHOT_DIR)"
printf 'not json' > "$(SNAPSHOT_DIR)/a1.snapshot.json"
check "node F2: an unreadable snapshot lets the turn end" "$(run subagent-stop "$(stop_payload)")" ""
printf '{"agents":[{"id":"h1"}],"started":[],"activity":[]}' > "$(SNAPSHOT_DIR)/a1.snapshot.json"
check "node F2: a snapshot with a malformed helper lets the turn end" "$(run subagent-stop "$(stop_payload)")" ""
fresh
write_snapshot "$HELPER" '[]' '{}'
printf 'not json' > "$(SNAPSHOT_DIR)/a1.watches.json"
check "node F2: unreadable watches start over, and the turn is held" "$(run subagent-stop "$(stop_payload)" | grep -c '"decision":"block"')" "1"
fresh
write_snapshot "$HELPER" '[]' '{}'
mkdir -p "$(SNAPSHOT_DIR)/x"
check "node F2: a snapshot the agent id names holds the turn" "$(run subagent-stop "$(stop_payload '[]' 'a1')" | grep -c '"decision":"block"')" "1"
rm -f "$(SNAPSHOT_DIR)/a1.watches.json"
check "node F2: an agent id that could name another folder holds nothing, though a snapshot sits there" "$(run subagent-stop "$(stop_payload '[]' 'x/../a1')")" ""
check "node F2: an agent id that could name another folder writes nothing there" "$([ -e "$(SNAPSHOT_DIR)/a1.watches.json" ] && echo written)" ""

FAKE="$SANDBOX/poisoned"
mkdir -p "$FAKE/hooks"
cp -R "$ROOT/hooks/fallback" "$ROOT/hooks/mods" "$FAKE/hooks/"
for heavy in session-rules helper-wait; do
  cat > "$FAKE/hooks/mods/$heavy.ts" <<'EOF'
import { writeFileSync } from 'node:fs'
writeFileSync(`${process.env.HOME}/heavy-loaded`, 'x')
throw new Error('heavy module loaded')
EOF
done

for entry in session-start subagent-start subagent-stop; do
  case "$entry" in
    session-start) payload_of() { start_payload; } ;;
    subagent-start) payload_of() { agent_payload general-purpose; } ;;
    subagent-stop) payload_of() { stop_payload; } ;;
  esac
  fresh
  write_snapshot "$HELPER" '[]' '{}'
  run_in "$FAKE" "$entry" "$(payload_of)" >/dev/null
  check "node F3: with no marker, $entry loads its module (the poison is reachable)" "$([ -e "$HOME_DIR/heavy-loaded" ] && echo loaded)" "loaded"
  for hook in session-start prompt-compose subagent-start subagent-stop; do
    fresh
    write_snapshot "$HELPER" '[]' '{}'
    mark "$hook"
    before="$(find "$HOME_DIR" | sort)"
    out="$(run_in "$FAKE" "$entry" "$(payload_of)")"
    code=$?
    check "node F3: after the module's $hook marker, $entry exits 0 with no output" "$code:$out" "0:"
    check "node F3: after the module's $hook marker, $entry writes nothing and loads no heavy module" "$(find "$HOME_DIR" | sort)" "$before"
    out="$(run "$entry" "$(payload_of)")"
    check "node F3: after the module's $hook marker, the real $entry prints nothing" "$out" ""
  done
done
fresh
mkdir -p "$HOME_DIR/.claude-workbench/dev-team-mod-ran/another-session"
check "node F3: another session's marker leaves this one's fallback on" "$(run session-start "$(start_payload)")" "$(context_json SessionStart)"
fresh
mkdir -p "$HOME_DIR/.claude-workbench/mod-ran/$SID"
check "node F3: workbench-core's marker for this session leaves the fallback on" "$(run session-start "$(start_payload)")" "$(context_json SessionStart)"

COMMANDS="$SANDBOX/commands"
module '
const { readFileSync } = await import("node:fs")
const hooks = JSON.parse(readFileSync("hooks/hooks.json", "utf8")).hooks
for (const [event, groups] of Object.entries(hooks))
  for (const group of groups)
    for (const hook of group.hooks) if (hook.command.includes("/hooks/fallback/")) process.stdout.write(`${event}\t${hook.command}\n`)' > "$COMMANDS"
check "node F4: hooks.json runs a fallback on SessionStart, SubagentStart and SubagentStop, and no other event" "$(cut -f1 "$COMMANDS" | tr '\n' ' ')" "SessionStart SubagentStart SubagentStop "
mkdir -p "$SANDBOX/no-node" "$SANDBOX/broken-node" "$SANDBOX/real-node"
printf '#!/bin/sh\necho broken >&2\nexit 3\n' > "$SANDBOX/broken-node/node"
chmod +x "$SANDBOX/broken-node/node"
ln -s "$(command -v node)" "$SANDBOX/real-node/node"
BASH_BIN="$(command -v bash)"
while IFS=$'\t' read -r event command; do
  fresh
  case "$event" in
    SessionStart) payload="$(start_payload)" ;;
    SubagentStart) payload="$(agent_payload general-purpose)" ;;
    SubagentStop) write_snapshot "$HELPER" '[]' '{}'; payload="$(stop_payload)" ;;
  esac
  for bin in no-node broken-node; do
    out="$(printf '%s' "$payload" | env -i HOME="$HOME_DIR" PATH="$SANDBOX/$bin" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" -c "$command" 2>/dev/null)"
    code=$?
    check "node F4: $event with $bin on PATH exits 0 with no output" "$code:$out" "0:"
  done
  out="$(printf '%s' "$payload" | env -i HOME="$HOME_DIR" PATH="$SANDBOX/real-node" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" -c "$command" 2>/dev/null)"
  code=$?
  case "$code:$out" in 0:'{'*) ok "node F4: $event's command runs its fallback from the plugin root when node is on PATH" ;; *) bad "node F4: $event's command runs its fallback from the plugin root when node is on PATH" "$code:$out" ;; esac
done < "$COMMANDS"

days_ago() { date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago" +%Y%m%d%H%M; }
fresh
WB="$HOME_DIR/.claude-workbench"
mkdir -p "$WB/dev-team-mod-ran/old" "$WB/dev-team-mod-ran/new" "$WB/dev-team-helper-wait/old" "$WB/dev-team-helper-wait/new" "$WB/mod-ran/old"
for file in dev-team-mod-ran/old/session-start dev-team-helper-wait/old/a1.snapshot.json mod-ran/old/session-start; do
  : > "$WB/$file"
  touch -t "$(days_ago 8)" "$WB/$file"
done
for file in dev-team-mod-ran/new/session-start dev-team-helper-wait/new/a1.watches.json; do
  : > "$WB/$file"
  touch -t "$(days_ago 6)" "$WB/$file"
done
module '
const { sweepArgvsOf } = await import("./hooks/mods/fallback.ts")
const { spawnSync } = await import("node:child_process")
for (const [command, ...args] of sweepArgvsOf(process.argv[1])) spawnSync(command, args)' "$HOME_DIR"
check "node F5: the sweep deletes files older than 7 days and their empty folders, and keeps newer ones" \
  "$(cd "$WB" && find . -mindepth 1 | sort | tr '\n' ' ')" \
  "./dev-team-helper-wait ./dev-team-helper-wait/new ./dev-team-helper-wait/new/a1.watches.json ./dev-team-mod-ran ./dev-team-mod-ran/new ./dev-team-mod-ran/new/session-start ./mod-ran ./mod-ran/old ./mod-ran/old/session-start "

echo
echo "fallbacks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
