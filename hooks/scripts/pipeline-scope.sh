#!/bin/bash
# Pipeline scope. PermissionRequest on Bash, for the scheduled pipeline only.
#
# bin/dispatch-agent.sh starts `claude -p --dangerously-skip-permissions` in a
# fresh mktemp -d folder with WORKBENCH_DEV_TEAM_PIPELINE=1. Ask rules still
# prompt there, and -p denies a prompt unless a PermissionRequest hook allows it.
# Mike's rule (2026-09-29): pipeline git and destructive operations are not
# prompted, and stay inside the roots below. One root is all of $TMPDIR, so
# another run's clone is in scope too. The pipeline doc writes each one as a
# plain line. This hook allows only when all of these hold, and is silent
# otherwise, so the run denies the call:
#   1. WORKBENCH_DEV_TEAM_PIPELINE is exactly 1 in this hook's own environment.
#   2. One simple command of plain words and quotes: no separator, $, backtick,
#      backslash, glob, redirect, pipe, ~, ^, or leading =.
#   3. `git -C <dir> <subcommand> …`, `rm …`, or `rmdir …`. Every path is absolute
#      with no . or .. part, so git's own options and the payload cwd never count.
#      The dir, the repository git finds there, and each absolute git argument
#      land in a root after symlinks resolve. Each rm and rmdir operand lands
#      strictly beneath one. rmdir takes no option, since -p climbs through a
#      root, and rm reads options only before its first operand, as BSD rm does.
#   4. The git subcommand is one the pipelines use: add, checkout, commit, diff,
#      log, merge, or push. Any other, an alias included, can run a program.
#   5. A push is `push [-u] <remote> <refspec>`. Its source resolves in the clone
#      to a local branch under refs/heads/, never a tag, since git sends a tag
#      source to refs/tags/. Its destination is not the branch <remote>/HEAD points
#      at, HEAD, @, or a name starting heads/, tags/, or remotes/, which git reads
#      as refs/<dst>. It never forces or deletes. Holmes and Watson never merge,
#      and a push to the default branch is a merge.
#   6. No Bash deny rule in ~/.claude/settings.json matches the command without
#      git's -C <dir>, with or without the rule's trailing " *". The harness
#      checks deny rules on the typed line before any prompt, and a `git push …`
#      rule never matches a `git -C` line. An unreadable settings file ends it.
# The roots come from the hook's environment and payload, which the agent cannot
# set: $TMPDIR, where mktemp -d lands; $HOME/Developer/scratchpad; and the
# session's /private/tmp/claude-*/*/<session_id>/scratchpad. The last two are
# found by name, so a planted symlink could aim them anywhere. Each is kept only
# when its physical path is the path itself, as in workbench-core's scope check.
# That also drops an id with a .. part, and the quoted id never globs.
# This catches mistakes and is not a security boundary: the clone's own git
# hooks run inside an allowed commit, and a relative git argument is judged only
# for a .. part.

set -u
[ "${WORKBENCH_DEV_TEAM_PIPELINE:-}" = 1 ] || exit 0
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -er '.tool_input.command | strings' 2>/dev/null) || exit 0
sid=$(printf '%s' "$payload" | jq -r '.session_id // "" | strings' 2>/dev/null) || exit 0
deny=(); settings="${HOME:-}/.claude/settings.json"
if [ -n "${HOME:-}" ] && [ -e "$settings" ]; then
  rules=$(jq -r '.permissions.deny[]? | strings | select(startswith("Bash(") and endswith(")")) | .[5:-1]' \
    "$settings" 2>/dev/null) || exit 0
  while IFS= read -r r; do [ -n "$r" ] && deny+=("$r"); done <<< "$rules"
fi
phys() { [ -n "$1" ] && (cd -P -- "$1" 2>/dev/null && pwd -P); }  # an existing directory, physically
plain() { [[ $1 == /* && /$1/ != */./* && /$1/ != */../* ]]; }    # absolute, no . or .. part
# Where rm acts: the parent resolves through symlinks and the last name does not,
# because rm removes a link and not its target. A trailing / resolves it all.
land() {
  local up; plain "$1" || return 1
  case $1 in */) phys "$1"; return ;; esac
  up=$(phys "${1%/*}/") || return 1
  printf '%s/%s' "${up%/}" "${1##*/}"
}
roots=()
r=$(phys "${TMPDIR:-}") && roots+=("$r")
named=("${HOME:+$HOME/Developer/scratchpad}" /private/tmp/claude-*/*/"$sid"/scratchpad /tmp/claude-*/*/"$sid"/scratchpad)
for c in "${named[@]}"; do r=$(phys "$c") && [ "$r" = "$c" ] && roots+=("$r"); done
[ ${#roots[@]} -gt 0 ] || exit 0
# inside <path> [strict]: a root or beneath one, and strict needs beneath. A root
# of / matches only / itself, since no path starts with //.
inside() {
  local r; for r in "${roots[@]}"; do
    case $1 in "$r"/?*) return 0 ;; "$r") [ -z "${2:-}" ] && return 0 ;; esac
  done; return 1
}
denied() {
  local r p; for r in ${deny[@]+"${deny[@]}"}; do
    case $r in *:\*) p="${r%:\*}*" ;; *) p=$r ;; esac
    # shellcheck disable=SC2053  # $p is unquoted on purpose: the rule's * is a glob
    [[ $canon == $p || $canon == ${p% \*} ]] && return 0
  done; return 1
}
pushcheck() { # pushcheck <words after push>: one local branch, never to the default
  [[ ${1:-} == -u || ${1:-} == --set-upstream ]] && shift
  [ $# = 2 ] || return 1
  local dst=${2#*:} def src ok
  [[ $2 == [-+:]* || $2 == *: || $2 == *:*:* ]] && return 1
  src=$(git -C "$g" rev-parse --verify --symbolic-full-name "${2%%:*}" 2>/dev/null) && [[ $src == refs/heads/?* ]] || return 1
  def=$(git -C "$g" symbolic-ref --short "refs/remotes/$1/HEAD" 2>/dev/null) || return 1
  shopt -s nocasematch   # only a branch name or refs/heads/<name> passes
  case ${dst#refs/heads/} in HEAD | @ | refs/* | heads/* | tags/* | remotes/* | "${def#"$1"/}") ok=1 ;; *) ok=0 ;; esac
  shopt -u nocasematch; return $ok
}
gitcheck() { # gitcheck <words after git>
  [ $# -ge 3 ] && [ "$1" = -C ] && plain "$2" || return 1
  local sub=$3 a v t n=0; g=$2; shift 3
  # git acts on the repository it finds at or above the dir. Its top level and
  # git dir must be in a root, which puts the dir in one too.
  while IFS= read -r t; do t=$(phys "$t") && inside "$t" || return 1; n=$((n + 1)); done \
    < <(git -C "$g" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null)
  [ $n = 2 ] || return 1
  case $sub in add | checkout | commit | diff | log | merge | push) ;; *) return 1 ;; esac
  canon="git $sub${*:+ $*}"
  for a; do
    v=${a#*=}   # the value of a --key=value word, else the word itself
    [[ /$v/ == */../* ]] && return 1
    if [[ $v == /* ]]; then t=$(land "$v") && inside "$t" || return 1; fi
  done
  [ "$sub" != push ] || pushcheck "$@"
}
word="^(\"[^\"\\\\\$\`]*\"|'[^']*'|[^][[:space:]\"'\\\\\$\`;&|<>(){}*?!#~^])+"
piece="^(\"([^\"]*)\"|'([^']*)'|([^\"']+))"
words=(); rest=$cmd
while [ -n "$rest" ]; do
  if [[ $rest =~ ^[[:blank:]]+ ]]; then rest=${rest:${#BASH_REMATCH[0]}}; continue; fi
  [[ $rest =~ $word ]] || exit 0
  raw=${BASH_REMATCH[0]}; rest=${rest:${#raw}}
  [[ $raw == =* ]] && exit 0
  w=''; while [ -n "$raw" ] && [[ $raw =~ $piece ]]; do
    w+=${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}; raw=${raw:${#BASH_REMATCH[0]}}
  done
  words+=("$w")
done
[ ${#words[@]} -gt 0 ] || exit 0
set -- "${words[@]}"; canon=$*
case $1 in
  git) shift; gitcheck "$@" || exit 0 ;;
  rm | rmdir) prog=$1; shift; opts=1
    for a; do
      if [ $opts = 1 ] && [[ $a == -* ]]; then
        [ "$a" = -- ] && opts=0 || [ "$prog" = rm ] || exit 0; continue
      fi
      opts=0   # BSD rm reads a later -x as the file ./-x
      t=$(land "$a") && inside "$t" strict || exit 0
    done
    [ -n "${t:-}" ] || exit 0 ;;
  *) exit 0 ;;
esac
denied && exit 0
printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}'
