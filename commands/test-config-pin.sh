#!/usr/bin/env bash
# Test for setup's pin check, pin replacement, and the move of an old config
# into /config (Step 6, commands/setup.md).
#
# It extracts the *real* blocks from setup.md (between the `config-pin-check`,
# `config-pin-replace` and `config-migrate` sentinel markers) and runs them
# against fixture configs, so the test can never drift from the shipped logic.
#
# Why the blocks exist: an install from before the pins shipped keeps its old
# model and effort in ~/.claude-workbench/dev-team-config.json, and the move
# would carry them into /config, where they win on both paths. Setup asks the
# user, per agent, whether to put them on the pin first.
# The check finds what to ask about. The replacement writes only what the user
# said yes to. The question itself is Claude's AskUserQuestion call, which no
# shell test can run, so these cases hold the two halves either side of it.
#
# Every case runs with HOME pointed at a throwaway directory, so a block that
# falls back to ~/.claude-workbench/ can never reach the real config.
#
# Run: bash commands/test-config-pin.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SRC="$REPO/commands/setup.md"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/check.sh"
REPLACE="$WORK/replace.sh"

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }

# --- extraction (fail closed) ------------------------------------------------

awk '/# >>> config-pin-check >>>/{f=1;next} /# <<< config-pin-check <<</{f=0} f' "$SRC" > "$CHECK"
awk '/# >>> config-pin-replace >>>/{f=1;next} /# <<< config-pin-replace <<</{f=0} f' "$SRC" > "$REPLACE"
for f in "$CHECK" "$REPLACE"; do
  if [ ! -s "$f" ]; then echo "FAIL: could not extract $(basename "$f" .sh) block from $SRC"; exit 1; fi
done

# The defaults, as an old config file would have held them: each agent's
# userConfig rows, read out of plugin.json rather than restated.
DEFAULT_CFG="$WORK/default-config.json"
jq '.userConfig as $u
  | {agents: (["lestrade", "holmes", "watson"] | map(. as $a | {key: $a, value: (
      ["model", "effort", "fallback", "maxBudgetUsd", "fanout", "lensModel"]
      | map(. as $k | $u[$a + ($k[0:1] | ascii_upcase) + $k[1:]].default as $d
            | select($d != null) | {key: $k, value: $d}) | from_entries)}) | from_entries)}' \
  "$REPO/.claude-plugin/plugin.json" > "$DEFAULT_CFG" 2>/dev/null
if [ "$(jq -r '.agents.watson.model // empty' "$DEFAULT_CFG" 2>/dev/null)" = "" ]; then
  echo "FAIL: could not read the userConfig defaults from plugin.json"; exit 1
fi

echo "Testing setup's pin check and pin replacement:"

# check <config> -> runs the check block; prints its output; returns its status
check() { ( HOME="$WORK/nohome" DEVTEAM_CONFIG="$1" bash "$CHECK" 2>&1 ); }
# replace <config> <agents> -> runs the replacement block with PIN_REPLACE set
replace() { ( HOME="$WORK/nohome" DEVTEAM_CONFIG="$1" PIN_REPLACE="$2" bash "$REPLACE" 2>&1 ); }
# differs <output> -> only the PIN_DIFFERS lines, sorted
differs() { printf '%s\n' "$1" | grep '^PIN_DIFFERS ' | LC_ALL=C sort; }

# The config every pre-pin install carries: the defaults setup shipped before.
OLD='{"agents":{
  "lestrade":{"model":"sonnet","effort":"high","fanout":true,"lensModel":"sonnet","fallback":"haiku"},
  "holmes":{"model":"opus","effort":"high","fanout":true,"lensModel":"sonnet","maxBudgetUsd":10.00,"fallback":"sonnet"},
  "watson":{"model":"opus","maxBudgetUsd":10.00,"fallback":"sonnet,haiku"}}}'

# --- 1. the check's pin is the shipped pin -----------------------------------
#
# Both blocks restate the pin, because setup runs them from Markdown with no
# file to read it from. Hold both copies to the default config, per agent, so
# the check never asks about a value the default does not ship.
for blk in "$CHECK" "$REPLACE"; do
  name=$(basename "$blk" .sh)
  agents=$(sed -n 's/^PIN_AGENTS="\(.*\)"$/\1/p' "$blk")
  model=$(sed -n 's/^PIN_MODEL="\(.*\)"$/\1/p' "$blk")
  effort=$(sed -n 's/^PIN_EFFORT="\(.*\)"$/\1/p' "$blk")
  shipped=$(jq -r '.agents | to_entries[] | "\(.key) \(.value.model // "") \(.value.effort // "")"' "$DEFAULT_CFG" | LC_ALL=C sort)
  expected=$(for a in $agents; do echo "$a $model $effort"; done | LC_ALL=C sort)
  if [ -n "$agents" ] && [ -n "$model" ] && [ "$shipped" = "$expected" ]; then
    ok "$name pins every shipped agent to the shipped default ($model at $effort)"
  else
    bad "$name pin disagrees with the default config:
$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$shipped"))"
  fi
done

# --- 2. a fresh default config asks nothing ----------------------------------
out=$(check "$DEFAULT_CFG"); rc=$?
if [ -z "$(differs "$out")" ] && [ "$rc" -eq 0 ]; then
  ok "the shipped default config differs from no pin"
else
  bad "default config flagged (rc=$rc): $out"
fi

# --- 3. an old config names every agent, with its current values -------------
#
# The printed values are what the question shows the user, so they are asserted
# exactly, "(none)" for Watson's absent effort included.
cfg="$WORK/old.json"; printf '%s' "$OLD" > "$cfg"
before=$(cat "$cfg")
out=$(check "$cfg"); rc=$?
expected="PIN_DIFFERS holmes model=opus effort=high
PIN_DIFFERS lestrade model=sonnet effort=high
PIN_DIFFERS watson model=opus effort=(none)"
if [ "$(differs "$out")" = "$expected" ] && [ "$rc" -eq 0 ]; then
  ok "a pre-pin config flags all three agents with their exact current values"
else
  bad "old config: expected
$expected
got
$(differs "$out") (rc=$rc)"
fi
if [ "$before" = "$(cat "$cfg")" ]; then
  ok "the check writes nothing"
else
  bad "the check changed the config"
fi

# --- 4. model and effort are each enough to differ ---------------------------
#
# One field off per agent, each way round, plus the bare ID the previous pin
# shipped: the `[1m]` suffix is part of the pin, so its absence is a difference.
cfg="$WORK/partial.json"
cat > "$cfg" <<'JSON'
{"agents":{
  "lestrade":{"model":"claude-opus-5-5[1m]","effort":"high"},
  "holmes":{"model":"claude-opus-5-5[1m]","effort":"medium"},
  "watson":{"model":"claude-opus-5-5","effort":"medium"}}}
JSON
out=$(check "$cfg")
expected="PIN_DIFFERS lestrade model=claude-opus-5-5[1m] effort=high
PIN_DIFFERS watson model=claude-opus-5-5 effort=medium"
if [ "$(differs "$out")" = "$expected" ]; then
  ok "an effort alone, or a model missing [1m], differs; a matching agent is not asked about"
else
  bad "partial config: got
$(differs "$out")"
fi

# 4b. An agent with no entry at all differs, with both values "(none)".
cfg="$WORK/absent-agent.json"
jq 'del(.agents.lestrade)' "$DEFAULT_CFG" > "$cfg"
out=$(check "$cfg")
if [ "$(differs "$out")" = "PIN_DIFFERS lestrade model=(none) effort=(none)" ]; then
  ok "an agent missing from the config differs, with both values shown as (none)"
else
  bad "absent agent: got '$(differs "$out")'"
fi

# 4c. Effort is compared the way the dev-team mod reads it, lower-cased.
cfg="$WORK/case.json"
jq '.agents.holmes.effort = "Medium"' "$DEFAULT_CFG" > "$cfg"
out=$(check "$cfg")
if [ -z "$(differs "$out")" ]; then
  ok "a mixed-case 'Medium' is already the pin, and is not asked about"
else
  bad "mixed-case effort flagged: $(differs "$out")"
fi

# --- 5. an unreadable config is skipped, not guessed at ----------------------
for label in malformed missing; do
  cfg="$WORK/$label.json"
  [ "$label" = malformed ] && printf '{ not json' > "$cfg"
  out=$(check "$cfg"); rc=$?
  if [ -z "$(differs "$out")" ] && [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "pin check skipped"; then
    ok "$label config -> warns, asks nothing, exit 0"
  else
    bad "$label config (rc=$rc): $out"
  fi
done

# --- 5b. a wrong-shaped entry is named, never asked about --------------------
#
# Valid JSON, wrong shape. "watson": "opus" is a plausible hand-edit shorthand.
# The check must name it as malformed, leak no jq error, and not offer to
# replace a "(none)" it never read. The other agents are still checked.
cfg="$WORK/shape-entry.json"
jq '.agents.watson = "opus"' "$DEFAULT_CFG" > "$cfg"
jq '.agents.holmes.effort = "high"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
out=$(check "$cfg"); rc=$?
if [ "$(differs "$out")" = "PIN_DIFFERS holmes model=claude-opus-5-5[1m] effort=high" ] \
   && printf '%s\n' "$out" | grep -qx "PIN_MALFORMED watson type=string" \
   && ! printf '%s' "$out" | grep -q "jq:" && [ "$rc" -eq 0 ]; then
  ok "a string agent entry -> PIN_MALFORMED watson, not asked about; holmes still checked; no jq noise"
else
  bad "wrong-shaped entry (rc=$rc): $out"
fi

# 5c. A wrong-shaped .agents, or a config that is not an object, asks nothing.
for pair in 'agents|{"agents":"oops"}' 'config|["agents"]'; do
  where=${pair%%|*}; cfg="$WORK/shape-$where.json"; printf '%s' "${pair#*|}" > "$cfg"
  out=$(check "$cfg"); rc=$?
  if [ -z "$(differs "$out")" ] && [ "$rc" -eq 0 ] \
     && [ "$(printf '%s\n' "$out" | grep '^PIN_MALFORMED ')" = "PIN_MALFORMED $where type=$(jq -r "if type == \"object\" then .agents | type else type end" "$cfg")" ] \
     && ! printf '%s' "$out" | grep -q "jq:"; then
    ok "a wrong-shaped $where -> one PIN_MALFORMED $where line, asks nothing, no jq noise"
  else
    bad "wrong-shaped $where (rc=$rc): $out"
  fi
done

# 5d. A present, non-string value is shown as it is, never as "(none)".
# `false` is the case `//` gets wrong: it reads as absent.
cfg="$WORK/non-string.json"
jq '.agents.watson.model = false | .agents.watson.effort = false' "$DEFAULT_CFG" > "$cfg"
out=$(check "$cfg")
if [ "$(differs "$out")" = "PIN_DIFFERS watson model=false effort=false" ]; then
  ok "a false model and a false effort print as false, not (none)"
else
  bad "non-string values: $(differs "$out")"
fi

# --- 6. a "no" writes nothing -------------------------------------------------
#
# Byte for byte, not just value for value: with no approval the file must not
# even be reformatted.
cfg="$WORK/declined.json"; printf '%s' "$OLD" > "$cfg"
out=$(replace "$cfg" ""); rc=$?
if [ "$OLD" = "$(cat "$cfg")" ] && [ "$rc" -eq 0 ]; then
  ok "an empty PIN_REPLACE leaves the config byte for byte, exit 0"
else
  bad "declined replace changed the file or failed (rc=$rc): $out"
fi

# --- 7. a "yes" writes that agent's model and effort, and nothing else --------
cfg="$WORK/one.json"; printf '%s' "$OLD" > "$cfg"
out=$(replace "$cfg" "holmes"); rc=$?
want=$(printf '%s' "$OLD" | jq -S '.agents.holmes.model = "claude-opus-5-5[1m]" | .agents.holmes.effort = "medium"')
if [ "$want" = "$(jq -S . "$cfg")" ] && [ "$rc" -eq 0 ]; then
  ok "only holmes's model and effort change; its other keys and the other agents keep their values"
else
  bad "replace holmes (rc=$rc): $(diff <(printf '%s\n' "$want") <(jq -S . "$cfg"))"
fi
out=$(check "$cfg")
if [ "$(differs "$out" | awk '{print $2}' | tr '\n' ' ')" = "lestrade watson " ]; then
  ok "a re-check asks only about the agents that were kept"
else
  bad "re-check after one replacement: $(differs "$out")"
fi

# 7b. Two yeses, and an entry with no effort key gains one.
cfg="$WORK/two.json"; printf '%s' "$OLD" > "$cfg"
replace "$cfg" "watson lestrade" > /dev/null
want=$(printf '%s' "$OLD" | jq -S '(.agents.watson, .agents.lestrade) |= (.model = "claude-opus-5-5[1m]" | .effort = "medium")')
if [ "$want" = "$(jq -S . "$cfg")" ]; then
  ok "each named agent is replaced, and watson's absent effort is added"
else
  bad "replace watson+lestrade: $(diff <(printf '%s\n' "$want") <(jq -S . "$cfg"))"
fi

# 7c. An agent with no entry gets one holding only the pin.
cfg="$WORK/new-entry.json"; jq 'del(.agents.lestrade)' "$DEFAULT_CFG" > "$cfg"
replace "$cfg" "lestrade" > /dev/null
if [ "$(jq -c '.agents.lestrade' "$cfg")" = '{"model":"claude-opus-5-5[1m]","effort":"medium"}' ]; then
  ok "a missing agent entry is created with the pin alone"
else
  bad "new entry: got $(jq -c '.agents.lestrade' "$cfg")"
fi

# --- 8. an unknown name is refused, never written -----------------------------
cfg="$WORK/unknown.json"; printf '%s' "$OLD" > "$cfg"
out=$(replace "$cfg" "moriarty"); rc=$?
if [ "$OLD" = "$(cat "$cfg")" ] && [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "'moriarty' is not one of"; then
  ok "an unknown agent name is refused by name, and the file is untouched"
else
  bad "unknown agent (rc=$rc): $out"
fi
cfg="$WORK/mixed.json"; printf '%s' "$OLD" > "$cfg"
replace "$cfg" "moriarty watson" > /dev/null
if [ "$(jq -r '.agents.moriarty // "absent"' "$cfg")" = "absent" ] \
   && [ "$(jq -r '.agents.watson.model' "$cfg")" = "claude-opus-5-5[1m]" ]; then
  ok "beside a known name, the unknown one is still not written"
else
  bad "mixed names: $(jq -c . "$cfg")"
fi

# --- 9. an unreadable config refuses the write, and keeps the file ------------
cfg="$WORK/broken.json"; printf '{ not json' > "$cfg"
out=$(replace "$cfg" "watson"); rc=$?
if [ "$(cat "$cfg")" = "{ not json" ] && [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Refusing to touch"; then
  ok "a malformed config refuses the replacement with exit 1, file untouched"
else
  bad "malformed replace (rc=$rc): $out"
fi

# --- 10. a wrong-shaped config refuses the write, and names the entry --------
#
# The check never asks about these, so reaching the write means the file
# changed in between. The write is refused whole, with the entry named, before
# jq is asked to write into it.
for pair in \
  'watson|.agents.watson is a JSON string|{"agents":{"watson":"opus","holmes":{"model":"opus"}}}' \
  'watson holmes|.agents.watson is a JSON string|{"agents":{"watson":"opus","holmes":{"model":"opus"}}}' \
  'watson|.agents is a JSON string|{"agents":"oops"}' \
  'watson|the config is a JSON array|["agents"]'; do
  who=${pair%%|*}; rest=${pair#*|}; why=${rest%%|*}; body=${rest#*|}
  cfg="$WORK/shape-replace.json"; printf '%s' "$body" > "$cfg"
  out=$(replace "$cfg" "$who"); rc=$?
  if [ "$(cat "$cfg")" = "$body" ] && [ "$rc" -eq 1 ] \
     && printf '%s' "$out" | grep -qF "Refusing to touch $cfg — $why" \
     && ! printf '%s' "$out" | grep -q "Could not write"; then
    ok "replace '$who' on $body -> refused, names '$why', exit 1, file untouched"
  else
    bad "wrong-shaped replace '$who' on $body (rc=$rc): $out"
  fi
done

# --- 11. a failed write reports failure, and keeps the file ------------------
#
# Only an environment fault reaches this now. The block writes the checked
# config straight over the file, with no temporary file, so the cheap fault to
# cause is a config file that refuses the write.
if [ "$(id -u)" -ne 0 ]; then
  cfg="$WORK/ro-config.json"; printf '%s' "$OLD" > "$cfg"; chmod 444 "$cfg"
  out=$(replace "$cfg" "watson"); rc=$?
  chmod 644 "$cfg"
  if [ "$OLD" = "$(cat "$cfg")" ] && [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Could not write" \
     && ! printf '%s' "$out" | grep -q "✅"; then
    ok "a write the file refuses -> 'Could not write', exit 1, no success line, file untouched"
  else
    bad "read-only config file (rc=$rc): $out"
  fi
else
  echo "  skip — read-only file case (root ignores file permissions)"
fi

# --- 12. the move into /config ------------------------------------------------
# Step 6b writes each old value that differs from its row's default through
# `claude plugin configure`, checks it landed where dispatch-agent.sh reads it,
# and only then renames the old file. `claude` is a stub that stores the values
# as Claude Code's own type declarations say it does: in the settings file,
# under pluginConfigs[<plugin>].options. A second stub stores nothing, as a
# write that lands somewhere else would look.
echo "Testing setup's move of the old config into /config:"
MIGRATE="$WORK/migrate.sh"
awk '/# >>> config-migrate >>>/{f=1;next} /# <<< config-migrate <<</{f=0} f' "$SRC" > "$MIGRATE"
if [ ! -s "$MIGRATE" ]; then
  bad "could not extract the config-migrate block from $SRC"
else
  MSTUB="$WORK/mstub"; LOST="$WORK/lost"; mkdir -p "$MSTUB" "$LOST"
  cat > "$MSTUB/claude" <<STUB
#!/usr/bin/env bash
# claude plugin configure <key> --values-stdin: merges stdin into the settings.
[ "\$1 \$2 \$4" = "plugin configure --values-stdin" ] || exit 64
printf '%s ' "\$*" >> "$WORK/claude.calls"
in=\$(cat)
f="\${WORKBENCH_SETTINGS_FILE}"
[ -f "\$f" ] || echo '{}' > "\$f"
# Values arrive as strings. The row's type turns them back, as the CLI does.
jq --arg k "\$3" --argjson v "\$in" --slurpfile m "$REPO/.claude-plugin/plugin.json" '
  .pluginConfigs[\$k].options += (\$v | with_entries(
    \$m[0].userConfig[.key].type as \$t
    | .value |= (if \$t == "number" then tonumber elif \$t == "boolean" then (. == "true") else . end)))' "\$f" > "\$f.new" && mv "\$f.new" "\$f"
STUB
  printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$LOST/claude"
  printf '#!/bin/sh\ncat >/dev/null\nexit 3\n' > "$WORK/refuse-claude"
  mkdir -p "$WORK/refuse"; mv "$WORK/refuse-claude" "$WORK/refuse/claude"
  chmod +x "$MSTUB/claude" "$LOST/claude" "$WORK/refuse/claude"
  MANIFEST="$REPO/.claude-plugin/plugin.json"
  # migrate <name> <old config, or "" for none> [stub dir] -> runs the block
  migrate() {
    local home="$WORK/mhome-$1"
    mkdir -p "$home/.claude-workbench" "$home/.claude"
    [ -z "$2" ] || printf '%s' "$2" > "$home/.claude-workbench/dev-team-config.json"
    : > "$WORK/claude.calls"
    ( HOME="$home" PLUGIN_MANIFEST="$MANIFEST" WORKBENCH_SETTINGS_FILE="$home/.claude/settings.json" \
        PATH="${3:-$MSTUB}:$PATH" bash "$MIGRATE" 2>&1 )
  }
  stored() { jq -c '.pluginConfigs["workbench-dev-team@claude-workbench"].options // {}' "$WORK/mhome-$1/.claude/settings.json" 2>/dev/null || echo none; }
  old_file() { printf '%s' "$WORK/mhome-$1/.claude-workbench/dev-team-config.json"; }
  moved() { find "$WORK/mhome-$1/.claude-workbench" -maxdepth 1 -name 'dev-team-config.json.migrated-*' | wc -l | tr -d ' '; }

  # The rows' defaults, as an old config would have held them.
  out=$(migrate defaults "$(cat "$DEFAULT_CFG")"); rc=$?
  [ "$rc" -eq 0 ] && ok "a config equal to the defaults moves cleanly" || bad "defaults: rc $rc / $out"
  [ -s "$WORK/claude.calls" ] && bad "a config equal to the defaults still wrote values" || ok "and writes no value"
  [ -e "$(old_file defaults)" ] && bad "the old file was not renamed" || ok "the old file is renamed"
  expect_moved=$(moved defaults); [ "$expect_moved" = 1 ] && ok "and kept beside it" || bad "renamed copies: $expect_moved"

  # Mike's own shape: 10.00 is the default 10, and an effort in capitals is the
  # default too, so nothing differs.
  out=$(migrate cased '{"agents":{"watson":{"model":"claude-opus-5-5[1m]","maxBudgetUsd":10.00,"fallback":"sonnet,haiku","effort":"Medium"}}}')
  [ -s "$WORK/claude.calls" ] && bad "10.00 or Medium read as different from the default: $out" || ok "10.00 and Medium read as the defaults"

  out=$(migrate old "$OLD"); rc=$?
  want='{"holmesEffort":"high","holmesModel":"opus","lestradeEffort":"high","lestradeModel":"sonnet","watsonModel":"opus"}'
  if [ "$rc" -eq 0 ] && [ "$(stored old | jq -cS .)" = "$want" ]; then
    ok "an old config writes exactly its values that differ from the defaults"
  else
    bad "an old config stored $(stored old) (rc $rc): $out"
  fi
  expect_lines=$(printf '%s\n' "$out" | grep -c '^MIGRATE ' | tr -d ' ')
  [ "$expect_lines" = 5 ] && ok "one MIGRATE line per value" || bad "MIGRATE lines: $expect_lines"
  printf '%s' "$out" | grep -qx 'MIGRATE watsonModel=opus' && ok "a MIGRATE line names the row and the value" || bad "no MIGRATE watsonModel=opus line: $out"
  [ "$(cat "$WORK/claude.calls")" = "plugin configure workbench-dev-team@claude-workbench --values-stdin " ] \
    && ok "one configure call, for this plugin" || bad "configure calls: $(cat "$WORK/claude.calls")"

  out=$(migrate typed '{"agents":{"watson":{"maxBudgetUsd":25,"fanout":true,"effort":8000},"holmes":{"fanout":false,"lensModel":"haiku","maxBudgetUsd":"lots"},"lestrade":{"effort":"extreme","model":5}}}')
  if [ "$(stored typed | jq -cS .)" = '{"holmesFanout":false,"holmesLensModel":"haiku","watsonMaxBudgetUsd":25}' ]; then
    ok "numbers and booleans move as their row's type"
  else
    bad "typed values stored $(stored typed): $out"
  fi
  for skip in "watson.fanout no /config row takes it" "watson.effort the row takes text" \
      "holmes.maxBudgetUsd the row takes a number" "lestrade.effort the row takes one of low, medium, high, xhigh, max" \
      "lestrade.model the row takes text"; do
    printf '%s\n' "$out" | grep -qxF "MIGRATE_SKIPPED $skip" && ok "skipped and named: $skip" || bad "no MIGRATE_SKIPPED $skip in: $out"
  done

  out=$(migrate agree '{"agents":{"watson":{"reprieveBudgetMultiplier":2},"holmes":{"reprieveBudgetMultiplier":2.0}}}')
  [ "$(stored agree)" = '{"reprieveBudgetMultiplier":2}' ] && ok "agents that agree on the multiplier give one row" || bad "agree stored $(stored agree): $out"
  out=$(migrate disagree '{"agents":{"watson":{"reprieveBudgetMultiplier":2},"holmes":{"reprieveBudgetMultiplier":4}}}')
  [ "$(stored disagree)" = '{}' ] || [ "$(stored disagree)" = none ] && ok "agents that disagree write no multiplier" || bad "disagree stored $(stored disagree)"
  printf '%s\n' "$out" | grep -q '^MIGRATE_SKIPPED watson.reprieveBudgetMultiplier the agents disagree' \
    && ok "and name it for the user" || bad "disagree not named: $out"

  out=$(migrate none ""); rc=$?
  [ "$rc" -eq 0 ] && [[ $out == *"No old agent config"* ]] && ok "no old config: nothing to move" || bad "no old config: $out"
  [ -s "$WORK/claude.calls" ] && bad "no old config, but configure ran" || ok "and no configure call"

  out=$(migrate lost "$OLD" "$LOST"); rc=$?
  [ "$rc" -eq 1 ] && ok "values that do not land in the settings file exit 1" || bad "lost: rc $rc / $out"
  [[ $out == *"where dispatch-agent.sh reads them"* ]] && ok "and say where they were looked for" || bad "lost message: $out"
  [ -e "$(old_file lost)" ] && ok "and the old file stays, so the move can run again" || bad "lost: the old file was renamed"

  out=$(migrate refused "$OLD" "$WORK/refuse"); rc=$?
  [ "$rc" -eq 1 ] && [ -e "$(old_file refused)" ] && ok "a refused configure exits 1 and keeps the old file" || bad "refused: rc $rc / $out"
  [[ $out == *"claude plugin configure refused the values"* ]] && ok "and names the refusal" || bad "refused message: $out"

  for shape in 'not json' '["a"]' '{"agents":["a"]}' '{"agents":{"watson":"opus"}}'; do
    out=$(migrate shape "$shape"); rc=$?
    [ "$rc" -eq 1 ] && [ ! -s "$WORK/claude.calls" ] && [ "$(cat "$(old_file shape)")" = "$shape" ] \
      && ok "a wrong-shaped old config ($shape) moves nothing and is kept" || bad "shape $shape: rc $rc / $out"
    [[ $out == *"is not valid JSON, or its shape is wrong"* ]] && ok "and says so ($shape)" || bad "shape message ($shape): $out"
  done

  # 6a runs in the session's own shell too. Under zsh a `for` over an unquoted
  # list runs once over the whole string, so each pin loop must still run per
  # agent there: the check names each agent that differs, and the replacement
  # writes each agent named, and nothing for a name it does not know.
  if command -v zsh >/dev/null 2>&1; then
    zcfg="$WORK/zsh-pin.json"; printf '%s' "$OLD" > "$zcfg"
    zout=$( HOME="$WORK/nohome" DEVTEAM_CONFIG="$zcfg" zsh "$CHECK" 2>&1 )
    [ "$(differs "$zout")" = "$(differs "$(check "$zcfg")")" ] && [ "$(differs "$zout" | wc -l | tr -d ' ')" = 3 ] \
      && ok "zsh: the pin check names each of the three agents, as bash does" || bad "zsh pin check: $zout"
    zout=$( HOME="$WORK/nohome" DEVTEAM_CONFIG="$zcfg" PIN_REPLACE="holmes watson mycroft" zsh "$REPLACE" 2>&1 ); rc=$?
    if [ "$rc" -eq 0 ] && [ "$(jq -c '[.agents.holmes.model, .agents.watson.effort, .agents.lestrade.model]' "$zcfg")" = '["claude-opus-5-5[1m]","medium","sonnet"]' ]; then
      ok "zsh: the replacement writes holmes and watson, each on its own, and leaves lestrade"
    else
      bad "zsh replacement: rc $rc, $(jq -c .agents "$zcfg"): $zout"
    fi
    [[ $zout == *"'mycroft' is not one of"* ]] && ok "zsh: an unknown name is named and not written" || bad "zsh unknown name: $zout"
    [ "$(jq -r '.agents | has("mycroft")' "$zcfg")" = false ] && ok "zsh: no entry for the unknown name" || bad "zsh wrote mycroft"
    [ "$(printf '%s\n' "$zout" | grep -c '^✅ ')" = 2 ] && ok "zsh: one confirmation per agent written" || bad "zsh confirmations: $zout"
  fi

  # The block runs in the session's own shell, which can be zsh.
  if command -v zsh >/dev/null 2>&1; then
    home="$WORK/mhome-zsh"; mkdir -p "$home/.claude-workbench" "$home/.claude"
    printf '%s' "$OLD" > "$home/.claude-workbench/dev-team-config.json"
    out=$( HOME="$home" PLUGIN_MANIFEST="$MANIFEST" WORKBENCH_SETTINGS_FILE="$home/.claude/settings.json" PATH="$MSTUB:$PATH" zsh "$MIGRATE" 2>&1 ); rc=$?
    [ "$rc" -eq 0 ] && [ "$(stored zsh | jq -cS .)" = "$want" ] && ok "zsh moves the same values as bash" || bad "zsh: rc $rc, stored $(stored zsh): $out"
  fi

  out=$( HOME="$WORK/mhome-nomanifest" DEVTEAM_CONFIG="$DEFAULT_CFG" PATH="$MSTUB:$PATH" bash -c 'unset PLUGIN_MANIFEST; bash "$1"' _ "$MIGRATE" 2>&1 ); rc=$?
  [ "$rc" -eq 1 ] && ok "no PLUGIN_MANIFEST exits 1" || bad "no manifest: rc $rc / $out"

  # A value the user set in /config before the move is kept unless the old file
  # differs on that row. And a second run finds no old file, so a later /config
  # edit is never overwritten.
  home="$WORK/mhome-rerun"; mkdir -p "$home/.claude"
  jq -n '{pluginConfigs: {"workbench-dev-team@claude-workbench": {options: {holmesMaxBudgetUsd: 15}}}, other: 1}' > "$home/.claude/settings.json"
  migrate rerun "$OLD" >/dev/null
  [ "$(jq -c '[.pluginConfigs["workbench-dev-team@claude-workbench"].options.holmesMaxBudgetUsd, .other]' "$home/.claude/settings.json")" = '[15,1]' ] \
    && ok "a row the old file left at its default keeps the /config value, and other keys stay" || bad "rerun settings: $(cat "$home/.claude/settings.json")"
  jq '.pluginConfigs["workbench-dev-team@claude-workbench"].options.watsonModel = "haiku"' "$home/.claude/settings.json" > "$home/s" && mv "$home/s" "$home/.claude/settings.json"
  out=$( HOME="$home" PLUGIN_MANIFEST="$MANIFEST" WORKBENCH_SETTINGS_FILE="$home/.claude/settings.json" PATH="$MSTUB:$PATH" bash "$MIGRATE" 2>&1 )
  [ "$(jq -r '.pluginConfigs["workbench-dev-team@claude-workbench"].options.watsonModel' "$home/.claude/settings.json")" = haiku ] \
    && [[ $out == *"No old agent config"* ]] && ok "a second run moves nothing over a later /config edit" || bad "second run: $out"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "config pin check: $pass passed, $fail failed"
else
  echo "config pin check: $pass passed, $fail FAILED"
fi
[ "$fail" -eq 0 ]
