#!/bin/bash
# Tests for commit-guard.sh. Run directly: bash hooks/scripts/test-commit-guard.sh
#
# Each case feeds a synthetic PreToolUse payload to the guard and asserts deny or
# silent. The guard never answers "ask" or "allow". The permissions.ask rules raise
# the prompt, and hooks/scripts/pipeline-scope.sh answers the pipeline's prompts
# (tested in test-pipeline-scope.sh).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/commit-guard.sh"
HOOKS_JSON="$HERE/../hooks.json"
PASS=0
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required to run this suite"; exit 1; }

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# payload <event> <command> <agent-id> — agent_id is left out when empty, the
# shape a main session sends.
payload() {
  jq -cn --arg e "$1" --arg c "$2" --arg a "$3" \
    '{hook_event_name: $e, tool_name: "Bash", session_id: "s", tool_input: {command: $c}}
     + (if $a == "" then {} else {agent_id: $a} end)'
}

# Every command a case runs joins the differential check at the end. Cases run
# in subshells, so the commands are kept in a file, NUL-separated.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/commit-guard-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SEEN_FILE="$WORK/seen"
: > "$SEEN_FILE"

# run pre <command> <agent-id> <pipeline flag value, or "" for unset> [guard]
run() {
  local body guard="${5:-$GUARD}"
  [ -z "${5:-}" ] && printf '%s\0' "$2" >> "$SEEN_FILE"
  body=$(payload PreToolUse "$2" "$3")
  if [ -n "$4" ]; then
    printf '%s' "$body" | env WORKBENCH_DEV_TEAM_PIPELINE="$4" bash "$guard"
  else
    printf '%s' "$body" | env -u WORKBENCH_DEV_TEAM_PIPELINE bash "$guard"
  fi
}

verdict_of() {
  local out="$1"
  [ -z "$out" ] && { echo silent; return; }
  case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput | (.permissionDecision // .decision.behavior // "?")' 2>/dev/null)" in
    deny) echo deny ;; allow) echo allow ;; ask) echo ask ;; *) echo "unparseable: $out" ;;
  esac
}

reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }

# expect <verdict> <reason fragment or ""> <pre|permission> <command> <agent> <flag>
expect() {
  local want="$1" frag="$2" out got desc
  shift 2
  out=$(run "$@")
  got=$(verdict_of "$out")
  desc="$1 [agent=${3:-none} flag=${4:-unset}] $(printf '%s' "$2" | tr '\n' ' ')"
  if [ "$got" != "$want" ]; then
    bad "$desc — expected $want, got $got"
  elif [ -n "$frag" ] && [[ "$(reason_of "$out")" != *"$frag"* ]]; then
    bad "$desc — denied, but the reason lacks \"$frag\": $(reason_of "$out")"
  else
    ok "$desc → $want"
  fi
}

FORCE="forces or deletes"; PLAIN="as a plain line"

echo "Foreground: a plain commit or push is left to the ask rules"
for c in 'git commit -m "fix: x"' 'git push' 'git push -u origin feat/add-d' 'git -C /repo push origin main' \
         'git -c user.name=x commit -F msg.txt' 'git commit -m x && git push' 'git push --follow-tags' \
         'git push --no-verify' 'git push origin HEAD:refs/heads/x' 'git push --dry-run' 'git push -oF' \
         'git commit -m "load env"' 'bash run-tests.sh && git push' 'printenv && git push' \
         'git -c core.hooksPath=/dev/null commit -m x' 'FOO=1 make && git push' 'export HUSKY=0; git push' \
         'git commit -m "set X=1 in config"' 'git commit -m "a=b c"' 'git commit -m "x; A=1" && git push' \
         "git commit -m 'y | B=\"2\"' && git push"; do
  expect silent "" pre "$c" "" ""
done

echo "Foreground: quotes in separate arguments do not pair across an unquoted && or ;"
for c in 'HUSKY=0 npm test "unit" && git commit -m "fix, then git push"' \
         "$(printf "git commit -F - <<'EOF'\nfix: x\n\nDEBUG=1 makes 'it' verbose; don't git push\nEOF")"; do
  expect silent "" pre "$c" "" ""
done

echo "Foreground: commands that are not a commit or push stay silent"
for c in 'git status' 'git log --oneline -5' 'grep -rn push README.md' 'cat .git/COMMIT_EDITMSG' \
         'git commit-tree HEAD^{tree} -m x' 'git status; echo push' 'git log | grep commit' 'digit push --force' \
         'bash -c "echo commit"' 'ls /usr/bin/git'; do
  expect silent "" pre "$c" "" ""
done

echo "Force and deletion pushes are refused"
for c in 'git push --force' 'git push -f' 'git push -uf origin x' 'git push --force-with-lease' 'git push --forc' \
         'git push --force-if-includes' 'git push --mirror' 'git push --delete origin x' 'git push -d origin x' \
         'git push --prune origin' 'git push origin +main' 'git push origin :old' 'git -C /x push --force' \
         'git commit -m x && git push -f'; do
  expect deny "$FORCE" pre "$c" "" ""
done

echo "Wrapped commits and pushes are refused, so the ask rules can see them"
for c in 'bash -c "git push"' "sh -c 'git commit -m x'" "zsh -lc 'git push'" '/bin/bash -c "cd x && git push"' \
         'bash -x -c "git push"' 'env git push' 'env GIT_DIR=x git commit -m y' '/usr/bin/env git push' \
         'eval "git push"' '/usr/bin/git push' '/opt/homebrew/bin/git -C . commit -m x' \
         "$(printf 'cd x\nenv git push')"; do
  expect deny "$PLAIN" pre "$c" "" ""
done

echo "A leading NAME=value is refused: the ask rules strip only known-safe variables"
for c in 'HUSKY=0 git commit -m x' 'SKIP=lint git commit -m x' 'GIT_TRACE=1 git push' 'A=1 B="x y" git push' \
         'cd x && HUSKY=0 git commit -m y' '(HUSKY=0 git push)' ' _X=1 git -C . push' \
         "$(printf 'cd x\nGIT_TRACE=1 git push')" 'MSG="a; b" git commit -m x' "M='a && b' git push" \
         'A="x | y" B=1 git push' "$(printf 'A="x\ny" git push')" 'A=x\"y git push' "A=it\\'s git push"; do
  expect deny "$PLAIN" pre "$c" "" ""
done
out=$(run pre 'HUSKY=0 git commit -m x' "" "")
[[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" == *"NAME=value"* ]] \
  && ok "the refusal names the NAME=value form" || bad "the refusal does not name NAME=value: $out"

echo "A sub-agent may not commit or push, wherever the command runs it"
for c in 'git commit -m x' 'git push' 'git -C . push origin feat' 'cd x && git commit -am y' '(git push)' \
         'echo $(git commit -m x)' "$(printf 'git status\ngit push')" 'git -C dir commit -m x' \
         'git -c k=v push' 'git --git-dir=x commit -m y' 'git --git-dir x --work-tree y push' 'git --no-pager push' \
         'git -C "a b" -c user.name="M B" commit -m x' 'git status | git push' 'git status; git commit -m x' \
         'git status || git push' 'sudo git push' 'if git push; then echo y; fi' 'xargs git commit -m x' \
         'time git push' '! git push' '{ git push; }' 'echo `git push`' 'git log --grep=x && git push' \
         'grep -rn "git push" README.md; git push'; do
  expect deny "sub-agent does not commit or push" pre "$c" agent-1 ""
done
echo "A sub-agent's escaped, quoted, redirected, continued, or runner-led commit is refused"
for c in '\git commit -m x' '"git" commit -m x' "'git' push" 'git "commit" -m x' \
         '2>/dev/null git push' '>log git push' '2>&1 git commit -m x' "$(printf 'git \\\ncommit -m x')" \
         'A=1 B=2 git push origin x' 'doas git push' 'find . -exec git commit -m x \;' \
         'find . -execdir git push \;' 'caffeinate git push' 'stdbuf -oL git push' 'flock /tmp/l git push' \
         'parallel git push ::: a' 'watch git push' 'ionice -c3 git push' 'noglob git push' \
         'nocorrect git push' 'git log; doas git push' '\gh pr merge 5' 'doas gh pr merge 5'; do
  out=$(run pre "$c" agent-1 "")
  [ "$(verdict_of "$out")" = deny ] && ok "sub-agent bypass: $(printf '%s' "$c" | tr '\n' ' ') → deny" \
    || bad "sub-agent bypass: $(printf '%s' "$c" | tr '\n' ' ') was not refused: $out"
done
echo "Every force or delete spelling is refused in every lane"
for c in '2>/dev/null git push --force' '"git" push -f' '\git push -f' 'git "push" --force' \
         'doas git push --force' "$(printf 'git \\\npush -f')" 'find . -exec git push -f \;' \
         "'git' push origin :old" 'stdbuf -oL git push --delete origin x' 'A=1 B=2 git push +main' \
         "awk 'BEGIN { system(\"git push --force\") }'"; do
  expect deny "$FORCE" pre "$c" "" ""
  expect deny "$FORCE" pre "$c" agent-1 ""
  expect deny "$FORCE" pre "$c" watson-run 1
done
echo "A read led by a known reader passes, even unquoted"
for c in 'echo git push' 'grep -rn git push .' 'printf "%s" git commit' 'cat notes | grep git push' \
         '2>/dev/null grep -rn git push .' 'git log --grep "fix git push" --oneline'; do
  expect silent "" pre "$c" agent-1 ""
done
echo "A sub-agent's wrapped or assigned commit is still refused"
for c in 'bash -c "git push"' 'env git commit -m x' 'eval "git push"' 'HUSKY=0 git commit -m x' '/usr/bin/git push'; do
  out=$(run pre "$c" agent-1 "")
  [ "$(verdict_of "$out")" = deny ] && ok "sub-agent wrapped: $c → deny" || bad "sub-agent wrapped: $c was not refused: $out"
done
echo "A sub-agent's read that only names the words passes"
for c in 'git log --grep=commit' 'git log --grep commit' 'git grep push' 'grep -rn "git commit" .' \
         'grep -rn "git push" README.md' "grep -n 'git commit' skills/x.md" 'rg "gh pr merge"' \
         'git show HEAD -- commit-guard.sh' 'git diff' 'git diff -- hooks/scripts/commit-guard.sh' \
         'cd x && git log --grep push | head' 'git status | grep "git push"' 'git log --oneline && git grep -n commit' \
         'git log -S "git commit" --oneline' "grep -E 'git (commit|push)' x.md" 'rg -n "gh api repos/o/r/pulls/5/merge" .' \
         'echo "run git push later"' 'git log --format=%s | grep -c push' 'gh search prs "pr merge"'; do
  expect silent "" pre "$c" agent-1 ""
  expect silent "" pre "$c" watson-run 1
done
echo "The sub-agent refusal no longer points at a Grep tool"
out=$(run pre 'git push' agent-1 "")
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
[[ $ctx != *Grep* && $ctx == *"Read tool"* ]] && ok "the refusal names the Read tool and no Grep tool" \
  || bad "the refusal still names Grep, or lacks the Read tool: $ctx"
echo "A sub-agent keeps its reads"
for c in 'git status' 'git log --oneline' 'git diff HEAD' 'grep -rn push README.md' \
         'git commit-tree HEAD^{tree} -m x' 'git log | grep push' 'git status; echo commit' 'ls .git/refs/push'; do
  expect silent "" pre "$c" agent-1 ""
done
echo "The flag must be exactly 1"
for flag in 0 true yes " 1"; do
  expect deny "sub-agent does not commit or push" pre 'git commit -m x' agent-1 "$flag"
done

echo "The pipeline (flag set, agent_id present from --agent) commits and pushes"
expect silent "" pre 'git commit -m x' watson-run 1
expect silent "" pre 'git push -u origin feat/x' watson-run 1
expect deny "$FORCE" pre 'git push --force' watson-run 1
expect deny "$PLAIN" pre 'bash -c "git push"' watson-run 1
expect deny "$PLAIN" pre 'HUSKY=0 git commit -m x' watson-run 1

MERGE="does not merge a pull request"
echo "A pull request merge: prompted in the foreground, refused for a sub-agent and for the pipeline"
for c in 'gh pr merge 5' 'gh pr merge 5 --squash --delete-branch' 'gh -R o/r pr merge 5' 'gh --repo o/r pr  merge' \
         'gh api -X PUT repos/o/r/pulls/5/merge' 'gh api repos/o/r/pulls/5/merge -X PUT' 'cd x && gh pr merge 5 --admin'; do
  expect silent "" pre "$c" "" ""
  expect deny "$MERGE" pre "$c" agent-1 ""
  expect deny "$MERGE" pre "$c" watson-run 1
  expect deny "$MERGE" pre "$c" "" 1
done
echo "Merge-like commands that are not a pull request merge stay silent"
for c in 'gh pr view 5 --json mergeable' 'gh pr list' 'gh api repos/o/r/pulls/5/mergeable' 'git merge origin/main' \
         'gh pr checks 5' 'ghx pr merge 5'; do
  expect silent "" pre "$c" agent-1 ""
  expect silent "" pre "$c" watson-run 1
done
echo "A wrapped merge is refused in the foreground, so the ask rules see it"
for c in 'bash -c "gh pr merge 5"' 'env gh pr merge 5' 'GH_TOKEN=x gh pr merge 5' '/opt/homebrew/bin/gh pr merge 5' \
         "eval 'gh -R o/r pr merge 5'"; do
  expect deny "$PLAIN" pre "$c" "" ""
done

echo "An unreadable payload fails closed"
out=$(printf 'not json: git push' | env -u WORKBENCH_DEV_TEAM_PIPELINE bash "$GUARD")
[ "$(verdict_of "$out")" = deny ] && ok "unreadable text that names a push is refused" || bad "unreadable text was not refused: $out"
out=$(printf 'not json: git push' | env WORKBENCH_DEV_TEAM_PIPELINE=1 bash "$GUARD")
[ "$(verdict_of "$out")" = deny ] && ok "...in the pipeline too" || bad "unreadable text passed in the pipeline: $out"
out=$(printf 'not json: gh pr merge 5' | env -u WORKBENCH_DEV_TEAM_PIPELINE bash "$GUARD")
[ "$(verdict_of "$out")" = deny ] && ok "...and one that names a merge" || bad "unreadable merge text was not refused: $out"
out=$(printf 'not json: ls' | env -u WORKBENCH_DEV_TEAM_PIPELINE bash "$GUARD")
[ -z "$out" ] && ok "unreadable text that names no commit, push, or merge stays silent" || bad "unreadable ls was refused: $out"

NOJQ="$WORK/nojq"
mkdir "$NOJQ"
ln -s "$(command -v cat)" "$NOJQ/cat"
out=$(payload PreToolUse 'git push' "" | env -u WORKBENCH_DEV_TEAM_PIPELINE PATH="$NOJQ" "$BASH" "$GUARD")
[ "$(verdict_of "$out")" = deny ] && ok "with no jq on PATH, a push is refused" || bad "with no jq, a push was not refused: $out"

echo "Every denial is valid JSON"
for c in 'git push --force' 'bash -c "git push"'; do
  out=$(run pre "$c" "" "")
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "parses: $c" || bad "not JSON: $out"
done
out=$(run pre 'git push' agent-1 "")
printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "parses: the sub-agent denial" || bad "not JSON: $out"
out=$(run pre 'gh pr merge 5' agent-1 "")
printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "parses: the merge denial" || bad "not JSON: $out"

echo "hooks.json wires PreToolUse to this script, and nothing else to it"
pre=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$HOOKS_JSON" | grep -c 'commit-guard.sh"$')
all=$(jq -r '.. | .command? // empty' "$HOOKS_JSON" | grep -c 'commit-guard.sh')
[ "$pre" = 1 ] && ok "PreToolUse Bash runs commit-guard.sh" || bad "PreToolUse Bash wiring is missing or duplicated ($pre)"
[ "$all" = 1 ] && ok "no other event runs commit-guard.sh" || bad "commit-guard.sh is wired $all times"

echo "No module in the cwd or on PYTHONPATH loads into the read allowlist"
# The allowlist runs in Python for a line the text match caught. A module planted
# in the hook's cwd or on PYTHONPATH must never run there. Each one only leaves a
# mark, and the verdicts must stay normal.
PLANT_CWD="$WORK/plant-cwd"; PLANT_PATH="$WORK/plant-path"; PLANT_MARK="$WORK/planted-module-ran"
mkdir -p "$PLANT_CWD" "$PLANT_PATH"
for d in "$PLANT_CWD" "$PLANT_PATH"; do
  for m in re json glob os read_allowlist sitecustomize usercustomize; do
    printf 'open(%s, "a").write("%s\\n")\n' "'$PLANT_MARK'" "$m" > "$d/$m.py"
  done
done
planted() { # planted <command>: the guard run as a sub-agent from the planted cwd
  local body
  body=$(payload PreToolUse "$1" agent-1)
  verdict_of "$(cd "$PLANT_CWD" && printf '%s' "$body" | env -u WORKBENCH_DEV_TEAM_PIPELINE \
    PYTHONPATH="$PLANT_PATH" PYTHONSTARTUP="$PLANT_PATH/re.py" bash "$GUARD")"
}
[ "$(planted 'grep -rn "git push" README.md')" = silent ] && ok "planted modules: an allowlisted read still passes" \
  || bad "planted modules: an allowlisted read was refused"
[ "$(planted 'git push')" = deny ] && ok "planted modules: a sub-agent push is still refused" \
  || bad "planted modules: a sub-agent push was not refused"
[ ! -e "$PLANT_MARK" ] && ok "no planted module ran inside the allowlist" \
  || bad "a planted module ran inside the allowlist: $(tr '\n' ' ' < "$PLANT_MARK")"

echo "Holmes's second-round bypasses are refused for a sub-agent"
# shellcheck source=testdata/hostile-commands.sh
. "$HERE/testdata/hostile-commands.sh"
for c in 'echo "$(git push)"' 'x="$(git commit -m y)"' 'echo \"; git push; echo \"' "\$'git' push origin x" \
         'git -c alias.ci=commit ci -m x' '{git,} push' '=git push' "awk 'BEGIN{system(\"git push\")}'" \
         'echo "$(gh pr merge 5)"' "$(printf "# it's here\ngit push")" '$"git" push' 'git${IFS}push' \
         "sed '1e git push' f" 'gh api -X PUT "repos/o/r/pulls/5/merge?merge_method=squash"' \
         'echo git push | sh' 'echo git push > x.sh; ./x.sh' 'cat <(git push)' 'rg --pre "git push" x'; do
  out=$(run pre "$c" agent-1 "")
  [ "$(verdict_of "$out")" = deny ] && ok "second round: $(printf '%s' "$c" | tr '\n' ' ') → deny" \
    || bad "second round: $(printf '%s' "$c" | tr '\n' ' ') was not refused: $out"
done
echo "A force push assembled from parts is refused in every lane"
for c in "$(printf 'git push origin --fo\\\nrce')" "git push \$'--force'" "git push origin \$'+main'"; do
  expect deny "$FORCE" pre "$c" "" ""
  expect deny "$FORCE" pre "$c" agent-1 ""
  expect deny "$FORCE" pre "$c" watson-run 1
done

echo "Differential: nothing main's guard refused is allowed now, outside the named reads"
# The reads a sub-agent may now run that main refused. Only a read that names a
# guarded word belongs here. Anything else main refused must stay refused.
READS_OK=('git log --grep=commit' 'git log --grep commit' 'git grep push' 'grep -rn "git commit" .'
  'grep -rn "git push" README.md' "grep -n 'git commit' skills/x.md" 'rg "gh pr merge"'
  'git show HEAD -- commit-guard.sh' 'git diff -- hooks/scripts/commit-guard.sh'
  'cd x && git log --grep push | head' 'git status | grep "git push"' 'git log --oneline && git grep -n commit'
  'git log -S "git commit" --oneline' "grep -E 'git (commit|push)' x.md" 'rg -n "gh api repos/o/r/pulls/5/merge" .'
  'echo "run git push later"' 'git log --format=%s | grep -c push' 'gh search prs "pr merge"' 'echo git push'
  'grep -rn git push .' 'printf "%s" git commit' 'cat notes | grep git push' '2>/dev/null grep -rn git push .'
  'git log --grep "fix git push" --oneline' 'git log | grep commit' 'git log | grep push'
  'git log --grep=push -- *')
for c in "${READS_OK[@]}"; do
  printf '%s' "$c" | python3 -I "$HERE/read_allowlist.py" \
    && ok "READS_OK entry is allowlisted: $c" || bad "READS_OK entry is not an allowlisted read: $c"
done
MAIN="$HERE/testdata/commit-guard-621f3fb.sh"
is_read() { local r; for r in "${READS_OK[@]}"; do [ "$r" = "$1" ] && return 0; done; return 1; }
SEEN=()
while IFS= read -r -d '' c; do SEEN+=("$c"); done < <(sort -zu "$SEEN_FILE")
compared=0; flagged=0
for c in "${HOSTILE[@]}" "${SEEN[@]}"; do
  for lane in ":" "agent-1:" "watson-run:1" ":1"; do
    a=${lane%%:*}; f=${lane#*:}; compared=$((compared + 1))
    [ "$(verdict_of "$(run pre "$c" "$a" "$f" "$MAIN")")" = deny ] || continue
    [ "$(verdict_of "$(run pre "$c" "$a" "$f" "$GUARD")")" = deny ] && continue
    is_read "$c" && continue
    flagged=$((flagged + 1)); bad "main refused, now allowed [agent=${a:-none} flag=${f:-unset}]: $(printf '%s' "$c" | tr '\n' ' ')"
  done
done
for c in "${ROUND4[@]}"; do
  for lane in ":" "agent-1:" "watson-run:1" ":1"; do
    a=${lane%%:*}; f=${lane#*:}
    check_main="$(verdict_of "$(run pre "$c" "$a" "$f" "$MAIN")")"
    [ "$(verdict_of "$(run pre "$c" "$a" "$f" "$GUARD")")" = "$check_main" ] \
      && ok "round 4, main's verdict ($check_main) [agent=${a:-none} flag=${f:-unset}]: $c" \
      || bad "round 4 differs from main ($check_main) [agent=${a:-none} flag=${f:-unset}]: $c"
  done
done
[ "$flagged" = 0 ] && ok "differential: $compared runs (${#HOSTILE[@]} hostile forms and ${#SEEN[@]} suite commands, 4 lanes), none newly allowed"
for c in "${READS_OK[@]}"; do expect silent "" pre "$c" agent-1 ""; done

echo "Size is part of the design"
lines=$(wc -l < "$GUARD")
[ "$lines" -lt 100 ] && ok "commit-guard.sh is $lines lines, under 100" || bad "commit-guard.sh grew to $lines lines"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
