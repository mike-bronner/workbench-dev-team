#!/bin/bash
# Tests for Step 6.6 of commands/setup.md — the block that installs the ten
# commit, push, and merge ask rules and removes what the old approval gate
# installed.
#
# The block is extracted from the Markdown between its `commit-ask-rules-install`
# sentinels and run for real against a sandbox HOME. It never touches the real
# settings file.

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_MD="$REPO/commands/setup.md"
PASS=0
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required to run this suite"; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/commit-ask-rules-setup.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

BLOCK="$SANDBOX/install-block.sh"
awk '/# >>> commit-ask-rules-install >>>/{f=1;next} /# <<< commit-ask-rules-install <<</{f=0} f' \
  "$SETUP_MD" > "$BLOCK"

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

if [ ! -s "$BLOCK" ]; then
  echo "❌ no installer block found in $SETUP_MD — the sentinels moved or were removed"
  exit 1
fi

new_home() { local home="$SANDBOX/home-$1"; mkdir -p "$home/.claude"; echo "$home"; }
run_block() { env -u WORKBENCH_SETTINGS_FILE HOME="$1" TMPDIR="$SANDBOX" bash "$BLOCK" 2>&1; }
ask_rules() { jq -r '.permissions.ask[]?' "$1/.claude/settings.json" 2>/dev/null; }
has_rule() { printf '%s\n' "$1" | grep -qxF "$2"; }

WANT=('Bash(git commit *)' 'Bash(git push *)' 'Bash(git * commit *)' 'Bash(git * push *)'
      'Bash(git * commit)' 'Bash(git * push)' 'Bash(gh pr merge:*)' 'Bash(gh * pr merge *)' 'Bash(gh * pr merge)' 'Bash(gh api *pulls/*/merge*)')

echo "A clean install:"
HOME_A="$(new_home a)"
OUT=$(run_block "$HOME_A"); STATUS=$?
[ "$STATUS" -eq 0 ] && ok "the block succeeds with no settings file" || bad "the block failed (exit $STATUS): $OUT"
RULES=$(ask_rules "$HOME_A")
for rule in "${WANT[@]}"; do
  has_rule "$RULES" "$rule" && ok "$rule is present" || bad "$rule is missing"
done
[ "$(printf '%s\n' "$RULES" | grep -c .)" = "${#WANT[@]}" ] && ok "exactly ${#WANT[@]} rules, no extras" || bad "unexpected rule list: $RULES"
case "$OUT" in *"ask rules installed"*) ok "it says so" ;; *) bad "no success line: $OUT" ;; esac

echo "Existing settings survive:"
HOME_B="$(new_home b)"
jq -n '{permissions: {ask: ["Bash(rm -rf:*)"], allow: ["Bash(ls:*)"], deny: ["Bash(git push *--force*)"]}, attribution: {commit: ""}}' \
  > "$HOME_B/.claude/settings.json"
OUT=$(run_block "$HOME_B"); STATUS=$?
[ "$STATUS" -eq 0 ] && ok "the block succeeds over existing settings" || bad "the block failed: $OUT"
has_rule "$(ask_rules "$HOME_B")" 'Bash(rm -rf:*)' && ok "an unrelated ask rule is kept" || bad "an unrelated ask rule was dropped"
[ "$(jq -c '.permissions.allow' "$HOME_B/.claude/settings.json")" = '["Bash(ls:*)"]' ] && ok "the allow list is untouched" || bad "the allow list changed"
[ "$(jq -c '.permissions.deny' "$HOME_B/.claude/settings.json")" = '["Bash(git push *--force*)"]' ] && ok "the deny list is untouched" || bad "the deny list changed"
[ "$(jq -r '.attribution.commit' "$HOME_B/.claude/settings.json")" = "" ] && ok "unrelated top-level keys are untouched" || bad "an unrelated key was lost"
ls "$HOME_B/.claude/"settings.json.bak-commit-rules-* >/dev/null 2>&1 && ok "a backup was written" || bad "no backup was written"

echo "Re-running changes nothing:"
BEFORE=$(ask_rules "$HOME_B" | sort)
run_block "$HOME_B" >/dev/null; STATUS=$?
[ "$STATUS" -eq 0 ] && [ "$BEFORE" = "$(ask_rules "$HOME_B" | sort)" ] && ok "a second run adds no duplicate" || bad "a second run changed the rule list"

echo "An install from the approval-gate era loses its rules, and its files are left to the human:"
HOME_U="$(new_home u)"
jq -n --arg abs "Bash(bash $HOME_U/.claude-workbench/bin/approve-commit.sh:*)" \
  '{permissions: {ask: [$abs, "Bash(bash \"$HOME/.claude-workbench/bin/approve-commit.sh\":*)", "Bash(approve:*)", "Bash(rm -rf:*)"]}}' \
  > "$HOME_U/.claude/settings.json"
mkdir -p "$HOME_U/.claude-workbench/bin" "$HOME_U/.claude-workbench/commit-approvals"
echo old > "$HOME_U/.claude-workbench/bin/approve-commit.sh"
echo '{"status":"approved"}' > "$HOME_U/.claude-workbench/commit-approvals/0123456789abcdef"
echo keep > "$HOME_U/.claude-workbench/bin/other-tool.sh"
OUT=$(run_block "$HOME_U"); STATUS=$?
[ "$STATUS" -eq 0 ] && ok "the block succeeds over the old rules" || bad "the block failed: $OUT"
RULES_U=$(ask_rules "$HOME_U")
case "$RULES_U" in *approve*) bad "an approve rule survived: $RULES_U" ;; *) ok "all three approve rules are gone" ;; esac
has_rule "$RULES_U" 'Bash(rm -rf:*)' && ok "...and the unrelated rule is kept" || bad "...but the unrelated rule was dropped"
[ "$(printf '%s\n' "$RULES_U" | grep -c .)" = $((${#WANT[@]} + 1)) ] && ok "...beside the ${#WANT[@]} new rules" || bad "unexpected rules: $RULES_U"
[ -e "$HOME_U/.claude-workbench/bin/approve-commit.sh" ] && [ -e "$HOME_U/.claude-workbench/commit-approvals/0123456789abcdef" ] \
  && ok "the block leaves the old files in place" || bad "the block removed a file itself"
[ -e "$HOME_U/.claude-workbench/bin/other-tool.sh" ] && ok "other files in ~/.claude-workbench/bin are kept" || bad "an unrelated file was removed"
printf '%s\n' "$OUT" | grep -qxF "LEGACY_LEFT $HOME_U/.claude-workbench/bin/approve-commit.sh" \
  && ok "it reports the old approve-commit.sh" || bad "no LEGACY_LEFT line for approve-commit.sh: $OUT"
printf '%s\n' "$OUT" | grep -qxF "LEGACY_LEFT $HOME_U/.claude-workbench/commit-approvals" \
  && ok "it reports the old approval records" || bad "no LEGACY_LEFT line for the records: $OUT"
case "$(run_block "$HOME_A")" in *LEGACY_LEFT*) bad "a clean install reports leftovers" ;; *) ok "a clean install reports no leftovers" ;; esac
STRAY=""
for f in "$HOME_B/.claude/"* "$HOME_B/.claude/".[!.]*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in settings.json | settings.json.bak-commit-rules-*) ;; *) STRAY="$STRAY ${f##*/}" ;; esac
done
[ -z "$STRAY" ] && ok "no temporary file is left beside settings.json" || bad "the block left a stray file beside settings.json:$STRAY"

# Whether this block survives workbench-core's destructive-scope guard is checked
# with every other setup block in commands/test-setup-scope-guard.sh.

echo "The docs name the same rules the block installs:"
README="$REPO/README.md"; GUARD="$REPO/hooks/scripts/commit-guard.sh"
for rule in "${WANT[@]}"; do
  inner=${rule#Bash(}; inner=${inner%)}
  grep -qF -- "- \`$rule\`" "$SETUP_MD" && grep -qF -- "$rule" "$README" && grep -qF -- "\`$inner\`" "$README" \
    && ok "setup and README list $rule" || bad "$rule is missing from the Step 6.6 list or the README"
done
[ "$(grep -cE '^- `Bash\(' "$SETUP_MD")" = "${#WANT[@]}" ] && ok "Step 6.6 lists ${#WANT[@]} rules" || bad "Step 6.6 lists a different number of rules"
grep -qE "Commit prompts: +${#WANT[@]} commit" "$SETUP_MD" && ok "the setup summary says ${#WANT[@]}" || bad "the setup summary states another count"
for rule in "${WANT[@]:0:6}"; do
  inner=${rule#Bash(}; inner=${inner%)}
  grep -qF -- "$inner," "$GUARD" && ok "commit-guard.sh names $inner" || bad "commit-guard.sh does not name $inner"
done

echo "An unreadable settings file fails closed:"
HOME_X="$(new_home x)"
echo '{not json' > "$HOME_X/.claude/settings.json"
OUT=$(run_block "$HOME_X"); STATUS=$?
[ "$STATUS" -ne 0 ] && ok "the block exits non-zero" || bad "the block claimed success: $OUT"
[ "$(cat "$HOME_X/.claude/settings.json")" = '{not json' ] && ok "...and leaves the file as it was" || bad "...but rewrote the file"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
