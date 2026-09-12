#!/bin/bash
# approve-commit.sh — grant one commit the approval hooks/scripts/commit-approval-gate.sh
# demands. Run it only after the human has seen the staged diff and the proposed
# commit message.
#
#   bash "$HOME/.claude-workbench/bin/approve-commit.sh" <request-id> "<commit subject>"
#
# The request id comes from the gate's own denial. The subject is optional, and
# when given it must appear in the command the id names — the human reads it in
# the permission prompt, so a label that describes some other commit is refused.
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

# The label is what the human reads in the permission prompt. It has to come out
# of the command it claims to describe, or the prompt describes nothing.
if label and label not in command:
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

print(f"✅ Approved {request_id}. This command, once:")
print()
print(f"  {command}")
print()
print("The approval expires in 15 minutes, and the commit spends it. Anything else needs a new one.")
PYEOF
