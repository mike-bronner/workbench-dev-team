#!/usr/bin/env bash
# Test for the Step 6a agent model-and-effort stamper in commands/setup.md.
#
# It extracts the *real* stamping block from setup.md (between the
# `agent-effort-stamp` sentinel markers) and runs it against fixture trees, so
# the test can never drift from the shipped logic.
#
# Why the step exists: the Agent tool has no effort parameter, and its `model`
# parameter takes an alias only, never a full model ID. So an interactively
# dispatched sub-agent reads both values from its own frontmatter. The shared
# config is canonical for the value; this step copies it to where an
# interactive dispatch will actually look.
#
# The headline case is AGREEMENT: the shipped default config in setup.md, run
# through the shipped stamper, must reproduce the committed agents/*.md byte for
# byte. That is the one assertion that goes red when the config defaults and the
# frontmatter drift apart in either direction.
#
# Every agent ships a pin, so a pin dropped from the config alone makes the
# stamper delete a line the committed file has, and one dropped from the
# frontmatter alone makes it write a line the committed file lacks. Either
# reddens case 1. Agreement cannot tell a pin that moved in both places at
# once, so case 1c holds the values themselves.
#
# Nothing here asserts that a spawned subagent actually ran at a given effort.
# That belongs to the harness, and a test of it would be brittle across versions.
#
# Every case runs with HOME pointed at a throwaway directory: the block falls
# back to ~/.claude/plugins/installed_plugins.json and ~/.claude-workbench/ when
# its inputs are unset, and a test that reaches the real install is not a test.
#
# Run: bash agents/test-effort-stamp.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SRC="$REPO/commands/setup.md"
SNIPPET=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -rf "$SNIPPET" "$WORK"' EXIT

pass=0; fail=0

ok()   { echo "  ok   — $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL — $1"; fail=$((fail+1)); }

# --- extraction (fail closed) ------------------------------------------------

awk '/# >>> agent-effort-stamp >>>/{f=1;next} /# <<< agent-effort-stamp <<</{f=0} f' \
  "$SRC" > "$SNIPPET"
if [ ! -s "$SNIPPET" ]; then
  echo "FAIL: could not extract agent-effort-stamp block from $SRC"; exit 1
fi

# The shipped default config, read out of Step 6's heredoc rather than restated
# here. A second hand-kept copy of these values is exactly the drift this file
# is meant to catch, so it must not introduce one.
DEFAULT_CFG="$WORK/default-config.json"
awk '/cat > "\$CONFIG" <<.EOF.$/{f=1;next} f && /^EOF$/{exit} f' "$SRC" > "$DEFAULT_CFG"
if [ ! -s "$DEFAULT_CFG" ] || ! jq empty "$DEFAULT_CFG" 2>/dev/null; then
  echo "FAIL: could not extract the default agent config heredoc from $SRC"; exit 1
fi

echo "Testing agent model-and-effort stamper ($SNIPPET):"

# --- helpers -----------------------------------------------------------------

# newtree <name> -> prints a root path holding a fresh copy of the shipped agents
newtree() {
  local root="$WORK/$1"
  rm -rf "$root"
  mkdir -p "$root/agents"
  cp "$REPO"/agents/*.md "$root/agents/"
  printf '%s' "$root"
}

# stamp <root> <config-path> -> runs the block; prints its output; returns its status
stamp() {
  local root="$1" cfg="$2"
  ( HOME="$WORK/nohome" \
    STAMP_ROOT="$root" \
    DEVTEAM_CONFIG="$cfg" \
    bash "$SNIPPET" 2>&1 )
}

# model_of <file> -> the frontmatter model value, or empty
model_of() {
  awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f&&/^model:/{sub(/^model:[[:space:]]*/,"");print;exit}' "$1"
}

# effort_of <file> -> the frontmatter effort value, or empty
effort_of() {
  awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f&&/^effort:/{sub(/^effort:[[:space:]]*/,"");print;exit}' "$1"
}

# md_diff <root> -> prints any difference between the shipped agents/*.md and the
# fixture's copies; silent when they agree. Scoped to the Markdown deliberately:
# agents/ also holds this suite's own scripts, and a whole-directory diff would
# report those as a mismatch on every run.
md_diff() {
  local f
  for f in "$REPO"/agents/*.md; do
    diff -u "$f" "$1/agents/$(basename "$f")" 2>&1
  done
}

mkdir -p "$WORK/nohome"

# --- 1. agreement: shipped defaults reproduce the committed frontmatter -------
#
# Byte-for-byte, not just the effort line: a stamper that mangled anything else
# in the file would pass a narrower assertion.
root=$(newtree agree)
out=$(stamp "$root" "$DEFAULT_CFG"); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "shipped defaults -> stamper exited $rc: $(printf '%s' "$out" | tr '\n' ' ')"
elif [ -z "$(md_diff "$root")" ]; then
  ok "shipped default config reproduces the committed agents/*.md exactly"
else
  bad "shipped default config does NOT match committed agents/*.md:
$(md_diff "$root" | head -20)"
fi

# 1b. Same run again over the already-stamped tree: a re-run must change nothing.
before=$(cat "$root"/agents/*.md)
stamp "$root" "$DEFAULT_CFG" > /dev/null 2>&1
if [ "$before" = "$(cat "$root"/agents/*.md)" ]; then
  ok "idempotent — a second run over a stamped tree changes nothing"
else
  bad "second run over a stamped tree altered the files"
fi

# 1c. Every agent ships exactly `claude-opus-5-5[1m]` at `medium`, in the config
#     and the frontmatter. The exact ID, never the `opus` alias, because the
#     alias moves to a new release unapproved. The `[1m]` variant, because the
#     agents budget more working context than the standard window may hold.
#     Every shipped pin is listed and compared whole, so a pin added, dropped,
#     or changed anywhere turns this red.
EXPECTED_PINS=""
for a in holmes lestrade watson; do
  EXPECTED_PINS="$EXPECTED_PINS
config $a.effort=medium
config $a.model=claude-opus-5-5[1m]
$a.md effort=medium
$a.md model=claude-opus-5-5[1m]"
done
EXPECTED_PINS=$(printf '%s\n' "$EXPECTED_PINS" | sed '/^$/d' | LC_ALL=C sort)
pinned=$(jq -r '.agents | to_entries[] | .key as $a | .value | to_entries[]
                | select(.key == "model" or .key == "effort")
                | "config \($a).\(.key)=\(.value)"' "$DEFAULT_CFG")
for f in "$REPO"/agents/*.md; do
  line=$(awk -v a="$(basename "$f")" '
           NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit}
           f&&/^(model|effort):/{k=$0; sub(/:.*/,"",k); v=$0; sub(/^[^:]*:[[:space:]]*/,"",v)
                                 print a " " k "=" v}' "$f")
  [ -n "$line" ] && pinned="$pinned
$line"
done
pinned=$(printf '%s\n' "$pinned" | sed '/^$/d' | LC_ALL=C sort)
if [ "$pinned" = "$EXPECTED_PINS" ]; then
  ok "every agent ships claude-opus-5-5[1m] at medium, in config and frontmatter"
else
  bad "shipped model/effort pins differ from claude-opus-5-5[1m] at medium for all three:
$(diff <(printf '%s\n' "$EXPECTED_PINS") <(printf '%s\n' "$pinned"))"
fi

# --- 2. a changed value actually lands ---------------------------------------
#
# Discriminating on purpose: every agent gets a DIFFERENT value from what its
# file holds, so a stamper that wrote the frontmatter it already found would
# fail. Holmes and Watson rewrite the `effort: medium` they ship. Lestrade's
# effort line is STRIPPED from the fixture (by grep, never by the stamper) to
# pin INSERTION into frontmatter that carries none.
cfg="$WORK/changed.json"
cat > "$cfg" <<'JSON'
{"agents":{"lestrade":{"effort":"low"},"holmes":{"effort":"high"},"watson":{"effort":"max"}}}
JSON
root=$(newtree changed)
grep -vxF -- "effort: medium" "$REPO/agents/lestrade.md" > "$root/agents/lestrade.md"
if [ "$(effort_of "$root/agents/lestrade.md")/$(effort_of "$root/agents/holmes.md")/$(effort_of "$root/agents/watson.md")" = "/medium/medium" ]; then
  ok "fixture holds no lestrade effort, and the shipped holmes and watson ones"
else
  bad "fixture setup failed — the insertion or rewrite branch below would go untested"
fi
stamp "$root" "$cfg" > /dev/null 2>&1
got="$(effort_of "$root/agents/lestrade.md")/$(effort_of "$root/agents/holmes.md")/$(effort_of "$root/agents/watson.md")"
if [ "$got" = "low/high/max" ]; then
  ok "each agent takes its own configured value (low/high/max)"
else
  bad "expected low/high/max, got '$got'"
fi

# 2b. `xhigh` — the value whose own schema description omits it, and the value no
#     shipped default names any more: all three agents ship `medium`. That is
#     precisely why this case stays.
#     Case 1 can no longer reach `xhigh` through any agent, so this pin is the
#     only thing left in the suite holding the enum's least-documented value.
cfg="$WORK/xhigh.json"
echo '{"agents":{"watson":{"effort":"xhigh"}}}' > "$cfg"
root=$(newtree xhigh)
stamp "$root" "$cfg" > /dev/null 2>&1
if [ "$(effort_of "$root/agents/watson.md")" = "xhigh" ]; then
  ok "xhigh is written — the CLI enum carries it even though the field description does not"
else
  bad "xhigh was not written: got '$(effort_of "$root/agents/watson.md")'"
fi

# 2b-bis. Case is not a typo. The harness lower-cases before checking its enum,
#         so `High` is a value it accepts — rejecting it here would be a silent
#         downgrade dressed up as a warning.
cfg="$WORK/case.json"
echo '{"agents":{"watson":{"effort":"XHigh"}}}' > "$cfg"
root=$(newtree case)
out=$(stamp "$root" "$cfg")
if [ "$(effort_of "$root/agents/watson.md")" = "xhigh" ]; then
  ok "a mixed-case value is normalized and written, not refused"
else
  bad "mixed-case refused or mangled: got '$(effort_of "$root/agents/watson.md")' — $(printf '%s' "$out" | tr '\n' ' ')"
fi

# 2c. The integer form the frontmatter schema documents.
cfg="$WORK/int.json"
echo '{"agents":{"watson":{"effort":32000}}}' > "$cfg"
root=$(newtree int)
stamp "$root" "$cfg" > /dev/null 2>&1
if [ "$(effort_of "$root/agents/watson.md")" = "32000" ]; then
  ok "an integer effort is written"
else
  bad "integer effort not written: got '$(effort_of "$root/agents/watson.md")'"
fi

# --- 3. an absent key REMOVES the line ---------------------------------------
#
# Both paths must stay in lockstep. If the config stops naming a value, the
# scheduled path stops passing its flag, so the frontmatter must stop carrying
# the line too. Leaving a stale line is the silent disagreement this closes.
#
# Watson ships both lines, so each removal acts on a real shipped line rather
# than on a fixture built to be removed. Case 1c pins that Watson ships them,
# so neither removal below can turn vacuous without that case going red first.
# The config keeps the OTHER key each time: what is under test is one absent
# key taking one line, not an empty config taking everything.
#
# without <line> -> the committed watson.md minus exactly that frontmatter line
without() { grep -vxF -- "$1" "$REPO/agents/watson.md"; }
for key in effort model; do
  case "$key" in
    effort) cfg_json='{"agents":{"watson":{"model":"claude-opus-5-5[1m]"}}}'; line="effort: medium" ;;
    model)  cfg_json='{"agents":{"watson":{"effort":"medium"}}}';             line="model: claude-opus-5-5[1m]" ;;
  esac
  cfg="$WORK/absent-$key.json"
  echo "$cfg_json" > "$cfg"
  root=$(newtree "absent-$key")
  if ! grep -qxF -- "$line" "$root/agents/watson.md"; then
    bad "fixture lacks '$line' — the removal below would pass vacuously"
    continue
  fi
  stamp "$root" "$cfg" > /dev/null 2>&1
  # Compared against the committed file rather than by counting lines: what is
  # left has to be the original minus that one line, byte for byte.
  if [ "$(without "$line")" = "$(cat "$root/agents/watson.md")" ]; then
    ok "an absent $key key removes exactly its line, nothing else"
  else
    bad "absent $key key: expected only '$line' gone, got:
$(diff <(without "$line") "$root/agents/watson.md" 2>&1 | head -10)"
  fi
done

# --- 3b. a configured model lands, as an alias or a full ID ------------------
#
# The model has to reach the frontmatter because the Agent tool cannot carry a
# full ID. Every agent ships a model line, so each row here pins the REWRITE of
# it: an alias over the shipped ID, the bare ID with its suffix dropped, and a
# different ID that keeps a bracketed suffix, which must survive the validator.
# INSERTION into frontmatter with no model line is case 7b's job.
cfg="$WORK/model.json"
echo '{"agents":{"lestrade":{"model":"sonnet"},"holmes":{"model":"claude-sonnet-5[1m]"},"watson":{"model":"claude-opus-5-5"}}}' > "$cfg"
root=$(newtree model)
stamp "$root" "$cfg" > /dev/null 2>&1
got="$(model_of "$root/agents/lestrade.md")|$(model_of "$root/agents/holmes.md")|$(model_of "$root/agents/watson.md")"
if [ "$got" = "sonnet|claude-sonnet-5[1m]|claude-opus-5-5" ]; then
  ok "an alias, a suffixed ID, and a bare ID each rewrite the shipped model"
else
  bad "expected 'sonnet|claude-sonnet-5[1m]|claude-opus-5-5', got '$got'"
fi

# 3c. A model value that would change what YAML parses is refused, and the
#     stale line goes with it. A space-and-hash turns the tail into a comment.
cfg="$WORK/model-bogus.json"
echo '{"agents":{"watson":{"model":"opus # pinned","effort":"medium"}}}' > "$cfg"
root=$(newtree model-bogus)
out=$(stamp "$root" "$cfg"); rc=$?
if [ -z "$(model_of "$root/agents/watson.md")" ] \
   && printf '%s' "$out" | grep -qF "'opus # pinned'" && [ "$rc" -eq 0 ]; then
  ok "an unsafe model value is refused by name, its stale line removed, exit 0"
else
  bad "unsafe model: got '$(model_of "$root/agents/watson.md")', rc=$rc — $(printf '%s' "$out" | tr '\n' ' ')"
fi

# 3d. A model value spanning several lines is refused whole. grep matches line
#     by line, so without the newline check the valid first line would pass the
#     value and the second would land in the frontmatter as a YAML key of its
#     own. The fixture's second line is a key the harness would read.
cfg="$WORK/model-multiline.json"
printf '%s\n' '{"agents":{"watson":{"model":"opus\npermissionMode: bypassPermissions","effort":"medium"}}}' > "$cfg"
root=$(newtree model-multiline)
out=$(stamp "$root" "$cfg"); rc=$?
if [ -z "$(model_of "$root/agents/watson.md")" ] \
   && ! grep -q '^permissionMode:' "$root/agents/watson.md" \
   && [ "$(effort_of "$root/agents/watson.md")" = "medium" ] \
   && printf '%s' "$out" | grep -qF "is not an alias or model ID" && [ "$rc" -eq 0 ]; then
  ok "a multi-line model value is refused whole, nothing of it written, exit 0"
else
  bad "multi-line model: got model '$(model_of "$root/agents/watson.md")', rc=$rc, file:
$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f' "$root/agents/watson.md" | grep -v '^description:')"
fi

# --- 4. an unrecognized value is refused, not written -------------------------
cfg="$WORK/bogus.json"
echo '{"agents":{"watson":{"effort":"turbo"}}}' > "$cfg"
root=$(newtree bogus)
out=$(stamp "$root" "$cfg"); rc=$?
if [ -n "$(effort_of "$root/agents/watson.md")" ]; then
  bad "unrecognized value was written: '$(effort_of "$root/agents/watson.md")'"
else
  ok "unrecognized value is not written, and the stale line goes with it"
fi
if printf '%s' "$out" | grep -q "watson" && printf '%s' "$out" | grep -qF "'turbo'"; then
  ok "the refusal names the agent and the offending value"
else
  bad "refusal did not name agent+value: $(printf '%s' "$out" | tr '\n' ' ')"
fi
if [ "$rc" -eq 0 ]; then
  ok "a refused value warns without aborting setup"
else
  bad "a refused value exited $rc — setup would abort over one bad config key"
fi

# --- 5. an unreadable config leaves every file alone --------------------------
for label in malformed missing; do
  cfg="$WORK/$label.json"
  case "$label" in
    malformed) echo '{"agents": {' > "$cfg" ;;
    missing)   rm -f "$cfg" ;;
  esac
  root=$(newtree "cfg-$label")
  out=$(stamp "$root" "$cfg"); rc=$?
  if [ "$rc" -eq 0 ] \
     && [ -z "$(md_diff "$root")" ] \
     && printf '%s' "$out" | grep -q '⚠'; then
    ok "$label config -> warns, touches nothing, exit 0"
  else
    bad "$label config: rc=$rc, files changed or no warning: $(printf '%s' "$out" | tr '\n' ' ')"
  fi
done

# --- 6. no resolvable root -> refuse ------------------------------------------
#
# Fail closed and loudly: nothing was stamped, so interactive dispatch is still
# running on whatever the plugin shipped, and a silent success would hide that.
out=$( HOME="$WORK/nohome" DEVTEAM_CONFIG="$DEFAULT_CFG" \
       env -u CLAUDE_PLUGIN_ROOT STAMP_ROOT="" bash "$SNIPPET" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "Could not locate the plugin's agents/"; then
  ok "no resolvable plugin root -> exit $rc with a reason"
else
  bad "unresolvable root: expected non-zero + reason, got rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"
fi

# --- 7. the frontmatter boundary is real --------------------------------------
#
# A body that happens to open lines with `model:` and `effort:` must survive
# untouched. Without the frontmatter scoping this fixture is silently rewritten,
# and no other case in this file would notice.
#
# The body is compared BYTE FOR BYTE, not by counting surviving lines. Unscoping
# the `model:` rule INSERTS a stray `effort:` into the body rather than deleting
# anything, so a count of the lines that should still be there stays green while
# the file is corrupted — verified by mutation, having first written it that way.
root="$WORK/boundary"
mkdir -p "$root/agents"
cat > "$root/agents/watson.md" <<'MD'
---
name: watson
description: fixture
model: opus
tools: Read
---

Body prose below. These are documentation, not frontmatter:

model: haiku
effort: low

End of body.
MD
cfg="$WORK/boundary.json"
echo '{"agents":{"watson":{"model":"sonnet","effort":"max"}}}' > "$cfg"
body() { awk 'f{print} $0=="---"{n++; if(n==2)f=1}' "$1"; }
body_before=$(body "$root/agents/watson.md")
stamp "$root" "$cfg" > /dev/null 2>&1
if [ "$(model_of "$root/agents/watson.md")/$(effort_of "$root/agents/watson.md")" = "sonnet/max" ] \
   && [ "$body_before" = "$(body "$root/agents/watson.md")" ]; then
  ok "only the frontmatter is rewritten — the body survives byte for byte"
else
  bad "frontmatter boundary leaked: fm='$(model_of "$root/agents/watson.md")/$(effort_of "$root/agents/watson.md")', body diff:
$(diff <(printf '%s\n' "$body_before") <(body "$root/agents/watson.md") 2>&1 | head -10)"
fi

# 7b. No `model:` or `effort:` line at all: both still land, before the closing fence.
root="$WORK/nomodel"
mkdir -p "$root/agents"
printf -- '---\nname: watson\ndescription: fixture\n---\n\nBody.\n' > "$root/agents/watson.md"
stamp "$root" "$cfg" > /dev/null 2>&1
if [ "$(model_of "$root/agents/watson.md")/$(effort_of "$root/agents/watson.md")" = "sonnet/max" ]; then
  ok "model and effort land in frontmatter that carried neither line"
else
  bad "silent frontmatter -> got '$(model_of "$root/agents/watson.md")/$(effort_of "$root/agents/watson.md")'"
fi

# 7c. Unterminated frontmatter: skip it rather than rewriting the whole file.
root="$WORK/unterminated"
mkdir -p "$root/agents"
printf -- '---\nname: watson\nmodel: opus\n\nNo closing fence anywhere.\n' > "$root/agents/watson.md"
sum_before=$(cksum < "$root/agents/watson.md")
out=$(stamp "$root" "$cfg"); rc=$?
if [ "$sum_before" = "$(cksum < "$root/agents/watson.md")" ] \
   && printf '%s' "$out" | grep -qF 'fences missing or unterminated'; then
  ok "unterminated frontmatter -> skipped with a warning, file untouched"
else
  bad "unterminated frontmatter: file changed or no warning (rc=$rc)"
fi

# --- 8. a fourth agent is discovered, never listed ----------------------------
#
# The stamper globs agents/*.md rather than naming the three it knows about. Pin
# that, so a fourth agent takes its configured effort the day it ships with no
# edit to Step 6a. What this guards is REACHABILITY, not the presence of a value:
# shipping without an effort is a supported state, even though no agent ships
# that way today.
root=$(newtree fourth)
printf -- '---\nname: moriarty\ndescription: fixture\nmodel: sonnet\n---\n\nBody.\n' \
  > "$root/agents/moriarty.md"
cfg="$WORK/fourth.json"
echo '{"agents":{"moriarty":{"effort":"medium"}}}' > "$cfg"
stamp "$root" "$cfg" > /dev/null 2>&1
if [ "$(effort_of "$root/agents/moriarty.md")" = "medium" ]; then
  ok "a fourth agent file is stamped with no edit to the step"
else
  bad "fourth agent not stamped: got '$(effort_of "$root/agents/moriarty.md")'"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "agent-effort stamper: $pass passed, $fail failed"
else
  echo "agent-effort stamper: $pass passed, $fail FAILED"
fi
[ "$fail" -eq 0 ]
