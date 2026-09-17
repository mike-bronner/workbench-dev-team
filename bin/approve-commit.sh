#!/bin/bash
# approve-commit.sh — grant one commit the approval hooks/scripts/commit-approval-gate.sh
# demands. Run it only after the human has seen the staged diff and the proposed
# commit message.
#
#   bash "$HOME/.claude-workbench/bin/approve-commit.sh" <request-id> "<commit subject>"
#
# The request id comes from the gate's own denial, in its additionalContext. The
# subject is optional, and when given it must be the real subject of the commit
# the id names — the human reads it in the permission prompt, so a label that
# describes some other commit is refused. Where the real subject lives depends on
# the command: in its own -m value, or in the message file a -F path points at.
#
# WHAT IT PRINTS ON SUCCESS, AND WHAT IT NO LONGER DOES. One line naming the
# COMMIT that was approved, and never the command again. The command has already
# been on screen twice by then — the agent ran it, and the permission prompt
# rendered it — so echoing it a third time meant a sixty-line heredoc with a
# whole commit message in it appearing twice in one session. The command is the
# noise; which commit was just approved is the fact that needed confirming.
#
# A MESSAGE THAT LIVES IN A FILE. `git commit -F <path>` keeps the message out of
# the command, and that shape is the one to prefer: the gate makes the command run
# twice, so a message written inline lands in the human's transcript twice in
# full. The subject check used to refuse exactly that shape, because it looked for
# the subject in the command text and a -F command carries only a path. It now
# reads the first line of the file git will read, in every spelling git accepts —
# -F <path>, --file=<path>, --file <path>, and a short cluster like -aF. Variables
# in the path are resolved from the assignments the command itself makes and from
# this process's environment, and never by running a shell on it: the recorded
# command is caller-controlled text, so expanding it through a shell would be the
# injection this gate is supposed to make impossible.
#
# THE FILE IS DISPLAY; THE COMMAND IS STILL THE DECISION. Every check that decides
# whether an approval may be granted at all — the id's shape, this copy's path,
# the ask rules, the waiting record — finishes before the first byte of a message
# file is read, and none of them can be moved by what a file holds. The file
# supplies one thing: the subject the human reads. So a file can only refuse an
# approval or name a commit. It can never widen one, change which command the
# approval covers, or stand in for an approval that was never granted.
#
# AND IT FAILS CLOSED, BECAUSE A SUBJECT NOBODY CAN ESTABLISH IS A GUESS. A path
# that will not resolve, a file that will not open, a file with no message in it,
# and `-F -` (the message came down standard input, which is gone by the time an
# approval runs) each refuse, naming their own case so the caller can correct the
# command and commit again. A command that names no message at all — `--amend
# --no-edit` — is not that case: it promised no subject, so the receipt falls back
# to the request id, as it always has.
#
# One thing the file shape makes stricter. When the message is in a file, no
# honest subject appears in the command text, so the label is compared against
# the file's first line instead of the command. Substring-matching the command
# there would have accepted "core" as the subject of `-F "$SP/core.txt"`.
#
# WHY THIS COMMAND EXISTS. A PreToolUse hook can only answer allow / deny / ask,
# and its "ask" is classifier-approvable: under permissions.defaultMode "auto"
# the classifier answers it and no human sees anything. A permission RULE is
# different — rules are evaluated before the classifier in every mode, so a rule
# forces a real prompt. /workbench-dev-team:setup therefore installs this script
# at a stable path and adds two permissions.ask rules covering it. Running it is
# the act the human is prompted on, and their answer is the approval.
#
# THIS SERVES THE FOREGROUND SESSION, AND ONLY THAT. The reasoning above holds
# where a human is attached to answer the prompt, and it fails in a sub-agent:
# the sub-agent's request is background and non-interactive, so the ask resolves
# with nobody answering it, and the agent holds the Bash that runs this command.
# It was measured doing exactly that 48 times in the gate's first day, a median
# 3.4 seconds after each denial. So the gate no longer offers a sub-agent this
# route at all: it refuses a sub-agent's commit, merge, and push outright, prints
# no request id, and writes no pending record. There is nothing here for one to
# approve. A sub-agent hands its work back uncommitted instead.
#
# Two refusals keep that story honest, and both fail closed:
#
#   1. If the ask rules are absent from settings, running this command prompts
#      nobody, so it grants nothing and says what to run.
#   2. If this copy is not the one at the stable path the rules name — the
#      plugin-cache copy, say — the rules cannot match it, so it grants nothing.
#
# What is left uncovered, stated plainly: an invocation spelled differently from
# the rules (`sh <path>`, or the path without the `bash` prefix) is not matched
# by them and is not prompted, and in the foreground session anything holding
# Bash can write the approval record directly. This is a protocol gate for that
# lane. It makes an unapproved foreground commit impossible to perform SILENTLY;
# it is not a barrier against a main agent that sets out to defeat it.
#
# The scheduled Index pipeline never runs this command. The gate exits before
# any of it when WORKBENCH_DEV_TEAM_PIPELINE=1, so the headless lane keeps
# committing unattended.

set -u

STABLE_DIR="${HOME:-}/.claude-workbench/bin"
STABLE_PATH="$STABLE_DIR/approve-commit.sh"
SANCTIONED_CMD='bash "$HOME/.claude-workbench/bin/approve-commit.sh"'

REQUEST_ID="${1:-}"
LABEL="${2:-}"

if [ -z "$REQUEST_ID" ] || [ "$REQUEST_ID" = "-h" ] || [ "$REQUEST_ID" = "--help" ]; then
  echo "usage: $SANCTIONED_CMD <request-id> [\"commit subject\"]" >&2
  echo "The request id is the one the commit approval gate printed when it refused the commit." >&2
  exit 2
fi

case "$REQUEST_ID" in
  *[!0-9a-f]* | "")
    echo "❌ approve-commit.sh: \"$REQUEST_ID\" is not a request id. Ids are lowercase hex, as printed by the gate." >&2
    exit 1
    ;;
esac

# Refuse any copy but the installed one. The permissions.ask rules name the
# stable path; a copy run from anywhere else is a copy no rule can match, so
# nothing prompted the human and there is no approval to record.
resolve() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
SELF_RESOLVED="$(resolve "$0")"
STABLE_RESOLVED="$(resolve "$STABLE_PATH")"

if [ -z "$STABLE_RESOLVED" ] || [ ! -f "$STABLE_PATH" ]; then
  echo "❌ approve-commit.sh: not installed at $STABLE_PATH." >&2
  echo "   Run /workbench-dev-team:setup. Until it is installed there, no permission rule can force a prompt, so nothing here can grant an approval." >&2
  exit 1
fi

if [ "$SELF_RESOLVED" != "$STABLE_RESOLVED" ]; then
  echo "❌ approve-commit.sh: this copy lives at $SELF_RESOLVED, and the permission rules name $STABLE_RESOLVED." >&2
  echo "   Nothing prompted the human for this call, so it grants nothing. Run:  $SANCTIONED_CMD $REQUEST_ID" >&2
  exit 1
fi

export APPROVE_REQUEST_ID="$REQUEST_ID"
export APPROVE_LABEL="$LABEL"
export APPROVE_SETTINGS="${WORKBENCH_SETTINGS_FILE:-${HOME:-}/.claude/settings.json}"
export APPROVE_STATE_DIR="${WORKBENCH_COMMIT_APPROVAL_DIR:-${HOME:-}/.claude-workbench/commit-approvals}"
export APPROVE_HOME="${HOME:-}"

python3 - <<'PYEOF'
import json
import os
import re
import shlex
import sys
import time

request_id = os.environ["APPROVE_REQUEST_ID"]
label = os.environ["APPROVE_LABEL"]
settings_path = os.environ["APPROVE_SETTINGS"]
state_dir = os.environ["APPROVE_STATE_DIR"]
home = os.environ["APPROVE_HOME"]

# Both spellings of the one sanctioned invocation: the "$HOME" form a caller
# types, and the absolute path it expands to. /workbench-dev-team:setup adds
# both, the same way it does for the dispatch wrapper.
REQUIRED_ASK_RULES = [
    'Bash(bash "$HOME/.claude-workbench/bin/approve-commit.sh":*)',
    f'Bash(bash {home}/.claude-workbench/bin/approve-commit.sh:*)',
]


def refuse(*lines: str) -> None:
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


try:
    with open(settings_path, "r", encoding="utf-8") as handle:
        settings = json.load(handle)
    ask_rules = settings.get("permissions", {}).get("ask", [])
    if not isinstance(ask_rules, list):
        ask_rules = []
except (OSError, ValueError):
    ask_rules = []

missing = [rule for rule in REQUIRED_ASK_RULES if rule not in ask_rules]
if missing:
    refuse(
        f"❌ approve-commit.sh: the permission rules that make this prompt are missing from {settings_path}.",
        "   Without them this command runs unprompted, so it would approve a commit nobody saw. It grants nothing.",
        "   Run /workbench-dev-team:setup, or add these to permissions.ask by hand:",
        *[f"     {rule}" for rule in missing],
    )

record_path = os.path.join(state_dir, request_id)
try:
    with open(record_path, "r", encoding="utf-8") as handle:
        record = json.load(handle)
    if not isinstance(record, dict) or not record.get("command"):
        raise ValueError("malformed record")
except (OSError, ValueError):
    refuse(
        f"❌ approve-commit.sh: no commit is waiting for approval under id {request_id}.",
        "   The gate writes that record when it refuses a commit. Run the git commit again and use the id it prints.",
    )

command = record["command"]

# A message file is whatever the caller pointed at, so it is read at arm's
# length: the first few KB, for one line, printed with control characters
# neutralised. An escape sequence in a commit message file would otherwise be
# rendered by the terminal the receipt is written to.
MESSAGE_READ_LIMIT = 8192
SUBJECT_DISPLAY_LIMIT = 200
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def first_line(text: str) -> str:
    lines = text.splitlines()
    return lines[0] if lines else ""


def path_source(path: str) -> tuple:
    """`-` is git's spelling for standard input, which is not a file."""
    return ("stdin", "") if path == "-" else ("file", path)


def message_source(cmd: str) -> tuple:
    """Where `cmd` says its commit message comes from: (kind, value).

    kind is "inline" (value is the message itself), "file" (value is the path
    exactly as the command spells it, variables and all), "stdin", or "" for a
    command that names no message at all — `--amend --no-edit`, say.

    Command text only. Nothing here opens a file or runs anything, because which
    command is being approved is a question about this text and nothing else.
    `-am` and `-aF` are covered: a short cluster ending in `m` takes the message
    next, and one ending in `F` takes a path.
    """
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        return "", ""
    for index, token in enumerate(tokens):
        if token.startswith("--message="):
            return "inline", token.split("=", 1)[1]
        if token.startswith("--file="):
            return path_source(token.split("=", 1)[1])
        cluster = token.startswith("-") and not token.startswith("--")
        inline = token == "--message" or (cluster and token.endswith("m"))
        in_file = token == "--file" or (cluster and token.endswith("F"))
        if (inline or in_file) and index + 1 < len(tokens):
            value = tokens[index + 1]
            return ("inline", value) if inline else path_source(value)
    return "", ""


def expand(text: str, assigned: dict) -> tuple:
    """`text` with $VAR and ${VAR} replaced, plus the first name with no value."""
    missing = []

    def value(match):
        name = match.group(1) or match.group(2)
        for source in (assigned, os.environ):
            if name in source:
                return source[name]
        missing.append(name)
        return ""

    return VARIABLE.sub(value, text), missing[0] if missing else ""


def resolve_path(raw: str, cmd: str) -> tuple:
    """An absolute path for `raw`, or ("", the case that stopped it).

    Values come from the assignments the recorded command makes itself
    (`SP=/tmp/x git commit -F "$SP/m.txt"`) and then from this process's
    environment. A shell is never run on the text — see the header.
    """
    assigned = {}
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        tokens = []
    for token in tokens:
        name, sep, raw_value = token.partition("=")
        if sep and IDENTIFIER.fullmatch(name):
            # `SP=/tmp/x; git commit …` is the shape an agent actually writes, and
            # shlex keeps that `;` stuck to the value. No path ends in a shell
            # operator, so dropping trailing ones costs nothing.
            expanded, unknown = expand(raw_value.rstrip(";&|"), assigned)
            if not unknown:
                assigned[name] = expanded

    path, unknown = expand(raw, assigned)
    if unknown:
        return "", f"the path names ${unknown}, and nothing here knows that value"
    if "$" in path or "`" in path:
        return "", f"the path {path} is built by the shell as it runs, and this command never runs one"
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        return "", f"the path {path} is relative, and the record does not say which directory the commit ran in"
    return path, ""


def file_subject(path: str) -> tuple:
    """The line git will take as the subject, or ("", the case that stopped it).

    git's default cleanup for a message it opens no editor on is `whitespace`:
    leading empty lines go, trailing whitespace goes, and a `#` line stays. So
    the subject is the first line with anything on it.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            head = handle.read(MESSAGE_READ_LIMIT)
    except (OSError, ValueError) as error:
        # ValueError covers a path the OS will not even accept, such as one with
        # a NUL in it. Every way a read can fail ends in the same refusal.
        return "", f"{path} cannot be read ({getattr(error, 'strerror', None) or error})"
    for line in head.splitlines():
        if line.strip():
            return line.rstrip(), ""
    return "", f"{path} holds no message, so there is no subject to name"


def for_display(subject: str) -> str:
    """A file's first line, made safe to print. Verification uses the real one."""
    clean = "".join(char if char.isprintable() else "�" for char in subject)
    if len(clean) > SUBJECT_DISPLAY_LIMIT:
        clean = clean[: SUBJECT_DISPLAY_LIMIT - 1] + "…"
    return clean


kind, source = message_source(command)
subject_in_file = ""
recovered = first_line(source) if kind == "inline" else ""

# A command that takes its message from a file is the one shape where the
# subject the human reads is not in the command text. Establish it here, once,
# and refuse when it cannot be established: an approval that cannot name its own
# commit is the guess this check exists to refuse.
if kind == "stdin":
    refuse(
        "❌ approve-commit.sh: this commit takes its message from standard input, which is gone by the time an approval runs.",
        "   Write the message to a file and commit with -F <path>. Then the prompt can name the real subject.",
    )

if kind == "file":
    message_path, problem = resolve_path(source, command)
    if not problem:
        subject_in_file, problem = file_subject(message_path)
    if problem:
        refuse(
            "❌ approve-commit.sh: this commit takes its message from a file, and that file cannot be read.",
            f"   {problem}.",
            "   Nothing here can name the commit, so nothing is approved. Commit again with a path this command can read.",
        )
    recovered = for_display(subject_in_file)

# The label is what the human reads in the permission prompt. It has to be the
# subject of the commit it claims to describe, or the prompt describes nothing.
if label and kind == "file":
    # With the message in a file, no honest subject appears in the command — only
    # the path does — so the file's own first line is what the label must be.
    if label.strip() != subject_in_file.strip():
        refuse(
            "❌ approve-commit.sh: that subject is not the one in this commit's message file.",
            "   The human reads the subject in the prompt, so it must be the real one. The file's first line is:",
            f"     {recovered}",
        )
elif label and label not in command:
    refuse(
        "❌ approve-commit.sh: that subject does not appear in the command this id names.",
        "   The human reads the subject in the prompt, so it must be the real one. The command is:",
        f"     {command}",
    )

record["status"] = "approved"
record["approved_at"] = time.time()

try:
    with open(record_path, "w", encoding="utf-8") as handle:
        json.dump(record, handle)
except OSError as error:
    refuse(f"❌ approve-commit.sh: cannot write {record_path} ({error}). Nothing was approved.")

# The receipt names WHICH COMMIT was approved, and never the command again. The
# command was already on screen twice by this point — the agent ran it, and the
# permission prompt rendered it — and a sixty-line heredoc printed a third time
# is the noise this receipt was making. What is left is the one fact the human
# needs confirmed back.
# For a file message the receipt names the file's own line rather than the label,
# because that line is what git will commit — and a label that reached this point
# is the same line anyway. It is also the one subject here that came out of a
# file, so it is the one printed at arm's length.
subject = recovered if kind == "file" else label or recovered
print(f"✅ Approved: {subject}" if subject else f"✅ Approved request {request_id}.")
print("   One commit spends it, and it expires in 15 minutes.")
PYEOF
