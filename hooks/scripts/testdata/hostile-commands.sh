# shellcheck shell=bash disable=SC2016,SC2034
# Hostile command forms for the differential check. test-commit-guard.sh and
# test-local-review-guard.sh each source this file, and run every command here,
# plus every command their own cases run, through main's guard (the frozen copy
# beside this file) and the current one. A command main refused that the current
# guard allows fails the suite, unless the suite names it as a read.
#
# Each entry is one command line. A newline inside an entry is part of the line.
# Two review rounds found these by tracing the masking design that preceded the
# plain-line exemption. Add each new bypass here, never only to one suite.

HOSTILE=(
  # Commit guard: a substitution, an escape, an expansion, or a brace runs git.
  'echo "$(git push)"'
  'x="$(git commit -m y)"'
  'echo \"; git push; echo \"'
  "\$'git' push origin x"
  '$"git" push'
  'git${IFS}push'
  '{git,} push'
  '=git push'
  'git -c alias.ci=commit ci -m x'
  "awk 'BEGIN{system(\"git push\")}'"
  "sed '1e git push' f"
  'echo "$(gh pr merge 5)"'
  'gh api -X PUT "repos/o/r/pulls/5/merge?merge_method=squash"'
  $'# it\'s here\ngit push'
  # A reader's text fed to something that runs it.
  'echo git push | sh'
  'printf "git push" | bash'
  "echo 'git commit -m x' | zsh"
  'echo git push | tclsh'
  'echo git push | xonsh'
  $'echo hi # it\'s\ngit push\n# it\'s'
  'echo git push > x.sh; bash x.sh'
  'echo git push > x.sh; ./x.sh'
  'echo git push | xargs -I{} sh -c {}'
  'cat <(git push)'
  'echo git push > >(sh)'
  'rg --pre "git push" x'
  'git grep -O"git push" x'
  'git log; git push'
  'git log --grep x | git push'
  'grep x f || git push'
  'cd x && git push'
  # Force and delete pushes the shell assembles from parts.
  $'git push origin --fo\\\nrce'
  "git push \$'--force'"
  "git push origin \$'+main'"
  '"git" push -f'
  # Local-review guard: a shell or program that runs quoted text.
  "\"bash\" -c 'true; rm README.md'"
  "\\bash -c 'true; rm README.md'"
  "\$'sh' -c 'true; rm README.md'"
  "gawk '{ print > \"out.txt\" }' f"
  "mawk '{ print > \"out.txt\" }' f"
  "nawk '{ print > \"out.txt\" }' f"
  "awk '{ print | \"sh\" }' f"
  "awk 'BEGIN { system(\"rm README.md\") }'"
  "expect -c 'spawn sh; send \"rm README.md\"'"
  "echo 'x; rm README.md' | tclsh"
  "lua -e 'x; os.remove(\"README.md\")'"
  "pwsh -c 'x; Remove-Item README.md'"
  "Rscript -e 'x; file.remove(\"README.md\")'"
  $'# it\'s a note\nrm README.md'
  $'echo hi # it\'s\nrm README.md\n# it\'s'
  'echo rm README.md | xonsh'
  "echo \\'; rm README.md; echo \\'"
  'echo \"; rm README.md; echo \"'
  "echo \\'; git push; echo \\'"
  "echo x >&2'README.md'"
  'echo "$(rm README.md)"'
  $'cat <<EOF\nit\'s\nEOF\nrm README.md'
  "sed 's/a/b/w out.txt' f"
  "grep -E 'x' f; git checkout -- f"
  'echo x | tee README.md'
  'git stash'
  '=rm README.md'
  # Local-review families: leading redirects, assignments, runners, git -c
  # config that names a program, and brace expansion.
  '2>/dev/null rm README.md'
  '>README.md echo x'
  'FOO=1 rm README.md'
  'A=1 B=2 chmod 644 README.md'
  'doas rm README.md'
  'find . -exec rm {} \;'
  'find . -name x -execdir rm README.md \;'
  '{rm,README.md}'
  'rm {README,x}.md'
  "grep -rn 'x' . > README.md"
)

# Round 4, which both suites also hold to main's exact verdict in every lane:
# a reader writes a file that a runner off any list then runs, a reader option
# that runs a program (quoted, abbreviated, or in a short cluster), and a git -c
# value that names a program.
ROUND4=(
  'echo git push > x.sh; csh x.sh'
  'echo git push > x.sh; tcsh x.sh'
  'echo git push > x.sh; make -f x.sh'
  'git grep "--open-files-in-pager=git push" foo'
  'git grep "-Ogit push" foo'
  'rg "--pre=git push" foo'
  'git grep --open-files=git push foo'
  'git grep -nOgit push foo'
  "git -c alias.x='!rm README.md' x"
  "git -c core.pager='sh -c \"rm README.md\"' log"
  "git -c core.fsmonitor='rm README.md' status"
  "git -c diff.external='rm README.md' diff"
  "git -c gpg.program='rm README.md' log --show-signature"
  "git -c 'alias.x=!rm README.md; true' x"
  'git grep -O"rm README.md" x'
  # A reader option that runs a program, written so it would pass if listed.
  'git grep -O git push x'
  'rg --pre git push foo'
  'git grep --open-files git push foo'
  # Round 5: a wildcard the shell expands after the check, and a %G format
  # placeholder that makes git run gpg.
  'rg "git push" *'
  'git log --grep=push *'
  'grep -rn "git push" ?'
  'git log --format=%GG --grep=push'
  'git log --pretty=format:%G? --grep push'
  'git show --format=%GS push'
  # Round 6: zsh extendedglob wildcards, ^ (all but), # (repeat), and a ~ that
  # does not lead the word (exclude).
  'rg "git push" ^x'
  'git log --grep=push ^x'
  'grep -rn "git push" x#'
  'rg "git push" a~b'
  # A line of readers alone that writes the words to a file.
  'echo git push > x.sh'
  'git log --grep push > out.txt'
  'echo git push >> ~/.bashrc'
)
HOSTILE+=("${ROUND4[@]}")
