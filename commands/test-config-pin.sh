#!/usr/bin/env bash
# Test for setup's pin check and pin replacement (Step 6, commands/setup.md).
#
# It extracts the *real* blocks from setup.md (between the `config-pin-check`
# and `config-pin-replace` sentinel markers) and runs them against fixture
# configs, so the test can never drift from the shipped logic.
#
# Why the blocks exist: setup never overwrites an existing config, so an install
# from before the pins shipped keeps its old model and effort. Dispatch passes
# those as flags and Step 6a stamps them over the frontmatter, so the old values
# win on both paths. Setup asks the user, per agent, whether to replace them.
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

# The shipped default config, read out of Step 6's heredoc rather than restated.
DEFAULT_CFG="$WORK/default-config.json"
awk '/cat > "\$CONFIG" <<.EOF.$/{f=1;next} f && /^EOF$/{exit} f' "$SRC" > "$DEFAULT_CFG"
if [ ! -s "$DEFAULT_CFG" ] || ! jq empty "$DEFAULT_CFG" 2>/dev/null; then
  echo "FAIL: could not extract the default agent config heredoc from $SRC"; exit 1
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

# 4c. Effort is compared the way Step 6a writes it, lower-cased.
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
# Only an environment fault reaches this now. Two are cheap to cause: a mktemp
# that fails (a stub first on PATH, since macOS mktemp ignores a bad TMPDIR),
# and a config directory that refuses the rename.
mkdir -p "$WORK/failbin"; printf '#!/bin/sh\nexit 1\n' > "$WORK/failbin/mktemp"; chmod +x "$WORK/failbin/mktemp"
cfg="$WORK/no-tmp.json"; printf '%s' "$OLD" > "$cfg"
out=$( PATH="$WORK/failbin:$PATH" HOME="$WORK/nohome" DEVTEAM_CONFIG="$cfg" PIN_REPLACE="watson" bash "$REPLACE" 2>&1 ); rc=$?
if [ "$OLD" = "$(cat "$cfg")" ] && [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Could not write"; then
  ok "no temp file -> 'Could not write', exit 1, file untouched"
else
  bad "no temp file (rc=$rc): $out"
fi
if [ "$(id -u)" -ne 0 ]; then
  ro="$WORK/ro"; mkdir -p "$ro"; cfg="$ro/config.json"; printf '%s' "$OLD" > "$cfg"; chmod 555 "$ro"
  out=$(replace "$cfg" "watson"); rc=$?
  chmod 755 "$ro"
  if [ "$OLD" = "$(cat "$cfg")" ] && [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Could not write" \
     && ! printf '%s' "$out" | grep -q "✅"; then
    ok "a rename the directory refuses -> 'Could not write', exit 1, no success line, file untouched"
  else
    bad "read-only config dir (rc=$rc): $out"
  fi
else
  echo "  skip — read-only directory case (root ignores directory permissions)"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "config pin check: $pass passed, $fail failed"
else
  echo "config pin check: $pass passed, $fail FAILED"
fi
[ "$fail" -eq 0 ]
