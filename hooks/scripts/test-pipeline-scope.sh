#!/bin/bash
# Tests for pipeline-scope.sh. Run directly: bash hooks/scripts/test-pipeline-scope.sh
#
# Each case feeds a synthetic PermissionRequest payload to the hook and asserts
# allow or silent. Silent means the -p run denies the call. The roots are real
# directories in a sandbox: TMPDIR stands in for where mktemp -d lands, HOME holds
# Developer/scratchpad and a settings file with deny rules, and a session
# scratchpad sits under /private/tmp/claude-*/<project>/<session id>/, or under
# /tmp/claude-* where /private/tmp does not exist (Linux).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/pipeline-scope.sh"
HOOKS_JSON="$HERE/../hooks.json"
PIPELINE_MD="$HERE/../../references/watson/index-mode-pipeline.md"
PASS=0
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required to run this suite"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "❌ git is required to run this suite"; exit 1; }

SANDBOX="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-scope.XXXXXX")" && pwd -P)"
# On macOS /tmp is a link to /private/tmp, and the hook keeps a session root only
# when its physical path is the path itself, so the fixture lives at the real path.
TMPROOT=/tmp; [ -d /private/tmp ] && TMPROOT=/private/tmp
SESSION_BASE="$(mktemp -d "$TMPROOT/claude-wbdt-test.XXXXXX")"
trap 'rm -rf "$SANDBOX" "$SESSION_BASE"' EXIT

T="$SANDBOX/T"              # $TMPDIR: where mktemp -d lands
H="$SANDBOX/home"           # $HOME
OUT="$SANDBOX/outside"      # in no root
CLONE="$T/tmp.clone"        # the run's project folder; its default branch is main
DEV="$T/tmp.dev"            # a clone whose default branch is develop
BARE="$T/tmp.bare"          # a clone with no origin/HEAD
SID="wbdt-$$-$RANDOM"
SP="$SESSION_BASE/proj/$SID/scratchpad"
mkdir -p "$CLONE/src" "$CLONE/empty" "$H/Developer/scratchpad/work" "$H/.claude" "$OUT/x" "$OUT/wt" "$SP/x"
# $OUT is a real repository, so a git -C into it gets past rev-parse and only the
# roots refuse it.
for repo in "$CLONE" "$DEV" "$BARE" "$OUT"; do git init -q "$repo"; done
git -C "$CLONE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$CLONE" config alias.p '!sh -c x'   # an alias that runs a program
# Hostile clones in a root: one whose .git file points at a git dir outside every
# root, and one whose core.worktree is outside. Each fails one half of the check.
git init -q --separate-git-dir "$OUT/hostile.git" "$T/tmp.gitfile"
git init -q "$T/tmp.wt"; git -C "$T/tmp.wt" config core.worktree "$OUT/wt"
git -C "$DEV" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
ln -s "$OUT" "$CLONE/link"
# Names a shell expands when unquoted. Quoted, they are plain names in the clone.
mkdir -p "$CLONE/~/x"; : > "$CLONE/=ls"
# A second scratchpad that a session id holding .. could climb into, and a
# directory that lets an id of x/../<id> resolve to the real one.
mkdir -p "$SESSION_BASE/proj2/scratchpad/y" "$SESSION_BASE/proj/x"
# Planted session scratchpads: a link at the scratchpad, and a link at the id.
LINKSID="wbdt-link-$$-$RANDOM"; UPSID="wbdt-up-$$-$RANDOM"
mkdir -p "$SESSION_BASE/proj/$LINKSID" "$SANDBOX/elsewhere/scratchpad/z"
ln -s "$OUT" "$SESSION_BASE/proj/$LINKSID/scratchpad"
ln -s "$SANDBOX/elsewhere" "$SESSION_BASE/proj/$UPSID"
# A planted ~/Developer/scratchpad.
mkdir -p "$SANDBOX/home4/Developer"; ln -s "$OUT" "$SANDBOX/home4/Developer/scratchpad"
# A home that is itself a repository, so git run in its scratchpad acts outside.
mkdir -p "$SANDBOX/home5/Developer/scratchpad/work"; git init -q "$SANDBOX/home5"
# A push source must be a local branch, so each clone gets one commit and real
# branches. CLONE also gets tags, one of them sharing a branch's name, and a
# remote-tracking ref, none of which a push may send.
seed() {
  local r=$1 b; shift; git -C "$r" symbolic-ref HEAD refs/heads/seed
  git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --allow-empty -m seed
  for b; do git -C "$r" branch "$b"; done
}
seed "$CLONE" feature/12-add-x feature/12-x feature/x feature/y both
seed "$DEV" main feature/x; seed "$BARE" feature/x
git -C "$CLONE" symbolic-ref HEAD refs/heads/feature/12-x
for t in v1 both feature/t; do git -C "$CLONE" -c tag.gpgsign=false tag "$t"; done
git -C "$CLONE" update-ref refs/remotes/origin/main HEAD
for r in heads/both tags/v1 tags/both tags/feature/t remotes/origin/main; do
  git -C "$CLONE" rev-parse -q --verify "refs/$r" >/dev/null || { echo "❌ fixture is missing refs/$r"; exit 1; }
done
SHA=$(git -C "$CLONE" rev-parse HEAD)
# The deny rules from Mike's settings that name git or rm, plus two on git log and
# git diff, which nothing else here refuses. Those cases show the rules are read,
# and the diff rule's trailing " *" is what a bare git diff must still match.
jq -n '{permissions: {deny: ["Bash(sudo:*)", "Bash(shred:*)", "Bash(git filter-branch:*)",
  "Bash(git reflog expire:*)", "Bash(git push *--force*)", "Bash(git push * -f *)", "Bash(git log:*)",
  "Bash(git diff *)", "Read(./.env)"]}}' \
  > "$H/.claude/settings.json"

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# run <cwd> <command> [flag, default 1] [session id] [home]
run() {
  local flag=() ; [ -n "${3-1}" ] && flag=(WORKBENCH_DEV_TEAM_PIPELINE="${3-1}")
  jq -cn --arg c "$2" --arg d "$1" --arg s "${4-$SID}" \
    '{hook_event_name: "PermissionRequest", tool_name: "Bash", session_id: $s, cwd: $d, tool_input: {command: $c}}' \
    | env -i PATH="$PATH" HOME="${5-$H}" TMPDIR="$T" ${flag[@]+"${flag[@]}"} bash "$HOOK"
}
verdict_of() {
  [ -z "$1" ] && { echo silent; return; }
  [ "$(printf '%s' "$1" | jq -r '.hookSpecificOutput | "\(.hookEventName) \(.decision.behavior)"' 2>/dev/null)" = "PermissionRequest allow" ] \
    && echo allow || echo "unparseable: $1"
}
# expect <allow|silent> <cwd> <command> [flag] [session id] [home]
expect() {
  local want=$1 got; shift
  got=$(verdict_of "$(run "$@")")
  [ "$got" = "$want" ] && ok "$want: $(printf '%s' "$2" | tr '\n' ' ') [cwd ${1#"$SANDBOX"}]" \
    || bad "expected $want, got $got: $(printf '%s' "$2" | tr '\n' ' ') [cwd ${1#"$SANDBOX"}]"
}

echo "One plain git or rm line inside the clone is allowed"
for c in "git -C $CLONE commit -m 'feat: ✨ Add x.' -m 'Watson-Branch: #12'" \
         "git -C $CLONE push -u origin feature/12-add-x" "git -C $CLONE push --set-upstream origin feature/12-x" \
         "git -C $CLONE push origin feature/12-x" "git -C $CLONE push origin HEAD:refs/heads/feature/12-x" \
         "git -C $CLONE push origin HEAD:feature/12-x" "git -C $CLONE push origin refs/heads/feature/12-x" \
         "git -C $CLONE commit -m \"fix: 🐛 Handle #12.\"" \
         "git -C $CLONE commit -F $H/Developer/scratchpad/work/msg.txt" "git -C $CLONE commit -F $SP/x/msg.txt" \
         "git -C $CLONE/src add -A" "git -C $CLONE checkout feature/12-x" "git -C $CLONE checkout -b feature/12-x" \
         "git -C $CLONE merge origin/main" "git -C $DEV push origin main" "git -C $CLONE push origin HEAD:heads" \
         "rm -rf $CLONE" "rm -rf $CLONE/src" "rm -rf $CLONE/src/" "rmdir $CLONE/empty" "rmdir -- $CLONE/empty" \
         "rm -rf -- $CLONE/src $CLONE/empty" \
         "rm -f $CLONE/link" "rm -rf '$CLONE/~/x' '$CLONE/=ls'"; do
  expect allow "$SANDBOX" "$c"
done
expect allow "$OUT" "git -C $CLONE commit -m x"   # the payload cwd is never read

echo "Scratch roots are in scope too"
expect allow "$SANDBOX" "rm -rf $H/Developer/scratchpad/work"
expect allow "$SANDBOX" "rm -rf $SP/x"
expect silent "$SANDBOX" "rm -rf $SP/x" 1 other-session
expect silent "$SANDBOX" "rm -rf $SP/x" 1 'bad id*'
expect silent "$SANDBOX" "rm -rf $SESSION_BASE/proj2/scratchpad/y" 1 '../proj2'
expect silent "$SANDBOX" "rm -rf $SP/x" 1 '*'   # a glob id would match every session
expect silent "$SANDBOX" "rm -rf $SP/x" 1 ''
expect silent "$SANDBOX" "rm -rf $SP/x" 1 "x/../$SID"

echo "A planted symlink never becomes a root"
expect silent "$SANDBOX" "rm -rf $OUT/x" 1 "$LINKSID"
expect silent "$SANDBOX" "rm -rf $SESSION_BASE/proj/$LINKSID/scratchpad/x" 1 "$LINKSID"
expect silent "$SANDBOX" "git -C $OUT commit -m x" 1 "$LINKSID"
expect silent "$SANDBOX" "rm -rf $SANDBOX/elsewhere/scratchpad/z" 1 "$UPSID"
expect silent "$SANDBOX" "rm -rf $SESSION_BASE/proj/$UPSID/scratchpad/z" 1 "$UPSID"
expect silent "$SANDBOX" "rm -rf $OUT/x" 1 "$SID" "$SANDBOX/home4"
expect silent "$SANDBOX" "git -C $OUT commit -m x" 1 "$SID" "$SANDBOX/home4"

echo "Relative paths, a cwd, and compound lines are never allowed"
for c in "git commit -m 'feat: x'" "git push origin feature/12-x" "git reset --hard" "rm -rf src" "rm -rf ./src/../empty"; do
  expect silent "$CLONE" "$c"
done
for c in "cd $CLONE && git add -A && git commit -m x" "$(printf 'git -C %s add -A\ngit -C %s commit -m x' "$CLONE" "$CLONE")" \
         "cd $CLONE && rm -rf src" "cd $CLONE; git push origin x" "cd $T && rm -rf tmp.clone" "cd $CLONE" "cd -" \
         "git -C $CLONE commit -m x; git -C $CLONE push origin x" "git -C $CLONE commit -m x && git -C $CLONE push origin x" \
         "rm -rf $CLONE/src; rm -rf $CLONE/empty" "git -C tmp.clone commit -m x" "git -C$CLONE commit -m x" \
         "git -C $CLONE/src/.. commit -m x" "git -C $CLONE/./src commit -m x" "rm -rf $CLONE/./src" "rm -rf $CLONE/src/../empty" \
         "rm -rf $CLONE/src/." "git -C $CLONE -C $CLONE/src commit -m x" "git -C $CLONE commit -F ../msg" \
         "rm -rf -- -x" "rm -rf" "git -C $CLONE" "rm -rf './~/x' '=ls'"; do
  expect silent "$SANDBOX" "$c"
done

echo "A root itself is never removed"
for c in "rm -rf $T" "rm -rf $T/" "rm -rf $H/Developer/scratchpad" "rm -rf $SP" "rmdir $T"; do
  expect silent "$SANDBOX" "$c"
done

echo "rmdir takes no option, and rm reads options only before its first operand"
# rmdir -p on an empty folder beneath a root walks up and removes the root too.
# BSD rm reads a dash word after an operand as a file in the cwd: ./-victim.
for c in "rmdir -p $SP/x" "rmdir -v $CLONE/empty" "rmdir --parents $CLONE/empty" "rmdir -- -p" \
         "rm -rf $CLONE/src -victim" "rm $CLONE/src -rf" "rm -rf $CLONE/src -- $CLONE/empty" "rm -rf -- $CLONE/src -x"; do
  expect silent "$SANDBOX" "$c"
done

echo "Outside the roots, through git -C, a path argument, or a symlink"
for c in "git -C $OUT commit -m x" "git -C $CLONE/link commit -m x" \
         "rm -rf $OUT" "rm -rf $CLONE/link/" "rm -rf $CLONE/link/.git" "rm -rf $CLONE $OUT" \
         "git -C $CLONE worktree add ../../outside/wt" "git -C $CLONE commit -F $OUT/msg" "git -C $CLONE clone x $OUT/y" \
         "rm -rf /" "rm -rf $HOME/.claude"; do
  expect silent "$SANDBOX" "$c"
done

echo "git -C a folder in a root, inside a repository outside every root"
expect silent "$SANDBOX" "git -C $SANDBOX/home5/Developer/scratchpad/work reset --hard" 1 "$SID" "$SANDBOX/home5"
expect silent "$SANDBOX" "git -C $SANDBOX/home5/Developer/scratchpad commit -m x" 1 "$SID" "$SANDBOX/home5"
expect silent "$SANDBOX" "git -C $T commit -m x"   # no repository at all
expect silent "$SANDBOX" "git -C $T/tmp.gitfile commit -m x"   # git dir outside, top level inside
expect silent "$SANDBOX" "git -C $T/tmp.wt commit -m x"        # top level outside, git dir inside

echo "git's own options are never allowed, spaced or attached"
for c in "git -C $CLONE --git-dir=$OUT/.git commit -m x" "git -C $CLONE --git-dir $CLONE/.git commit -m x" \
         "git -C $CLONE --work-tree=$CLONE commit -m x" "git -C $CLONE --work-tree $CLONE commit -m x" \
         "git -C $CLONE --namespace=x push origin feature/x" "git -C $CLONE --namespace x push origin feature/x" \
         "git -C $CLONE -c core.hooksPath=/x commit -m x" "git -C $CLONE -ccore.hooksPath=/x commit -m x" \
         "git -C $CLONE -c core.sshCommand=x push origin feature/x" "git -C $CLONE --config-env=core.pager=X commit -m x" \
         "git -C $CLONE --exec-path=/x push origin feature/x" "git -C $CLONE --no-pager commit -m x" \
         "git --git-dir $CLONE/.git commit -m x" "git --work-tree $CLONE commit -m x" "git --namespace $CLONE commit -m x"; do
  expect silent "$SANDBOX" "$c"
done

echo "Only the pipelines' own git subcommands, and no option that runs a program"
for c in "git -C $CLONE config --global user.name x" "git -C $CLONE config --system user.name x" \
         "git -C $CLONE rebase --exec x main" "git -C $CLONE rebase main" \
         "git -C $CLONE push --receive-pack=x origin feature/x" "git -C $CLONE push --rece=x origin feature/x" \
         "git -C $CLONE push --exec=x origin" "git -C $CLONE push --upload-pack=x origin feature/x" \
         "git -C $CLONE fetch --upload-pack=x origin" "git -C $CLONE submodule foreach 'git push origin feature/x'" \
         "git -C $CLONE bisect run git push origin feature/x" "git -C $CLONE difftool -x 'git push' HEAD" \
         "git -C $CLONE p origin feature/x" "git -C $CLONE reset --hard" "git -C $CLONE clean -fdx" \
         "git -C $CLONE stash drop" "git -C $CLONE stash push" "git -C $CLONE gc" "git -C $CLONE Commit -m x"; do
  expect silent "$SANDBOX" "$c"
done

echo "A push names one branch, never the default, and never forces or deletes"
for c in "git -C $CLONE push" "git -C $CLONE push origin" "git -C $CLONE push -u origin" "git -C $CLONE push -u origin HEAD" \
         "git -C $CLONE push origin HEAD" "git -C $CLONE push origin @" "git -C $CLONE push origin HEAD:HEAD" \
         "git -C $CLONE push --all" "git -C $CLONE push --all origin" "git -C $CLONE push origin --all" \
         "git -C $CLONE push --branches origin" "git -C $CLONE push --mirror" "git -C $CLONE push --tags origin" \
         "git -C $CLONE push origin main" "git -C $CLONE push origin Main" "git -C $CLONE push origin refs/heads/main" \
         "git -C $CLONE push origin HEAD:main" "git -C $CLONE push origin feature/x:refs/heads/main" \
         "git -C $CLONE push origin feature/x:MAIN" "git -C $CLONE push origin feature/x:refs/tags/v1" \
         "git -C $CLONE push origin feature/x:refs/for/x" "git -C $CLONE push origin a:b:c" \
         "git -C $CLONE push origin feature/x feature/y" "git -C $CLONE push origin feature/x -u" \
         "git -C $CLONE push --prune origin feature/x" "git -C $CLONE push -uf origin feature/x" \
         "git -C $CLONE push -f origin feature/x" "git -C $CLONE push --force origin feature/x" \
         "git -C $CLONE push origin feature/x --force-with-lease" "git -C $CLONE push origin +feature/x" \
         "git -C $CLONE push origin :feature/x" "git -C $CLONE push origin feature/x:" \
         "git -C $CLONE push --delete origin feature/x" "git -C $CLONE push -d origin feature/x" \
         "git -C $CLONE push origin -f" "git -C $CLONE push upstream feature/x" \
         "git -C $CLONE push https://github.com/o/r feature/x" "git -C $CLONE push -- origin feature/x" \
         "git -C $DEV push origin develop" "git -C $DEV push origin HEAD:refs/heads/develop" \
         "git -C $DEV push origin feature/x:Develop" "git -C $BARE push origin feature/x" \
         "git -C $CLONE push origin feature/x:heads/main" "git -C $CLONE push origin heads/main" \
         "git -C $CLONE push origin HEAD:Heads/main" "git -C $CLONE push origin feature/x:heads/feature/x" \
         "git -C $CLONE push origin feature/x:tags/v1" "git -C $CLONE push origin tags/v1" \
         "git -C $CLONE push origin feature/x:remotes/origin/main" "git -C $DEV push origin HEAD:heads/develop"; do
  expect silent "$SANDBOX" "$c"
done

echo "A push source must resolve to a local branch, so never a tag"
for c in "git -C $CLONE push origin v1" "git -C $CLONE push origin v1:feature/x" \
         "git -C $CLONE push origin refs/tags/v1:feature/x" "git -C $CLONE push origin tags/v1:feature/x" \
         "git -C $CLONE push origin feature/t" "git -C $CLONE push origin both" \
         "git -C $CLONE push origin both:feature/x" "git -C $CLONE push origin origin/main:feature/x" \
         "git -C $CLONE push origin $SHA:feature/x" "git -C $CLONE push origin nosuch:feature/x" \
         "git -C $CLONE push origin nosuch"; do
  expect silent "$SANDBOX" "$c"
done
expect allow "$SANDBOX" "git -C $CLONE push origin feature/x:feature/y"   # a branch source still passes

echo "Merges are never allowed"
for c in "gh pr merge 5" "gh -R o/r pr merge 5 --squash" "gh -R o/r pr merge" "gh api -X PUT repos/o/r/pulls/5/merge"; do
  expect silent "$SANDBOX" "$c"
done

echo "Deny-listed commands are never allowed"
for c in "git -C $CLONE filter-branch --tree-filter x HEAD" "git -C $CLONE reflog expire --all" \
         "git -C $CLONE log --oneline -20" "git -C $CLONE log" "git -C $CLONE diff HEAD" "git -C $CLONE diff" \
         "sudo rm -rf $CLONE/src" "shred $CLONE/src"; do
  expect silent "$SANDBOX" "$c"
done
mkdir -p "$SANDBOX/home2"   # no settings file, so no deny rule
for c in "git -C $CLONE log --oneline -20" "git -C $CLONE log" "git -C $CLONE diff HEAD" "git -C $CLONE diff"; do
  expect allow "$SANDBOX" "$c" 1 "$SID" "$SANDBOX/home2"
done
mkdir -p "$SANDBOX/home3/.claude"; echo '{not json' > "$SANDBOX/home3/.claude/settings.json"
expect silent "$SANDBOX" "git -C $CLONE log" 1 "$SID" "$SANDBOX/home3"

echo "Anything the grammar cannot read, or any other command, ends the check"
for c in "git -C $CLONE commit -m \"\$(cat msg)\"" "git -C $CLONE commit -m \"a \`b\`\"" "git -C $CLONE push origin \$BRANCH" \
         "rm -rf $CLONE/*" "rm -rf $CLONE/{a,b}" "rm -rf ~/x" "rm -rf $CLONE/a\\ b" "git -C $CLONE commit -m x | tee y" \
         "git -C $CLONE push origin feature/x &" "git -C $CLONE commit -m x || true" "(git -C $CLONE commit -m x)" \
         "git -C $CLONE commit -m x > y" "bash -c 'git -C $CLONE commit -m x'" "env git -C $CLONE commit -m x" \
         "HUSKY=0 git -C $CLONE commit -m x" "/usr/bin/git -C $CLONE commit -m x" "echo hi" \
         "git -C $CLONE commit -m x # note" "git -C $CLONE commit -m 'unterminated" "=git -C $CLONE commit -m x" \
         "rm -rf $CLONE/src^x" "git -C $CLONE commit -m x^y" "git -C $CLONE reset --hard HEAD~1" "rm -rf $CLONE/a~b" \
         "git -C $CLONE commit -m =x"; do
  expect silent "$SANDBOX" "$c"
done

echo "The flag must be exactly 1"
for flag in "" 0 true " 1"; do
  got=$(verdict_of "$(run "$SANDBOX" "rm -rf $CLONE" "$flag")")
  [ "$got" = silent ] && ok "flag '$flag' → silent" || bad "flag '$flag' → $got"
done

echo "With no usable root, nothing is allowed"
p=$(jq -cn --arg c "rm -rf $CLONE" '{session_id: "x", cwd: "/", tool_input: {command: $c}}')
out=$(printf '%s' "$p" | env -i PATH="$PATH" HOME="$SANDBOX/nohome" WORKBENCH_DEV_TEAM_PIPELINE=1 bash "$HOOK")
[ -z "$out" ] && ok "no TMPDIR and no scratchpad → silent" || bad "allowed with no roots: $out"
p=$(jq -cn --arg c "rm -rf $OUT/x" '{session_id: "x", cwd: "/", tool_input: {command: $c}}')
out=$(printf '%s' "$p" | env -i PATH="$PATH" HOME="$SANDBOX/nohome" TMPDIR=/ WORKBENCH_DEV_TEAM_PIPELINE=1 bash "$HOOK")
[ -z "$out" ] && ok "TMPDIR=/ puts no path beneath a root" || bad "TMPDIR=/ let rm reach $OUT/x: $out"

echo "An unreadable payload fails closed"
out=$(printf 'not json: rm -rf %s' "$CLONE" | env -i PATH="$PATH" HOME="$H" TMPDIR="$T" WORKBENCH_DEV_TEAM_PIPELINE=1 bash "$HOOK")
[ -z "$out" ] && ok "unreadable text → silent" || bad "unreadable text was allowed: $out"
NOJQ="$SANDBOX/nojq"; mkdir -p "$NOJQ"; ln -s "$(command -v cat)" "$NOJQ/cat"
out=$(jq -cn --arg c "rm -rf $CLONE" --arg d "$SANDBOX" '{cwd: $d, tool_input: {command: $c}}' \
  | env -i PATH="$NOJQ" HOME="$H" TMPDIR="$T" WORKBENCH_DEV_TEAM_PIPELINE=1 "$BASH" "$HOOK" 2>/dev/null)
[ -z "$out" ] && ok "no jq on PATH → silent" || bad "allowed with no jq: $out"

echo "The pipeline doc's own git and cleanup lines are allowed"
n=0
while IFS= read -r line; do
  line=${line//<clone path>/$CLONE}; line=${line//<issue_number>/12}; line=${line//<branch>/feature/12-add-x}
  expect allow "$SANDBOX" "$line"; n=$((n + 1))
done < <(grep -E '^(git -C <clone path> |rm -rf <clone path>)' "$PIPELINE_MD")
[ "$n" -ge 3 ] && ok "$n lines found in the pipeline doc" || bad "only $n git -C or rm lines found in $PIPELINE_MD"

echo "hooks.json wires PermissionRequest to this hook alone"
perm=$(jq -r '[.hooks.PermissionRequest[]? | select(.matcher == "Bash") | .hooks[].command] | join("\n")' "$HOOKS_JSON")
[ "$(printf '%s\n' "$perm" | grep -c .)" = 1 ] && [[ $perm == *'pipeline-scope.sh"' ]] \
  && ok "PermissionRequest Bash runs pipeline-scope.sh and nothing else" || bad "PermissionRequest wiring: $perm"

echo "Size is part of the design"
lines=$(wc -l < "$HOOK")
[ "$lines" -le 140 ] && ok "pipeline-scope.sh is $lines lines, at most 140" || bad "pipeline-scope.sh grew to $lines lines"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
