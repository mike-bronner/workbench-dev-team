// @SANDBOX@ stands for the review sandbox (tests/guard-corpus.ts, REVIEW_TREE):
// @SANDBOX@/repo is the tree under review and the working directory, and
// @SANDBOX@/tmp is a scratch root.

export const COMMIT_PASSES: readonly string[] = [
  // A file-edit script whose comment says "git commit or push" (2026-10-06).
  "python3 - <<'EOF'\n# Apply the edit and hand it back: no git commit or push here.\nimport pathlib\np = pathlib.Path('notes.md')\np.write_text(p.read_text().replace('a', 'b'))\nEOF",
  "python3 - <<'EOF'\n    # then git commit or push, as the brief says\nprint('ok')\nEOF",
  // A heredoc data file whose text names a push or quotes `git push origin`.
  "cat > notes.md <<'EOF'\nAfter review, run git push origin main.\nEOF",
  "cat > plan.md <<'EOF'\nThe pipeline pushes with `git push`, and Mike merges with gh pr merge.\nEOF",
  "cat <<'EOF' > summary.txt\nWatson does not git commit or push.\nEOF",
  "cat > tests/zz-probe.test.ts <<'EOF'\nimport { describe, expect, test } from 'claude-code/testing'\nconst VAULT = `${HOME}/Documents/Claude/Memory`\nconst cases = [\n  'gh pr merge -m \"$PR\"',\n  'gh pr merge --merge \"$PR\"',\n  'gh pr merge -m 12 --delete-branch',\n]\nfor (const c of cases) test(c, async ($) => { await $.tool.call({ tool: 'Bash', command: c }) })\nEOF",
  // Reads that name the words.
  'grep -rn "git push" .',
  "grep -E 'git (commit|push)' notes.md",
  'git log --grep commit --oneline',
  'git log -S "git commit" --oneline',
  'rg -n "gh api repos/o/r/pulls/5/merge" .',
  'echo "run git push later"',
  'git status | grep "git push"',
  'git show HEAD -- hooks/mods/commit-guard.ts',
  // gh api lines with a built endpoint that cannot form pulls/<n>/merge,
  // as Holmes and Watson run them (Holmes, round 2).
  'gh api "repos/o/r/pulls/$PR_NUM/comments?per_page=100"',
  'gh api repos/$REPO/issues',
  'gh api graphql -f query="$Q"',
  'for b in $(gh api --paginate "repos/$REPO/branches" --jq \'.[].name\'); do echo "$b"; done',
  'gh api "repos/$REPO/compare/$BASE...$wr_b" --jq \'.commits[].commit.message\'',
  // A global option's value given after = or attached decides no subcommand.
  'git --git-dir=$D log --oneline',
  'git --work-tree="$W" status',
  'git -C$D status',
  'gh --repo=$REPO pr view 5',
  'gh -R"$REPO" pr view 5',
  // A built endpoint with no PUT never merges (Holmes, round 3).
  'gh api repos/$R/pulls/$PR --jq .head.ref',
  'gh api repos/$X',
  'gh api -X POST "repos/$R/issues/$N/comments" -f body=x',
  'gh api --method GET "$URL"',
  'gh api -X GET repos/o/r/pulls$X',
  'gh api -iX GET repos/$X',
  "gh api graphql -f query='query{viewer{login}}'",
  // A plain "$NAME/…" or "${NAME}/…" in double quotes before a literal path
  // names its program by the last path part, as workbench-core's reader has
  // read it since 4e83554 (batch C1).
  '"$HOME/bin/x" a',
  '"${CLAUDE_PLUGIN_ROOT}/bin/dispatch-tick.sh" a',
  '"$HOME"/bin/x a',
  "perl -i -pe 's/\"Bash\\(git push --force:\\*\\)\", //' assets/permissions/rails.json",
  "sed -i '' -e 's/git push --force//' notes.md",
  "sed 's/git commit/git push/g; y/ab/ba/' notes.md > out.md",
  "gh pr create --title x --body 'Each commit is signed, and we push once.'",
  'gh pr comment 5 --body "Run git commit -m x, then git push --force-with-lease."',
]

// Lines a reviewer may run in the tree under review, with @SANDBOX@/repo as
// the working directory, though the bash guard refused them or a reviewer
// reported them refused.
export const REVIEW_PASSES: readonly string[] = [
  // A > or => inside a sed or awk program.
  "awk '$3 > 5' file.txt",
  "awk '{ if ($1 > 0) print $1 }' file.txt",
  "sed 's/=>/->/' file.txt",
  "sed -n '/a > b/p' file.txt",
  // A > and a tee inside a quoted heredoc body.
  "cat <<'EOF'\na > b\ntee x\nEOF",
  "cat <<'EOF' | grep -c x\n2>&1 > out.txt\nEOF",
  'for t in hooks/test-*.sh; do out=$(bash "$t" 2>&1); rc=$?; if [ $rc -ne 0 ]; then echo "FAIL $t"; echo "$out" | tail -5; fi; done',
  // A quoted heredoc body written to a scratch file is data, whatever its text
  // holds: an `-I{}` and an `=> {` refused a Holmes write under the 0.52.0 bash
  // guard (2026-10-09).
  "cat > @SANDBOX@/tmp/scratch/notes.md <<'EOF'\nfind . -name '*.md' | xargs -I{} cp {} out/\nEOF",
  "cat <<'EOF' > @SANDBOX@/tmp/scratch/notes.md\nconst pick = (row) => {\n  return row.id\n}\nEOF",
  // A git read through process substitution, and a quoted grep pattern that
  // names a git verb. A Holmes review reported both refused (2026-10-09).
  // Neither the 0.52.0 bash guard nor this port refuses them. They are pinned
  // so neither starts to.
  'diff <(git show HEAD:README.md) README.md',
  "grep -n 'git status' README.md",
  // The same pattern naming a writing verb, which a misread would refuse.
  "grep -n 'git restore' README.md",
  // A > inside single-quoted bash -c text.
  "bash -c 'grep -c \">\" file.txt'",
  "bash -c 'echo \"a > b\"'",
  // Arithmetic and [[ ]].
  '(( i > 0 )) && echo yes',
  'echo $(( 3 > 2 ))',
  '[[ a > b ]] && echo yes',
  // A read-only grep whose pattern holds `git (add`.
  "grep -E 'git (add|commit)' file.txt",
  "grep -rnE 'git (add|commit|push)|chmod|rm -rf' .",
  // A < inside quoted test strings, read as a redirect to `/` (2026-10-07).
  'grep -n "claude-<uid>/<session>/scratchpad" file.txt',
  "rg -F 'claude-<uid>/' . && rg -F '<session>/' .",
  // cp reads its sources: only the destination is written.
  'cp file.txt @SANDBOX@/tmp/scratch/copy.txt',
  'cp src/a.txt src/b.txt @SANDBOX@/tmp/scratch/',
  'cp -r src @SANDBOX@/tmp/scratch/',
  // In-place edits and new folders on a scratch copy.
  "sed -i '' 's/a/b/' @SANDBOX@/tmp/scratch/target.txt",
  "sed -i 's/a/b/' @SANDBOX@/tmp/scratch/target.txt",
  "sed -i.bak -e 's/a/b/' @SANDBOX@/tmp/scratch/target.txt",
  "perl -pi -e 's/a/b/' @SANDBOX@/tmp/scratch/target.txt",
  "perl -i -pe 's/a/b/' @SANDBOX@/tmp/scratch/target.txt",
  'mkdir @SANDBOX@/tmp/scratch/new',
  'mkdir -p @SANDBOX@/tmp/scratch/new/deeper',
  // git archive into scratch, and the reads a review runs.
  'git archive HEAD -o @SANDBOX@/tmp/scratch/head.tar',
  'git archive --format=tar HEAD > @SANDBOX@/tmp/scratch/head.tar',
  'git diff HEAD > @SANDBOX@/tmp/scratch/review.diff',
  'git status && git diff HEAD && git ls-files --others --exclude-standard',
  'bash run-tests.sh',
  'grep -rn chmod .',
  'command -v tee',
  // Formatters and linters in check mode, with `.` as their path.
  'prettier --check .',
  'black --check .',
  'ruff check .',
  'gofmt -l .',
  'case x in git) echo;; esac',
  // The read forms of git verbs that also write or run a program.
  'git symbolic-ref HEAD',
  'git symbolic-ref --short HEAD',
  'git reflog',
  'git reflog show --oneline',
  'git reflog -n 5',
  'git log --remotes --oneline',
  'git diff --text',
  'git log -Oorder.txt',
  'git grep -n needle',
  'git grep --text needle',
  'FOO=1 git status',
  'git status; git diff --stat',
  "print -r -- 'a > b'; git status",
  'git diff --stat',
]

// Lines a reviewer may never run in the tree under review.
export const REVIEW_REFUSALS: readonly string[] = [
  'chmod 644 README.md',
  'git switch -c feature',
  'git checkout -b feature',
  'git branch feature',
  'git worktree add ../x',
  'git restore .',
  'git checkout -- file.txt',
  'git stash',
  'echo x > README.md',
  'echo x >> README.md',
  'for t in hooks/test-*.sh; do out=$(bash "$t" 2>&1) > README.md; done',
  'for t in hooks/test-*.sh; do out=$(bash "$t" 2>&1 > README.md); done',
  'tee README.md < file.txt',
  'cp @SANDBOX@/tmp/scratch/target.txt file.txt',
  "sed -i '' 's/a/b/' file.txt",
  "perl -pi -e 's/a/b/' file.txt",
  'mkdir newdir',
  'rm -rf src',
  'mv file.txt other.txt',
  // Wrappers and runners written as paths.
  '/usr/bin/sudo chmod 644 README.md',
  '/usr/bin/nice chmod 644 README.md',
  '/usr/local/bin/bundle exec rubocop -a',
  '"/a b/nice" chmod 644 README.md',
  // Value options inside short-flag clusters, and shortened long options.
  'doas -nu root chmod 644 README.md',
  'sudo -nu root chmod 644 README.md',
  'nice --adj 5 chmod 644 README.md',
  'uv --direc /x run chmod 644 README.md',
  'timeout -s9 5 chmod 644 README.md',
  // xargs long options.
  'xargs --max-args=1 rm < list.txt',
  'xargs --arg-file=list.txt rm',
  'git ls-files | xargs --null chmod 644',
  // Wrappers no list named before.
  'setsid chmod 644 README.md',
  'caffeinate chmod 644 README.md',
  'caffeinate -i rm README.md',
  'parallel chmod 644 ::: README.md',
  'chronic rm README.md',
  'unbuffer rm README.md',
  'flock /tmp/lock rm README.md',
  'watch -x rm README.md',
  'watch rm README.md',
  'stdbuf -oL rm README.md',
  'ionice -c3 rm README.md',
  'gtimeout 5 rm README.md',
  'exec -a name chmod 644 README.md',
  'nohup rm README.md',
  'env -S "rm README.md"',
  // env's split-string option, which the shell reader leaves placed (a gap
  // reported to workbench-core), and npm exec's command line.
  "env --spl='chmod 644 README.md'",
  "env --split-string='rm README.md'",
  "npm exec -c 'prettier -w .'",
  "npx -c 'rm README.md'",
  'sudo -s rm README.md',
  'npx -y prettier -w .',
  'ssh-agent rm README.md',
  'some-unknown-runner rm README.md',
  // Programs that write or run.
  "awk '{ print > \"out.txt\" }' file.txt",
  "gawk '{ print | \"sh\" }' file.txt",
  "awk 'BEGIN { system(\"rm README.md\") }'",
  "sed 's/a/b/w out.txt' file.txt",
  "sed -n 'w out.txt' file.txt",
  'find . -delete',
  'find . -exec rm {} \\;',
  "bash -c 'rm README.md'",
  'echo "$(rm README.md)"',
  'cat <<EOF\n$(rm README.md)\nEOF',
  "trap 'rm README.md' EXIT",
  // What the reader cannot read.
  '$CMD README.md',
  '{rm,README.md}',
  '=rm README.md',
  'echo rm README.md | sh',
  'git -c core.pager=cat log',
  "git -c alias.x='!rm README.md' x",
  'cd src && rm file.txt',
  // git forms that write or run a program though the verb mostly reads
  // (Holmes, Phase 4 review).
  'git symbolic-ref HEAD refs/heads/x',
  'git symbolic-ref -d HEAD',
  'git reflog expire --expire=now --all',
  'git reflog delete HEAD@{1}',
  'git reflog drop',
  'git grep -Ocat needle',
  'git grep -O cat needle',
  'git grep -nOcat needle',
  'git grep --open-files-in-pager=cat needle',
  'git grep --open-files=cat needle',
  'git ls-remote --upload-pack=cat .',
  'git ls-remote --upload=cat .',
  'git archive --remote=. --exec=cat HEAD',
  'git archive --remote=. HEAD',
  'git diff --ext-diff',
  'git log -p --textconv',
  'git cat-file --textconv HEAD:file.txt',
  'git cat-file --filters HEAD:file.txt',
  // A GIT_ variable can name a program, as git -c can (Holmes, round 2).
  'GIT_EXTERNAL_DIFF=/x/prog git diff',
  'env GIT_EXTERNAL_DIFF=/x/prog git diff',
  'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=/x/prog git diff',
  'GIT_CONFIG_GLOBAL=/x/cfg git diff',
  'GIT_SSH_COMMAND=/x/prog git ls-remote origin',
  'export GIT_EXTERNAL_DIFF=/x/prog; git diff',
  // Any other statement that can change git's environment (Holmes, round 3).
  'printf -v GIT_EXTERNAL_DIFF %s cat; export GIT_EXTERNAL_DIFF; git diff',
  'for GIT_EXTERNAL_DIFF in cat; do export GIT_EXTERNAL_DIFF; git diff; done',
  ': ${GIT_EXTERNAL_DIFF:=cat}; export GIT_EXTERNAL_DIFF; git diff',
  'export $V; git diff',
  // Each on its own, with no export beside it.
  'printf -v GIT_EXTERNAL_DIFF %s cat; git diff',
  ': ${GIT_EXTERNAL_DIFF:=cat}; git diff',
  'X=1; git diff',
  'env FOO=1 true; git diff',
  'declare -x GIT_PAGER=cat; git log',
  'read GIT_DIR < list.txt; git status',
  'mapfile -t A < list.txt; git status',
  'readarray A < list.txt; git status',
  'getopts ab o; git diff',
  'set -a; git status',
  'set -o allexport; git status',
  'source ./env.sh; git diff',
  '. ./env.sh; git diff',
  'eval "export X=1"; git diff',
  'let x=1; git diff',
  'git diff ${X:=1}',
  // zsh, Mike's shell, sets variables by name in builtins of its own
  // (Holmes, round 4).
  "setopt allexport; print -v GIT_EXTERNAL_DIFF '/x/prog'; git diff",
  "print -v GIT_EXTERNAL_DIFF '/x/prog'; git diff",
  'setopt allexport; git diff',
  'unsetopt nounset; git diff',
  'emulate -L zsh; git diff',
  'integer n=1; git diff',
  'float f=1; git diff',
  'strftime -s GIT_DIR %s 0; git status',
  'zparseopts -D -E v=V; git diff',
  'vared GIT_DIR; git status',
  'zstyle -s :x y GIT_DIR; git status',
  'getln GIT_DIR; git status',
  // git grep runs textconv only when asked.
  'git grep --textconv needle',
  'git grep --textc needle',
]
