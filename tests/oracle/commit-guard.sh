#!/bin/bash
# Commit guard. PreToolUse on Bash. Refuses what the permissions.ask rules cannot
# cover, and is silent on everything else.
#
# The approval is a "Commit it" pick in `AskUserQuestion`, once the human says
# their review is done. Claude Code's own prompt is the mechanical backstop.
# /workbench-dev-team:setup installs the ask rules git commit *, git push *,
# git * commit *, git * push *, git * commit, git * push, gh * pr merge *,
# gh * pr merge, and gh api *pulls/*/merge*, beside workbench-core's own
# gh pr merge:*. This guard does not ask and does not approve. It catches honest
# mistakes. It is not a security boundary: a script file, an interpreter, or a
# shell alias gets past it, and past the ask rules too. Review is the real gate.
#
# It refuses, in this order:
#   1. A push that forces or deletes, in every lane: --force, --force-with-lease,
#      --mirror, --delete, --prune (and their prefixes), -f or -d in a short
#      cluster, or a refspec that starts with + or :. Matched as written, and
#      again with quotes, escapes, and line continuations removed.
#   2. A pull request merge from a sub-agent or from the pipeline: gh pr merge in
#      any spelling, or gh api on pulls/<n>/merge. Holmes and Watson never merge.
#   3. A commit or push from a sub-agent. The lane signal is the harness-supplied
#      agent_id. A sub-agent hands its work back uncommitted.
#   4. A commit, push, or merge behind bash -c, sh -c, zsh -c, env, eval, a
#      leading NAME=value assignment, or a program named by its path. The ask
#      rules do not match those forms, so no prompt appears.
#
# THE PIPELINE. bin/dispatch-agent.sh runs `claude -p --agent … ` with
# WORKBENCH_DEV_TEAM_PIPELINE=1 in the environment, and hooks inherit it. --agent
# puts an agent_id in every payload, so rule 3 checks the flag first, or the
# pipeline could never commit. Rule 2 does not: the pipeline never merges.
# hooks/scripts/pipeline-scope.sh answers the pipeline's prompts. A sub-agent of
# an interactive session does not carry the flag unless the session itself does,
# through a shell export or a settings env block, so set it in neither.
#
# READS. The text match is main's: a line that names a commit, push, or merge
# anywhere counts. Rules 2 to 4 skip a line that read_allowlist.py, beside this
# script, accepts: every segment a listed reader, using only listed options,
# with no file redirect. Python starts only for a line the text match caught,
# isolated (-I), so no module in the cwd or on PYTHONPATH loads. If it is
# missing or fails, nothing is skipped. A payload jq cannot read fails closed:
# it is refused when its raw text names a commit, push, or merge.

set -u
payload=$(cat)
pipeline=0; [ "${WORKBENCH_DEV_TEAM_PIPELINE:-}" = 1 ] && pipeline=1
unreadable=0
if ! agent=$(printf '%s' "$payload" | jq -er '.agent_id // ""' 2>/dev/null) \
   || ! cmd=$(printf '%s' "$payload" | jq -er '.tool_input.command // ""' 2>/dev/null); then
  agent=''; cmd="$payload"; unreadable=1
fi

nl=$'\n'
w='[^[:alnum:]_.-]'                 # a character that cannot be part of a word
seg="[^;&|$nl]"                     # a character that does not end a command
git_op="git$w($seg*[^[:alnum:]_-])?(commit|push)(\$|[^[:alnum:]_-])"
merge="gh$w($seg*[^[:alnum:]_-])?(pr[[:space:]]+merge|api$w$seg*pulls/[^[:space:]/]+/merge)(\$|[^[:alnum:]_/-])"
op="($git_op|$merge)"
push_op="git$w($seg*[^[:alnum:]_-])?push$seg*"
force="(^|$w)${push_op}[[:space:]](--(forc|m|de|pru)|-[[:alnum:]]*[fd]|[+:][^[:space:]])"
wrapper="(^|[[:space:];&|(\`{/])((ba|z)?sh[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*-[[:alnum:]]*c|env|eval)[[:space:]](.*$w)?$op|/$op"
# A quoted part may hold ; & | or a newline. Quotes pair from the left only.
value="(\"[^\"]*\"|'[^']*'|\\\\.|[^;&|$nl\"'\\\\])*"
assign="(^|[;&|(\`{$nl])[[:space:]]*[[:alpha:]_][[:alnum:]_]*=${value}[[:space:]]$op"   # HUSKY=0 git …

deny() { # deny <line for the human> <context for the model> — no jq, no quotes
  printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "🛑 Blocked: %s", "additionalContext": "Commit guard (workbench-dev-team). %s"}}\n' "$1" "$2"
  exit 0
}

if [ "$unreadable" = 1 ]; then
  [[ $cmd =~ (^|$w)$op ]] || exit 0
  deny "a commit, push, or merge the guard could not read." \
    "The hook payload did not parse with jq, so the guard refuses any call whose text names a commit, push, or merge. Report this to the human: jq is a prerequisite of workbench-dev-team (see its README)."
fi
f=${cmd//\\$nl/}; f=${f//\$\'/\'}; f=${f//\$\"/\"}; f=${f//[\'\"\\]/}   # quotes, escapes, joins gone
if [[ $cmd =~ $force || $f =~ $force ]]; then
  deny "a push that forces or deletes." \
    "Pushes that force or delete remote refs are refused outright, and no approval changes that. Push without the force or delete, or ask the human to do it."
fi
[[ $cmd =~ (^|$w)$op ]] || exit 0
printf '%s' "$cmd" | python3 -I -B "$(dirname "$0")/read_allowlist.py" 2>/dev/null && exit 0
READS="A command that only reads, such as git log --grep or a grep for these words, is not refused here. If one was, report it as a guard defect, and use the Read tool for the file meanwhile."
if [[ $cmd =~ (^|$w)$merge ]] && { [ -n "$agent" ] || [ "$pipeline" = 1 ]; }; then
  deny "a sub-agent or the pipeline does not merge a pull request." \
    "Merging is the human's own step, after review. Report that the pull request is ready to merge, and stop. Do not look for another route to a merge. $READS"
fi
if [ -n "$agent" ] && [ "$pipeline" != 1 ]; then
  deny "a sub-agent does not commit or push." \
    "Leave the working tree uncommitted. Report the diff and a proposed commit message to the session that dispatched you. Do not ask to commit. Do not look for another route to a commit or push. $READS"
fi
if [[ $cmd =~ $wrapper || $cmd =~ $assign ]]; then
  deny "run the commit, push, or merge as a plain line, so you are asked." \
    "The permission rules that prompt the human match a plain git or gh line, and they miss one behind bash -c, sh -c, env, eval, a leading NAME=value, or a path. Run it as git commit …, git push …, or gh pr merge …, with git -C <dir> for a directory and git -c <key>=<value> for configuration. Drop a variable prefix such as HUSKY=0. If a word such as env only appears in the message, pass the message with git commit -F <file>."
fi
exit 0
