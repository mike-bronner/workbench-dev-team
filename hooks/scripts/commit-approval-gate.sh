#!/bin/bash
# Commit approval gate (PreToolUse, matcher: Bash).
#
# Three lanes, decided in this order. Only two of them may write history.
#
#   1. The scheduled Index pipeline — WORKBENCH_DEV_TEAM_PIPELINE=1, exported by
#      bin/dispatch-agent.sh onto the `claude -p` process it spawns. Silent.
#      Nobody is at the keyboard there, and board dispatch + Holmes review + the
#      human's own PR merge is the approval chain instead.
#   2. A sub-agent without that flag — the payload carries a non-empty agent_id.
#      REFUSED, for every command that commits, merges, or pushes, or could hide
#      one, and offered no approval path whatsoever. It hands the work back to the
#      session that dispatched it, as an uncommitted working tree.
#   3. A foreground session — the payload's agent_id is empty. A plain `git
#      commit` or `git push` needs an approval the human answered a prompt for,
#      minutes earlier. Anything else that could hide one is refused, and asked
#      for in the plain form. A push that forces or deletes remote refs is refused
#      outright. A gh call that is neither a read (GH_READS) nor one of the
#      human's everyday actions (GH_OWN) is prompted like a push, as one plain
#      gh line. gh text the gate cannot read is refused. Merge, rebase, pull, revert, cherry-pick, am, and `gh pr merge` stay the
#      human's own, and this gate has no opinion on them.
#
# WHY PUSH IS IN LANE 3. The gate used to wave a foreground push through, and the
# prose said push was "the human's own". Agents read that as "hand the push to
# the human" and stopped short of it, while a push that did run went out with no
# prompt at all. A permissions.ask rule for `git push` cannot fix that: an
# unattended `claude -p` pipeline run cannot answer one, so every pipeline push
# would stall (workbench-core's rails.json records this). This hook can carry the
# pipeline exemption, so the push prompt lives here, on the commit's own route.
# The agent attempts the push, and the gate makes the human answer for it.
#
# THE GATE DOES NOT PARSE BASH. It recognises a small set of plain shapes and
# nothing else. Two rounds of review taught this: splitting on whitespace missed
# subshells, wrappers, and quoting, and a shlex tokenizer then let apostrophes in
# two `#` comments pair up and hide a commit and a push between them, silently,
# in both lanes. Each parser was a new set of shell it got wrong — and the Bash
# tool runs zsh here, not bash, which is a second grammar. So every command
# falls into one of three classes:
#
#   (a) THE PLAIN FORM, prompted. One line, and exactly one of:
#         git [-C <path>] commit <args>
#         git [-C <path>] push <args>
#         git [-C <path>] commit <args> && git [-C <path>] push <args>
#       Every word is plain: ASCII letters, digits, and - _ . / : = + @ , % ^,
#       or a quoted string, and a bare word may not start with `=`, which zsh
#       expands to a path. A single-quoted string may hold anything but `'`. A
#       double-quoted string may not hold $, a backtick, or a backslash, because
#       bash or zsh expands those inside it. The program and the verb are bare.
#       Nothing else is allowed: no expansion, substitution, glob, brace,
#       redirect, pipe, comment, heredoc, assignment, wrapper, second line, or
#       separator other than the one `&&`. So the gate knows exactly which words
#       git receives, and the approval covers exactly those.
#   (b) COULD HIDE ONE, refused with no request id, and asked for in the plain
#       form. Decided by substring tests over the raw text, case-insensitive,
#       with no parsing at all, so no quote, comment, or line break can move a
#       word out of view. The one exception is a gh body in a quoted-delimiter
#       heredoc (below): the tests then run over the gh line alone, because the
#       shell runs nothing from the body. A command is class (b) when it is neither class (a)
#       nor a read-only chain (below), and
#         - it names git or yadm (`git` not followed by a letter, so `github` is
#           not git, and not preceded by a letter, a digit, or a dot, so `.git`
#           the directory and `digit` are not git either — `/usr/bin/git` and
#           `git-push` still are) and either names a verb word — commit, push, send-pack
#           (the plumbing under push), autocorrect (which turns a typo into
#           either), or alias (which renames one) — or
#           holds a character that lets the shell build a word the text does not
#           show: $ ` \ ' " { } * ? [ ], or
#         - it names gh as a word, and a verb as a whole word (GH_VERBS), so
#           `gh pr view --json mergedAt` names none. `gh api` keeps the
#           substring test, because a GraphQL mutation is camelCase. The one
#           exception is text whose every gh call is a `gh api` read (a GET with
#           no field or --input): a read runs no verb, so a path such as
#           `pulls/1/comments` or `pulls/1/merge` is not a verb. Text the gate
#           cannot read, or any other gh call beside it, keeps the test.
#       Lane 2 adds merge, rebase, pull, revert, cherry-pick, and `am` as a word to
#       the verbs, because a sub-agent may do none of them. It also refuses
#       every gh call that is not a read, and gh text it cannot read (see "gh
#       is decided by ALLOWLIST" below). This holds even in a read-only chain.
#   (c) EVERYTHING ELSE passes untouched. That includes a plain one-line git
#       command whose verb is not gated in the lane (`git status`, `git log`),
#       unless it names a verb and is not one of the commands that cannot run
#       another command from their arguments (SAFE_VERBS). `git log --grep
#       push` stays silent; `git rebase --exec 'git push'` does not.
#       It also includes a READ-ONLY CHAIN: the plain-word alphabet above, with
#       segments joined by a standalone `|`, `&&`, `||`, or `;`, and optionally
#       a standalone `2>&1` or `2>/dev/null`, where every segment is either
#       `git [-C <path>] <SAFE_VERBS verb>` or a no-exec reader (NO_EXEC_READERS:
#       grep, head, cat, jq, and the like). No segment can run another program,
#       so no segment can commit or push, whatever words it prints or greps for.
#       sed, awk, xargs, find, and every interpreter are left out on purpose,
#       because each one can run a command from its arguments.
#       A plain `gh` call is a segment too, when it names no gated verb outside
#       the value of a text option (GH_DATA_OPTIONS: --body, --title, --notes,
#       --comment, --jq, --json, --template), or when it is a `gh api` read.
#       gh may write to GitHub, and a few of its
#       commands run git (`pr checkout` and `repo clone` fetch, `pr create` can
#       push), but which ones is decided by gh's own words, never by a body or a
#       title. A PR body that says "commit" is text it posts. Whether the gh
#       call may run at all is decided apart from this, by the gh allowlist
#       below. In a chain a quoted string
#       may span lines, because the shell expands nothing inside it. A line
#       break outside quotes, or a `#`, still ends the chain rule, so an
#       apostrophe in a comment never opens a quote. In a chain a
#       double-quoted string may also hold a backslash, read as the shell
#       reads it, so a grep pattern such as "a\|b" is data. A $ or backtick
#       the backslash does not quote is still an expansion, and still refused.
#
#   A gh body in a heredoc whose delimiter is quoted (`<<'EOF'`), fed to a gh
#   flag that reads the body from stdin (`--body-file -`, `--notes-file -`,
#   `-F -`), is data in the same way: the shell expands nothing in it. The gate
#   then reads the gh line alone, by its own words, and the full text still
#   keys any approval. heredoc_gh_line() below states the exact shape. An
#   unquoted `<<EOF` expands $( ) and backticks in its body, so it is not data.
#
# FAST PATH. Before python3 starts, python-fallback.sh's payload_may_name_git
# checks the raw payload. When it cannot name git, gh, or yadm, no class above
# can refuse it, so the gate exits with no opinion. The test errs only toward
# running the full check: a JSON escape, a `\u`, or any non-ASCII byte sends
# the payload on.
#
# The cost is real and deliberate: some innocent commands are still refused,
# such as `cd repo && git log --format='%h'` or a `$var` beside a git word. The
# refusal says how to run them instead. A false refusal costs one retry; a false
# silence is an unapproved push. The read-only chain exists because the cost was
# measured and was not small: 61 refusals in 2,933 Bash calls in one day, and 6
# of them held a real commit, push, or merge. Every innocent refusal teaches an
# agent to move the command into a script file, which this gate cannot read.
#
# THREAT MODEL, stated plainly. This gate catches ordinary and mistaken
# commands. It does not catch deliberate obfuscation, and no command-text gate
# can. Deliberate obfuscation means building the program name from variables,
# substitutions, or split quoting (`g''h`), or moving the command into a script
# file. A script file bypasses any parser of the command text, so an agent that
# sets out to evade this gate can. The backstop for that agent is the harness
# permission system and human review, not this gate. Where a rule can refuse an
# obfuscated shape at no cost to ordinary use, it does: a gh word stored in a
# variable, a program word the shell builds, a gh call through xargs, and a
# `gh api` word that could split into flags are all refused. Those rules narrow
# the gap. They do not close it.
#
# What stays outside, concretely: a program name spelled in pieces the text
# never shows whole, a script file, or a gitconfig alias or
# help.autocorrect setting reached through a command that names neither verb.
# SHELL ALIASES AND FUNCTIONS ARE THE LIVE CASE. The Bash tool runs zsh with the
# user's shell snapshot, and that snapshot defines oh-my-zsh's git aliases and
# `g=git`: `gp`, `gcmsg`, `gcam`, `gwip`, `gpf!`, `gpod`, `g push`. Their text
# names neither git nor a verb, so each one is silent in both lanes, as it was
# before this gate existed. The gate reads the command text, and the expansion
# happens in the shell after it.
# Every shape Holmes listed in two review rounds is class (a) or (b).
#
# WHY A FORCE OR DELETION PUSH IS REFUSED, NOT APPROVED. workbench-core's rails
# deny `git push --force` by prefix and nothing else. So an approval spent on
# that spelling would buy a second denial, and every other spelling would run.
# Mike does not force-push, and he chose to refuse deletion pushes the same way
# rather than name them in a prompt. So a plain-form push that does either is
# refused with no request id and no record, and nothing a planted record can buy:
#
#   force    --force, --force-with-lease[=…], --mirror, any prefix of those that
#            git accepts (`--force-w`, `--mirr`), `-f` in any short cluster, and
#            a refspec with a leading `+`
#   delete   --delete, --prune, their prefixes, `-d` in any short cluster, and a
#            refspec with an empty source (`:branch`, `:refs/heads/x`)
#   config   remote.<r>.mirror, or a remote.<r>.push refspec that does either,
#            in the repository's own config
#
# WHY LANE 2 EXISTS. Lane 3's approval arrives by a second route:
# bin/approve-commit.sh, installed by /workbench-dev-team:setup at
# $HOME/.claude-workbench/bin/, run as `approve` through bin/approve, and covered
# by permissions.ask rules. A permission RULE is evaluated before the auto-mode
# classifier in every mode, so running
# that command does force a real prompt, and the human answering it is the
# approval. approve-commit.sh refuses to grant anything unless those rules are
# present, so a half-finished setup fails closed.
#
# That reasoning holds in a foreground session and fails in a sub-agent. The
# sub-agent's request meta records requestShape "background" and
# requestNonInteractive true: no human is attached, so the ask resolves with
# nobody answering it. The approval command is a Bash command, and the sub-agent
# holds Bash — so the agent was both the requester and the approver. Measured
# across every transcript on this machine in the gate's first day: 48 sub-agent
# self-approvals, median 3.4 seconds between the denial and the approval, and 17
# unapproved commits on main out of one run alone. Three seconds is not a human
# reading a diff.
#
# So lane 2 is not offered a path. Its denial prints no request id and no
# command, and it writes no pending record for one to spend. The check also runs
# BEFORE any approval record is read, so a record planted by hand buys nothing
# either.
#
# THE LANE SIGNAL IS agent_id, AND NOTHING ELSE. The harness supplies it, not the
# command, so an agent cannot forge its absence. It is non-empty for every
# sub-agent and empty for a main session. `agent_type` must never be substituted:
# it is present for BOTH a scheduled `claude -p --agent watson` and an
# interactively dispatched one, so it cannot tell them apart and would re-open
# the hole this lane closes.
#
# WHAT LANE 2 MATCHES is a rule, not a list: every git verb that writes a commit,
# integrates another history, or publishes one, plus every gh call that is not
# a read (GH_READS). GATED_GIT
# below is that rule's current membership and the only place it is enumerated —
# a verb belongs there when it satisfies the rule, and prose elsewhere states the
# rule rather than copying the list. Matching `git commit` alone is what left
# merge and push open: a list, one verb wide.
#
# The verdict is "deny", and that is the whole point. The gate used to return
# "ask" and never stopped a single commit: a hook's "ask" is classifier-
# approvable, so under permissions.defaultMode "auto" the auto-mode classifier
# approved it and no human was ever prompted. The harness's own safety checks
# pair "ask" with a classifierApprovable:false marker that hooks cannot set. Of
# the three verdicts a hook can return, only "deny" binds.
#
# ONE APPROVAL COVERS ONE RUN OF ONE COMMAND, AND WHAT IT WRITES. The gate keys
# each request by session, agent, working directory, and the exact command text,
# and deletes the record the moment it lets that command through. It also binds
# the approval to what the command would write, read again when it runs:
#
#   commit   HEAD and the staged diff, plus the working-tree diff when the commit
#            takes files from there (-a, --include, --only, -p, --interactive,
#            or a pathspec), read with no external diff or textconv. A
#            change voids the approval: "The staged changes differ from what you
#            approved."
#   push     the repository, HEAD, the branch HEAD names, every local branch and
#            tag tip, and every remote.*, branch.*, push.*, and url.* setting. A
#            change voids the approval: "The repository changed since you
#            approved it."
#
# In `commit && push`, both are read before the command runs. The push then
# sends the pre-command state plus the one commit whose staged content was
# approved, so it sends nothing the human was not shown. When the gate cannot
# read the repository at all, it refuses rather than approve something it cannot
# describe.
#
# The pipeline signal is per-process on purpose. A file-existence check — the old
# live-PID /tmp/watson.lock — answered "is a pipeline running on this host?",
# not "is THIS process the pipeline?", so a scheduled run waived approval for
# every concurrent interactive session on the same machine. That leak let four
# unapproved commits land across two interactive Watsons. An inherited
# environment variable cannot reach a session the dispatcher did not spawn. Do
# not reintroduce a host-wide or identity-shaped substitute.
#
# THE REFUSAL IS SPLIT ACROSS THE TWO CHANNELS A HOOK HAS, and the split changes
# nothing about what is refused. Measured on Claude Code 2.1.274 with a probe
# hook (insights/2026-09-17-hook-message-channels-measured.md in the memory
# vault): `permissionDecisionReason` becomes the tool_result and is the text a
# PERSON reads, and `additionalContext` survives a deny and arrives in its own
# block, which only the model reads.
#
# So the reason is ONE line naming the action that was gated — "🛑 Blocked:
# `git commit`. It needs your approval first." — and the request id, the approval
# command, the `description` the prompt must carry, and the policy all move to
# the context. Every one of those is a thing only an agent acts on, and at 922
# characters they were the wall a person had to read past to learn they had
# tried to commit.
#
# THE SPLIT CANNOT WEAKEN THIS GATE, and the direction matters. If a harness ever
# dropped additionalContext, the agent would lose the request id and the approval
# command, so no approval could be granted and the commit would stay refused.
# The failure mode of losing the model's half is a commit that does not happen.
# Nothing that decides the verdict lives in either message.
#
# NO MARKDOWN EMPHASIS, ANYWHERE. Whether a client renders the reason as Markdown
# is unsettled, and the model receives the raw source either way. So emphasis is
# carried by POSITION — the action leads the line — and by backticks, which read
# as a quoted command whether or not they are rendered.
#
# Exit 0 with no output = no opinion (normal permission flow applies).
# Exit 0 with permissionDecision "deny" = the harness refuses the call.

set -u

# Pipeline carve-out: the dispatcher's flag, and nothing else.
if [ "${WORKBENCH_DEV_TEAM_PIPELINE:-0}" = "1" ]; then
  exit 0
fi

# Capture the payload before the heredoc below claims stdin for the
# python program itself.
GATE_PAYLOAD="$(cat)"
export GATE_PAYLOAD
export GATE_STATE_DIR="${WORKBENCH_COMMIT_APPROVAL_DIR:-${HOME:-}/.claude-workbench/commit-approvals}"

# Without a working python3 the classifier below never runs. A hook that exits
# 127 or 1 is a non-blocking error to the harness, so the call would run with no
# opinion at all: every commit and push unapproved. So that case fails closed
# for any Bash call whose payload names git, gh, or yadm, and stays out of the
# way for everything else.
#
# The helper that does that is a file of its own, so its absence is the same
# failure one step earlier: payload_may_name_git would exit 127 below, and the
# `|| exit 0` would let every commit and push through. So a helper that did not
# load refuses any Bash call whose payload names git, gh, or yadm as a word.
. "$(dirname "$0")/python-fallback.sh" 2>/dev/null
if ! declare -F payload_may_name_git python_fallback >/dev/null; then
  if printf '%s' "$GATE_PAYLOAD" | grep -Eiq '(^|[^a-z0-9])(git|gh|yadm)([^a-z0-9]|$)'; then
    printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "🛑 Blocked: a git command. python-fallback.sh is missing, so the Commit approval gate cannot read it.", "additionalContext": "Commit approval gate (workbench-dev-team). hooks/scripts/python-fallback.sh did not load, so the gate refuses any command that names git, gh, or yadm. Report this to the human: reinstall workbench-dev-team. Do not try another spelling of the command."}}'
  fi
  exit 0
fi

# Fast path. Every refusal below needs the command to name git, gh, or yadm, or
# the approval command, so a payload that names none of them gets no opinion
# without starting python3, which measured about 57 ms on every Bash call.
# payload_may_name_git errs only toward the full check, and so does the approval
# test: the letters of "approve" in any case, with any run of punctuation
# between them, send the payload on. So `appro\ve`, `ap''prove`, and the JSON
# escapes of their backslashes and quotes all reach python3. A JSON `\u` escape
# or a non-ASCII byte already does, through payload_may_name_git.
APPROVE_RE='[Aa][^[:alnum:][:space:]]*[Pp][^[:alnum:][:space:]]*[Pp][^[:alnum:][:space:]]*[Rr][^[:alnum:][:space:]]*[Oo][^[:alnum:][:space:]]*[Vv][^[:alnum:][:space:]]*[Ee]'
payload_may_name_git "$GATE_PAYLOAD" || [[ $GATE_PAYLOAD =~ $APPROVE_RE ]] || exit 0

command -v python3 >/dev/null 2>&1 || python_fallback "Commit approval gate"

python3 - <<'PYEOF'
import hashlib
import json
import os
import re
import shlex
import string
import subprocess
import sys
import time

# How long an answered prompt stays good. Long enough for the agent to retry the
# command it just had denied; far too short to sit around as a standing waiver.
APPROVAL_TTL_SECONDS = 900

# Records older than this are swept on any gate run. They are dead either way —
# every one of them is past the TTL — and the sweep keeps the directory from
# growing by one file per attempt forever.
RECORD_MAX_AGE_SECONDS = 86400

APPROVE_CMD = "approve"

# THE APPROVAL COMMAND ITSELF. Its subject is a label approve-commit.sh checks
# against the waiting record, and the shell never runs it. So the command, spelled
# exactly as one of its permissions.ask rules names it, is given no opinion, and
# no word in the subject can refuse it: gh, git, commit, push, or anything else.
# The spellings are `approve` (bin/approve, which the harness puts on PATH from
# the plugin's bin/), and the long form in both of the ways setup's rules spell
# it. After the spelling comes the request id, bare lowercase hex, then at most
# one plain word or quoted string: the plain-word alphabet, one line, no
# expansion, and nothing run beside it. A subject in single quotes may hold
# anything but `'`, so `'$(git push)'` is text and runs nothing.
#
# Every other invocation the text shows is refused, in both lanes. A spelling no
# rule names — another shell, a path, a wrapper, or a second command beside it —
# runs with no prompt, and an approval nobody was prompted for is the failure
# this gate exists to prevent. A sub-agent is refused the rules' own spellings
# too: its request is non-interactive, so a rule prompts nobody there. A name the
# shell builds from pieces the text never shows whole — a variable set elsewhere,
# a command substitution, a glob — gets past this check. See runs_approval().
_HOME = os.environ.get("HOME", "")
APPROVAL_FORMS = ("approve ", 'bash "$HOME/.claude-workbench/bin/approve-commit.sh" ') + (
    (f"bash {_HOME}/.claude-workbench/bin/approve-commit.sh ",) if _HOME else ())
APPROVAL_NAMES = {"approve", "approve-commit.sh"}
# An approval name as a word in text, the way a shell or a wrapper would receive
# it: `/approve` and `"approve` count, `--approve` and `test-approve-commit.sh`
# do not.
APPROVAL_WORD = re.compile(r"(?i)(?<![a-z0-9_.-])(?:approve|approve-commit\.sh)(?![a-z0-9_.-])")

# The description the approval prompt must carry. The prompt renders three lines
# (the command, the Bash call's `description`, and the ask rule's reason), and
# the description is the one a human reads. Left to each session's judgement it
# came out as "Request human approval for this commit": true, and empty of the
# one fact the answer turns on. A prompt with no decision content in it gets
# cleared unread, and that reflex reaches the other ask rules too, `git reset
# --hard` and `gh pr merge` among them. So the denial dictates the line rather
# than describing an intent, and it names everything the command does: the
# commit's subject, and the branch and remote of the push.
APPROVE_DESC = "Commit: <first line of the commit message>"
APPROVE_DESC_PUSH = "Push: <branch> to <remote>"
APPROVE_DESC_COMMIT_PUSH = "Commit and push: <first line of the commit message>, <branch> to <remote>"
APPROVE_DESC_GH = "GitHub write: <what it writes> to <owner/repo>"

GATE = "Commit approval gate (workbench-dev-team)."


def deny(action: str, clause: str, context: str) -> None:
    """Refuse the call, and say so twice over.

    `action` and `clause` are the ONE line a person reads: what was gated, then
    at most one short clause they can act on. `context` is everything an agent
    needs to recover, and it opens with the gate's name so the model can report
    which gate fired. Never put a request id, an approval command, or a policy
    paragraph in the first two.
    """
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"🛑 Blocked: {action}. {clause}",
            "additionalContext": f"{GATE} {context}",
        }
    }))
    sys.exit(0)


try:
    payload = json.loads(os.environ.get("GATE_PAYLOAD", ""))
except (json.JSONDecodeError, ValueError):
    sys.exit(0)  # unparseable input -> no opinion

if payload.get("tool_name") != "Bash":
    sys.exit(0)

command = payload.get("tool_input", {}).get("command", "") or ""
session_id = str(payload.get("session_id") or "")
agent_id = str(payload.get("agent_id") or "")
cwd = str(payload.get("cwd") or "")

# ---------------------------------------------------------------------------
# Classifying the command. See "THE GATE DOES NOT PARSE BASH" in the header.
# ---------------------------------------------------------------------------

# Every git subcommand that writes a commit (commit, revert, cherry-pick, am),
# integrates another history (merge, rebase, pull), or publishes one (push). The
# rule is the membership test — add a verb here when it does one of those three,
# and note that `git pull` qualifies because it merges. Lane 2 refuses all of
# them; lane 3 prompts for the two it can approve.
GATED_GIT = {"commit", "revert", "cherry-pick", "am", "merge", "rebase", "pull", "push"}
APPROVABLE = {"commit", "push"}

# Commands that cannot run another command from their arguments. Several of them
# write (add, branch, checkout, reset, rm, tag), so "safe" means only that: no
# argument makes them run a commit or a push. A plain one-line call to one of
# these stays silent even when its text names a verb, so `git log --grep push`
# and `git stash push` cost nothing. A verb that can run a command — rebase
# --exec, submodule foreach, bisect run, grep -O, fetch --upload-pack, config —
# is not here.
SAFE_VERBS = {"add", "blame", "branch", "cat-file", "check-ignore", "checkout", "count-objects",
              "describe", "diff", "diff-tree", "for-each-ref", "help", "init", "log", "ls-files",
              "ls-tree", "merge-base", "mv", "name-rev", "reflog", "reset", "restore", "rev-list",
              "rev-parse", "rm", "shortlog", "show", "show-ref", "stash", "status", "switch", "tag",
              "whatchanged"}

# Programs that read and print and cannot run another program from their
# arguments. A read-only chain may use these beside SAFE_VERBS git calls. sort
# and uniq are here with exceptions no_exec() refuses: sort's
# --compress-program runs a program, and sort -o and a second uniq operand write
# a file. sed (e), awk (system), xargs, find (-exec), and every interpreter are
# absent because each one can run a command.
NO_EXEC_READERS = {"cat", "cut", "diff", "echo", "grep", "head", "jq", "ls", "pwd", "sort", "tail",
                   "tr", "uniq", "wc"}

# The standalone words a read-only chain may use between or after its segments.
# Each is recognised only as a whole word, so `a|b` or `x;` stays unreadable.
CHAIN_WORDS = {"&&": "and", "||": "sep", "|": "sep", ";": "sep", "2>&1": "redir", "2>/dev/null": "redir"}

# The substring tests for class (b). Raw text, case-insensitive, no parsing.
# `.git` is a directory, not a program, and `digit` is a word, so neither names
# git. `/usr/bin/git`, `git-push`, and `GIT` still do.
GIT_NAME = re.compile(r"(?i)((?<![a-z0-9.])git(?![a-z])|yadm)")
GH_NAME = re.compile(r"(?i)(?<![a-z0-9])gh(?![a-z0-9])")
FOREGROUND_VERBS = ("commit", "push", "send-pack", "autocorrect", "alias")
SUB_AGENT_VERBS = FOREGROUND_VERBS + ("merge", "rebase", "pull", "revert", "cherry")
# Beside git or yadm a verb is any substring, so `git -c alias.p=push p` and
# `git-push` are caught.
VERBS = {
    "foreground": re.compile("(?i)" + "|".join(FOREGROUND_VERBS)),
    "sub-agent": re.compile("(?i)" + "|".join(SUB_AGENT_VERBS) + r"|(?<![a-z])am(?![a-z])"),
}
# Beside gh a verb is a whole word, so `gh pr merge` and `--merge` are caught
# while `mergedAt` and `--state merged` are not. gh names a subcommand by its
# whole word, so no spelling of `pr merge` hides inside a longer one. `gh api`
# is the exception: it reaches the REST path `.../merges` and the GraphQL
# mutation `mergePullRequest`, so an api call keeps the substring test.
GH_VERBS = {
    lane: re.compile(r"(?i)(?<![a-z])(?:" + "|".join(verbs) + r")(?![a-z])")
    for lane, verbs in (("foreground", FOREGROUND_VERBS), ("sub-agent", SUB_AGENT_VERBS + ("am",)))
}
GH_API = re.compile(r"(?i)(?<![a-z])api(?![a-z])")
# gh options whose value is text gh sends to GitHub or uses to format its own
# output: a body, a title, release notes, a jq filter, a JSON field list, or a Go
# template. None of them names a command gh runs, so their value is not searched
# for a verb. That is what lets `--body 'All commits ...'` and `--json commits`
# through. Long forms only: a short flag can mean different things across gh's
# commands, and skipping the word after the wrong one could skip a real verb.
GH_DATA_OPTIONS = {"--body", "--title", "--notes", "--comment", "--jq", "--json", "--template"}
# A character that lets the shell build a word the text does not show whole.
SHELL_BUILDS = re.compile(r"[$`\\'\"{}*?\[\]]")

# The plain form's alphabet. A bare word is made of these and nothing else.
BARE = set(string.ascii_letters + string.digits + "-_./:=+@,%^")


def double_quoted(inner: str):
    """(the text a program receives, True when the shell builds any of it) for
    the inside of a double-quoted string.

    Inside double quotes a backslash quotes only $ ` " \\ and a line break, and
    stays in front of any other character, in bash and in zsh alike. zsh also
    lets a backslash quote `!`, and whether it stays depends on an option, so
    `\\!` counts as built. An unquoted $ or backtick runs an expansion, so the
    shell builds the word. Everything else is literal text.
    """
    value, built, index = "", False, 0
    while index < len(inner):
        char = inner[index]
        if char == "\\" and index + 1 < len(inner):
            following = inner[index + 1]
            if following in "$`\"\\":
                value += following
            elif following != "\n":
                built = built or following == "!"
                value += char + following
            index += 2
        else:
            built = built or char in "$`"
            value, index = value + char, index + 1
    return value, built


def closing_quote(text: str, start: int) -> int:
    """The index of the `"` that closes the string opening at start, or -1.
    A backslash inside it quotes the character after it, a `"` included."""
    index = start + 1
    while index < len(text) and text[index] != '"':
        index += 2 if text[index] == "\\" else 1
    return index if index < len(text) else -1


def plain_words(text: str, quoted_lines: bool = False, escapes: bool = False):
    """[(word, kind)] for a one-line command of plain words, or None.

    kind is "bare", "quoted", "and" for a standalone `&&`, "sep" for a standalone
    `|`, `||`, or `;`, or "redir" for a standalone `2>&1` or `2>/dev/null`. The
    word is what git receives: quotes removed, nothing expanded, because nothing
    that bash or zsh would expand is allowed to be there. The Bash tool runs zsh
    here, and zsh expands a bare word that starts with `=` (`=ls` becomes
    /bin/ls), so that word is refused too.

    With quoted_lines, a quoted string may span lines. Its text is still one
    word the program receives, and the shell expands nothing in it, so a PR body
    in `--body '...'` is data. A line break OUTSIDE quotes is still refused, as
    is `#`, so an apostrophe in a comment cannot open a quote here: the scan
    reaches the `#` first and gives up. The plain form never passes this, so an
    approved command stays one line.

    With escapes, a double-quoted string may hold a backslash, which is how a
    grep pattern spells `\\|` or `\\s`. The backslash is read as the shell reads
    it (double_quoted), so the word is still exactly what the program receives.
    A $ or backtick the backslash does not quote is still refused, because that
    is an expansion. The plain form and a prompted gh line never pass this.
    """
    line = text.strip(" \t\n")
    words = []
    i = 0
    while i < len(line):
        if line[i] in " \t":
            i += 1
            continue
        end = line.find(" ", i)
        token = line[i:] if end < 0 else line[i:end]
        token = token.split("\t", 1)[0]
        if token in CHAIN_WORDS:
            words.append((token, CHAIN_WORDS[token]))
            i += len(token)
            continue
        word, kind = "", "bare"
        while i < len(line) and line[i] not in " \t":
            char = line[i]
            if char in BARE:
                if char == "=" and not word and kind == "bare":
                    return None  # zsh expands a leading `=ls` to a path
                word += char
                i += 1
            elif char in "'\"":
                end = closing_quote(line, i) if char == '"' and escapes else line.find(char, i + 1)
                if end < 0:
                    return None
                inner = line[i + 1:end]
                if "\n" in inner and not quoted_lines:
                    return None
                if char == '"':
                    if not escapes and any(c in inner for c in "$`\\"):
                        return None
                    inner, built = double_quoted(inner)
                    if built:
                        return None
                word, kind, i = word + inner, "quoted", end + 1
            else:
                return None  # anything else is shell the gate does not read
        words.append((word, kind))
    return words


def plain_form(text: str):
    """The git invocations of a plain one-line command, or None.

    `git [-C <path>] <verb> <args>`, or two of them joined by one `&&` when they
    are exactly a commit and then a push.
    """
    words = plain_words(text)
    # A pipe, a `;`, an `||`, or a redirect is never part of the plain form: the
    # approval covers the words git receives, and nothing else may run beside it.
    if not words or any(kind in ("sep", "redir") for _, kind in words):
        return None
    statements = [[]]
    for word, kind in words:
        if kind == "and":
            statements.append([])
        else:
            statements[-1].append((word, kind))
    if len(statements) > 2:
        return None
    invocations = []
    for statement in statements:
        if not statement or statement[0] != ("git", "bare"):
            return None
        index, directory = 1, ""
        if len(statement) > 2 and statement[1] == ("-C", "bare"):
            index, directory = 3, statement[2][0]
        if index >= len(statement):
            return None
        verb, kind = statement[index]
        if kind != "bare" or not re.fullmatch(r"[a-z][a-z0-9-]*", verb):
            return None
        invocations.append({
            "verb": verb,
            # Passed to git exactly as written, from cwd, so git resolves it the
            # way the real command will. os.path.normpath would fold `lnk/..`
            # without following the symlink, and bind the wrong repository.
            "dir": directory or ".",
            "args": [word for word, _ in statement[index + 1:]],
            "words": [word for word, _ in statement],
        })
    if len(invocations) == 2 and [i["verb"] for i in invocations] != ["commit", "push"]:
        return None
    return invocations


def no_exec(segment: list) -> bool:
    """True when one chain segment can run no program but the one it names."""
    program, kind = segment[0]
    if kind != "bare":
        return False
    if program == "git":
        index = 3 if len(segment) > 2 and segment[1] == ("-C", "bare") else 1
        return index < len(segment) and segment[index][1] == "bare" and segment[index][0] in SAFE_VERBS
    args = [word for word, _ in segment[1:]]
    if program == "sort":
        # --compress-program runs a program, and -o / --output writes a file.
        # Unique long-option prefixes reach them from `--c` and `--o`, and `-o`
        # can sit in a short cluster, so every spelling that could be either is
        # refused.
        return not any(w.startswith(("--c", "--o")) or (w.startswith("-") and not w.startswith("--")
                                                        and "o" in w) for w in args)
    if program == "uniq":
        # A second operand is an output file, and a chain here only reads.
        return len([w for w in args if w == "-" or not w.startswith("-")]) <= 1
    return program in NO_EXEC_READERS


def gh_verbs(text: str, lane: str):
    """The verb test for gh text: whole words, or substrings for `gh api`."""
    return (VERBS if GH_API.search(text) else GH_VERBS)[lane]


def gh_api_read(args: list) -> bool:
    """True when the words after gh are a `gh api` GET with no body."""
    path, index = gh_path(args)
    return path == ("api",) and gh_api_reads(args[index:])


def gh_all_api_reads(text: str) -> bool:
    """True when the text makes at least one gh call and every one is a `gh api`
    read. A GET runs no verb, whatever its path names: `pulls/.../comments`
    holds `pull`, and `pulls/1/merge` holds `merge`. Text the gate cannot read
    (gh_calls is None) and any other gh call keep the substring test."""
    calls = gh_calls(text)
    return bool(calls) and all(gh_api_read(call) for call in calls)


def gh_names_no_verb(segment: list, lane: str) -> bool:
    """True when a gh call names no gated verb outside its GH_DATA_OPTIONS text.

    What gh does is decided by its own words, and a body or a jq filter is text
    it sends or formats. A `gh api` read runs no verb. Whether the gh call may
    run is gh_kind()'s, below.
    """
    # plain_words expanded nothing, so each word is also its own raw text.
    if gh_api_read([(word, word) for word, _ in segment[1:]]):
        return True
    kept, skip = [], False
    for word, _ in segment[1:]:
        if skip:
            skip = False
        elif word.split("=", 1)[0] in GH_DATA_OPTIONS:
            skip = "=" not in word
        else:
            kept.append(word)
    verbs = gh_verbs(" ".join(kept), lane)
    return not any(verbs.search(word) for word in kept)


def read_only_chain(text: str, lane: str) -> bool:
    """True for plain words joined by standalone separators, where every segment
    is a SAFE_VERBS git call, a no-exec reader, or a gh call that names no gated
    verb. A quoted string may span lines here, and a double-quoted one may hold
    a backslash. See class (c) in the header."""
    words = plain_words(text, quoted_lines=True, escapes=True)
    if not words:
        return False
    segments = [[]]
    for word, kind in words:
        if kind in ("and", "sep"):
            segments.append([])
        elif kind != "redir":
            segments[-1].append((word, kind))
    return all(segment and (no_exec(segment) or (segment[0] == ("gh", "bare")
                                                 and gh_names_no_verb(segment, lane)))
               for segment in segments)


def could_hide(text: str, lane: str) -> bool:
    """Class (b): the text could run a gated verb the gate cannot see whole."""
    if GIT_NAME.search(text) and (VERBS[lane].search(text) or SHELL_BUILDS.search(text)):
        return True
    return bool(GH_NAME.search(text) and gh_verbs(text, lane).search(text) and not gh_all_api_reads(text))


def classify(text: str, lane: str, gated: set):
    """("gated", invocations), ("hidden", None), or ("silent", None)."""
    invocations = plain_form(text)
    if invocations:
        if any(i["verb"] in gated for i in invocations):
            return "gated", invocations
        if invocations[0]["verb"] in SAFE_VERBS or not VERBS[lane].search(text):
            return "silent", None
        return "hidden", None
    if read_only_chain(text, lane):
        return "silent", None
    return ("hidden", None) if could_hide(text, lane) else ("silent", None)


# gh is decided by ALLOWLIST, never by a list of write spellings. gh api reaches
# every GitHub endpoint, REST and GraphQL, so a list of the calls that write can
# never be finished: six review rounds each found a spelling the last one missed
# (a flag before the subcommand, a repository by id, a GraphQL ref mutation,
# `pr update-branch`, `release edit`). So each gh call is named by the command
# path gh itself runs, and the path decides:
#
#   read   GH_READS, or `gh api` sending a GET with no field or --input. Silent
#          in both lanes.
#   own    GH_OWN, Mike's everyday actions in his own voice, none of which
#          moves a ref: comments, issue create and edit, pr create naming its
#          --head, pr edit, reviews, labels, pr ready, and pr and issue close
#          and reopen. A pr close that deletes its head branch (--delete-branch,
#          or -d in a short flag cluster) moves a ref, so it is a write, and so
#          is one holding a word the shell builds. Silent in the foreground,
#          refused to a sub-agent.
#   merge  `gh pr merge`. The human's own in the foreground, as before, and
#          refused to a sub-agent.
#   write  everything else, an unknown path included: an alias, an extension,
#          or a flag whose arity decides the path. Prompted in the foreground as
#          one plain gh line, refused to a sub-agent.
#
# Text the gate cannot read, where gh is named, is refused in both lanes with no
# approval: an unbalanced quote, a gh word the shell builds, gh inside a string
# another program runs, a gh word in a variable's value, or a program word the
# shell builds (`$G`, `$(printf gh)`). A gh call through xargs reads as a write,
# since xargs adds words the text never shows.
GH_READS = ({("pr", verb) for verb in ("view", "list", "diff", "status", "checks", "checkout")}
            | {("issue", verb) for verb in ("view", "list", "status")}
            | {("repo", verb) for verb in ("view", "list", "clone")}
            | {("release", verb) for verb in ("view", "list")}
            | {("run", verb) for verb in ("view", "list", "watch")}
            | {("workflow", verb) for verb in ("view", "list")}
            | {("search", verb) for verb in ("issues", "prs", "repos", "code", "commits")}
            | {("label", "list"), ("auth", "status"), ("status",), ("version",)})
GH_OWN = {("pr", "comment"), ("issue", "comment"), ("issue", "create"), ("issue", "edit"),
          ("pr", "edit"), ("pr", "review"), ("label", "create"), ("label", "edit"),
          ("pr", "ready"), ("pr", "close"), ("pr", "reopen"), ("issue", "close"), ("issue", "reopen")}
# gh commands that take no subcommand, so their path is one word.
GH_ONE_WORD = {"api", "status", "version"}
# Flags gh takes before a subcommand whose arity the gate knows. cobra reads the
# word after any other `--flag` or `-x` as that flag's value, and gh reads it as
# a subcommand when the flag is a switch, so both readings are tried below and
# must agree.
GH_VALUE_FLAGS = {"-R", "--repo"}
GH_SWITCHES = {"-h", "--help", "--version"}
# `gh pr create` pushes the current branch unless --head (-H) names one.
GH_HEAD = re.compile(r"--head(=|$)|-H")
# `gh pr create`'s flags, from its --help: the ones that take a value, and the
# switches. pr_create_head() walks them to find what --head really receives.
PR_CREATE_VALUE_LONG = {"--base", "--head", "--body", "--body-file", "--title", "--template", "--label",
                        "--assignee", "--reviewer", "--milestone", "--project", "--repo", "--recover"}
PR_CREATE_VALUE_SHORT = set("BHbFtTlarmpR")
PR_CREATE_SWITCH_LONG = {"--draft", "--fill", "--fill-first", "--fill-verbose", "--web", "--editor",
                         "--dry-run", "--no-maintainer-edit", "--help"}
PR_CREATE_SWITCH_SHORT = set("dfweh")
# An expansion that stays one word inside double quotes: $NAME not followed by
# a subscript, or ${NAME}. See stays_one_word().
PLAIN_EXPANSION = re.compile(r"\$(?:[A-Za-z_][A-Za-z0-9_]*(?![A-Za-z0-9_\[])|\{[A-Za-z_][A-Za-z0-9_]*\})")
# gh api's flags, by what the gate needs to know about them.
GH_API_FIELDS = {"--field", "--raw-field", "--input"}
GH_API_VALUE_LONG = {"--jq", "--template", "--header", "--hostname", "--cache", "--preview"}
GH_API_VALUE_SHORT = set("Hpqt")
GH_PROGRAM = re.compile(r"(?i)(?:.*/)?gh")
# gh as a word in text: bounded by anything but a letter, a digit, `.`, `_`, or
# `-`, so `gh-tools` and `github` are not gh, and `/gh/` and `\gh` are.
GH_WORD = re.compile(r"(?i)(?<![a-z0-9_.-])gh(?![a-z0-9_.-])")
# Programs that run the command in their arguments, and programs whose arguments
# are only data. A gh word anywhere else is text the gate cannot read.
GH_WRAPPERS = {"env", "command", "exec", "nohup", "sudo", "nice", "timeout", "xargs", "noglob",
               "builtin", "time", "caffeinate"}
GH_DATA_PROGRAMS = NO_EXEC_READERS | {"which", "type", "whence", "where", "printf"}
SHELL_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"}
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
SEGMENT_ENDS = set(";&|()\n`")
REDIRECTS = set("<>")


def shell_segments(text: str):
    """[[(value, raw)]] per command segment, or None when a quote is unbalanced.

    A lexer, not a parser: it splits words the way the shell does and never
    guesses what an expansion yields. value is the word the program receives, or
    None when the shell could change it ($, a glob, a brace, a tilde, a
    backslash outside quotes). A backslash inside double quotes is read as the
    shell reads it (double_quoted), so `"a\\|b"` is the literal `a\\|b`. A
    segment ends at an unquoted ; & | ( ) newline or backtick, so a `$( )` or
    backtick substitution is a segment of its own. The word after a
    redirect is a file and is dropped. `#` at the start of a word ends the line.
    Every mistake it can make splits a word the shell would not, which only ever
    shows the gate more to refuse.
    """
    segments, i, n, redirect = [[]], 0, len(text), False
    while i < n:
        char = text[i]
        if char in " \t":
            i += 1
        elif char in SEGMENT_ENDS:
            segments.append([])
            i, redirect = i + 1, False
        elif char in REDIRECTS:
            i, redirect = i + 1, True
        elif char == "#":
            end = text.find("\n", i)
            i = n if end < 0 else end
        else:
            start, value, dynamic = i, "", False
            while i < n and text[i] not in " \t" and text[i] not in SEGMENT_ENDS and text[i] not in REDIRECTS:
                char = text[i]
                if char == "'":
                    end = text.find("'", i + 1)
                    if end < 0:
                        return None
                    value, i = value + text[i + 1:end], end + 1
                elif char == '"':
                    end = closing_quote(text, i)
                    if end < 0:
                        return None
                    inner, built = double_quoted(text[i + 1:end])
                    dynamic = dynamic or built
                    value, i = value + inner, end + 1
                elif char == "\\":
                    dynamic, value, i = True, value + text[i + 1:i + 2], i + 2
                else:
                    dynamic = dynamic or char in "$*?[]{}~!" or (char == "=" and i == start)
                    value, i = value + char, i + 1
            if not redirect:
                segments[-1].append((None if dynamic else value, text[start:i]))
            redirect = False
    return segments


def gh_calls(text: str):
    """[[(value, raw)] of the words after gh] for every gh call the text makes,
    or None when it names gh somewhere the gate cannot read."""
    if not GH_NAME.search(text):
        return []
    segments = shell_segments(text)
    if segments is None:
        return None
    # A gh word the shell builds, or gh inside a string it substitutes, runs a
    # command the gate cannot name.
    if any(value is None and GH_WORD.search(raw) for segment in segments for value, raw in segment):
        return None
    calls = []
    for words in segments:
        index = 0
        while index < len(words) and (ASSIGNMENT.match(words[index][1]) or words[index][0] in SHELL_KEYWORDS):
            # `G=gh; $G api ...`: a gh word stored in a variable is run later
            # by a program word the shell builds.
            if ASSIGNMENT.match(words[index][1]) and GH_WORD.search(words[index][1].split("=", 1)[1]):
                return None
            index += 1
        words = words[index:]
        if not words:
            continue
        program = words[0][0]
        if program is None:
            # A program word the shell builds, such as `$G` or the `$` of
            # `$(printf gh)`, could be gh.
            return None
        if GH_PROGRAM.fullmatch(program):
            calls.append(words[1:])
        elif program in GH_WRAPPERS and not (program == "command" and words[1:2] and words[1][0] in ("-v", "-V")):
            for position, (value, raw) in enumerate(words[1:], start=1):
                if value is not None and GH_PROGRAM.fullmatch(value):
                    call = words[position + 1:]
                    if program == "xargs" or ("xargs", "xargs") in words[1:position]:
                        # xargs adds words from its input that the text never
                        # shows, so the call reads as one the gate cannot name.
                        call = [(None, "xargs")] + call
                    calls.append(call)
                    break
                if GH_WORD.search(raw) or (value is None and not ASSIGNMENT.match(raw)):
                    return None  # a gh word, or a word the shell builds, as the wrapped program
        elif program not in GH_DATA_PROGRAMS and program != "command" \
                and any(GH_WORD.search(raw) for _, raw in words):
            return None  # gh in the arguments of a program that may run them
    return calls


# Programs that run the program named after their own flags. Only that program is
# checked, so `timeout 60 grep approve` stays a grep. zsh's precommand modifiers
# are here too: `-`, `nocorrect`, and, through GH_WRAPPERS, `builtin`, `command`,
# `exec`, and `noglob`. The rest run their argument as a program on macOS or
# Linux. A program missing from this set is still caught when the word it would
# run is the approval name with an id after it (see program_runs_approval), so
# the set widens what is followed, and never decides alone what is refused.
APPROVAL_WRAPPERS = GH_WRAPPERS | {
    "nocorrect", "-", "stdbuf", "gstdbuf", "flock", "ionice", "chrt", "taskset", "taskpolicy",
    "arch", "script", "unbuffer", "chronic", "lockf", "doas", "setsid", "gtimeout", "su", "runuser",
    "unshare", "nsenter", "systemd-run", "firejail", "sandbox-exec", "strace", "ltrace", "dtruss",
    "valgrind", "faketime", "proxychains", "proxychains4", "torsocks", "rlwrap", "entr", "catchsegv"}
# Wrappers that take one operand before the program: a lock file, a CPU mask, a
# priority, a transcript file, or a user. The walk reads them a third way, with
# that operand skipped.
OPERAND_WRAPPERS = {"flock", "lockf", "taskset", "chrt", "script", "su", "runuser"}
# Shells, and `source`, run a script file named after their flags, so that file
# is checked and its arguments are not: `bash run-tests.sh --filter approve` runs
# run-tests.sh. A shell given `-c` runs its arguments as code, and so do `su -c`
# and `script -c`, so every argument is checked there.
APPROVAL_SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "source", "."}
STRING_RUNNERS = APPROVAL_SHELLS - {"source", "."} | {"su", "script"}
# Programs that run all their arguments as one command line: every argument is
# checked.
CODE_RUNNERS = {"eval", "watch", "parallel"}
# A short flag cluster holding `c`, as in `-c`, `-lc`, or `-ec`.
SHELL_STRING_FLAG = re.compile(r"-[A-Za-z]*c[A-Za-z]*")
# Programs that only read their arguments, so an approval name after them is a
# pattern or a file, not a program. Leaving one out costs a false refusal only.
APPROVAL_READERS = GH_DATA_PROGRAMS | {"rg", "ag", "ack", "fd", "man", "file", "stat", "bat", "git"}
# A request id, as the gate prints it.
REQUEST_ID = re.compile(r"[0-9a-f]+")
# A word a wrapper takes that is not a program: a duration or a count, as in
# `timeout 60` or `nice -n 5`.
PLAIN_NUMBER = re.compile(r"[0-9]+(?:\.[0-9]+)?[smhd]?")
# A ${...} expansion, which can yield the name from anywhere inside it.
BRACED = re.compile(r"\$\{[^}]*\}")
# The marks a shell removes or acts on while it builds a word.
SHELL_MARKS = re.compile(r"[\\'\"$]")


def shell_text(value, raw: str) -> str:
    """The word a program could receive: its value, or, for a word the shell
    builds, its raw text with backslashes, quotes, and `$` removed.
    `\\approve`, `appro\\ve`, and `$'approve'` all run bin/approve, and each one
    reads as `approve` here. `=approve` reads as itself, and APPROVAL_WORD still
    finds the name behind the `=`."""
    return value if value is not None else SHELL_MARKS.sub("", raw)


def names_approval(value, raw: str) -> bool:
    """True when one word could be, or could carry, the approval command.

    A word the shell builds is read with its quoting and expansion marks
    removed, the fail-closed rule gh_calls() applies to a gh word. A `${...}`
    expansion in it fails closed on `approve` anywhere inside the braces,
    because ${X:-approve} yields the name from behind a dash.
    """
    if value is None and any("approve" in part.lower() for part in BRACED.findall(raw)):
        return True
    return bool(APPROVAL_WORD.search(shell_text(value, raw)))


def assigns_approval(raw: str) -> bool:
    """True when the word is an assignment whose value names the approval
    command, as in `A=approve; $A`. The same rule gh_calls() applies to a gh
    word in a variable's value."""
    return bool(ASSIGNMENT.match(raw)) and names_approval(None, raw.split("=", 1)[1])


def split_strings(args: list) -> list:
    """The command lines `env -S` (--split-string) is given, as (value, raw).
    env splits that value into words and runs them, so it is read as a command
    line of its own. `-S` may close a short cluster, as in `-iS`, and take its
    value attached or as the next word."""
    found = []
    for index, (value, raw) in enumerate(args):
        following = args[index + 1] if index + 1 < len(args) else ("", "")
        if value is None:
            continue
        if value.startswith("--split-string"):
            found.append((value.split("=", 1)[1], raw) if "=" in value else following)
        elif value.startswith("-") and not value.startswith("--") and "S" in value:
            rest = value[value.index("S") + 1:]
            found.append((rest, raw) if rest else following)
    return found


def program_runs_approval(words: list, loose: bool) -> bool:
    """True when this program word, with its arguments, runs the approval command.

    A wrapper, a shell, or `source` is followed to the program or script it runs.
    Which word that is depends on which flags take a value, so the arguments are
    read twice, as gh_path() reads a gh call: once with every flag taking no
    value, and once with every flag taking the next word. Either reading finding
    the command is enough. A word the shell builds may be a flag, so the walk
    checks it and goes on past it.

    An argument assigning the name is refused whatever the program, which covers
    the declaration builtins: `export A=approve`, `typeset -x A=approve`,
    `declare`, `local`, `readonly`, and `integer`.

    Any other program is not followed, because the gate cannot tell whether it
    runs its argument. It is refused only when the word it would run is the
    approval name followed by an id, lowercase hex or a word the shell builds:
    the command does nothing without one, and a pattern or a file rarely looks
    like one. So `stdbuf -o0 approve <id>` is refused, and `grep approve file`
    is not. A known reader (APPROVAL_READERS) is exempt outright.

    loose is True when the command's text names the approval command anywhere.
    A program word the shell builds is then refused, because it may take the
    name from a variable filled by `read <<< approve`, `printf -v`, or an array.
    """
    value, raw = words[0]
    name = os.path.basename(shell_text(value, raw)).lower()
    if name in APPROVAL_NAMES or (value is None and (loose or names_approval(value, raw))):
        return True
    args = words[1:]
    if name in CODE_RUNNERS or (name in STRING_RUNNERS
                                and any(v is None or SHELL_STRING_FLAG.fullmatch(v) for v, _ in args)):
        return any(names_approval(v, r) for v, r in args)
    if name == "command" and args[:1] and args[0][0] in ("-v", "-V"):
        return False  # a lookup, which runs nothing
    if name == "env":
        for split, split_raw in split_strings(args):
            if (runs_approval(split) if split is not None else names_approval(split, split_raw)):
                return True
    if name in APPROVAL_READERS:
        return False
    follows = name in APPROVAL_WRAPPERS or name in APPROVAL_SHELLS
    for greedy, operands in ((False, 0), (True, 0), (False, 1), (True, 1)):
        if operands and name not in OPERAND_WRAPPERS:
            continue
        index = 0
        while index < len(args):
            arg, arg_raw = args[index]
            if assigns_approval(arg_raw) or (arg is None and (loose or names_approval(arg, arg_raw))):
                return True
            if arg is None or ASSIGNMENT.match(arg_raw) or PLAIN_NUMBER.fullmatch(arg):
                index += 1
            elif len(arg) > 1 and arg[0] in "-+":
                index += 2 if greedy and "=" not in arg else 1
            elif operands:
                operands, index = operands - 1, index + 1
            else:
                if follows and program_runs_approval(args[index:], loose):
                    return True
                if not follows and os.path.basename(arg).lower() in APPROVAL_NAMES:
                    after = args[index + 1] if index + 1 < len(args) else None
                    if after and (after[0] is None or REQUEST_ID.fullmatch(after[0])):
                        return True
                break
    return False


def runs_approval(text: str) -> bool:
    """True when the text runs the approval command, in any spelling the text
    shows.

    A program word whose last path part is an approval name is an invocation, and
    so is a program word the shell builds that holds one, and a variable assigned
    the name. A wrapper, a shell, or `source` is followed to the program it runs
    (program_runs_approval), so `nocorrect approve` and `sh <path>` are
    invocations and `timeout 60 grep approve` is not. Names are compared in
    lowercase, because macOS resolves `APPROVE` to `approve` on its default file
    system. Text the lexer cannot split fails closed on any approval word.
    """
    segments = shell_segments(text)
    if segments is None:
        return bool(APPROVAL_WORD.search(text))
    loose = bool(APPROVAL_WORD.search(SHELL_MARKS.sub("", text)))
    for words in segments:
        index = 0
        while index < len(words) and (ASSIGNMENT.match(words[index][1]) or words[index][0] in SHELL_KEYWORDS):
            if assigns_approval(words[index][1]):
                return True
            index += 1
        if words[index:] and program_runs_approval(words[index:], loose):
            return True
    return False


def approval_form(text: str) -> bool:
    """True when the text is the approval command, spelled as a rule names it."""
    for prefix in APPROVAL_FORMS:
        if text.startswith(prefix):
            words = plain_words(text[len(prefix):])
            return (bool(words) and len(words) <= 2
                    and all(kind in ("bare", "quoted") for _, kind in words)
                    and words[0][1] == "bare" and re.fullmatch(r"[0-9a-f]+", words[0][0]) is not None)
    return False


def gh_path(args: list):
    """(path, index of the word after it) for the gh call, or (None, 0) when a
    word the shell builds or a flag's arity decides the path.

    cobra skips flags to find the subcommand, and takes the word after a flag it
    does not know as that flag's value. So the path is read twice, once with
    every unknown flag taking a value and once with none, and must agree.
    """
    readings = []
    for greedy in (False, True):
        path, index = [], 0
        while index < len(args) and len(path) < (1 if path[:1] and path[0] in GH_ONE_WORD else 2):
            value = args[index][0]
            if value is None:
                return None, 0
            if value == "--":
                break
            if value.startswith("-") and value != "-":
                takes = "=" not in value and value not in GH_SWITCHES and (
                    value in GH_VALUE_FLAGS or (greedy and (value.startswith("--") or len(value) == 2)))
                index += 2 if takes else 1
                continue
            path.append(value)
            index += 1
        readings.append((tuple(path), index))
    if readings[0][0] != readings[1][0]:
        return None, 0
    return readings[0]


def starts_literal(raw: str) -> bool:
    """True when a word's first character is a literal that is not a dash, so
    no expansion can turn the word into a flag."""
    first, second = raw[:1], raw[1:2]
    return (first in BARE and first not in "-=") or (first in "'\"" and bool(second) and second not in "-$`\\'\"")


def stays_one_word(raw: str) -> bool:
    """True when a word the shell builds still reaches the program as exactly one
    word: literal text, single quotes, and double quotes whose only expansions
    are a plain $NAME or ${NAME}. Unquoted, $( ), $NAME, and zsh's ${=X} split on
    whitespace or vanish when empty, and "${=X}", "$@", and zsh's "$a[@]" split
    even inside double quotes. So every other expansion fails."""
    index = 0
    while index < len(raw):
        char = raw[index]
        if char == "'":
            index = raw.find("'", index + 1) + 1
        elif char == '"':
            end = raw.find('"', index + 1)
            inner = raw[index + 1:end]
            if end < 0 or "`" in inner or "\\" in inner or "$" in PLAIN_EXPANSION.sub("", inner):
                return False
            index = end + 1
        elif char in BARE:
            index += 1
        else:
            return False
    return True


def pr_create_head(args: list) -> bool:
    """True when `gh pr create`'s words give --head (-H) a non-empty value.

    cobra gives a value flag the next word whatever it looks like, so in
    `--base --head` the --head is --base's value and names no head. A flag of
    unknown arity, or a word the shell builds, could swallow the --head the same
    way, so either one names none. The last --head wins, as it does in gh.
    """
    head, index = "", 0
    while index < len(args):
        value = args[index][0]
        following = args[index + 1] if index + 1 < len(args) else ("", "")
        if value is None:
            return False
        if value == "--":
            break
        # taken is the (value, raw) word a value flag takes, else None.
        name, taken, step = None, None, 1
        if value.startswith("--"):
            name, eq, attached = value.partition("=")
            if name in PR_CREATE_VALUE_LONG:
                taken, step = ((attached, attached), 1) if eq else (following, 2)
            elif name not in PR_CREATE_SWITCH_LONG:
                return False
        elif value.startswith("-") and len(value) > 1:
            for position, letter in enumerate(value[1:], start=2):
                if letter in PR_CREATE_SWITCH_SHORT:
                    continue
                if letter not in PR_CREATE_VALUE_SHORT:
                    return False
                name = "--head" if letter == "H" else "-" + letter
                rest = value[position:]
                rest = rest[1:] if rest.startswith("=") else rest
                taken, step = ((rest, rest), 1) if value[position:] else (following, 2)
                break
        if taken is not None:
            word, raw = taken
            if word is None and (name == "--head" or not stays_one_word(raw)):
                # A head the shell builds could be empty, and an unquoted $T
                # that is empty vanishes, so its flag takes the word after it.
                return False
            if name == "--head":
                head = word
        index += step
    return bool(head)


def gh_api_reads(args: list) -> bool:
    """True when the words after `gh api` send a GET with no body.

    gh api sends a POST when a field (-f, -F, --field, --raw-field) or --input is
    given with no method, and whatever -X/--method names otherwise. A field makes
    a GET into a query string, and it is still refused: a read needs none.
    """
    # A word the shell builds is harmless only when it stays one word that
    # cannot start with a dash. Any other one could hold `-X POST`.
    if any(value is None and not (starts_literal(raw) and stays_one_word(raw)) for value, raw in args):
        return False
    method, index = "GET", 0
    while index < len(args):
        value, raw = args[index]
        # A method the shell builds is None here, and None is never GET.
        following = args[index + 1][0] if index + 1 < len(args) else ""
        if value is None:
            index += 1
            continue
        if value == "--":
            break
        if value.startswith("--"):
            name, eq, attached = value.partition("=")
            if name in GH_API_FIELDS:
                return False
            if name == "--method":
                method = attached if eq else following
                index += 1 if eq else 2
                continue
            index += 2 if name in GH_API_VALUE_LONG and not eq else 1
            continue
        if value.startswith("-") and len(value) > 1:
            letters, step = value[1:], 1
            for position, letter in enumerate(letters):
                rest = letters[position + 1:]
                if letter == "i":
                    continue
                if letter in "fF":
                    return False
                if letter == "X":
                    method = rest.lstrip("=") if rest else following
                elif letter not in GH_API_VALUE_SHORT:
                    return False  # a flag the gate does not know
                step = 1 if rest else 2
                break
            index += step
            continue
        index += 1
    return method is not None and method.upper() == "GET"


def gh_kind(args: list):
    """("read" | "own" | "merge" | "write", the action named in a refusal)."""
    path, index = gh_path(args)
    if path is None:
        return "write", "a `gh` command whose subcommand the gate cannot read"
    if path == ("api",):
        return ("read" if gh_api_reads(args[index:]) else "write"), "`gh api` writing to GitHub"
    label = "`gh " + " ".join(path) + "`"
    if path in GH_READS or (not path and args and all(v in GH_SWITCHES for v, _ in args)):
        return "read", label
    if path == ("pr", "merge"):
        return "merge", label
    if path in (("pr", "create"), ("pr", "close")):
        kept, skip = [], False
        for value, _ in args:
            if skip:
                skip = False
            elif value is not None and value.split("=", 1)[0] in GH_DATA_OPTIONS:
                skip = "=" not in value
            else:
                kept.append(value)
        if path == ("pr", "create"):
            # Both tests must pass: the spelling test that always stood, and the
            # parse that sees --base swallow --head or an empty --head=.
            names_head = any(w is not None and GH_HEAD.match(w) for w in kept)
            return ("own" if names_head and pr_create_head(args) else "write"), label
        # Deleting the head branch moves a ref, and the own list moves none. A
        # word the shell builds could be -d, so it counts as one.
        deletes = any(w is None or w.split("=", 1)[0] == "--delete-branch"
                      or (w.startswith("-") and not w.startswith("--") and "d" in w) for w in kept)
        return ("write" if deletes else "own"), label
    return ("own" if path in GH_OWN else "write"), label


# A gh body in a heredoc whose delimiter is quoted: `gh ... --body-file - <<'X'`,
# then the body, then a line that is X alone. bash and zsh expand nothing in
# that body and run nothing from it, so it is data, as a `--body '...'` string
# is. Only the gh line is classified, by its own words, exactly as a gh line
# with no heredoc. The shape is narrow on purpose:
#   - the gh line is one line of plain words (plain_words, with no escapes),
#     so the `<<` after it is a real redirect and not text inside a quote;
#   - the delimiter is quoted with ' or ", and made of letters, digits, and _.
#     An unquoted `<<X` expands $( ) and backticks in the body, so it is not
#     this shape, and neither is `<<-X`;
#   - gh reads the body from stdin: --body-file -, --notes-file -, or -F -;
#   - nothing but blank lines (spaces and tabs only) follows the first line
#     that is X alone, which is where the shell ends the body too.
# The full command text, body included, still keys any approval.
QUOTED_HEREDOC = re.compile(r"[ \t]<<(['\"])([A-Za-z0-9_]+)\1[ \t]*$")
GH_STDIN_BODY = {"--body-file", "--notes-file", "-F"}


def heredoc_gh_line(text: str):
    """The gh line of a quoted-delimiter heredoc feeding a gh body, or None."""
    first, newline, rest = text.partition("\n")
    opener = QUOTED_HEREDOC.search(first)
    if not newline or not opener:
        return None
    lines = rest.split("\n")
    delimiter = opener.group(2)
    # Blank means space and tab alone, as the shell counts it. str.strip() also
    # drops \r, \x0b, \x1c-\x1f, and unicode spaces, and a line of those runs as
    # a command.
    if delimiter not in lines or any(line.strip(" \t") for line in lines[lines.index(delimiter) + 1:]):
        return None
    line = first[:opener.start()]
    words = plain_words(line)
    if not words or words[0] != ("gh", "bare") or any(kind not in ("bare", "quoted") for _, kind in words):
        return None
    values = [word for word, _ in words]
    reads_stdin = any(word in ("--body-file=-", "--notes-file=-")
                      or (word in GH_STDIN_BODY and values[index + 1:index + 2] == ["-"])
                      for index, word in enumerate(values))
    return line if reads_stdin else None


# What the gate classifies: the gh line of a heredoc body, else the command.
text = heredoc_gh_line(command) or command
gh_found = gh_calls(text)
gh_kinds = None if gh_found is None else [gh_kind(call) for call in gh_found]

# Lane 2. Before any record is read, so a planted approval cannot be spent, and
# before one is written, so no id exists for the agent to approve.
if agent_id:
    if runs_approval(command):
        deny(
            "the commit approval command",
            "A sub-agent has no approval route.",
            f"This sub-agent ({agent_id[:8]}) has no pipeline flag. Approval belongs "
            "to the foreground session, where a human answers the prompt. Hand the "
            "work back: leave the tree uncommitted, and report the diff and a "
            "proposed commit message to the session that dispatched you."
        )
    verdict, invocations = classify(text, "sub-agent", GATED_GIT)
    gh_reads = gh_kinds is not None and all(kind == "read" for kind, _ in gh_kinds)
    if verdict == "silent" and gh_reads:
        sys.exit(0)
    if verdict == "silent":
        deny(
            "a `gh` command the gate cannot read" if gh_kinds is None
            else next(label for kind, label in gh_kinds if kind != "read"),
            "A sub-agent only reads through gh.",
            f"This sub-agent ({agent_id[:8]}) has no pipeline flag, and a sub-agent "
            "uses gh only to read: pr view, list, diff, status, checks, and "
            "checkout; issue view, list, and status; repo view, list, and clone; "
            "release, run, and workflow view and list; search; and `gh api` with no "
            "-X other than GET and no field or --input. A GitHub action in your own "
            "voice goes through the Index MCP tools, and anything else goes back "
            "to the session that dispatched you, in your report. Write the command "
            "with gh and its subcommand as literal words, or it cannot be read."
        )
    action = (f"`git {invocations[0]['verb']}`" if invocations
              else "a command that names a git commit, merge, or push")
    deny(
        action,
        "A sub-agent does not commit, merge, or push.",
        f"This sub-agent ({agent_id[:8]}) has no pipeline flag, so no human can approve "
        "this, and no approval command exists for you. Hand the work back: leave "
        "the tree uncommitted, and report the diff and a proposed commit message "
        "to the session that dispatched you. If you were sent to work an Index "
        "item, report that to the dispatching session and stop. Never run "
        "bin/dispatch-agent.sh, set WORKBENCH_DEV_TEAM_PIPELINE, or write an "
        "approval record. If the command only reads, run the git or gh "
        "part as a plain line of its own, with -C <path> in place of cd."
    )

# Lane 3. The approval command first: its subject is never run, so no word in it
# may refuse the command, and a spelling no rule prompts for may not run it.
if runs_approval(command):
    if approval_form(command):
        sys.exit(0)
    deny(
        "an approval command that no permission rule prompts for",
        "Run it exactly as the gate printed it.",
        "A permissions.ask rule raises the approval prompt, and it matches only "
        "the spellings setup installed. Run the one the gate prints: "
        f"`{APPROVE_CMD} <request-id> '<commit subject>'`, alone on one line. Any "
        "other spelling, a second command beside it, or a subject the shell "
        "expands would run with no prompt, so it is refused. Put the subject in "
        "single quotes, or leave it out."
    )
if gh_kinds is None:
    deny(
        "this command runs `gh` in a way the gate cannot read",
        "Run the gh call as a plain line of its own.",
        "The gate decides a gh call by the subcommand gh runs, so gh and its "
        "subcommand must be literal words: no quote left open, no gh word the "
        "shell builds, and no gh inside a string another program runs. A "
        "multi-line body goes to --body-file - (or --notes-file -) in a heredoc "
        "with a quoted delimiter, <<'EOF', never in double quotes."
    )
github_write = next((label for kind, label in gh_kinds if kind == "write"), None)
if github_write:
    # Prompted like a push, but only as one plain line that is the gh call and
    # nothing else, so the approval covers exactly the words gh receives.
    words = plain_words(text)
    if not words or words[0] != ("gh", "bare") or any(kind not in ("bare", "quoted") for _, kind in words):
        deny(
            f"this command could hide {github_write}",
            "Run it as a plain line of its own.",
            "A gh call that is neither a read nor one of your everyday actions "
            "(comments, issue create or edit, pr create with --head, pr edit, "
            "reviews, labels, pr ready, pr or issue close and reopen, but not "
            "pr close --delete-branch) is prompted only as one plain line of the gh call "
            "alone, words bare or quoted, with no $, backtick, or backslash in "
            "double quotes, and no cd, pipe, redirect, separator, variable, or "
            "wrapper. Give a multi-line body as a file to --body-file or "
            "--notes-file, or as --body-file - (or --notes-file -) fed by a "
            "heredoc with a quoted delimiter, <<'EOF'."
        )
    verdict, invocations = "gated", []
else:
    verdict, invocations = classify(text, "foreground", APPROVABLE)
if verdict == "silent":
    sys.exit(0)

if verdict == "hidden":
    # Class (b): refused with no id, before any record is read or written. The
    # context is short on purpose: it fires more than any other, and every
    # character reaches the model's context on every refusal.
    deny(
        "this command could hide a `git commit` or `git push`",
        "Run it as a plain line of its own.",
        "Only the plain form is prompted: one line, `git [-C <path>] commit|push "
        "<args>`, or a commit && a push. Words bare or quoted, no $, backtick, or "
        "backslash in double quotes, and no cd, pipe, redirect, comment, heredoc, "
        "variable, wrapper, or other separator. Run git add on its own, and give "
        "a multi-line message as -F <absolute path> to a scratchpad file. A gh "
        "body goes to --body-file - in a heredoc with a quoted delimiter, <<'EOF'. "
        "A read (log, show, diff, status, or gh) runs silently as a plain line of its own."
    )

# Class (a) from here on: the gate knows exactly which words git receives.
commits = [i for i in invocations if i["verb"] == "commit"]
pushes = [i for i in invocations if i["verb"] == "push"]
gated = github_write or " and ".join(f"`git {i['verb']}`" for i in invocations)

# Long push options that refuse the push, matched as git matches them: a word is
# the option when it is a prefix of the option's name. An ambiguous prefix such as
# `--f` makes git itself fail, so refusing it costs nothing.
FORCE_OPTIONS = ("force", "force-with-lease", "mirror")
DELETE_OPTIONS = ("delete", "prune")


def push_refusal(args: list):
    """"force" or "delete" when the push's own words do either, else None."""
    options_done = False
    for word in args:
        if not options_done and word == "--":
            options_done = True
            continue
        if not options_done and word.startswith("--"):
            name = word[2:].split("=", 1)[0].lower()
            if name and any(option.startswith(name) for option in FORCE_OPTIONS):
                return "force"
            if name and any(option.startswith(name) for option in DELETE_OPTIONS):
                return "delete"
            continue
        if not options_done and word.startswith("-") and len(word) > 1:
            for char in word[1:]:
                if char == "o":
                    break  # -o takes the rest of the word as its value
                if char == "f":
                    return "force"
                if char == "d":
                    return "delete"
            continue
        if word.startswith("+"):
            return "force"
        if word.startswith(":") and word != ":":
            return "delete"
    return None


def config_refusal(lines: list):
    """"force" or "delete" when remote config makes an ordinary push do either."""
    for line in lines:
        key, _, value = line.partition(" ")
        key = key.lower()
        if not key.startswith("remote."):
            continue
        if key.endswith(".mirror") and value.strip().lower() not in ("false", "no", "off", "0"):
            return "force"
        if key.endswith(".push"):
            if value.startswith("+"):
                return "force"
            if value.startswith(":") and value != ":":
                return "delete"
    return None


REFUSED = {
    "force": ("--force", "Force pushes are not approved here.",
              "This push rewrites remote history: a force, a force-with-lease, a "
              "mirror, or a `+` refspec, in the command or in remote config. The "
              "gate offers no approval for one. Push without force, or hand the "
              "force push to the human to run themselves."),
    "delete": ("--delete", "Pushes that delete remote refs are not approved here.",
               "This push deletes remote refs: --delete, -d, --prune, or a refspec "
               "with an empty source such as `:branch`, in the command or in remote "
               "config. The gate offers no approval for one. Hand the deletion to "
               "the human to run themselves."),
}

for push in pushes:
    refusal = push_refusal(push["args"])
    if refusal:
        flag, clause, context = REFUSED[refusal]
        deny(f"`git push {flag}`", clause, context)

if not session_id:
    deny(
        gated,
        "No session id, so no approval can bind to it.",
        "This call carries no session id, and an approval is keyed by session, "
        "agent, working directory, and command text. Report this — the gate "
        "cannot be satisfied until the harness sends a session id."
    )

if not cwd:
    deny(
        gated,
        "No working directory, so no approval can bind to it.",
        "This call carries no cwd, and an approval is keyed by session, agent, "
        "working directory, and command text. Report this — the gate cannot be "
        "satisfied until the harness sends one."
    )


def git(directory: str, *args):
    """A finished `git -C <directory> <args>` run from cwd, or None when it could
    not run. `directory` is the -C value exactly as the command writes it."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    try:
        return subprocess.run(["git", "-C", directory, *args], cwd=cwd, env=env,
                              capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def digest(data) -> str:
    if isinstance(data, bytes):
        return hashlib.sha256(data).hexdigest()
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode("utf-8", "surrogatepass")).hexdigest()


# Commit options that take the next word as their value, and the ones that take
# files from the working tree. A word that is neither an option nor an option's
# value is a pathspec. An abbreviated value option is not skipped, so its value
# reads as a pathspec: the stricter binding, never the looser one.
COMMIT_VALUE_LONG = {"--message", "--file", "--reuse-message", "--reedit-message", "--author",
                     "--date", "--cleanup", "--fixup", "--squash", "--template", "--trailer"}
COMMIT_WORKTREE_LONG = ("all", "include", "only", "pathspec-from-file", "patch", "interactive")


def takes_worktree(args: list) -> bool:
    skip = False
    for word in args:
        if skip:
            skip = False
            continue
        if word == "--":
            return True  # anything after it is a pathspec
        if word.startswith("--"):
            name = word.split("=", 1)[0]
            if any(option.startswith(name[2:]) for option in COMMIT_WORKTREE_LONG):
                return True
            skip = name in COMMIT_VALUE_LONG and "=" not in word
            continue
        if word.startswith("-") and len(word) > 1:
            for position, char in enumerate(word[1:], start=1):
                if char in "aiop":
                    return True
                if char == "U":
                    if position == len(word) - 1:
                        return True  # a bare -U is taken as -p
                    break  # -U<n> is a context size
                if char in "mFCct":
                    skip = position == len(word) - 1  # the value is the next word
                    break
                if char in "Su":
                    break  # an optional value, attached
            continue
        return True
    return False


def commit_state(commit: dict):
    """What a commit would record, or None: HEAD, the staged diff, and the
    working-tree diff when the commit takes files from there."""
    directory = commit["dir"]
    where = git(directory, "rev-parse", "--absolute-git-dir")
    if where is None or where.returncode != 0:
        return None
    head = git(directory, "rev-parse", "--verify", "-q", "HEAD")
    # --no-ext-diff and --no-textconv, or the digest hashes whatever program
    # diff.external or a textconv driver prints, which can be a constant.
    staged = git(directory, "diff", "--no-ext-diff", "--no-textconv", "--cached", "--binary")
    if head is None or staged is None or staged.returncode != 0:
        return None
    state = {"git_dir": where.stdout.decode().strip(), "head": head.stdout.decode().strip(),
             "staged": digest(staged.stdout), "worktree": ""}
    if takes_worktree(commit["args"]):
        tree = git(directory, "diff", "--no-ext-diff", "--no-textconv", "--binary")
        if tree is None or tree.returncode != 0:
            return None
        state["worktree"] = digest(tree.stdout)
    return state


def push_state(push: dict):
    """What a push would send, or None: the repository, HEAD, the branch HEAD
    names, every local branch and tag tip, and every setting that picks the
    remote, the refspec, or the URL."""
    directory = push["dir"]
    head = git(directory, "rev-parse", "--absolute-git-dir", "HEAD")
    if head is None or head.returncode != 0:
        return None
    git_dir, _, sha = head.stdout.decode().strip().partition("\n")
    branch = git(directory, "symbolic-ref", "-q", "HEAD")
    refs = git(directory, "for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags")
    config = git(directory, "config", "--get-regexp", r"^(remote|branch|push|url)\.")
    if None in (branch, refs, config) or refs.returncode != 0 \
            or branch.returncode not in (0, 1) or config.returncode not in (0, 1):
        return None
    return {
        "git_dir": git_dir,
        "head": sha.strip(),
        "branch": branch.stdout.decode().strip() if branch.returncode == 0 else "",
        "refs": digest(refs.stdout),
        "config": config.stdout.decode(errors="replace").strip().splitlines(),
    }


def gh_state(words: list):
    """What a GitHub write reads when it runs, or None when git cannot run.

    The command text does not say what gh sends when a word names a file:
    `--input <path>`, `-F key=@<path>`, `--notes-file <path>`, or a release
    asset `<path>#label`. So every spelling of every word that names a file is
    bound by that file's content, and a file that appears later changes the
    binding too. gh resolves `{owner}/{repo}` and a release's repository from
    the git remote, so the remote config is bound as well.
    """
    files = {}
    for word, _ in words:
        value = word.split("=", 1)[-1]
        for candidate in {word, value, value.lstrip("@"), value.lstrip("@").split("#", 1)[0]}:
            path = os.path.join(cwd, candidate) if candidate else ""
            if path and os.path.isfile(path):
                try:
                    with open(path, "rb") as handle:
                        files[candidate] = digest(handle.read())
                except OSError:
                    files[candidate] = "unreadable"
    remote = git(".", "config", "--get-regexp", r"^remote\.")
    if remote is None:
        return None
    return {"files": files,
            "remote": remote.stdout.decode(errors="replace").strip() if remote.returncode == 0 else ""}


gh_bound = gh_state(plain_words(text)) if github_write else None
if github_write and gh_bound is None:
    deny(
        gated,
        "The gate cannot read the repository this write runs in.",
        "The gate binds a GitHub-write approval to the files the command names "
        "and to the git remote gh reads its repository from. git could not run "
        "here, so nothing can be bound."
    )

staged = commit_state(commits[0]) if commits else None
if commits and staged is None:
    deny(
        gated,
        "The gate cannot read the repository this commit runs in.",
        "The gate binds a commit approval to HEAD and the staged changes, so the "
        "commit that runs is the one the human was shown. It could not read them "
        "here: no repository at the working directory or the -C path, or a git "
        "that failed. Run the commit from the repository, or with a literal -C path."
    )

state = push_state(pushes[0]) if pushes else None
if pushes:
    if state is None:
        deny(
            gated,
            "The gate cannot read the repository this push runs in.",
            "The gate binds a push approval to the repository it runs in — HEAD, "
            "its branch, every local branch and tag, and the remote, branch, push, "
            "and url config — so the push that runs is the push the human was "
            "shown. It could not read that here: no repository at the working "
            "directory or the -C path, or a git that failed."
        )
    refusal = config_refusal(state["config"])
    if refusal:
        flag, clause, context = REFUSED[refusal]
        deny(f"`git push {flag}`", clause,
             context + " Here it comes from the repository's own remote config, so "
             "a plain push would do it too.")

# The key answers "is THIS command, by THIS agent, in THIS session and THIS
# directory approved?" and no broader question. Editing the command voids the
# approval, and so does running it anywhere else. The agent component is moot in
# practice now — lane 2 turned back every caller with an agent id — and it stays
# in the key anyway, so a record can never be reused across identities.
request_id = hashlib.sha256(
    "\x1f".join([session_id, agent_id, cwd, command]).encode("utf-8", "surrogatepass")
).hexdigest()[:16]

state_dir = os.environ.get("GATE_STATE_DIR", "")
if not state_dir or state_dir.startswith("/.claude-workbench"):
    # An empty HOME collapses the default to "/.claude-workbench/...", a path
    # every user on the host shares. Host-wide approval state is the exact shape
    # of the watson.lock leak, so this case is refused rather than relocated.
    deny(
        gated,
        "HOME is unset, so no approval can be recorded.",
        "No approval directory is addressable. The default would collapse to "
        "\"/.claude-workbench/...\", a path every user on the host shares, and "
        "host-wide approval state is the leak shape this gate was rebuilt to "
        "close. So the case is refused rather than relocated."
    )

record_path = os.path.join(state_dir, request_id)


def read_record(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
        return record if isinstance(record, dict) else {}
    except (OSError, ValueError):
        return {}


def sweep(directory: str) -> None:
    cutoff = time.time() - RECORD_MAX_AGE_SECONDS
    try:
        entries = os.listdir(directory)
    except OSError:
        return
    for name in entries:
        stale = os.path.join(directory, name)
        try:
            if os.path.isfile(stale) and os.path.getmtime(stale) < cutoff:
                os.unlink(stale)
        except OSError:
            continue


staged_print = digest(staged) if staged else ""
state_print = digest(state) if state else digest(gh_bound) if gh_bound else ""
record = read_record(record_path)
why = "new"

if record.get("status") == "approved":
    # One approval, one run. The record dies here whatever happens next: if the
    # commit or push fails downstream, the next attempt asks the human again.
    #
    # A record that will not delete is refused rather than honoured. Letting the
    # call through on an undeletable record hands the session a standing waiver
    # for that command — one approval covering every run that follows,
    # which is the failure this whole gate exists to prevent.
    try:
        os.unlink(record_path)
    except OSError as error:
        deny(
            gated,
            "The approval record cannot be deleted.",
            f"The record at {record_path} cannot be deleted ({error}), so it "
            "cannot be spent. An approval that survives its command approves "
            "every commit or push after it, so the call is refused instead."
        )
    try:
        age = time.time() - float(record.get("approved_at", 0))
    except (TypeError, ValueError):
        age = APPROVAL_TTL_SECONDS + 1
    if age > APPROVAL_TTL_SECONDS:
        why = "expired"
    elif record.get("staged", "") != staged_print:
        why = "staged"
    elif record.get("state", "") != state_print:
        why = "changed"
    else:
        sys.exit(0)  # approved, fresh, unchanged, and now spent -> normal flow

# No usable approval. Record the request so approve-commit.sh can find it, then
# refuse. The record names the command, which is what the human ends up
# approving. The parsed commit and push are display for approve-commit.sh: the
# verdict never reads them back, it re-reads the command.
push = pushes[0] if pushes else None
try:
    os.makedirs(state_dir, exist_ok=True)
    sweep(state_dir)
    with open(record_path, "w", encoding="utf-8") as handle:
        json.dump({
            "status": "pending",
            "session_id": session_id,
            "agent_id": agent_id,
            "cwd": cwd,
            "command": command,
            "requested_at": time.time(),
            "verbs": ["gh"] if github_write else [i["verb"] for i in invocations],
            "commit_words": commits[0]["words"] if commits else None,
            "push": shlex.join(push["words"]) if push else None,
            # The gh line alone, for approve-commit.sh's receipt. For a heredoc
            # body that is the line before the body. "command" keys the approval.
            "gh": text if github_write else None,
            "branch": state["branch"] if state else None,
            "head": state["head"] if state else None,
            "staged": staged_print,
            "state": state_print,
        }, handle)
except OSError as error:
    deny(
        gated,
        "The approval record cannot be written.",
        f"Cannot write the approval record under {state_dir} ({error}). The "
        "call is refused until that path is writable."
    )

# The one clause a PERSON acts on is the only thing that differs between these:
# a first request, an approval that ran out, or one the repository outgrew. The
# request id and the command belong to the agent, so the context carries them.
clause = {
    "new": "It needs your approval first.",
    "expired": f"Your approval expired after {APPROVAL_TTL_SECONDS // 60} minutes.",
    "staged": "The staged changes differ from what you approved.",
    "changed": ("A file or the remote it reads changed since you approved it." if github_write
                else "The repository changed since you approved it."),
}[why]

# What the human is shown, what the approval command carries, and what the
# prompt's description says all follow from what the call does. A commit is
# named by its subject. A push is named by its branch and remote, and its
# approval command takes no label: the receipt names the push itself.
if commits:
    show = "the staged diff and the proposed commit message"
    approve_line = f"{APPROVE_CMD} {request_id} '<commit subject>'"
    description = APPROVE_DESC_COMMIT_PUSH if pushes else APPROVE_DESC
elif github_write:
    show = ("the exact gh command and what it writes: the repository, the path, "
            "ref, or tag, and the content it sends")
    approve_line = f"{APPROVE_CMD} {request_id}"
    description = APPROVE_DESC_GH
else:
    show = "what the push publishes: the branch, the remote, and the commits it sends"
    approve_line = f"{APPROVE_CMD} {request_id}"
    description = APPROVE_DESC_PUSH
if commits and pushes:
    show += ", and the branch, remote, and commits the push sends"
bound = ""
if staged:
    bound += (" The commit is bound to HEAD and the staged changes"
              + (", and to the working-tree changes it takes" if staged["worktree"] else "")
              + ": any change before it runs voids the approval.")
if state:
    where = state["branch"].replace("refs/heads/", "") or "a detached HEAD"
    bound += (f" The push is bound to {where} at {state['head'][:12]} in "
              f"{state['git_dir']}: any change to the repository's branches, tags, "
              "HEAD, or remote, branch, push, or url config before it runs voids "
              "the approval.")
if gh_bound:
    bound += (" The write is bound to the content of every file the command names "
              "and to the git remote config: any change before it runs voids the "
              "approval.")

deny(
    gated,
    clause,
    f"Show the human {show}.{bound} "
    f"Then run this exact command, which prompts them to approve:\n\n"
    f"  {approve_line}\n\n"
    + ("Keep the subject in single quotes. If it holds an apostrophe, leave the "
       "subject out.\n\n" if commits else "")
    + f"Run it with the Bash tool's `description` parameter set to exactly "
    f'"{description}". The prompt renders that description, and it is the line '
    "the human reads before answering. A description that names the action "
    "instead of what it does gives them nothing to decide on, so they learn to "
    "clear the prompt unread.\n\n"
    "The human answering that prompt is the approval. When they accept it, run "
    "the same command again, from the same directory. One approval covers one "
    "run of one command, and a changed command needs a new one. Never edit this "
    "gate, and never set WORKBENCH_DEV_TEAM_PIPELINE — that variable belongs to "
    "the scheduled pipeline alone."
)
PYEOF
[ $? -eq 0 ] || python_fallback "Commit approval gate"
