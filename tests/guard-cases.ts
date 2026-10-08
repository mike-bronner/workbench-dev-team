// The guards' named cases: the false positives reviewers hit with the bash
// guards, which the ports must let through, and the bypass spellings earlier
// review rounds found, which the ports must keep refusing. tests/guards.test.ts
// runs each one through the hooks module, and tests/differential.mjs runs each
// one beside the frozen bash guards in tests/oracle/.
//
// @SANDBOX@ stands for the review sandbox (tests/guard-corpus.ts, REVIEW_TREE):
// @SANDBOX@/repo is the tree under review and the working directory, and
// @SANDBOX@/tmp is a scratch root.

// What a case expects of the commit guard in one lane.
export type CommitLane = 'main' | 'sub-agent' | 'pipeline'

// Lines the commit guard lets through in every lane, though the bash guard
// refused some of them in some lane.
export const COMMIT_PASSES: readonly string[] = [
  // A file-edit script whose comment says "git commit or push" (2026-10-06).
  "python3 - <<'EOF'\n# Apply the edit and hand it back: no git commit or push here.\nimport pathlib\np = pathlib.Path('notes.md')\np.write_text(p.read_text().replace('a', 'b'))\nEOF",
  "python3 - <<'EOF'\n    # then git commit or push, as the brief says\nprint('ok')\nEOF",
  // A heredoc data file whose text names a push or quotes `git push origin`.
  "cat > notes.md <<'EOF'\nAfter review, run git push origin main.\nEOF",
  "cat > plan.md <<'EOF'\nThe pipeline pushes with `git push`, and Mike merges with gh pr merge.\nEOF",
  "cat <<'EOF' > summary.txt\nWatson does not git commit or push.\nEOF",
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
]

// Lines the commit guard lets through in the main lane: a plain commit, push
// or merge is left to the ask rules and core's commit approval gate. Each -m
// message keeps the git-commit format, which the subject check holds a main
// or pipeline commit to (tests/commit-subject.test.ts).
export const COMMIT_MAIN_PASSES: readonly string[] = [
  'git commit -m "fix: 🐛 Fix x."',
  'git push',
  'git push -u origin feat/add-d',
  'git -C /repo push origin main',
  'git -c user.name=x commit -F msg.txt',
  'git commit -m "fix: 🐛 Fix x." && git push',
  // A word such as env in the message, which the bash guard read as a wrapper.
  'git commit -m "feat: ✨ Load env vars." && git push',
  'git commit -m "refactor: ♻️ Use bash -c and eval less." && git push',
  'bash run-tests.sh && git push',
  'cd /repo && git push',
  'gh pr merge 5 --squash',
  'git commit -F - <<\'EOF\'\nfeat: x\n\nMentions git push --force in the body.\nEOF',
  // A value built at run time decides no subcommand.
  'git -C "$(pwd)" push',
  'git commit -m "$(cat msg.txt)"',
  // An attended main loop is not held to the built-name rule.
  '"$PY" script.py',
]

// Spellings that must stay refused, with the lanes each is refused in. A
// sub-agent's commit, push or merge is refused in any spelling. The main lane
// and the pipeline refuse a forced or deleting push, and a commit, push or
// merge the ask rules cannot see.
export const COMMIT_REFUSALS: readonly (readonly [string, readonly CommitLane[]])[] = [
  // Forced and deleting pushes, in every lane.
  ['git push -f', ['main', 'sub-agent', 'pipeline']],
  ['git push --force', ['main', 'sub-agent', 'pipeline']],
  ['git push --force-with-lease origin x', ['main', 'sub-agent', 'pipeline']],
  ['git push --forc', ['main', 'sub-agent', 'pipeline']],
  ['git push --mirror', ['main', 'sub-agent', 'pipeline']],
  ['git push --delete origin x', ['main', 'sub-agent', 'pipeline']],
  ['git push --prune origin', ['main', 'sub-agent', 'pipeline']],
  ['git push -fu origin x', ['main', 'sub-agent', 'pipeline']],
  ['git push -ud origin x', ['main', 'sub-agent', 'pipeline']],
  ['git push origin +main', ['main', 'sub-agent', 'pipeline']],
  ['git push origin :old', ['main', 'sub-agent', 'pipeline']],
  ["git push $'--force'", ['main', 'sub-agent', 'pipeline']],
  ['git push origin --fo\\\nrce', ['main', 'sub-agent', 'pipeline']],
  ['"git" push -f', ['main', 'sub-agent', 'pipeline']],
  ["git -c alias.p='push -f' p", ['main', 'sub-agent', 'pipeline']],
  ['git -c remote.origin.mirror=true push', ['main', 'sub-agent', 'pipeline']],
  ['echo git push -f > x.sh; bash x.sh', ['main', 'sub-agent', 'pipeline']],
  // Merges by an agent or the pipeline.
  ['gh pr merge 5', ['sub-agent', 'pipeline']],
  ['gh -R o/r pr merge 5 --squash', ['sub-agent', 'pipeline']],
  ['gh api -X PUT repos/o/r/pulls/5/merge', ['sub-agent', 'pipeline']],
  ['gh api -X PUT "repos/o/r/pulls/5/merge?merge_method=squash"', ['sub-agent', 'pipeline']],
  ['echo gh pr merge 5 > x.sh; bash x.sh', ['sub-agent', 'pipeline']],
  // A sub-agent's commit or push, in the spellings review rounds found. A
  // commit the main lane and the pipeline pass carries a subject in the
  // git-commit format, which the subject check holds them to.
  ['git commit -m "fix: 🐛 Fix x."', ['sub-agent']],
  ['git push', ['sub-agent']],
  ['g\\it push', ['sub-agent']],
  ['"git" push', ['sub-agent']],
  ["'git' commit -m 'fix: 🐛 Fix x.'", ['sub-agent']],
  ['git \\\npush', ['sub-agent']],
  ['>out git push', ['sub-agent']],
  ['2>/dev/null git commit -m "fix: 🐛 Fix x."', ['sub-agent']],
  ['echo git push > x.sh; ./x.sh', ['sub-agent']],
  ['echo git push > x.sh; make -f x.sh', ['sub-agent']],
  // Hidden from the ask rules, so refused in every lane.
  ['HUSKY=0 git commit -m x', ['main', 'sub-agent', 'pipeline']],
  ['A=1 B=2 git push', ['main', 'sub-agent', 'pipeline']],
  ['env git push', ['main', 'sub-agent', 'pipeline']],
  ['env -u X git commit -m x', ['main', 'sub-agent', 'pipeline']],
  ['sudo -u mike git push', ['main', 'sub-agent', 'pipeline']],
  ['doas git push', ['main', 'sub-agent', 'pipeline']],
  // The harness strips these wrappers before it matches an ask rule, so only
  // a sub-agent is refused.
  ['nice -n 5 git commit -m "fix: 🐛 Fix x."', ['sub-agent']],
  ['timeout 30 git push', ['sub-agent']],
  ['command git push', ['sub-agent']],
  ['caffeinate git push', ['main', 'sub-agent', 'pipeline']],
  ['stdbuf -oL git push', ['sub-agent']],
  ['flock /tmp/lock git push', ['main', 'sub-agent', 'pipeline']],
  ['setsid git push', ['main', 'sub-agent', 'pipeline']],
  ['chronic git push', ['main', 'sub-agent', 'pipeline']],
  ['unbuffer git push', ['main', 'sub-agent', 'pipeline']],
  ['xargs -I{} git push', ['main', 'sub-agent', 'pipeline']],
  ['parallel git push ::: a', ['main', 'sub-agent', 'pipeline']],
  ['find . -exec git push \\;', ['main', 'sub-agent', 'pipeline']],
  ['/usr/bin/git push', ['main', 'sub-agent', 'pipeline']],
  ['/usr/local/bin/GIT push', ['main', 'sub-agent', 'pipeline']],
  ['GIT commit -m x', ['main', 'sub-agent', 'pipeline']],
  ["$'\\x67it' push", ['main', 'sub-agent', 'pipeline']],
  ["git $'\\x70ush'", ['main', 'sub-agent', 'pipeline']],
  ['bash -c "git push"', ['main', 'sub-agent', 'pipeline']],
  ["sh -c 'git commit -m x'", ['main', 'sub-agent', 'pipeline']],
  ['zsh -c "gh pr merge 5"', ['main', 'sub-agent', 'pipeline']],
  ['eval git push', ['main', 'sub-agent', 'pipeline']],
  ["env --split-string='git push'", ['main', 'sub-agent', 'pipeline']],
  ['echo "$(git push)"', ['main', 'sub-agent', 'pipeline']],
  ['x="$(git commit -m y)"', ['main', 'sub-agent', 'pipeline']],
  ['cat <(git push)', ['main', 'sub-agent', 'pipeline']],
  ['echo git push | sh', ['main', 'sub-agent', 'pipeline']],
  ["cat <<'EOF' | bash\ngit push\nEOF", ['main', 'sub-agent', 'pipeline']],
  ['git -c alias.ci=commit ci -m x', ['main', 'sub-agent', 'pipeline']],
  ["git -c alias.x='!git push' x", ['main', 'sub-agent', 'pipeline']],
  ['{git,} push', ['main', 'sub-agent', 'pipeline']],
  ['=git push', ['main', 'sub-agent', 'pipeline']],
  ['git${IFS}push', ['main', 'sub-agent', 'pipeline']],
  ['$GIT push', ['main', 'sub-agent', 'pipeline']],
  ["awk 'BEGIN{system(\"git push\")}'", ['main', 'sub-agent', 'pipeline']],
  ["sed '1e git push' f", ['main', 'sub-agent', 'pipeline']],
  ["python3 -c 'import os; os.system(\"git push\")'", ['main', 'sub-agent', 'pipeline']],
  ['rg --pre "git push" x', ['main', 'sub-agent', 'pipeline']],
  ['git grep -O"git push" x', ['main', 'sub-agent', 'pipeline']],
  ["git -c core.pager='git push' log", ['main', 'sub-agent', 'pipeline']],
  // A subcommand, or an option before it, built at run time (Holmes, Phase 4
  // review): any subcommand at all, so refused in every lane.
  ['git "$(echo commit)" -m x', ['main', 'sub-agent', 'pipeline']],
  ['git `echo commit` -m x', ['main', 'sub-agent', 'pipeline']],
  ['git $(echo c)ommit -m x', ['main', 'sub-agent', 'pipeline']],
  ['git c"$(echo ommit)" -m x', ['main', 'sub-agent', 'pipeline']],
  ['git "$(echo push)"', ['main', 'sub-agent', 'pipeline']],
  ['x=commit; git $x -m y', ['main', 'sub-agent', 'pipeline']],
  ['git -c "$(echo alias.ci=commit)" ci -m x', ['main', 'sub-agent', 'pipeline']],
  ["git -c alias.ci=\"$(echo commit)\" ci -m x", ['main', 'sub-agent', 'pipeline']],
  ['git "$(echo -C)" . commit -m x', ['main', 'sub-agent', 'pipeline']],
  ['gh "$(echo pr)" merge 5', ['main', 'sub-agent', 'pipeline']],
  ['gh pr "$(echo merge)" 5', ['main', 'sub-agent', 'pipeline']],
  ['gh pr `echo merge` 5', ['main', 'sub-agent', 'pipeline']],
  ['gh api -X PUT "$(echo repos/o/r/pulls/5/merge)"', ['main', 'sub-agent', 'pipeline']],
  // A built gh api endpoint that can still form pulls/<n>/merge.
  ['gh api -X PUT "$URL"', ['main', 'sub-agent', 'pipeline']],
  ['gh api -X PUT "repos/o/r/pulls/5/$ACTION"', ['main', 'sub-agent', 'pipeline']],
  ['gh api -X PUT "repos/o/r/pulls/$N"', ['main', 'sub-agent', 'pipeline']],
  ['gh api -X PUT "repos/o/r/pulls/$N/merge"', ['sub-agent', 'pipeline']],
  // With a PUT, or a built method, any built endpoint counts as a merge the
  // ask rules cannot see (Holmes, round 3), in every spelling gh reads.
  ['gh api repos/o/r/pulls$X -X PUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/o/r/$P/5/$A -X PUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$P/5/merge -X PUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$X -X PUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api "$BASE/$A" -X PUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$X -XPUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$X -X=PUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$X -iXPUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$X --method PUT', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$X --method=put', ['main', 'sub-agent', 'pipeline']],
  ['gh api repos/$X -X "$M"', ['main', 'sub-agent', 'pipeline']],
  // A short cluster that ends in X takes the next word, and a built word where
  // a flag could stand may be the method (Holmes, round 4).
  ['gh api -iX PUT repos/$X', ['main', 'sub-agent', 'pipeline']],
  ['gh api $M repos/$X', ['main', 'sub-agent', 'pipeline']],
  // A GraphQL merge goes over POST, whatever the endpoint (Holmes, round 4).
  ["gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"PR_1\"}){clientMutationId}}'", ['main', 'sub-agent', 'pipeline']],
  ["gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"PR_1\"}){clientMutationId}}'", ['main', 'sub-agent', 'pipeline']],
  ["gh api \"$E\" -f query='mutation{mergePullRequest(input:{pullRequestId:\"PR_1\"}){clientMutationId}}'", ['main', 'sub-agent', 'pipeline']],
  ["gh api graphql --input - <<'EOF'\n{\"query\": \"mutation{mergePullRequest(input:{pullRequestId:\\\"PR_1\\\"}){clientMutationId}}\"}\nEOF", ['main', 'sub-agent', 'pipeline']],
  // A built subcommand after an =value or attached option is still refused.
  ['git --git-dir=$D "$(echo commit)" -m x', ['main', 'sub-agent', 'pipeline']],
  ['git -C$D $(echo push)', ['main', 'sub-agent', 'pipeline']],
  ['gh -R"$REPO" "$(echo pr)" merge 5', ['main', 'sub-agent', 'pipeline']],
  // A command name built at run time or not placed, whatever the line names:
  // refused for a sub-agent and an unattended run (Mike, 2026-10-07), and
  // left to the ask rules in an attended main loop.
  ['g$(echo it) com$(echo mit) -m x', ['sub-agent', 'pipeline']],
  ['"$(echo git)" "$(echo commit)" -m x', ['main', 'sub-agent', 'pipeline']],
  ['"$PY" script.py', ['sub-agent', 'pipeline']],
  ['$CMD status', ['sub-agent', 'pipeline']],
  ['$(which python3) script.py', ['sub-agent', 'pipeline']],
  ['sudo -s ls', ['sub-agent', 'pipeline']],
]

// Lines a reviewer may run in the tree under review, with @SANDBOX@/repo as
// the working directory, though the bash guard refused them.
export const REVIEW_PASSES: readonly string[] = [
  // A > or => inside a sed or awk program.
  "awk '$3 > 5' file.txt",
  "awk '{ if ($1 > 0) print $1 }' file.txt",
  "sed 's/=>/->/' file.txt",
  "sed -n '/a > b/p' file.txt",
  // A > and a tee inside a quoted heredoc body.
  "cat <<'EOF'\na > b\ntee x\nEOF",
  "cat <<'EOF' | grep -c x\n2>&1 > out.txt\nEOF",
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
  'git restore .',
  'git checkout -- file.txt',
  'git stash',
  'echo x > README.md',
  'echo x >> README.md',
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
