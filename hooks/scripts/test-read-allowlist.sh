#!/bin/bash
# Tests for read_allowlist.py, the read allowlist both guards share.
# Run directly: bash hooks/scripts/test-read-allowlist.sh
#
# A line passes only when every segment is a listed reader using listed options.
# Each "falls back" case below is a line that must get main's verdict: an
# unlisted reader or option, an abbreviation, an unlisted letter in a short
# cluster, a quoted option word, a file redirect, or a shell construct the
# tokenizer does not model. The last check holds the lists themselves: no
# option that runs a program, writes a file, or reads a pager may ever be added.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ALLOW="$HERE/read_allowlist.py"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
show() { printf '%s' "$1" | tr '\n' ' '; }

echo "Reads that pass"
for c in 'git log --grep=commit' 'git log --grep commit' 'git grep push' 'grep -rn "git commit" .' \
         'git status | grep "git push"' 'git log --oneline && git grep -n commit' 'rg "gh pr merge" skills' \
         'git log -S "git commit" --oneline' "grep -E 'git (commit|push)' x.md" 'echo "run git push later"' \
         'git log --format=%s | grep -c push' 'gh search prs "pr merge"' 'echo git push' 'grep -rn git push .' \
         'printf "%s" git commit' 'cat notes | grep git push' '2>/dev/null grep -rn git push .' \
         'git log --grep "fix git push" --oneline' 'cd x && git log --grep push | head' \
         'git diff HEAD 2>&1 | head -50' "rg -n 'x > y' ." "grep -nE '[<>]' f" 'grep -rn "\->" .' \
         'git show HEAD -- commit-guard.sh' 'git -C /repo diff --stat' 'git log -5 --oneline' \
         "printf '%s\n' 'git stash; chmod 644 x'" 'ls -la > /dev/null' 'gh pr view 5 --json title -q .title' \
         'jq -r .name package.json' 'tail -n 20 log.txt' 'wc -l README.md' 'git diff --no-ext-diff' \
         'git log --grep=push -- *' 'git diff --stat -- *.md' 'grep -rn "git push" -- *' \
         'git log --format=%H --grep=push' "git log --pretty='%h %s' --grep push" 'rg -g "*.md" push' \
         'git log --grep=push -- ^x' 'git log --grep=push -- a#b' 'git log --grep=push -- a~b' \
         'cat ~/notes.md' 'git log "^main" --oneline' "grep -n '^#' f"; do
  if printf '%s' "$c" | python3 -I "$ALLOW"; then ok "read: $(show "$c")"; else bad "read refused: $(show "$c")"; fi
done

echo "Lines that fall back to main's verdict"
for c in 'git grep "--open-files-in-pager=git push" foo' 'git grep "-Ogit push" foo' 'rg "--pre=git push" foo' \
         'git grep --open-files=git push foo' 'git grep -nOgit push foo' 'git grep -O less x' 'rg --pre cat x' \
         'rg -z x' 'echo git push > x.sh; csh x.sh' 'echo git push > x.sh' 'grep x f >> out.txt' 'cat < f' \
         'echo git push | sh' 'echo git push | tcsh' 'make -f x.sh' 'git -c alias.ci=commit ci' \
         "git -c core.pager='rm README.md' log" 'git -c diff.external=rm diff' 'git log --output=x' \
         'git log --ext-diff' 'git diff --textconv' 'tail -f log' 'gh pr view 5 --web' 'gh pr checks --watch' \
         'FOO=1 grep x f' 'doas grep x f' 'find . -exec rm {} \;' 'awk "\$3 > 5" f' "awk '{print}' f" \
         'echo "$(git push)"' 'echo `git push`' 'echo \"; git push; echo \"' "\$'git' push" '{git,} push' \
         '=git push' "$(printf "echo hi # it's\ngit push\n# it's")" 'grep x f &' 'grep x f |& head' \
         '(git log)' 'cat <(git push)' 'git log --gre=x' 'grep -n "->" f' 'git push' 'git commit -m x' \
         "$(printf 'git log \\\n--oneline')" 'grep -rnX x .' '"grep" x f' "gr'ep' x f" 'sed -n 1p f' \
         'rg "git push" *' 'git log --grep=push *' 'grep -rn x ?' 'grep -rn x [a-z]*' 'ls *' 'cat *.md' \
         'git -C * log' 'git l* --oneline' 'gr?p x f' 'rg -g *.md push' 'git log -n * --oneline' \
         'ls ~[foo]' 'git log --format=%GG --grep=push' 'git log --pretty=format:%G? --grep push' \
         'git show --format=%GS HEAD' 'git log --format %GK' 'git show --pretty=%GF' 'git log --format=%GP' \
         'git log --format=%GT' "git log --format='%h %G?'" \
         'rg "git push" ^x' 'git log --grep=push ^x' 'git log ^main --oneline' 'grep -rn x a#' \
         'rg push x#' 'grep -rn x a~b' 'rg push *.md~x.md' 'git log --grep=push ~x~y' 'grep ^foo f'; do
  if printf '%s' "$c" | python3 -I "$ALLOW"; then bad "allowlisted, should fall back: $(show "$c")"; else ok "falls back: $(show "$c")"; fi
done

echo "The lists hold no option that runs a program, writes a file, or reads a pager"
banned="$(python3 -I -B - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from read_allowlist import READERS
BANNED_LONG = {"--pre", "--pre-glob", "--search-zip", "--open-files-in-pager", "--ext-diff", "--output",
               "--textconv", "--web", "--watch", "--follow-name", "--exec", "--config", "--paginate",
               "--file", "--files-from", "--output-directory"}
BANNED_SHORT = {"rg": "z", "git grep": "Of", "tail": "fF", "grep": "f", "gh pr view": "w",
                "gh pr list": "w", "gh issue view": "w", "gh issue list": "w"}
from read_allowlist import masked_read
for name, (flags, values, long, long_values, _) in READERS.items():
    for option in (long | long_values) & BANNED_LONG:
        print(f"{name} {option}")
    for letter in (flags | values) & set(BANNED_SHORT.get(name, "")):
        print(f"{name} -{letter}")
    # A listed --format or --pretty runs gpg on any %G placeholder.
    for option in long_values & {"--format", "--pretty"}:
        for code in ("%G?", "%GG", "%GS", "%GK", "%GF", "%GP", "%GT"):
            for line in (f"{name} {option}={code}", f"{name} {option} '{code}'"):
                if masked_read(line) is not None:
                    print(line)
PY
)"
[ -z "$banned" ] && ok "no banned option is listed" || bad "banned options listed: $(show "$banned")"

echo "The lists match the reviewed snapshot"
# Every reader and option on the list is a security decision, because a listed
# line may differ from main's verdict. So the lists are pinned whole: a change
# fails here until testdata/read-allowlist.expected is updated in the same
# change, where a reviewer sees it, with a corpus form in
# testdata/hostile-commands.sh for any option that could run a program.
current="$(python3 -I -B - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from read_allowlist import READERS
for name in sorted(READERS):
    flags, values, long, long_values, digits = READERS[name]
    print(f"{name}: flags={''.join(sorted(flags))} values={''.join(sorted(values))} "
          f"long={' '.join(sorted(long))} long_values={' '.join(sorted(long_values))} digits={digits}")
PY
)"
if [ "$current" = "$(cat "$HERE/testdata/read-allowlist.expected")" ]; then
  ok "the allowlist matches testdata/read-allowlist.expected"
else
  bad "the allowlist changed: $(diff <(printf '%s\n' "$current") "$HERE/testdata/read-allowlist.expected" | tr '\n' ' ')"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
