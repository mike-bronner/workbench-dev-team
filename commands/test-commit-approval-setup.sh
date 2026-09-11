#!/bin/bash
# Tests for Step 6.6 of commands/setup.md — the block that installs
# bin/approve-commit.sh and adds the permission rules that make it prompt.
#
# The block is extracted from the Markdown between its `commit-approval-install`
# sentinels and run for real against a sandbox HOME. A setup step nobody executes
# is a setup step nobody can trust: the gate denies every interactive commit, and
# this block is the only thing that can make an approval possible again.

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_MD="$REPO/commands/setup.md"
PASS=0
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required to run this suite"; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/commit-approval-setup.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

BLOCK="$SANDBOX/install-block.sh"
awk '/# >>> commit-approval-install >>>/{f=1;next} /# <<< commit-approval-install <<</{f=0} f' \
  "$SETUP_MD" > "$BLOCK"

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

if [ ! -s "$BLOCK" ]; then
  echo "❌ no installer block found in $SETUP_MD — the sentinels moved or were removed"
  exit 1
fi

# A fresh HOME per case: the block's whole job is to change one, so no case may
# inherit another's leftovers.
new_home() {
  local home="$SANDBOX/home-$1"
  mkdir -p "$home/.claude/plugins"
  echo "$home"
}

# A registry naming this working tree as the installed plugin — the path the
# block is supposed to prefer over the running root.
write_registry() { # write_registry <home> <install-path>
  jq -n --arg path "$2" '{plugins: {"workbench-dev-team@claude-workbench": [
    {enabled: true, installPath: $path, version: "9.9.9"}]}}' \
    > "$1/.claude/plugins/installed_plugins.json"
}

run_block() { # run_block <home> [env assignments...]
  local home="$1"; shift
  env -u CLAUDE_PLUGIN_ROOT -u WORKBENCH_SETTINGS_FILE -u WORKBENCH_COMMIT_APPROVAL_DIR \
    HOME="$home" TMPDIR="$SANDBOX" "$@" bash "$BLOCK" 2>&1
}

ask_rules() { jq -r '.permissions.ask[]?' "$1/.claude/settings.json" 2>/dev/null; }

echo "A clean install:"
HOME_A="$(new_home a)"
write_registry "$HOME_A" "$REPO"
OUT=$(run_block "$HOME_A"); STATUS=$?
if [ "$STATUS" -eq 0 ]; then ok "the block succeeds"; else bad "the block failed (exit $STATUS): $OUT"; fi
if [ -x "$HOME_A/.claude-workbench/bin/approve-commit.sh" ]; then
  ok "approve-commit.sh is installed and executable"
else
  bad "approve-commit.sh was not installed"
fi
RULES=$(ask_rules "$HOME_A")
case "$RULES" in
  *'Bash(bash "$HOME/.claude-workbench/bin/approve-commit.sh":*)'*) ok "the \$HOME-spelled ask rule is present" ;;
  *) bad "the \$HOME-spelled ask rule is missing" ;;
esac
case "$RULES" in
  *"Bash(bash $HOME_A/.claude-workbench/bin/approve-commit.sh:*)"*) ok "the absolute ask rule is present" ;;
  *) bad "the absolute ask rule is missing" ;;
esac
case "$OUT" in
  *"Commit approval installed"*) ok "the end-to-end check passes and says so" ;;
  *) bad "the block did not confirm the end-to-end check: $OUT" ;;
esac
# The gate's ask rules must never turn into a git commit ask rule. That shape
# always prompts, and the headless pipeline has nobody to answer it.
case "$RULES" in
  *"git commit"*) bad "a git commit ask rule was added — this deadlocks the pipeline" ;;
  *) ok "no git commit ask rule was added" ;;
esac

echo "Existing settings survive:"
HOME_B="$(new_home b)"
write_registry "$HOME_B" "$REPO"
jq -n '{permissions: {ask: ["Bash(rm -rf:*)"], allow: ["Bash(ls:*)"]}, attribution: {commit: ""}}' \
  > "$HOME_B/.claude/settings.json"
OUT=$(run_block "$HOME_B"); STATUS=$?
if [ "$STATUS" -eq 0 ]; then ok "the block succeeds over existing settings"; else bad "the block failed: $OUT"; fi
case "$(ask_rules "$HOME_B")" in
  *"Bash(rm -rf:*)"*) ok "an unrelated ask rule is kept" ;;
  *) bad "an unrelated ask rule was dropped" ;;
esac
if [ "$(jq -r '.permissions.allow[0]' "$HOME_B/.claude/settings.json")" = "Bash(ls:*)" ]; then
  ok "the allow list is untouched"
else
  bad "the allow list was rewritten"
fi
if [ "$(jq -r '.attribution.commit' "$HOME_B/.claude/settings.json")" = "" ]; then
  ok "unrelated top-level keys are untouched"
else
  bad "an unrelated top-level key was lost"
fi

echo "Re-running changes nothing:"
BEFORE=$(ask_rules "$HOME_B" | sort)
OUT=$(run_block "$HOME_B"); STATUS=$?
AFTER=$(ask_rules "$HOME_B" | sort)
if [ "$STATUS" -eq 0 ] && [ "$BEFORE" = "$AFTER" ]; then
  ok "a second run adds no duplicate rules"
else
  bad "a second run changed the rule list"
fi

echo "Source resolution:"
HOME_C="$(new_home c)"
# No registry entry, but a running root that has the script: the block takes it
# and says out loud that the copy may be stale.
OUT=$(run_block "$HOME_C" CLAUDE_PLUGIN_ROOT="$REPO"); STATUS=$?
if [ "$STATUS" -eq 0 ]; then ok "it falls back to the running plugin root"; else bad "the fallback failed: $OUT"; fi
case "$OUT" in
  *"can be stale"*) ok "...and warns that the running root can be stale" ;;
  *) bad "...but says nothing about staleness" ;;
esac

HOME_D="$(new_home d)"
OUT=$(run_block "$HOME_D"); STATUS=$?
if [ "$STATUS" -ne 0 ]; then ok "no registry and no running root is a hard failure"; else bad "it claimed success with no source"; fi
# Assert the reason, not just the exit status: a later guard also fails on an
# unresolved source, so a status-only check passes with this one deleted.
case "$OUT" in
  *"Could not locate bin/approve-commit.sh"*) ok "...for the stated reason" ;;
  *) bad "...but not because the source was unresolvable: $OUT" ;;
esac
if [ ! -e "$HOME_D/.claude-workbench/bin/approve-commit.sh" ]; then
  ok "...and nothing was installed"
else
  bad "...but something was installed anyway"
fi

echo "A source whose own tests fail is never installed:"
HOME_E="$(new_home e)"
BROKEN="$SANDBOX/broken-plugin"
mkdir -p "$BROKEN/bin"
cp "$REPO/bin/approve-commit.sh" "$BROKEN/bin/approve-commit.sh"
printf '#!/bin/bash\necho "  ❌ pretend failure"\nexit 1\n' > "$BROKEN/bin/test-approve-commit.sh"
chmod +x "$BROKEN/bin/test-approve-commit.sh"
write_registry "$HOME_E" "$BROKEN"
OUT=$(run_block "$HOME_E"); STATUS=$?
if [ "$STATUS" -ne 0 ]; then ok "a failing test suite stops the install"; else bad "it installed a script that fails its own suite"; fi
if [ ! -e "$HOME_E/.claude-workbench/bin/approve-commit.sh" ]; then
  ok "...and nothing was installed"
else
  bad "...but the script was installed anyway"
fi
if [ ! -e "$HOME_E/.claude/settings.json" ]; then
  ok "...and no permission rules were added"
else
  bad "...but the rules were added for a script that is not there"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
