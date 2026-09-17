#!/usr/bin/env bash
# Test for the Step 6a agent-effort stamper in commands/setup.md.
#
# It extracts the *real* stamping block from setup.md (between the
# `agent-effort-stamp` sentinel markers) and runs it against fixture trees, so
# the test can never drift from the shipped logic.
#
# Why the step exists: the Agent tool has a per-invocation `model` parameter and
# no effort parameter, so an interactively dispatched sub-agent reads its effort
# from its own frontmatter. The shared config is canonical for the value; this
# step copies it to where an interactive dispatch will actually look.
#
# The headline case is AGREEMENT: the shipped default config in setup.md, run
# through the shipped stamper, must reproduce the committed agents/*.md byte for
# byte. That is the one assertion that goes red when the config defaults and the
# frontmatter drift apart in either direction.
#
# An ABSENT effort is part of that agreement, not an exception to it. Watson
# ships no effort key and no effort line, so re-adding one to the config alone
# makes the stamper write a line the committed file lacks, and re-adding one to
# the frontmatter alone makes it delete a line the committed file has. Either
# reddens case 1. That is the whole mechanical guard on Watson's absence.
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

echo "Testing agent-effort stamper ($SNIPPET):"

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

# --- 2. a changed value actually lands ---------------------------------------
#
# Discriminating on purpose: every agent gets a DIFFERENT value from its shipped
# default, so a stamper that wrote the frontmatter it already found would fail.
# Watson ships no effort line at all, so its row also pins INSERTION into silent
# frontmatter, where lestrade's and holmes's pin the rewrite of a line already
# there. Both branches of the awk, one case.
cfg="$WORK/changed.json"
cat > "$cfg" <<'JSON'
{"agents":{"lestrade":{"effort":"low"},"holmes":{"effort":"medium"},"watson":{"effort":"max"}}}
JSON
root=$(newtree changed)
stamp "$root" "$cfg" > /dev/null 2>&1
got="$(effort_of "$root/agents/lestrade.md")/$(effort_of "$root/agents/holmes.md")/$(effort_of "$root/agents/watson.md")"
if [ "$got" = "low/medium/max" ]; then
  ok "each agent takes its own configured value (low/medium/max)"
else
  bad "expected low/medium/max, got '$got'"
fi

# 2b. `xhigh` — the value whose own schema description omits it, and the value no
#     shipped default names any more: Holmes and Lestrade ship `high`, and Watson
#     ships no effort at all. That is precisely why this case stays. Case 1 can no
#     longer reach `xhigh` through any agent, so this pin is the only thing left
#     in the suite holding the enum's least-documented value.
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
# Both paths must stay in lockstep. If the config stops naming an effort, the
# scheduled path stops passing --effort, so the frontmatter must stop carrying
# one too. Leaving a stale line is the silent disagreement this closes.
#
# The fixture CONSTRUCTS the line it then expects to lose. Watson now ships with
# no effort line, so copying the shipped tree and stamping an absent key would
# assert a removal against a file that had nothing to remove — green whether or
# not the stamper can delete anything at all, and unreachable by construction.
# The seed is written by awk rather than by the stamper, so the code under test
# never builds its own fixture.
cfg="$WORK/absent.json"
echo '{"agents":{"watson":{"model":"opus"}}}' > "$cfg"
root=$(newtree absent)
awk 'NR==1 && $0=="---" {print; print "effort: xhigh"; next} {print}' \
  "$REPO/agents/watson.md" > "$root/agents/watson.md"
if [ "$(effort_of "$root/agents/watson.md")" = "xhigh" ]; then
  ok "seeded a stale effort line for the removal to find"
else
  bad "seeding failed — the removal assertions below would pass vacuously"
fi
stamp "$root" "$cfg" > /dev/null 2>&1
if [ -z "$(effort_of "$root/agents/watson.md")" ]; then
  ok "an absent config key removes the effort line"
else
  bad "absent key left effort '$(effort_of "$root/agents/watson.md")' behind"
fi
# ...and the rest of the file survives that removal. Compared against the
# committed file rather than by counting lines: the seed is one line, so what is
# left has to be the original byte for byte, and no count needs keeping in step.
if diff -q "$REPO/agents/watson.md" "$root/agents/watson.md" > /dev/null 2>&1; then
  ok "removal takes exactly one line, nothing else"
else
  bad "removal changed more than the effort line:
$(diff -u "$REPO/agents/watson.md" "$root/agents/watson.md" 2>&1 | head -10)"
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
echo '{"agents":{"watson":{"effort":"max"}}}' > "$cfg"
body() { awk 'f{print} $0=="---"{n++; if(n==2)f=1}' "$1"; }
body_before=$(body "$root/agents/watson.md")
stamp "$root" "$cfg" > /dev/null 2>&1
if [ "$(effort_of "$root/agents/watson.md")" = "max" ] \
   && [ "$body_before" = "$(body "$root/agents/watson.md")" ]; then
  ok "only the frontmatter is rewritten — the body survives byte for byte"
else
  bad "frontmatter boundary leaked: fm='$(effort_of "$root/agents/watson.md")', body diff:
$(diff <(printf '%s\n' "$body_before") <(body "$root/agents/watson.md") 2>&1 | head -10)"
fi

# 7b. No `model:` line at all: the value still has to land, before the closing fence.
root="$WORK/nomodel"
mkdir -p "$root/agents"
printf -- '---\nname: watson\ndescription: fixture\n---\n\nBody.\n' > "$root/agents/watson.md"
stamp "$root" "$cfg" > /dev/null 2>&1
if [ "$(effort_of "$root/agents/watson.md")" = "max" ]; then
  ok "effort lands even with no model: line to anchor to"
else
  bad "no model: anchor -> effort missing"
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
# shipping without an effort is a supported state, and Watson ships that way.
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
