#!/bin/bash
# Tests for local-review-guard.sh. Run directly: ./test-local-review-guard.sh
#
# Each case feeds a synthetic hook payload and asserts the guard's behaviour:
# what it arms, what it refuses, what it leaves alone, and what it releases.
#
# Two properties carry most of the weight, and both have a named failure behind
# them. (1) A refused command must come back "deny" and never "ask" — a hook's
# "ask" is classifier-approvable, which is how the sibling commit gate spent its
# whole life stopping nothing. (2) A session that is NOT running a review must be
# untouched while another session is — a host-wide signal would gag the human's
# own window, which is the commit gate's watson.lock leak with the sign flipped.
#
# The sandbox owns HOME, TMPDIR and the state directory, so no case can read or
# write the developer's real environment: the verdict has to come from the
# guard, never from what happens to be on this host.

set -u
GUARD="$(cd "$(dirname "$0")" && pwd)/local-review-guard.sh"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/local-review-guard.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
STATE="$SANDBOX/state"
WORKDIR="$SANDBOX/repo"
mkdir -p "$WORKDIR" "$SANDBOX/home"

BRIEF="Workdir: $WORKDIR (branch: main — in place)

Goal: the guard refuses a mutation and permits a read.

Context: prose.

Constraints:
- none

Done when: the suite is green."

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected $3, got $2"; fi; }

# Build the payload first, then feed it with printf. Piping a generator straight
# into the guard breaks its stdout when the carve-out exits before reading stdin.
run_guard() { # run_guard <payload> [env assignments...]
  local body="$1"; shift
  printf '%s' "$body" | env -u WORKBENCH_DEV_TEAM_PIPELINE \
    WORKBENCH_LOCAL_REVIEW_DIR="$STATE" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" \
    "$@" bash "$GUARD"
}

agent_payload() { # agent_payload <event> <subagent_type> <prompt> [session]
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": sys.argv[1], "tool_name": "Agent",
                  "session_id": sys.argv[4], "agent_id": "",
                  "tool_input": {"subagent_type": sys.argv[2], "prompt": sys.argv[3]}}))' \
    "$1" "$2" "$3" "${4-session-A}"
}

bash_payload() { # bash_payload <command> [session] [agent] [cwd]
  python3 -c '
import json, sys
body = {"hook_event_name": "PreToolUse", "tool_name": "Bash",
        "session_id": sys.argv[2], "agent_id": sys.argv[3],
        "tool_input": {"command": sys.argv[1]}}
if sys.argv[4]:
    body["cwd"] = sys.argv[4]
print(json.dumps(body))' "$1" "${2-session-A}" "${3-agent-1}" "${4-}"
}

verdict_of() {
  if printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; then echo deny
  elif printf '%s' "$1" | grep -q '"permissionDecision": *"ask"'; then echo ask
  else echo silent; fi
}

records() { ls -1 "$STATE" 2>/dev/null | wc -l | tr -d ' '; }
reset_state() { rm -rf "$STATE"; }

arm()    { run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "$BRIEF" "${1-session-A}")" >/dev/null; }
disarm() { run_guard "$(agent_payload PostToolUse "workbench-dev-team:holmes" "$BRIEF" "${1-session-A}")" >/dev/null; }

# bash_verdict <command> [session] [agent] [cwd]
bash_verdict() { verdict_of "$(run_guard "$(bash_payload "$1" "${2-session-A}" "${3-agent-1}" "${4-}")")"; }

echo "── arming: only a Holmes local dispatch arms ──────────────────────────"

reset_state
arm
check "a Holmes prose brief arms the session" "$(records)" 1

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "Item ID: 412")" >/dev/null
check "an 'Item ID' dispatch is Index mode and does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "  412  ")" >/dev/null
check "a bare integer id does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "PVTI_lADOAbc123")" >/dev/null
check "a bare PVTI id does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "3823652e-6394-4478-a87d-a1e838a84e90")" >/dev/null
check "a bare UUID id does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:watson" "$BRIEF")" >/dev/null
check "a Watson dispatch does not arm" "$(records)" 0

reset_state
run_guard "$(agent_payload PreToolUse "Explore" "$BRIEF")" >/dev/null
check "a generic lens dispatch does not arm" "$(records)" 0

# The scheduled pipeline never reviews a live working tree, and must not inherit
# a rule written for one. Same carve-out signal the commit gate uses, checked
# first so no state is even consulted.
reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "$BRIEF")" WORKBENCH_DEV_TEAM_PIPELINE=1 >/dev/null
check "the pipeline carve-out suppresses arming" "$(records)" 0

echo
echo "── reading and testing stay legal ─────────────────────────────────────"

reset_state
arm
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
OUTSIDE="$SANDBOX/scratch"
mkdir -p "$OUTSIDE" "$WORKDIR/src"
ln -sfn "$WORKDIR/src" "$SANDBOX/link-into-tree"
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed outside the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$OUTSIDE")" silent
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
rm -rf ~/definitely-not-the-tree
EOF

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused into the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$OUTSIDE")" deny
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
rm -rf $SANDBOX/link-into-tree/file.txt
touch $SANDBOX/link-into-tree/new.txt
EOF

# A write whose path the guard cannot resolve is refused, wherever it runs.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused, unresolvable: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$OUTSIDE")" deny
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
  check "refused, a link entry in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$OUTSIDE")" deny
done <<EOF
rm $WORKDIR/link-out
rm -f $WORKDIR/dir-link-out
unlink $WORKDIR/link-out
mv $WORKDIR/link-out $OUTSIDE/moved
chmod -h 644 $WORKDIR/link-out
EOF
check "a relative link entry in the tree's cwd is refused" \
  "$(bash_verdict "rm link-out" session-A agent-1 "$WORKDIR")" deny
check "the outside target itself stays writable" \
  "$(bash_verdict "rm $OUTSIDE/target.txt" session-A agent-1 "$OUTSIDE")" silent
check "patch in the tree's own cwd is refused" \
  "$(bash_verdict "patch -p1 -i $OUTSIDE/fix.diff" session-A agent-1 "$WORKDIR")" deny

echo
echo "── ordinary writers and formatters (round 5) ──────────────────────────"

# Each of these ran silently with cwd in the tree before round 5. The writer
# list is fixed, not a rule, so each writer it names is pinned here.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" deny
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
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" silent
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
  "$(bash_verdict "ln -s $OUTSIDE/x" session-A agent-1 "$WORKDIR")" deny

echo
echo "── lookups, long write flags, and project runners (round 6) ───────────"

# Each of these ran silently before round 6: a long rubocop write spelling, a
# default writer, or a listed writer behind a project runner.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" deny
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
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" deny
done <<EOF
command black app.py
terraform fmt -check=false
EOF

# Each of these was refused before round 6, and none writes a file: a lookup,
# a help or config form, a string handed to a formatter, or a uniq option's
# value read as the output file.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" silent
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
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" silent
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
  check "refused with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" deny
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
  check "allowed with cwd in the tree: $cmd" "$(bash_verdict "$cmd" session-A agent-1 "$WORKDIR")" silent
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

check "redirect to an absolute path outside the tree is allowed" \
  "$(bash_verdict "git diff HEAD > /tmp/review.diff")" silent
check "redirect into the tree under review is refused" \
  "$(bash_verdict "git diff HEAD > $WORKDIR/notes.md")" deny
check "a relative redirect resolved into the tree is refused" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A agent-1 "$WORKDIR")" deny
check "a relative redirect resolved outside the tree is allowed" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A agent-1 "$SANDBOX/elsewhere")" silent
check "a relative redirect with no cwd to resolve it fails closed" \
  "$(bash_verdict "git diff HEAD > notes.md")" deny
check "2>&1 is a descriptor, not a file target" \
  "$(bash_verdict "bash run-tests.sh 2>&1")" silent
check ">&2 and 2>&- are descriptors, not file targets" \
  "$(bash_verdict "echo x >&2 2>&-")" silent
check "2>/dev/null outside the tree is allowed" \
  "$(bash_verdict "ls 2>/dev/null")" silent

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

# The payload's cwd outside the tree is the case that exposed the gap: a target
# joined onto cwd as text lands outside, while the shell writes inside. So each
# of these runs from $ELSEWHERE, and each writes into the tree when it runs.
ELSEWHERE="$SANDBOX/elsewhere"
mkdir -p "$ELSEWHERE"
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  check "with cwd outside the tree, refused: $cmd" \
    "$(bash_verdict "$cmd" session-A agent-1 "$ELSEWHERE")" deny
done <<EOF
echo x > "$WORKDIR/README.md"
echo x > ~/../repo/README.md
echo x > \$HOME/../repo/README.md
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
  check "with cwd outside the tree, allowed: $cmd" \
    "$(bash_verdict "$cmd" session-A agent-1 "$ELSEWHERE")" silent
done <<EOF
echo x > notes.md
echo x > ~/notes.md
rm notes.md
cd $WORKDIR && git status --short
EOF

echo
echo "── scope: only sub-agents, only the session under review ──────────────"

# The constraint-3 regression guard. A host-wide signal would gag this.
check "a different session is untouched while this one is armed" \
  "$(bash_verdict "chmod 644 file.txt" session-B agent-9)" silent
check "the armed session's main thread keeps its own tools" \
  "$(bash_verdict "chmod 644 file.txt" session-A "")" silent
check "the pipeline carve-out is silent even on an armed session" \
  "$(verdict_of "$(run_guard "$(bash_payload "git restore ." session-A agent-1)" WORKBENCH_DEV_TEAM_PIPELINE=1)")" silent

reset_state
check "an unarmed session is untouched" "$(bash_verdict "git restore .")" silent
check "an unarmed session may still chmod" "$(bash_verdict "chmod 644 file.txt")" silent

echo
echo "── editing tools are judged by path ───────────────────────────────────"

edit_payload() { # edit_payload <tool> <path> [session] [agent]
  python3 -c '
import json, sys
field = "notebook_path" if sys.argv[1] == "NotebookEdit" else "file_path"
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": sys.argv[1],
                  "session_id": sys.argv[3], "agent_id": sys.argv[4],
                  "tool_input": {field: sys.argv[2]}}))' "$1" "$2" "${3-session-A}" "${4-agent-1}"
}
edit_verdict() { verdict_of "$(run_guard "$(edit_payload "$@")")"; }

reset_state
arm
for tool in Edit Write NotebookEdit; do
  check "$tool inside the tree is refused" "$(edit_verdict "$tool" "$WORKDIR/src/file.txt")" deny
  check "$tool outside the tree is allowed" "$(edit_verdict "$tool" "$SANDBOX/scratch/file.txt")" silent
done
check "an Edit through a symlink into the tree is refused" \
  "$(edit_verdict Edit "$SANDBOX/link-into-tree/file.txt")" deny
check "an Edit with a relative path and no cwd is refused" "$(edit_verdict Edit "src/file.txt")" deny
check "the main thread keeps its own editing tools" \
  "$(edit_verdict Edit "$WORKDIR/src/file.txt" session-A "")" silent
check "another session's sub-agent is untouched" \
  "$(edit_verdict Edit "$WORKDIR/src/file.txt" session-B agent-9)" silent
check "the human line names the tool" \
  "$(run_guard "$(edit_payload Write "$WORKDIR/x")" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])')" \
  '🛑 Blocked: `Write`. A local review is reading this working tree.'
reset_state
check "an unarmed session's sub-agent may edit" "$(edit_verdict Edit "$WORKDIR/src/file.txt")" silent
HOOKS_JSON="$(cd "$(dirname "$0")/../.." && pwd)/hooks/hooks.json"
if python3 - "$HOOKS_JSON" <<'PY'
import json, re, sys
blocks = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
matchers = [b["matcher"] for b in blocks
            if any("local-review-guard.sh" in h["command"] for h in b["hooks"])]
sys.exit(0 if all(any(re.fullmatch(m, t) for m in matchers)
                  for t in ("Bash", "Agent", "Edit", "Write", "NotebookEdit")) else 1)
PY
then ok "hooks.json routes Bash, Agent, and the three editing tools to the guard"
else bad "hooks.json does not route every editing tool to the guard"; fi

echo
echo "── a missing or failing python3 fails closed while a review is armed ──"

# Two PATHs stand in for a broken host: one with no python3 at all, and one whose
# python3 exits 1. The second is the status branch after the heredoc, which no
# case reached before. Each holds only the tools the guard's shell half needs,
# so the host's own python3 cannot answer for them.
NOPY="$SANDBOX/no-python"
BADPY="$SANDBOX/bad-python"
mkdir -p "$NOPY" "$BADPY"
for tool in bash cat grep dirname; do
  ln -sf "$(command -v "$tool")" "$NOPY/$tool"
  ln -sf "$(command -v "$tool")" "$BADPY/$tool"
done
printf '#!/bin/sh\nexit 1\n' > "$BADPY/python3"
chmod +x "$BADPY/python3"
# `git` with its g written as a JSON unicode escape, backslash included, so the
# raw payload carries the escape the fast path sends on to python3.
ESCAPED_NAME="$(printf '%su0067it' '\')"
# With a review armed, python3 is what tells a read from a write. Without it the
# guard used to refuse only text naming git, which is the commit gate's rule, so
# every one of the writes below ran unchecked.
for broken in "$NOPY" "$BADPY"; do
  label="no python3"; [ "$broken" = "$BADPY" ] && label="a python3 that exits 1"
  reset_state
  arm
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    check "$label: refused, $cmd" \
      "$(verdict_of "$(run_guard "$(bash_payload "$cmd")" PATH="$broken")")" deny
  done <<EOF
chmod 644 $WORKDIR/file.txt
rm -rf $WORKDIR/src
mv $WORKDIR/a $WORKDIR/b
echo x > $WORKDIR/notes.md
git status
ls -la
EOF
  for tool in Edit Write NotebookEdit; do
    check "$label: $tool into the tree is refused" \
      "$(verdict_of "$(run_guard "$(edit_payload "$tool" "$WORKDIR/src/file.txt")" PATH="$broken")")" deny
  done
  check "$label: the main thread keeps its tools" \
    "$(verdict_of "$(run_guard "$(bash_payload "chmod 644 $WORKDIR/file.txt" session-A "")" PATH="$broken")")" silent
  check "$label: command text naming agent_id cannot fake a sub-agent" \
    "$(verdict_of "$(run_guard "$(bash_payload 'echo "agent_id": "x"' session-A "")" PATH="$broken")")" silent
  check "$label: an Agent dispatch is not refused" \
    "$(verdict_of "$(run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "$BRIEF")" PATH="$broken")")" silent
  CONTEXT_OUT="$(run_guard "$(bash_payload "ls")" PATH="$broken")"
  case "$CONTEXT_OUT" in
    *"python3 is missing or failed"*) ok "$label: the refusal names python3 as the cause" ;;
    *) bad "$label: the refusal does not name python3" ;;
  esac
  printf '%s' "$CONTEXT_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    && ok "$label: the refusal is valid JSON" || bad "$label: the refusal is not valid JSON"

  # No record on the host: nothing to protect, so no opinion. The fast path's
  # own escapes reach this branch too: a holmes mention, a \u escape, and a
  # non-ASCII byte each send the payload past the fast path to python3.
  reset_state
  check "$label, no review armed: a write keeps its normal flow" \
    "$(verdict_of "$(run_guard "$(bash_payload "chmod 644 $WORKDIR/file.txt")" PATH="$broken")")" silent
  check "$label, no review armed: a command naming holmes keeps its normal flow" \
    "$(verdict_of "$(run_guard "$(bash_payload "grep holmes $WORKDIR/x")" PATH="$broken")")" silent
  check "$label, no review armed: a \\u escape keeps its normal flow" \
    "$(verdict_of "$(run_guard '{"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s", "agent_id": "a", "tool_input": {"command": "echo '"$ESCAPED_NAME"'"}}' PATH="$broken")")" silent
  check "$label, no review armed: a non-ASCII payload keeps its normal flow" \
    "$(verdict_of "$(run_guard '{"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s", "agent_id": "a", "tool_input": {"command": "echo ſ"}}' PATH="$broken")")" silent
  # ...and with a record, the same escape shapes are refused like anything else.
  arm
  check "$label, armed: a \\u escape is refused" \
    "$(verdict_of "$(run_guard '{"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s", "agent_id": "a", "tool_input": {"command": "echo '"$ESCAPED_NAME"'"}}' PATH="$broken")")" deny
  check "$label, armed: a non-ASCII payload is refused" \
    "$(verdict_of "$(run_guard '{"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s", "agent_id": "a", "tool_input": {"command": "echo ſ"}}' PATH="$broken")")" deny
done
reset_state
printf 'git status\n' | env PATH="$NOPY" /bin/bash "$GUARD" --classify >/dev/null 2>&1
check "no python3: --classify reports the failure rather than passing" "$?" 2

echo
echo "── fast path: python3 starts only when a review could be in play ──────"

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
reset_state
check "no record: a Bash call does not start python3" \
  "$(python_started "$(bash_payload "git restore .")")" no
check "no record: a lens dispatch does not start python3" \
  "$(python_started "$(agent_payload PreToolUse "Explore" "read the diff")")" no
check "no record: a returning lens does not start python3" \
  "$(python_started "$(agent_payload PostToolUse "Explore" "read the diff")")" no
check "no record: a Holmes dispatch still starts python3, to arm" \
  "$(python_started "$(agent_payload PreToolUse "workbench-dev-team:holmes" "$BRIEF")")" yes
check "...and it armed" "$(records)" 1
check "a record on the host: a Bash call starts python3" \
  "$(python_started "$(bash_payload "git status" session-B)")" yes
check "...and the guarded session is still refused through the fast path" \
  "$(verdict_of "$(run_guard "$(bash_payload "git restore .")" PATH="$SPY:$PATH")")" deny
reset_state
# Raw UTF-8, as the harness sends it. agent_payload's json.dumps would write a
# backslash-u escape instead, which is the next case's rule, not this one.
check "no record: a non-ASCII payload starts python3, which folds ſ into s" \
  "$(python_started '{"hook_event_name": "PreToolUse", "tool_name": "Agent", "session_id": "session-A", "agent_id": "", "tool_input": {"subagent_type": "workbench-dev-team:holmeſ", "prompt": "Goal: review."}}')" yes
check "...and python3 did read it as holmes, so skipping it would have missed an arm" "$(records)" 1
reset_state
check "no record: holmes spelled with a \\u escape starts python3" \
  "$(python_started '{"hook_event_name": "PreToolUse", "tool_name": "Agent", "session_id": "session-A", "agent_id": "", "tool_input": {"subagent_type": "\u0068olmes", "prompt": "Goal: review."}}')" yes
check "...and it armed" "$(records)" 1
reset_state
mkdir -p "$STATE"
touch "$STATE/.hidden-record"
check "a dot-file record still counts as a record" \
  "$(python_started "$(bash_payload "git status")")" yes
rm -f "$STATE/.hidden-record"
chmod 300 "$STATE"
check "a state directory that cannot be listed starts python3" \
  "$(python_started "$(bash_payload "git status")")" yes
chmod 700 "$STATE"
reset_state

echo
echo "── the verdict binds: deny, never ask ─────────────────────────────────"

reset_state
arm
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
printf '%s' "$DENIAL" | grep -qi 'local-review guard' && ok "the denial names the guard" \
  || bad "the denial does not name the guard"
printf '%s' "$DENIAL" | grep -q "$WORKDIR" && ok "the denial names the tree it protects" \
  || bad "the denial does not name the tree it protects"
# The commit gate's lane 2 offers no approval path on purpose, and neither does
# this. A denial that prints a way out is an invitation to take it.
printf '%s' "$DENIAL" | grep -qi 'approve\|override\|WORKBENCH_LOCAL_REVIEW_DIR' \
  && bad "the denial leaks a way around itself" \
  || ok "the denial offers no way around itself"

echo
echo "── release: the record is held until the review returns ───────────────"

reset_state
arm
disarm
check "a returning Holmes dispatch releases the record" "$(records)" 0

reset_state
arm
# A lens sub-agent returning mid-review is an Agent PostToolUse too. It must not
# unlock the tree the rest of the fan-out is still reading.
run_guard "$(agent_payload PostToolUse "Explore" "read the diff")" >/dev/null
check "a lens returning does not release the review's record" "$(records)" 1
check "and the tree is still guarded" "$(bash_verdict "git restore .")" deny

reset_state
arm
arm
disarm
check "two reviews in flight need two releases" "$(records)" 1
check "and the second is still guarded" "$(bash_verdict "chmod 644 file.txt")" deny
disarm
check "the second release clears it" "$(records)" 0

# A review that dies without returning must not hold the session forever.
reset_state
arm
python3 - "$STATE" <<'PY'
import json, os, sys, time
directory = sys.argv[1]
for name in os.listdir(directory):
    path = os.path.join(directory, name)
    with open(path) as handle:
        record = json.load(handle)
    record["armed_at"] = time.time() - 7201
    with open(path, "w") as handle:
        json.dump(record, handle)
PY
check "a record past its TTL no longer gates" "$(bash_verdict "git restore .")" silent

echo
echo "── fail-safe inputs ───────────────────────────────────────────────────"

reset_state
arm
check "an unparseable payload yields no opinion" "$(verdict_of "$(printf 'not json' | \
  env -u WORKBENCH_DEV_TEAM_PIPELINE WORKBENCH_LOCAL_REVIEW_DIR="$STATE" \
  HOME="$SANDBOX/home" TMPDIR="$SANDBOX" bash "$GUARD")")" silent
check "a payload with no session id yields no opinion" \
  "$(bash_verdict "git restore ." "" agent-1)" silent
check "a non-Bash, non-Agent tool is not this guard's business" \
  "$(verdict_of "$(run_guard "$(python3 -c '
import json
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Read",
                  "session_id": "session-A", "agent_id": "agent-1",
                  "tool_input": {"file_path": "/etc/hosts"}}))')")")" silent

# A brief with no parseable workdir still arms. Only the redirect rule needs a
# path; every other rule is independent of one, and the dangerous verbs are what
# the breach used.
reset_state
run_guard "$(agent_payload PreToolUse "workbench-dev-team:holmes" "Goal: review the tree. Done when: done.")" >/dev/null
check "a brief with no Workdir slot still arms" "$(records)" 1
check "and still refuses a mutation" "$(bash_verdict "chmod 644 file.txt")" deny
check "but has no tree to judge a redirect against" \
  "$(bash_verdict "git diff HEAD > notes.md" session-A agent-1 "$WORKDIR")" silent

echo
echo "── the denial's wording: one line for the human, the rest for the model ──"

# The refusal is split across the hook's two channels. The human line is ONE
# line naming the ACTION they took; everything an agent acts on lives in
# additionalContext, which survives a deny and reaches only the model. Each half
# is asserted on the channel it belongs to, because asserting on the whole
# payload would pass whichever field the text ended up in.
field_of() { # field_of <payload-json> <field>
  printf '%s' "$1" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"][sys.argv[1]])' "$2"
}

reset_state
arm
DENY_OUT="$(run_guard "$(bash_payload "chmod 644 file.txt")")"
DENY_REASON="$(field_of "$DENY_OUT" permissionDecisionReason)"
DENY_CONTEXT="$(field_of "$DENY_OUT" additionalContext)"

check "the human line names the action and nothing else" "$DENY_REASON" \
  '🛑 Blocked: `chmod`. A local review is reading this working tree.'
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
  *"Local-review guard (workbench-dev-team)."*)
    ok "the context names the guard, so the model can report which one fired" ;;
  *) bad "the context does not name the guard" ;;
esac
case "$DENY_CONTEXT" in
  *"changes a file's content, location, existence, or metadata"*)
    ok "the context carries the reason the classifier gave" ;;
  *) bad "the context lost the classifier's reason" ;;
esac
case "$DENY_CONTEXT" in
  *"$WORKDIR"*) ok "the context names the tree under review" ;;
  *) bad "the context does not name the tree under review" ;;
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
  field_of "$(run_guard "$(bash_payload "$1" session-A agent-1 "${2-}")")" permissionDecisionReason
}
check "a git write names the verb" "$(action_of 'git restore .')" \
  '🛑 Blocked: `git restore`. A local review is reading this working tree.'
check "an in-place edit names -i" "$(action_of 'sed -i s/a/b/ f')" \
  '🛑 Blocked: `sed -i`. A local review is reading this working tree.'
check "a rewrite flag says so" "$(action_of 'prettier --write .')" \
  '🛑 Blocked: `prettier` with a rewrite flag. A local review is reading this working tree.'
check "a redirect into the tree says so" "$(action_of 'git diff HEAD > notes.md' "$WORKDIR")" \
  '🛑 Blocked: redirecting output into the tree under review. A local review is reading this working tree.'

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
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
