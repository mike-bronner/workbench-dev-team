#!/bin/bash
# Tests for local-review-guard.sh, the review guard. Run directly:
# ./test-local-review-guard.sh
#
# Each case feeds a synthetic hook payload and asserts the guard's behaviour:
# whom it holds to the rule, what it refuses, and what it leaves alone.
#
# Two properties carry most of the weight, and both have a named failure behind
# them. (1) A refused command must come back "deny" and never "ask" — a hook's
# "ask" is classifier-approvable, which is how the sibling commit gate spent its
# whole life stopping nothing. (2) Only a reviewer's agent_type is held to the
# rule — a guard that gagged every agent would stop the human's own work and
# Watson's, which is the commit gate's watson.lock leak with the sign flipped.
#
# The sandbox owns HOME and TMPDIR, so no case can read or write the
# developer's real environment: the verdict has to come from the guard, never
# from what happens to be on this host. The tree under review sits OUTSIDE
# $TMPDIR, because $TMPDIR is a scratch root and a tree inside one is writable.

set -u
GUARD="$(cd "$(dirname "$0")" && pwd)/local-review-guard.sh"
PASS=0
FAIL=0

# Physical, so a named root under it is not dropped for a symlink in its path
# (macOS puts mktemp -d under /var, a link to /private/var).
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/local-review-guard.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
TMPROOT="$SANDBOX/tmp"
WORKDIR="$SANDBOX/repo"
SCRATCHPAD="$SANDBOX/home/Developer/scratchpad"
mkdir -p "$TMPROOT" "$WORKDIR" "$SCRATCHPAD"

LENS="workbench-dev-team:holmes-lens"
HOLMES="workbench-dev-team:holmes"
WATSON="workbench-dev-team:watson"

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected $3, got $2"; fi; }

# Build the payload first, then feed it with printf. Piping a generator straight
# into the guard breaks its stdout when the guard exits before reading stdin.
run_guard() { # run_guard <payload> [env assignments...]; RUN_GUARD picks the script
  local body="$1"; shift
  printf '%s' "$body" | env -u WORKBENCH_DEV_TEAM_PIPELINE \
    HOME="$SANDBOX/home" TMPDIR="$TMPROOT" "$@" bash "${RUN_GUARD:-$GUARD}"
}

# Every reviewer command a case runs joins the differential check at the end,
# with its cwd. Cases run in subshells, so they are kept in a file.
SEEN_FILE="$SANDBOX/seen"
: > "$SEEN_FILE"

bash_payload() { # bash_payload <command> [session] [agent_type] [cwd]
  [ "${3-$LENS}" = "$LENS" ] && printf '%s\0%s\0' "$1" "${4-}" >> "$SEEN_FILE"
  python3 -I -c '
import json, sys
body = {"hook_event_name": "PreToolUse", "tool_name": "Bash",
        "session_id": sys.argv[2], "agent_id": "agent-1",
        "tool_input": {"command": sys.argv[1]}}
if sys.argv[3]:
    body["agent_type"] = sys.argv[3]
if sys.argv[4]:
    body["cwd"] = sys.argv[4]
print(json.dumps(body))' "$1" "${2-session-A}" "${3-$LENS}" "${4-}"
}

verdict_of() {
  if printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; then echo deny
  elif printf '%s' "$1" | grep -q '"permissionDecision": *"ask"'; then echo ask
  else echo silent; fi
}

# bash_verdict <command> [session] [agent_type] [cwd]
bash_verdict() { verdict_of "$(run_guard "$(bash_payload "$1" "${2-session-A}" "${3-$LENS}" "${4-}")")"; }

echo "── the rule is keyed on agent_type ────────────────────────────────────"

BREACH="chmod 644 $WORKDIR/agents/lint-holmes-local-mode.sh"
check "a helper's write into the tree is refused" "$(bash_verdict "$BREACH" session-A "$LENS")" deny
check "Holmes's own write into the tree is refused" "$(bash_verdict "$BREACH" session-A "$HOLMES")" deny
check "Watson's write into the same tree is allowed" "$(bash_verdict "$BREACH" session-A "$WATSON")" silent
check "a generic sub-agent's write is not this guard's business" \
  "$(bash_verdict "$BREACH" session-A general-purpose)" silent
check "a session with no agent_type keeps its tools" "$(bash_verdict "$BREACH" session-A "")" silent
check "a bare holmes type is held too" "$(bash_verdict "$BREACH" session-A holmes)" deny
check "holmes spelled with ſ folds to holmes and is held" \
  "$(bash_verdict "$BREACH" session-A "workbench-dev-team:holmeſ")" deny
check "a type that only contains holmes is not held" \
  "$(bash_verdict "$BREACH" session-A "workbench-dev-team:holmes-review-bot")" silent
# The scheduled pipeline starts Holmes with --agent, so its main thread carries
# agent_type and no agent_id, and the pipeline flag is on. Neither exempts it.
check "a pipeline main thread (agent_type, no agent_id, pipeline flag) is held" \
  "$(verdict_of "$(run_guard "$(python3 -I -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "session_id": "session-P", "agent_type": sys.argv[1],
                  "tool_input": {"command": sys.argv[2]}}))' "$HOLMES" "$BREACH")" \
    WORKBENCH_DEV_TEAM_PIPELINE=1)")" deny

echo
echo "── the scratch roots ──────────────────────────────────────────────────"

check "a write beneath \$TMPDIR is allowed" "$(bash_verdict "touch $TMPROOT/probe")" silent
check "a write beneath ~/Developer/scratchpad is allowed" "$(bash_verdict "touch $SCRATCHPAD/probe")" silent
SESSION_PAD="$SANDBOX/session-pad"
mkdir -p "$SESSION_PAD"
check "a write beneath the payload's scratchpad_dir is allowed" \
  "$(verdict_of "$(run_guard "$(python3 -I -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "session_id": "session-A", "agent_id": "agent-1", "agent_type": sys.argv[1],
                  "scratchpad_dir": sys.argv[2],
                  "tool_input": {"command": "touch " + sys.argv[2] + "/probe"}}))' "$LENS" "$SESSION_PAD")")")" silent
check "a root itself is not writable" "$(bash_verdict "rm -rf $TMPROOT")" deny
check "a write outside every root is refused" "$(bash_verdict "touch $SANDBOX/home/notes.txt")" deny
# Holmes's Index-mode setup and teardown, as agents/holmes.md words them. The
# clone lives in a mktemp -d directory, which is beneath $TMPDIR.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "Index mode keeps working: $cmd" "$(bash_verdict "$cmd" session-A "$HOLMES")" silent
done <<EOF
mktemp -d
gh repo clone owner/repo $TMPROOT/clone
gh pr checkout 12
rm -rf $TMPROOT/clone
jq -r .agents.holmes.lensModel $SANDBOX/home/.claude-workbench/dev-team-config.json 2>/dev/null
EOF
# A named root is found by name, so a planted symlink could aim it anywhere.
LINKED_HOME="$SANDBOX/linked-home"
mkdir -p "$LINKED_HOME/Developer"
ln -sfn "$WORKDIR" "$LINKED_HOME/Developer/scratchpad"
LINKED_OUT="$(run_guard "$(bash_payload "touch $LINKED_HOME/Developer/scratchpad/x")" HOME="$LINKED_HOME")"
check "a symlinked ~/Developer/scratchpad is not a root" "$(verdict_of "$LINKED_OUT")" deny
# The refusal lists the roots it found, so a planted link must not be named as
# one: the model would take it as a place it may write.
case "$LINKED_OUT" in
  *"$LINKED_HOME/Developer/scratchpad\`"*) bad "the refusal names the symlinked scratchpad as a root" ;;
  *) ok "the refusal does not name the symlinked scratchpad as a root" ;;
esac

echo
echo "── reading and testing stay legal ─────────────────────────────────────"

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed: $cmd" "$(bash_verdict "$cmd")" silent
done <<EOF
git -C $WORKDIR status --short
git -C $WORKDIR diff HEAD
git -C $WORKDIR ls-files --others --exclude-standard
git -C $WORKDIR status -sb
git rev-parse --short HEAD
git log --oneline -5
git show HEAD:file.txt
git blame file.txt
bash run-tests.sh
npm test
grep -i needle file.txt
rg --files
cat $WORKDIR/file.txt
EOF

echo
echo "── mutation is refused ────────────────────────────────────────────────"

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused: $cmd" "$(bash_verdict "$cmd")" deny
done <<EOF
git restore .
git restore --staged --worktree src/
git -C $WORKDIR restore agents/lint.sh
git checkout -- .
git switch main
git stash
git stash push -m wip
git reset --hard HEAD
git clean -fd
git commit -m x
git apply patch.diff
chmod 644 agents/lint-holmes-local-mode.sh
chmod +x run-tests.sh
chown mike file.txt
rm -rf build
mv old.txt new.txt
truncate -s 0 file.txt
sed -i '' s/a/b/ file.txt
perl -i -pe s/a/b/ file.txt
npx prettier --write .
ruff check --fix .
find . -name '*.tmp' -delete
xargs -0 rm
sudo rm -rf /
git status && chmod 644 file.txt
EOF

# The measured breach, spelled as it happened: a lens sub-agent changed a script
# in the tree under review from 755 to 644 with the prohibition verbatim in its
# own prompt. The tree here is the sandbox's, so the path is rooted there.
check "the breach command itself is refused" \
  "$(bash_verdict "chmod 644 $WORKDIR/agents/lint-holmes-local-mode.sh")" deny

echo
echo "── file writes are judged by resolved target ──────────────────────────"

# rm and mv used to be refused everywhere, which stopped a reviewer clearing its
# own scratch. Now every file-writing command is judged by the paths it writes.
OUTSIDE="$TMPROOT/scratch"
mkdir -p "$OUTSIDE" "$WORKDIR/src"
ln -sfn "$WORKDIR/src" "$TMPROOT/link-into-tree"
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed in scratch: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$OUTSIDE")" silent
done <<EOF
rm -rf $OUTSIDE/build
rm -f notes.txt
mv a.txt b.txt
cp $WORKDIR/src/file.txt $OUTSIDE/copy.txt
cp -r $WORKDIR/src $OUTSIDE/
tee $OUTSIDE/log.txt
touch $OUTSIDE/stamp
ln -s $WORKDIR/src $OUTSIDE/src-link
install -m 644 $WORKDIR/file.txt $OUTSIDE/file.txt
dd if=$WORKDIR/file.txt of=$OUTSIDE/file.bin
patch -d $OUTSIDE -p1 -i $OUTSIDE/fix.diff
chmod 644 $OUTSIDE/file.txt
EOF

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused into the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$OUTSIDE")" deny
done <<EOF
cp $OUTSIDE/file.txt $WORKDIR/src/file.txt
cp -t $WORKDIR/src $OUTSIDE/file.txt
cp --target-directory=$WORKDIR $OUTSIDE/file.txt
tee -a $WORKDIR/notes.md
touch $WORKDIR/new.txt
ln -s $OUTSIDE/x $WORKDIR/x
install -d $WORKDIR/newdir
install $OUTSIDE/file.txt $WORKDIR/file.txt
dd if=/dev/zero of=$WORKDIR/file.txt
patch -d $WORKDIR -p1 -i $OUTSIDE/fix.diff
patch --directory=$WORKDIR -p1
rm -rf $WORKDIR/src
mv $WORKDIR/src/file.txt $OUTSIDE/
rm -rf $SANDBOX
rm -rf $TMPROOT/link-into-tree/file.txt
touch $TMPROOT/link-into-tree/new.txt
rm -rf ~/definitely-not-the-tree
EOF

# A write whose path the guard cannot resolve is refused, wherever it runs.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused, unresolvable: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$OUTSIDE")" deny
done <<EOF
rm -rf \$DIR
rm -f $OUTSIDE/*.tmp
touch "$OUTSIDE/a b"
cp x \$(mktemp)
find . -name x | xargs rm
EOF
check "a relative write with no cwd is refused" "$(bash_verdict "touch notes.txt")" deny

# A link that lives in the tree and points out of it. rm, mv, unlink, and chmod -h
# act on the link entry, which is in the tree, so resolving the whole path to
# the outside target let each of them through. 0.50.0 refused these.
touch "$OUTSIDE/target.txt"
ln -sfn "$OUTSIDE/target.txt" "$WORKDIR/link-out"
ln -sfn "$OUTSIDE" "$WORKDIR/dir-link-out"
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused, a link entry in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$OUTSIDE")" deny
done <<EOF
rm $WORKDIR/link-out
rm -f $WORKDIR/dir-link-out
unlink $WORKDIR/link-out
mv $WORKDIR/link-out $OUTSIDE/moved
chmod -h 644 $WORKDIR/link-out
EOF
check "a relative link entry in the tree's cwd is refused" \
  "$(bash_verdict "rm link-out" session-A "$LENS" "$WORKDIR")" deny
check "the outside target itself stays writable" \
  "$(bash_verdict "rm $OUTSIDE/target.txt" session-A "$LENS" "$OUTSIDE")" silent
check "patch in the tree's own cwd is refused" \
  "$(bash_verdict "patch -p1 -i $OUTSIDE/fix.diff" session-A "$LENS" "$WORKDIR")" deny

echo
echo "── ordinary writers and formatters (round 5) ──────────────────────────"

# Each of these ran silently with cwd in the tree before round 5. The writer
# list is fixed, not a rule, so each writer it names is pinned here.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" deny
done <<EOF
mkdir newdir
mkdir -p -m 755 $WORKDIR/a/b
rsync -a $OUTSIDE/ $WORKDIR/
rsync -a $OUTSIDE/ newdir/
rsync -a --remove-source-files README.md $OUTSIDE/
tar -xf $OUTSIDE/a.tar -C $WORKDIR
tar -xf $OUTSIDE/a.tar
tar xzf $OUTSIDE/a.tgz
tar --extract --file=$OUTSIDE/a.tar --directory=$WORKDIR
tar -czf $WORKDIR/out.tgz $OUTSIDE
unzip $OUTSIDE/a.zip -d $WORKDIR
unzip $OUTSIDE/a.zip
unzip -o $OUTSIDE/a.zip
sort -o README.md README.md
sort -uo README.md README.md
sort --output=README.md README.md
uniq $OUTSIDE/in.txt README.md
gofmt -w main.go
gofmt -l -w .
goimports -w main.go
prettier -w src
npx prettier -w src
shfmt -w run-tests.sh
shfmt -l -w .
clang-format -i main.c
black app.py
black .
python3 -m black app.py
rustfmt src/main.rs
cargo fmt
cargo +nightly fmt --all
go fmt ./...
ruff format app.py
isort app.py
terraform fmt
mix format
env -u FOO chmod 644 README.md
env -u FOO -P /usr/bin chmod 644 README.md
env -S 'chmod 644 README.md'
sudo -u root chmod 644 README.md
xargs -n 1 rm
EOF

# The same programs reading: check mode, listing mode, and writes that land
# outside the tree. A guard that refused these would stop the review itself.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" silent
done <<EOF
prettier --check .
prettier -c .
black --check .
black --diff app.py
gofmt -l .
gofmt -d main.go
shfmt -d run-tests.sh
cargo fmt --check
cargo fmt -- --check
rustfmt --check src/main.rs
go fmt -n ./...
ruff format --check .
ruff check .
isort --check-only app.py
terraform fmt -check
mix format --check-formatted
clang-format main.c
black --version
mkdir -p $OUTSIDE/probe
rsync -a $WORKDIR/ $OUTSIDE/copy/
rsync -a README.md $OUTSIDE/
tar -tf $OUTSIDE/a.tar
tar -cf $OUTSIDE/tree.tar .
tar -xf $OUTSIDE/a.tar -C $OUTSIDE
tar -xOf $OUTSIDE/a.tar README.md
unzip -l $OUTSIDE/a.zip
unzip $OUTSIDE/a.zip -d $OUTSIDE/x
sort README.md
sort -o $OUTSIDE/sorted.txt README.md
uniq README.md
uniq README.md $OUTSIDE/u.txt
env -u FOO ls
env FOO=1 bash run-tests.sh
EOF

check "ln with one operand lands in the cwd, the tree" \
  "$(bash_verdict "ln -s $OUTSIDE/x" session-A "$LENS" "$WORKDIR")" deny

echo
echo "── lookups, long write flags, and project runners (round 6) ───────────"

# Each of these ran silently before round 6: a long rubocop write spelling, a
# default writer, or a listed writer behind a project runner.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" deny
done <<EOF
rubocop --autocorrect
rubocop --autocorrect-all
rubocop --auto-correct
rubocop --auto-correct-all
rubocop -x
rubocop --fix-layout
bundle exec rubocop -a
uv run black .
uv run --with black black .
poetry run black .
poetry -C sub run black .
pipx run black .
pnpm exec prettier -w .
pnpm dlx prettier -w .
npm exec -- prettier -w .
npm x prettier -w .
npm exec -c 'prettier -w .'
yarn prettier -w .
yarn exec prettier -w .
yarn dlx prettier -w .
yarn run prettier -w .
composer exec pint
vendor/bin/pint
pint app
php-cs-fixer fix src
vendor/bin/php-cs-fixer fix
rustfmt --print-config default rustfmt.toml
rustfmt --print-config=minimal m.toml
EOF

# Already refused before round 6, and pinned so the round-6 changes cannot open
# them: a wrapper with no lookup flag, and a check switched off by its value.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" deny
done <<EOF
command black app.py
terraform fmt -check=false
EOF

# Each of these was refused before round 6, and none writes a file: a lookup,
# a help or config form, a string handed to a formatter, or a uniq option's
# value read as the output file.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" silent
done <<EOF
command -v black
command -v rustfmt
command -v unzip
command -V isort
command -pv black
unzip -h
unzip
rustfmt --print-config default
rustfmt --print-config current src/main.rs
rustfmt --help=config
isort --show-config
black -c 'x=1'
black --code=x
uniq --skip-fields 1 README.md
uniq --skip-chars 2 README.md
uniq --check-chars 3 README.md
EOF

# Lookups, test runs through the runners, and check modes that were already
# silent. Pinned so the round-6 changes cannot start refusing them.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" silent
done <<EOF
which black
type black
command -v rm
npm test
yarn test
yarn install
uv run pytest
bundle exec rspec
poetry run pytest
pipx run pytest
pnpm exec vitest
vendor/bin/pint --test
pint --test
php-cs-fixer fix --dry-run
php-cs-fixer check
rubocop
EOF

echo
echo "── clustered formatter write flags, and stdin forms (round 7) ─────────"

# Each of these ran silently before round 7: a write letter bundled with
# another short flag, for the four formatters whose parsers bundle them.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" deny
done <<EOF
yapf -ir .
yapf -ri .
python3 -m yapf -ir .
autopep8 -ai x.py
autopep8 -ia x.py
prettier -lw .
rubocop -aD
bundle exec rubocop -Da
black - app.py
EOF

# Each of these was refused before round 7 and writes only to stdout: a
# formatter reading stdin. The rest were already silent, and are pinned so the
# cluster walk cannot start refusing a check mode or a flag that is not a
# cluster.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A "$LENS" "$WORKDIR")" silent
done <<EOF
black -
cat x.py | black -q -
black --stdin-filename x.py -
isort -
echo code | rustfmt
clang-format -sort-includes main.c
yapf -dr .
yapf -l1-9i -d x.py
autopep8 -d x.py
prettier -lc .
rubocop -D
EOF

echo
echo "── git's listing forms read, and their other forms write ──────────────"

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed: $cmd" "$(bash_verdict "$cmd")" silent
done <<EOF
git branch --show-current
git branch
git branch -a -v
git branch --list feature/*
git remote -v
git remote get-url origin
git config --get remote.origin.url
git config --list
git config get user.name
git stash list
git stash show -p
git worktree list
git tag -l v1.*
git tag
git tag -n5
git ls-remote origin
git branch --contains abc1234
git branch -r --no-contains abc1234
git branch --merged main
git tag --contains abc1234
git tag --points-at HEAD
EOF

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused: $cmd" "$(bash_verdict "$cmd")" deny
done <<EOF
git branch -D feature
git branch new-branch
git branch -m old new
git remote add upstream x
git remote remove origin
git config user.name x
git config --add a.b c
git config --get a.b --unset
git stash drop
git stash pop
git worktree add ../x
git tag v2
git tag -d v1
git tag -l -d v1
git branch --contains abc1234 new-branch
EOF

echo
echo "── in-place -i is read anywhere in a flag cluster ─────────────────────"

# The second measured breach. A lens ran `perl -pi` against the tree it was
# reviewing and the guard allowed it, because `-i` was matched as a whole token
# only. `perl -pi -e` is the commonest spelling of an in-place Perl edit, so the
# gap covered the likeliest case rather than an edge one. Every line below was
# ALLOWED before the cluster scan landed.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused: $cmd" "$(bash_verdict "$cmd")" deny
done <<EOF
perl -pi -e s/a/b/ file.txt
perl -ni -e print file.txt
perl -pi.bak -e s/a/b/ file.txt
perl -lpi -e s/a/b/ file.txt
sed -ie s/a/b/ file.txt
ruby -pi -e x file.txt
ruby -i.bak -pe x file.txt
sed --in-place s/a/b/ file.txt
EOF

# sed's own two spellings, both of which the cluster scan first shipped allowing.
# `-I` is an in-place edit on BSD and macOS sed exactly as `-i` is, and GNU sed
# rejects it outright, so there is no platform where refusing it costs a read.
# `sed -li` is the joined form BSD's no-argument `-l` (line-buffered) makes
# reachable; it was allowed while `l` sat in sed's terminator set, because the
# scan stopped at the `l` and never saw the `i`.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused: $cmd" "$(bash_verdict "$cmd")" deny
done <<EOF
sed -I s/a/b/ file.txt
sed -I.bak s/a/b/ file.txt
sed -nI s/a/b/ file.txt
sed -li s/a/b/ file.txt
sed -lni s/a/b/ file.txt
sed -nlI s/a/b/ file.txt
EOF

# The other direction, and the reason the in-place letter is per-interpreter
# rather than a hardcoded pair. `-I` is an include directory to perl and ruby,
# so widening sed's letters must not have widened theirs.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed: $cmd" "$(bash_verdict "$cmd")" silent
done <<EOF
perl -Ilib -ne print file.txt
perl -Ilib -Ilib2 -ne print file.txt
ruby -Ilib -e puts
ruby -Ilib:vendor -e puts
sed -l 5 -n p file.txt
sed -l5 -n p file.txt
EOF

# The other half of the same rule, and the reason it is a terminator scan rather
# than "an i anywhere". A cluster's flags end at the first switch that takes the
# rest of the token as its value; after that the letters are program text, an
# include path, or a module name. Matching `i` blindly would refuse all of these
# and kill the reading the mode exists to do.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed: $cmd" "$(bash_verdict "$cmd")" silent
done <<EOF
perl -pes/i/j/ file.txt
perl -ne print file.txt
sed -n 1p file.txt
sed -nE s/x/y/i file.txt
sed -ffilter.sed file.txt
perl -Ilib -ne print file.txt
perl -MList::Util -ne print file.txt
ruby -Ilib -e puts
ruby -rtime -e puts
EOF

# `grep -i` is ignore-case, and the whole reason a blanket `-i` rule was rejected.
# The cluster scan must not have widened the flag rule past the three interpreters.
check "grep keeps its clustered -i too" "$(bash_verdict "grep -ri needle .")" silent

# The in-place letters and the terminators are per-interpreter, so a table that
# knew an interpreter in one half and not the other would raise KeyError — which
# crashes the hook, and a crashed hook fails OPEN. A verdict cannot catch that on
# its own: a crash prints nothing, so it reads as "silent" exactly like an
# allowed command does. Stderr is what tells them apart, and it is asserted here
# on a command from each interpreter that must reach the cluster walk at all.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  STRAY="$(run_guard "$(bash_payload "$cmd")" 2>&1 >/dev/null)"
  if [ -z "$STRAY" ]; then ok "no interpreter is half-known to the table: $cmd"
  else bad "the cluster walk errored on $cmd — $STRAY"; fi
done <<EOF
sed -n 1p file.txt
perl -pes/i/j/ file.txt
ruby -rtime -e puts
EOF

echo
echo "── redirection is judged by target, not refused outright ──────────────"

ELSEWHERE="$TMPROOT/elsewhere"
mkdir -p "$ELSEWHERE"
check "redirect to a path in scratch is allowed" \
  "$(bash_verdict "git diff HEAD > $OUTSIDE/review.diff")" silent
check "redirect to /tmp, which is no scratch root here, is refused" \
  "$(bash_verdict "git diff HEAD > /tmp/review.diff")" deny
check "redirect into the tree under review is refused" \
  "$(bash_verdict "git diff HEAD > $WORKDIR/notes.md")" deny
check "a relative redirect resolved into the tree is refused" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A "$LENS" "$WORKDIR")" deny
check "a relative redirect resolved into scratch is allowed" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A "$LENS" "$ELSEWHERE")" silent
check "a relative redirect with no cwd to resolve it fails closed" \
  "$(bash_verdict "git diff HEAD > notes.md")" deny
check "2>&1 is a descriptor, not a file target" \
  "$(bash_verdict "bash run-tests.sh 2>&1")" silent
check ">&2 and 2>&- are descriptors, not file targets" \
  "$(bash_verdict "echo x >&2 2>&-")" silent
check "2>/dev/null writes no file and is allowed" \
  "$(bash_verdict "ls 2>/dev/null")" silent
check "> /dev/stdout and 2> /dev/fd/2 write no file" \
  "$(bash_verdict "echo x > /dev/stdout 2> /dev/fd/2")" silent

# A digit before `>` names the descriptor being redirected, and the target is
# still a file. `>|` overrides noclobber, and `>&word` sends both streams to a
# file when the word is not a descriptor number. Each one writes into the tree.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "a descriptor-prefixed or clobbering redirect into the tree is refused: $cmd" \
    "$(bash_verdict "$cmd")" deny
done <<EOF
echo x 1> $WORKDIR/f
echo x 2> $WORKDIR/f
echo x 2>> $WORKDIR/f
echo x >| $WORKDIR/f
echo x 1>| $WORKDIR/f
echo x >& $WORKDIR/f
echo x 2>&1 > $WORKDIR/f
EOF

# The payload's cwd in scratch is the case that exposed the gap: a target
# joined onto cwd as text lands in scratch, while the shell writes into the
# tree. So each of these runs from $ELSEWHERE, and each writes into the tree.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "with cwd in scratch, refused: $cmd" \
    "$(bash_verdict "$cmd" session-A "$LENS" "$ELSEWHERE")" deny
done <<EOF
echo x > "$WORKDIR/README.md"
echo x > ~/../repo/README.md
echo x > \$HOME/../repo/README.md
echo x > ~/notes.md
cd $WORKDIR && echo x > README.md
cd $WORKDIR && rm README.md
(cd $WORKDIR && rm README.md)
cd $WORKDIR; touch README.md
builtin cd $WORKDIR; echo x > README.md
command cd $WORKDIR && echo x > README.md
( cd $WORKDIR && echo x > f )
(cd $WORKDIR; touch README.md; true)
{ cd $WORKDIR; }; echo x > README.md
if true; then cd $WORKDIR; fi; echo x > README.md
chdir $WORKDIR; echo x > README.md
pushd $WORKDIR && rm README.md
pushd $WORKDIR; echo x > README.md
popd && rm README.md
popd; touch README.md
env -C $WORKDIR chmod 644 README.md
env --chdir=$WORKDIR touch README.md
echo x >! $WORKDIR/README.md
echo x >>! $WORKDIR/README.md
EOF
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "with cwd in scratch, allowed: $cmd" \
    "$(bash_verdict "$cmd" session-A "$LENS" "$ELSEWHERE")" silent
done <<EOF
echo x > notes.md
echo x > ~/Developer/scratchpad/notes.md
rm notes.md
cd $WORKDIR && git status --short
EOF

echo
echo "── quoted text is data: a read that names guarded words or > runs ───"

# Each of these was refused once in a real review: a search pattern that names
# git verbs or writers was split at a quoted | or ;, and a quoted > or a
# descriptor duplication was read as a redirect to a file.
for c in 'grep -rnE "git (commit|push)|chmod|rm -rf" .' "rg -n 'git commit; git restore .' skills" \
         'grep -rn "a; rm -rf x" .' 'git diff HEAD 2>&1 | head -50' "grep -nE '[<>]' f" \
         'grep -rn "\->" .' "rg -n 'x > y' ." 'git diff > /dev/null 2>&1' 'ls 2>/dev/null' \
         'git log -1 2>&1 | tail -3' "grep -c 'a > b' f 2>/dev/null" \
         "printf '%s\n' 'git stash; chmod 644 x'" 'grep -n "x" f | sed -n "1,5p"'; do
  check "read: $c" "$(bash_verdict "$c" session-A "$LENS" "$WORKDIR")" silent
done
# These reads are not on the allowlist, so they get main's verdict, which
# refused them: awk runs its program text, a quoted "->" is an option word to
# grep, and $( ) is a substitution. Mike accepted refused reads as the cost.
for c in "awk '\$3 > 5' data.txt" "awk -F, '{ if (\$2 >= 10) print }' data.csv" 'grep -n "->" src/x.php' \
         'echo "$(git status --short 2>&1)"'; do
  check "read now refused, as main refused it: $c" "$(bash_verdict "$c" session-A "$LENS" "$WORKDIR")" deny
done
echo "...and every write that was refused before is refused still"
for c in "echo x > $WORKDIR/out.txt" 'echo x > out.txt' 'grep -rn "x" . > notes.txt' \
         'cat f 2>&1 > out.txt' "echo 'x' > \"$WORKDIR/q\"" "echo \"a\" ; rm -rf $WORKDIR/x" \
         "sh -c 'git status; rm -rf x'" 'bash -c "echo a; chmod 644 f"' "perl -e 'print 1; unlink \"x\"'" \
         'echo "$(cd x; rm -rf y)"' "echo \$'a\\'b'; rm -rf $WORKDIR/x" 'git restore x' \
         "grep -n 'a' f; git checkout -- f" "\"rm\" -rf $WORKDIR/x" "\\rm -rf $WORKDIR/x" \
         "awk '{ print > \"out.txt\" }' f" "$(printf "cat <<'EOF'\nit's\nEOF\nrm -rf %s/x" "$WORKDIR")"; do
  check "write: $c" "$(bash_verdict "$c" session-A "$LENS" "$WORKDIR")" deny
done

echo "...and the forms Holmes traced in the second round are refused"
for c in "\"bash\" -c 'true; rm README.md'" "\\bash -c 'true; rm README.md'" "\$'sh' -c 'true; rm README.md'" \
         "gawk '{ print > \"out.txt\" }' f" "mawk '{ print > \"out.txt\" }' f" "nawk '{ print > \"out.txt\" }' f" \
         "$(printf "# it's a note\nrm README.md")" "echo x >&2'README.md'"; do
  check "second round: $(printf '%s' "$c" | tr '\n' ' ')" "$(bash_verdict "$c" session-A "$LENS" "$WORKDIR")" deny
done

echo
echo "── editing tools are judged by path ───────────────────────────────────"

edit_payload() { # edit_payload <tool> <path> [agent_type]
  python3 -I -c '
import json, sys
field = "notebook_path" if sys.argv[1] == "NotebookEdit" else "file_path"
body = {"hook_event_name": "PreToolUse", "tool_name": sys.argv[1],
        "session_id": "session-A", "agent_id": "agent-1",
        "tool_input": {field: sys.argv[2]}}
if sys.argv[3]:
    body["agent_type"] = sys.argv[3]
print(json.dumps(body))' "$1" "$2" "${3-$LENS}"
}
edit_verdict() { verdict_of "$(run_guard "$(edit_payload "$@")")"; }

for tool in Edit Write NotebookEdit; do
  check "$tool from a helper into the tree is refused" "$(edit_verdict "$tool" "$WORKDIR/src/file.txt")" deny
  check "$tool from a helper into scratch is allowed" "$(edit_verdict "$tool" "$OUTSIDE/file.txt")" silent
  check "$tool from Watson into the tree is allowed" \
    "$(edit_verdict "$tool" "$WORKDIR/src/file.txt" "$WATSON")" silent
done
check "an Edit from Holmes into the tree is refused" \
  "$(edit_verdict Edit "$WORKDIR/src/file.txt" "$HOLMES")" deny
check "an Edit through a symlink out of scratch into the tree is refused" \
  "$(edit_verdict Edit "$TMPROOT/link-into-tree/file.txt")" deny
check "an Edit with a relative path and no cwd is refused" "$(edit_verdict Edit "src/file.txt")" deny
check "a session with no agent_type keeps its editing tools" \
  "$(edit_verdict Edit "$WORKDIR/src/file.txt" "")" silent
check "the human line names the tool" \
  "$(run_guard "$(edit_payload Write "$WORKDIR/x")" | python3 -I -c \
    'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])')" \
  '🛑 Blocked: `Write`. A Holmes reviewer writes only in scratch.'

# The guard is static, so it belongs on PreToolUse for the four writing tools
# and nowhere else. An Agent entry, or any post-call event, would be the hold
# machinery this version removed coming back.
HOOKS_JSON="$(cd "$(dirname "$0")/../.." && pwd)/hooks/hooks.json"
if python3 -I - "$HOOKS_JSON" <<'PY'
import json, re, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
matchers = [b.get("matcher", "") for b in hooks["PreToolUse"]
            if any("local-review-guard.sh" in h["command"] for h in b["hooks"])]
routed = all(any(re.fullmatch(m, t) for m in matchers)
             for t in ("Bash", "Edit", "Write", "NotebookEdit"))
agent = any(re.fullmatch(m, "Agent") for m in matchers)
elsewhere = [e for e, blocks in hooks.items() if e != "PreToolUse"
             and any("local-review-guard.sh" in h["command"] for b in blocks for h in b["hooks"])]
sys.exit(0 if routed and not agent and not elsewhere else 1)
PY
then ok "hooks.json routes Bash and the three editing tools to the guard, and nothing else"
else bad "hooks.json routes the guard wrongly: a writing tool is missing, or Agent or another event is wired"; fi

echo
echo "── a missing or failing python3 fails closed for a reviewer ───────────"

# Two PATHs stand in for a broken host: one with no python3 at all, and one whose
# python3 exits 1. The second is the status branch after the heredoc. Each holds
# only the tools the guard's shell half needs, so the host's own python3 cannot
# answer for them.
NOPY="$SANDBOX/no-python"
BADPY="$SANDBOX/bad-python"
mkdir -p "$NOPY" "$BADPY"
for tool in bash cat grep dirname; do
  ln -sf "$(command -v "$tool")" "$NOPY/$tool"
  ln -sf "$(command -v "$tool")" "$BADPY/$tool"
done
printf '#!/bin/sh\nexit 1\n' > "$BADPY/python3"
chmod +x "$BADPY/python3"
# `holmes` with its h written as a JSON unicode escape, backslash included, so
# the raw agent_type carries the escape python3 would have had to decode.
ESCAPED_TYPE="$(printf 'workbench-dev-team:%su0068olmes' '\')"
raw_bash() { # raw_bash <agent_type-json-text> <command>
  printf '{"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s", "agent_id": "a", "agent_type": "%s", "tool_input": {"command": "%s"}}' "$1" "$2"
}
for broken in "$NOPY" "$BADPY"; do
  label="no python3"; [ "$broken" = "$BADPY" ] && label="a python3 that exits 1"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    check "$label: a reviewer is refused, $cmd" \
      "$(verdict_of "$(run_guard "$(bash_payload "$cmd")" PATH="$broken")")" deny
  done <<EOF
chmod 644 $WORKDIR/file.txt
rm -rf $WORKDIR/src
echo x > $WORKDIR/notes.md
git status
ls -la
EOF
  for tool in Edit Write NotebookEdit; do
    check "$label: $tool from a reviewer is refused" \
      "$(verdict_of "$(run_guard "$(edit_payload "$tool" "$WORKDIR/src/file.txt")" PATH="$broken")")" deny
  done
  check "$label: Watson keeps its tools" \
    "$(verdict_of "$(run_guard "$(bash_payload "chmod 644 $WORKDIR/file.txt" session-A "$WATSON")" PATH="$broken")")" silent
  check "$label: a session with no agent_type keeps its tools" \
    "$(verdict_of "$(run_guard "$(bash_payload "chmod 644 $WORKDIR/file.txt" session-A "")" PATH="$broken")")" silent
  check "$label: command text naming agent_type cannot fake a reviewer" \
    "$(verdict_of "$(run_guard "$(bash_payload 'echo "agent_type": "holmes"' session-A "$WATSON")" PATH="$broken")")" silent
  check "$label: a reviewer type spelled with a \\u escape is refused" \
    "$(verdict_of "$(run_guard "$(raw_bash "$ESCAPED_TYPE" "ls")" PATH="$broken")")" deny
  check "$label: a non-ASCII reviewer type is refused" \
    "$(verdict_of "$(run_guard "$(raw_bash "workbench-dev-team:holmeſ" "ls")" PATH="$broken")")" deny
  check "$label: a non-reviewer with a \\u escape in its command keeps its tools" \
    "$(verdict_of "$(run_guard "$(raw_bash "$WATSON" "$(printf 'echo %su0067it' '\')")" PATH="$broken")")" silent
  CONTEXT_OUT="$(run_guard "$(bash_payload "ls")" PATH="$broken")"
  case "$CONTEXT_OUT" in
    *"python3 is missing or failed"*) ok "$label: the refusal names python3 as the cause" ;;
    *) bad "$label: the refusal does not name python3" ;;
  esac
  printf '%s' "$CONTEXT_OUT" | python3 -I -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    && ok "$label: the refusal is valid JSON" || bad "$label: the refusal is not valid JSON"
done
printf 'git status\n' | env PATH="$NOPY" /bin/bash "$GUARD" --classify >/dev/null 2>&1
check "no python3: --classify reports the failure rather than passing" "$?" 2

echo
echo "── fast path: python3 starts only for a reviewer ──────────────────────"

# A python3 that leaves a marker and then runs the real one, so each case can
# tell whether the guard started it at all, while the verdict still comes from
# the real classifier.
SPY="$SANDBOX/spy-python"
SPY_MARK="$SANDBOX/python-ran"
mkdir -p "$SPY"
printf '#!/bin/sh\ntouch "%s"\nexec "%s" "$@"\n' "$SPY_MARK" "$(command -v python3)" > "$SPY/python3"
chmod +x "$SPY/python3"
python_started() { # python_started <payload> — "yes" or "no"
  rm -f "$SPY_MARK"
  run_guard "$1" PATH="$SPY:$PATH" >/dev/null
  if [ -e "$SPY_MARK" ]; then echo yes; else echo no; fi
}
check "Watson's Bash call does not start python3" \
  "$(python_started "$(bash_payload "git restore ." session-A "$WATSON")")" no
check "a session with no agent_type does not start python3" \
  "$(python_started "$(bash_payload "chmod 644 x" session-A "")")" no
check "a reviewer's Bash call starts python3" \
  "$(python_started "$(bash_payload "git status")")" yes
check "...and a reviewer is still refused through the fast path" \
  "$(verdict_of "$(run_guard "$(bash_payload "git restore .")" PATH="$SPY:$PATH")")" deny
# Raw UTF-8, as the harness sends it. bash_payload's json.dumps would write a
# backslash-u escape instead, which is the next case's rule, not this one.
check "a non-ASCII agent_type starts python3, which folds ſ into s" \
  "$(python_started "$(raw_bash "workbench-dev-team:holmeſ" "git restore .")")" yes
check "a reviewer type spelled with a \\u escape starts python3" \
  "$(python_started "$(raw_bash "$ESCAPED_TYPE" "git restore .")")" yes
check "...and python3 reads it as holmes, so skipping it would have missed a reviewer" \
  "$(verdict_of "$(run_guard "$(raw_bash "$ESCAPED_TYPE" "git restore .")")")" deny

echo
echo "── the verdict binds: deny, never ask ─────────────────────────────────"

ASK_SEEN=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  [ "$(bash_verdict "$cmd")" = ask ] && ASK_SEEN="$cmd"
done <<EOF
git restore .
chmod 644 file.txt
rm -rf .
git stash
EOF
check "no refusal path returns the classifier-approvable 'ask'" "${ASK_SEEN:-none}" none

DENIAL="$(run_guard "$(bash_payload "git restore .")")"
printf '%s' "$DENIAL" | grep -q 'Review guard (workbench-dev-team)' && ok "the denial names the guard" \
  || bad "the denial does not name the guard"
printf '%s' "$DENIAL" | grep -q "$TMPROOT" && ok "the denial names the scratch roots" \
  || bad "the denial does not name the scratch roots"
# The denial offers no approval path, on purpose. A denial that prints a way out is an invitation to take it.
printf '%s' "$DENIAL" | grep -qi 'approve\|override' \
  && bad "the denial leaks a way around itself" \
  || ok "the denial offers no way around itself"

echo
echo "── fail-safe inputs ───────────────────────────────────────────────────"

check "an unparseable payload yields no opinion" "$(verdict_of "$(printf 'not json' | \
  env -u WORKBENCH_DEV_TEAM_PIPELINE HOME="$SANDBOX/home" TMPDIR="$TMPROOT" bash "$GUARD")")" silent
check "a payload with no session id is still judged by its agent_type" \
  "$(bash_verdict "git restore ." "")" deny
check "a non-Bash, non-editing tool is not this guard's business" \
  "$(verdict_of "$(run_guard "$(python3 -I -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Read",
                  "session_id": "session-A", "agent_id": "agent-1", "agent_type": sys.argv[1],
                  "tool_input": {"file_path": "/etc/hosts"}}))' "$LENS")")")" silent
check "an Agent dispatch is not this guard's business" \
  "$(verdict_of "$(run_guard "$(python3 -I -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Agent",
                  "session_id": "session-A", "agent_id": "agent-1", "agent_type": sys.argv[1],
                  "tool_input": {"subagent_type": sys.argv[1], "prompt": "rm -rf /"}}))' "$HOLMES")")")" silent
check "a PostToolUse payload is not this guard's business" \
  "$(verdict_of "$(run_guard "$(python3 -I -c '
import json, sys
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash",
                  "session_id": "session-A", "agent_id": "agent-1", "agent_type": sys.argv[1],
                  "tool_input": {"command": "git restore ."}}))' "$LENS")")")" silent
check "with no scratch root anywhere, every reviewer write is refused" \
  "$(verdict_of "$(run_guard "$(bash_payload "touch $OUTSIDE/x")" TMPDIR="$SANDBOX/missing" HOME="$SANDBOX/nohome")")" deny

echo
echo "── the denial's wording: one line for the human, the rest for the model ──"

# The refusal is split across the hook's two channels. The human line is ONE
# line naming the ACTION they took; everything an agent acts on lives in
# additionalContext, which survives a deny and reaches only the model. Each half
# is asserted on the channel it belongs to, because asserting on the whole
# payload would pass whichever field the text ended up in.
field_of() { # field_of <payload-json> <field>
  printf '%s' "$1" | python3 -I -c \
    'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"][sys.argv[1]])' "$2"
}

DENY_OUT="$(run_guard "$(bash_payload "chmod 644 file.txt")")"
DENY_REASON="$(field_of "$DENY_OUT" permissionDecisionReason)"
DENY_CONTEXT="$(field_of "$DENY_OUT" additionalContext)"

check "the human line names the action and nothing else" "$DENY_REASON" \
  '🛑 Blocked: `chmod`. A Holmes reviewer writes only in scratch.'
if [ "$(printf '%s' "$DENY_REASON" | grep -c .)" = "1" ] && [ "${#DENY_REASON}" -le 120 ]; then
  ok "the human line is one line and stays short (${#DENY_REASON} chars)"
else
  bad "the human line grew past one short line (${#DENY_REASON} chars)"
fi
# No Markdown emphasis: whether a client renders it is unsettled, and the model
# receives the raw source either way, so asterisks would show up as asterisks.
case "$DENY_REASON" in
  *'**'*) bad "the human line uses Markdown emphasis" ;;
  *) ok "the human line carries no Markdown emphasis" ;;
esac
# The tree's absolute path is the noise a person was asked to stop reading.
case "$DENY_REASON" in
  *"$WORKDIR"*) bad "the human line replays the absolute workdir" ;;
  *) ok "the human line replays no absolute path" ;;
esac

case "$DENY_CONTEXT" in
  *"Review guard (workbench-dev-team)."*)
    ok "the context names the guard, so the model can report which one fired" ;;
  *) bad "the context does not name the guard" ;;
esac
case "$DENY_CONTEXT" in
  *"changes a file's content, location, existence, or metadata"*)
    ok "the context carries the reason the classifier gave" ;;
  *) bad "the context lost the classifier's reason" ;;
esac
case "$DENY_CONTEXT" in
  *"$TMPROOT"*) ok "the context names the scratch roots" ;;
  *) bad "the context does not name the scratch roots" ;;
esac
case "$DENY_CONTEXT" in
  *"git diff HEAD"*) ok "the context still says what to run instead" ;;
  *) bad "the context lost the allowed alternatives" ;;
esac
case "$DENY_CONTEXT" in
  *"no path around this"*) ok "the context still refuses an escape hatch" ;;
  *) bad "the context lost the no-escape-hatch line" ;;
esac

# Each rule gets its own action word. One label for every refusal would tell a
# person nothing the emoji does not already say.
action_of() { # action_of <command> [cwd]
  field_of "$(run_guard "$(bash_payload "$1" session-A "$LENS" "${2-}")")" permissionDecisionReason
}
check "a git write names the verb" "$(action_of 'git restore .')" \
  '🛑 Blocked: `git restore`. A Holmes reviewer writes only in scratch.'
check "an in-place edit names -i" "$(action_of 'sed -i s/a/b/ f')" \
  '🛑 Blocked: `sed -i`. A Holmes reviewer writes only in scratch.'
check "a rewrite flag says so" "$(action_of 'prettier --write .')" \
  '🛑 Blocked: `prettier` with a rewrite flag. A Holmes reviewer writes only in scratch.'
check "a redirect into the tree says so" "$(action_of 'git diff HEAD > notes.md' "$WORKDIR")" \
  '🛑 Blocked: redirecting output outside the scratch roots. A Holmes reviewer writes only in scratch.'

echo
echo "── --classify: the same rule the lint holds the docs to ───────────────"

printf 'git -C /w status --short\ngit -C /w diff HEAD\nbash run-tests.sh\n' | bash "$GUARD" --classify >/dev/null \
  && ok "--classify passes the reference's own documented commands" \
  || bad "--classify rejects a command the reference tells a reviewer to run"
printf 'git status\ngit restore .\nchmod 644 x\n' | bash "$GUARD" --classify >/dev/null \
  && bad "--classify passed a block containing git restore and chmod" \
  || ok "--classify fails a block containing a destructive command"
CLASSIFIED="$(printf 'git restore .\nchmod 644 x\n' | bash "$GUARD" --classify)"
check "--classify reports every offending line, not just the first" \
  "$(printf '%s\n' "$CLASSIFIED" | grep -c .)" 2
# Prose that names the verbs mid-sentence must stay legal, or the next author is
# taught to delete the warning to get the lint green.
printf 'every other git verb is forbidden. That includes restore, stash, and clean.\n' \
  | bash "$GUARD" --classify >/dev/null \
  && ok "--classify leaves the prohibition's own prose alone" \
  || bad "--classify reddens on prose that merely names the verbs"

echo
echo "── isolation: no module in the cwd or on PYTHONPATH loads into the guard ──"

# In Local mode the hook's cwd is the tree under review, so a module planted
# there must never run inside the guard, and neither may one on PYTHONPATH.
# Each planted module only leaves a mark. The verdicts must stay normal, and the
# allowlisted read must still pass, which proves the real read_allowlist.py
# loaded from the guard's own folder.
PLANT_CWD="$SANDBOX/plant-cwd"; PLANT_PATH="$SANDBOX/plant-path"; PLANT_MARK="$SANDBOX/planted-module-ran"
mkdir -p "$PLANT_CWD" "$PLANT_PATH"
for d in "$PLANT_CWD" "$PLANT_PATH"; do
  for m in re json glob os read_allowlist sitecustomize usercustomize; do
    printf 'open(%s, "a").write("%s\\n")\n' "'$PLANT_MARK'" "$m" > "$d/$m.py"
  done
done
planted_verdict() { # planted_verdict <command>: the guard run from the planted cwd
  local body
  body=$(bash_payload "$1" session-A "$LENS" "$WORKDIR")
  verdict_of "$(cd "$PLANT_CWD" && run_guard "$body" PYTHONPATH="$PLANT_PATH" PYTHONSTARTUP="$PLANT_PATH/re.py")"
}
check "planted modules: a write into the tree is still refused" "$(planted_verdict "chmod 644 $WORKDIR/x")" deny
check "planted modules: git status still passes" "$(planted_verdict 'git status')" silent
check "planted modules: an allowlisted read still passes" \
  "$(planted_verdict 'grep -rnE "git (commit|push)|chmod|rm -rf" .')" silent
[ ! -e "$PLANT_MARK" ] && ok "no planted module ran inside the guard" \
  || bad "a planted module ran inside the guard: $(tr '\n' ' ' < "$PLANT_MARK")"

echo
echo "── differential: nothing main's guard refused is allowed now ──────────"

# The reads a reviewer may now run that main refused. Each one is an
# allowlisted read (checked below): a listed reader with listed options whose
# quoted text names a guarded word or a > or |. Anything else main refused
# must stay refused.
READS_OK=('grep -rnE "git (commit|push)|chmod|rm -rf" .' "rg -n 'git commit; git restore .' skills"
  'grep -rn "a; rm -rf x" .' "grep -nE '[<>]' f" 'grep -rn "\->" .' "rg -n 'x > y' ."
  "grep -c 'a > b' f 2>/dev/null" "printf '%s\n' 'git stash; chmod 644 x'")
is_read() { local r; for r in "${READS_OK[@]}"; do [ "$r" = "$1" ] && return 0; done; return 1; }
for c in "${READS_OK[@]}"; do
  printf '%s' "$c" | python3 -I "$(dirname "$GUARD")/read_allowlist.py" \
    && ok "READS_OK entry is allowlisted: $c" || bad "READS_OK entry is not an allowlisted read: $c"
done
# shellcheck source=testdata/hostile-commands.sh
. "$(dirname "$GUARD")/testdata/hostile-commands.sh"
MAIN="$(dirname "$GUARD")/testdata/local-review-guard-621f3fb.sh"
CASES=()
for c in "${HOSTILE[@]}"; do CASES+=("$c" "$WORKDIR"); done
while IFS= read -r -d '' c && IFS= read -r -d '' d; do CASES+=("$c" "$d"); done < "$SEEN_FILE"
compared=0; flagged=0; i=0
while [ "$i" -lt "${#CASES[@]}" ]; do
  c=${CASES[i]}; d=${CASES[i + 1]}; i=$((i + 2)); compared=$((compared + 1))
  body=$(bash_payload "$c" session-A "$LENS" "$d")
  [ "$(verdict_of "$(RUN_GUARD="$MAIN" run_guard "$body")")" = deny ] || continue
  [ "$(verdict_of "$(run_guard "$body")")" = deny ] && continue
  is_read "$c" && continue
  flagged=$((flagged + 1)); bad "main refused, now allowed (cwd ${d:-none}): $(printf '%s' "$c" | tr '\n' ' ')"
done
for c in "${ROUND4[@]}"; do
  body=$(bash_payload "$c" session-A "$LENS" "$WORKDIR")
  main_verdict="$(verdict_of "$(RUN_GUARD="$MAIN" run_guard "$body")")"
  check "round 4, main's verdict: $c" "$(verdict_of "$(run_guard "$body")")" "$main_verdict"
done
[ "$flagged" = 0 ] && ok "differential: $compared commands (${#HOSTILE[@]} hostile forms and every reviewer case), none newly allowed"
for c in "${READS_OK[@]}"; do
  check "named read passes: $c" "$(bash_verdict "$c" session-A "$LENS" "$WORKDIR")" silent
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
