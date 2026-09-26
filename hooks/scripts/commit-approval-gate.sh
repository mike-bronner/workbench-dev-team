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
#      outright. Merge, rebase, pull, revert, cherry-pick, am, and `gh pr merge`
#      stay the human's own, and this gate has no opinion on them.
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
#       word out of view. A command is class (b) when it is not class (a) and
#         - it names git or yadm (`git` not followed by a letter, so `github` is
#           not git) and either names a verb word — commit, push, send-pack
#           (the plumbing under push), autocorrect (which turns a typo into
#           either), or alias (which renames one) — or
#           holds a character that lets the shell build a word the text does not
#           show: $ ` \ ' " { } * ? [ ], or
#         - it names gh as a word, and a verb.
#       Lane 2 adds merge, rebase, pull, revert, cherry-pick, and `am` as a word to
#       the verbs, because a sub-agent may do none of them.
#   (c) EVERYTHING ELSE passes untouched. That includes a plain one-line git
#       command whose verb is not gated in the lane (`git status`, `git log`),
#       unless it names a verb and is not one of the commands that cannot run
#       another command from their arguments (SAFE_VERBS). `git log --grep
#       push` stays silent; `git rebase --exec 'git push'` does not.
#
# The cost is real and deliberate: some innocent commands are refused, such as
# `cd repo && git log --format='%h'` or `echo "commit"` beside a git word. The
# refusal says how to run them instead. A false refusal costs one retry; a false
# silence is an unapproved push.
#
# What stays outside, stated plainly. This is not anti-evasion machinery, and a
# command built to hide from a substring test can: a program name spelled in
# pieces the text never shows whole, a script file, or a gitconfig alias or
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
# $HOME/.claude-workbench/bin/ and covered by permissions.ask rules. A permission
# RULE is evaluated before the auto-mode classifier in every mode, so running
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
# integrates another history, or publishes one, plus `gh pr merge`. GATED_GIT
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

APPROVE_CMD = 'bash "$HOME/.claude-workbench/bin/approve-commit.sh"'

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

# The substring tests for class (b). Raw text, case-insensitive, no parsing.
GIT_NAME = re.compile(r"(?i)(git(?![a-z])|yadm)")
GH_NAME = re.compile(r"(?i)(?<![a-z0-9])gh(?![a-z0-9])")
VERBS = {
    "foreground": re.compile(r"(?i)commit|push|send-pack|autocorrect|alias"),
    "sub-agent": re.compile(r"(?i)commit|push|send-pack|autocorrect|alias|merge|rebase|pull|revert|cherry|(?<![a-z])am(?![a-z])"),
}
# A character that lets the shell build a word the text does not show whole.
SHELL_BUILDS = re.compile(r"[$`\\'\"{}*?\[\]]")

# The plain form's alphabet. A bare word is made of these and nothing else.
BARE = set(string.ascii_letters + string.digits + "-_./:=+@,%^")


def plain_words(text: str):
    """[(word, kind)] for a one-line command of plain words, or None.

    kind is "bare", "quoted", or "and" for a standalone `&&`. The word is what
    git receives: quotes removed, nothing expanded, because nothing that bash or
    zsh would expand is allowed to be there. The Bash tool runs zsh here, and zsh
    expands a bare word that starts with `=` (`=ls` becomes /bin/ls), so that
    word is refused too.
    """
    line = text.strip(" \t\n")
    words = []
    i = 0
    while i < len(line):
        if line[i] in " \t":
            i += 1
            continue
        if line.startswith("&&", i) and (i + 2 == len(line) or line[i + 2] in " \t"):
            words.append(("&&", "and"))
            i += 2
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
                end = line.find(char, i + 1)
                if end < 0:
                    return None
                inner = line[i + 1:end]
                if "\n" in inner or (char == '"' and any(c in inner for c in "$`\\")):
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
    if not words:
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


def could_hide(text: str, lane: str) -> bool:
    """Class (b): the text could run a gated verb the gate cannot see whole."""
    verbs = VERBS[lane]
    if GIT_NAME.search(text) and (verbs.search(text) or SHELL_BUILDS.search(text)):
        return True
    return bool(GH_NAME.search(text) and verbs.search(text))


def classify(text: str, lane: str, gated: set):
    """("gated", invocations), ("hidden", None), or ("silent", None)."""
    invocations = plain_form(text)
    if invocations:
        if any(i["verb"] in gated for i in invocations):
            return "gated", invocations
        if invocations[0]["verb"] in SAFE_VERBS or not VERBS[lane].search(text):
            return "silent", None
        return "hidden", None
    return ("hidden", None) if could_hide(text, lane) else ("silent", None)


# Lane 2. Before any record is read, so a planted approval cannot be spent, and
# before one is written, so no id exists for the agent to approve.
if agent_id:
    verdict, invocations = classify(command, "sub-agent", GATED_GIT)
    if verdict == "silent":
        sys.exit(0)
    action = (f"`git {invocations[0]['verb']}`" if invocations
              else "a command that names a git commit, merge, or push")
    deny(
        action,
        "A sub-agent does not commit, merge, or push.",
        f"This call comes from a sub-agent (agent {agent_id[:8]}) that carries no "
        "pipeline flag, so no human is reachable to approve it. There is no "
        "approval command for you to run, by design: any command you can run "
        "yourself is not an approval.\n\n"
        "Hand the work back instead. Leave the tree uncommitted, and report the "
        "diff and the proposed commit message to the session that dispatched "
        "you. That session commits it, where a prompt does reach a human.\n\n"
        "The two lanes that may write history are the scheduled Index pipeline, "
        "which bin/dispatch-agent.sh marks with WORKBENCH_DEV_TEAM_PIPELINE=1, "
        "and the foreground session. An Index item dispatched from a "
        "conversation lands here too: re-dispatch it through "
        "bin/dispatch-agent.sh, which sets that flag. Never set the flag "
        "yourself, and never write an approval record by hand."
    )

# Lane 3.
verdict, invocations = classify(command, "foreground", APPROVABLE)
if verdict == "silent":
    sys.exit(0)

PLAIN_FORM = (
    "The gate prompts only for the plain form, one line on its own:\n\n"
    "  git [-C <path>] commit <args>\n"
    "  git [-C <path>] push <args>\n"
    "  git [-C <path>] commit <args> && git [-C <path>] push <args>\n\n"
    "Every word plain or quoted, and no bare word starting with =: no $, "
    "backtick, backslash, glob, brace, "
    "redirect, pipe, comment, heredoc, variable assignment, wrapper such as env "
    "or time, or other separator. A double-quoted string may not hold $, a "
    "backtick, or a backslash. Run git add as its own call. Write a multi-line "
    "commit message to a file in the session scratchpad and use -F <absolute "
    "path>; the heredoc form -m \"$(cat <<'EOF' ... EOF)\" is refused. Use -C "
    "<path> rather than cd."
)

if verdict == "hidden":
    # Class (b): refused with no id, before any record is read or written.
    deny(
        "this command could hide a `git commit` or `git push`",
        "Run it as a plain line of its own.",
        "This command names git and a commit or push, or holds shell the gate "
        "does not read, and it is not the plain form. The gate refuses it rather "
        "than guess what it runs. " + PLAIN_FORM + " A git command that cannot run "
        "another command from its arguments — log, show, diff, status, and the "
        "like — can run as a plain line of its own too."
    )

# Class (a) from here on: the gate knows exactly which words git receives.
commits = [i for i in invocations if i["verb"] == "commit"]
pushes = [i for i in invocations if i["verb"] == "push"]
gated = " and ".join(f"`git {i['verb']}`" for i in invocations)

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
state_print = digest(state) if state else ""
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
            "verbs": [i["verb"] for i in invocations],
            "commit_words": commits[0]["words"] if commits else None,
            "push": shlex.join(push["words"]) if push else None,
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
    "changed": "The repository changed since you approved it.",
}[why]

# What the human is shown, what the approval command carries, and what the
# prompt's description says all follow from what the call does. A commit is
# named by its subject. A push is named by its branch and remote, and its
# approval command takes no label: the receipt names the push itself.
if commits:
    show = "the staged diff and the proposed commit message"
    approve_line = f'{APPROVE_CMD} {request_id} "<commit subject>"'
    description = APPROVE_DESC_COMMIT_PUSH if pushes else APPROVE_DESC
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

deny(
    gated,
    clause,
    f"Show the human {show}.{bound} "
    f"Then run this exact command, which prompts them to approve:\n\n"
    f"  {approve_line}\n\n"
    f"Run it with the Bash tool's `description` parameter set to exactly "
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
