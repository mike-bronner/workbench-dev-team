#!/bin/bash
# Commit approval gate (PreToolUse, matcher: Bash).
#
# Refuses every `git commit` that the human has not approved. The /develop skill
# tells the model to present the diff and proposed message BEFORE attempting the
# commit; this hook is the harness-level backstop for when prose fails.
#
# The verdict is "deny", and that is the whole point. The gate used to return
# "ask" and never stopped a single commit: a hook's "ask" is classifier-
# approvable, so under permissions.defaultMode "auto" the auto-mode classifier
# approved it and no human was ever prompted. The harness's own safety checks
# pair "ask" with a classifierApprovable:false marker that hooks cannot set. Of
# the three verdicts a hook can return, only "deny" binds.
#
# Approval therefore arrives by a second route: bin/approve-commit.sh, installed by
# /workbench-dev-team:setup at $HOME/.claude-workbench/bin/ and covered by
# permissions.ask rules. A permission RULE is evaluated before the classifier in
# every mode, so running that command does force a real prompt. The human
# answering it is the approval. approve-commit.sh refuses to grant anything unless
# those rules are present, so a half-finished setup fails closed.
#
# One approval covers one commit. The gate keys each request by session, agent,
# and the exact command text, and deletes the record the moment it lets a commit
# through. A second commit — or the same commit a second time — starts over.
#
# Carve-out — the autonomous Index pipeline, and only that. The one signal is
# WORKBENCH_DEV_TEAM_PIPELINE=1, exported by bin/dispatch-agent.sh onto the
# `claude -p` process it spawns. There, no human is present to answer a prompt,
# and board dispatch + Holmes review + the human's PR merge is the approval
# chain instead.
#
# The signal is per-process on purpose. A file-existence check — the old
# live-PID /tmp/watson.lock — answered "is a pipeline running on this host?",
# not "is THIS process the pipeline?", so a scheduled run waived approval for
# every concurrent interactive session on the same machine. That leak let four
# unapproved commits land across two interactive Watsons. An inherited
# environment variable cannot reach a session the dispatcher did not spawn.
#
# Do not reintroduce a host-wide or identity-shaped substitute. In particular
# `agent_type` in the hook payload is present for BOTH a scheduled
# `claude -p --agent watson` and an interactively dispatched one, so it cannot
# tell them apart and would re-open the same hole. The approval records this
# gate writes carry the same discipline: the session id and the agent id are
# both in the key, so an approval granted to one agent is unusable by any other
# agent, in any other session, for any other command.
#
# What this gate is NOT: a defence against an agent that sets out to defeat it.
# The approval record is a file, and anything holding Bash can write a file.
# What it does guarantee is that an unapproved commit cannot happen SILENTLY —
# the sanctioned path runs through a prompt the human answers.
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
import sys
import time

# How long an answered prompt stays good. Long enough for the agent to retry the
# commit it just had denied; far too short to sit around as a standing waiver.
APPROVAL_TTL_SECONDS = 900

# Records older than this are swept on any gate run. They are dead either way —
# every one of them is past the TTL — and the sweep keeps the directory from
# growing by one file per commit attempt forever.
RECORD_MAX_AGE_SECONDS = 86400

APPROVE_CMD = 'bash "$HOME/.claude-workbench/bin/approve-commit.sh"'


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
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

# git options that consume the following token as a value, so the
# subcommand search must skip both.
GIT_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def is_git_commit(cmd: str) -> bool:
    # Split into pipeline/list segments; a commit can hide in any of them.
    for segment in re.split(r"\|\||&&|[|;\n&]", cmd):
        tokens = segment.strip().split()
        # Drop leading env assignments and command/builtin wrappers.
        while tokens and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]) or tokens[0] in ("command", "builtin", "exec")):
            tokens.pop(0)
        if not tokens or tokens[0] != "git":
            continue
        i = 1
        while i < len(tokens):
            tok = tokens[i]
            base = tok.split("=", 1)[0]
            if base in GIT_OPTS_WITH_ARG and "=" not in tok:
                i += 2
            elif tok.startswith("-"):
                i += 1
            else:
                if tok == "commit":
                    return True
                break  # some other git subcommand
    return False


if not is_git_commit(command):
    sys.exit(0)

# From here on the call IS a commit, and every exit is a verdict. Anything the
# gate cannot establish — a session it cannot name, a directory it cannot write
# — ends in a denial, never in silence.

session_id = str(payload.get("session_id") or "")
agent_id = str(payload.get("agent_id") or "")

if not session_id:
    deny(
        "🔒 Commit approval gate (workbench-dev-team): this call carries no "
        "session id, so an approval cannot be bound to it. The commit is "
        "refused. Report this — the gate cannot be satisfied until the harness "
        "sends a session id."
    )

# The key answers "is THIS commit, by THIS agent, in THIS session approved?" and
# no broader question. Two agents in one session never share an approval, and
# editing the command voids the one it already has.
request_id = hashlib.sha256(
    "\x1f".join([session_id, agent_id, command]).encode("utf-8", "surrogatepass")
).hexdigest()[:16]

state_dir = os.environ.get("GATE_STATE_DIR", "")
if not state_dir or state_dir.startswith("/.claude-workbench"):
    # An empty HOME collapses the default to "/.claude-workbench/...", a path
    # every user on the host shares. Host-wide approval state is the exact shape
    # of the watson.lock leak, so this case is refused rather than relocated.
    deny(
        "🔒 Commit approval gate (workbench-dev-team): no approval directory is "
        "addressable (HOME is unset). The commit is refused."
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


record = read_record(record_path)

if record.get("status") == "approved":
    # One approval, one commit. The record dies here whatever happens next: if
    # the commit fails downstream, the next attempt asks the human again.
    #
    # A record that will not delete is refused rather than honoured. Letting the
    # commit through on an undeletable record hands the session a standing
    # waiver for that command — one approval covering every commit that follows,
    # which is the failure this whole gate exists to prevent.
    try:
        os.unlink(record_path)
    except OSError as error:
        deny(
            "🔒 Commit approval gate (workbench-dev-team): the approval record "
            f"at {record_path} cannot be deleted ({error}), so it cannot be "
            "spent. The commit is refused, because an approval that survives "
            "its commit approves every commit after it."
        )
    try:
        age = time.time() - float(record.get("approved_at", 0))
    except (TypeError, ValueError):
        age = APPROVAL_TTL_SECONDS + 1
    if age <= APPROVAL_TTL_SECONDS:
        sys.exit(0)  # approved, fresh, and now spent -> normal permission flow
    expired = True
else:
    expired = False

# No usable approval. Record the request so approve-commit.sh can find it, then
# refuse. The record names the command, which is what the human ends up
# approving — approve-commit.sh reads it back out.
try:
    os.makedirs(state_dir, exist_ok=True)
    sweep(state_dir)
    with open(record_path, "w", encoding="utf-8") as handle:
        json.dump({
            "status": "pending",
            "session_id": session_id,
            "agent_id": agent_id,
            "command": command,
            "requested_at": time.time(),
        }, handle)
except OSError as error:
    deny(
        "🔒 Commit approval gate (workbench-dev-team): cannot write the approval "
        f"record under {state_dir} ({error}). The commit is refused until that "
        "path is writable."
    )

lead = (
    f"🔒 Commit approval gate (workbench-dev-team): the approval for this commit "
    f"expired. Approvals last {APPROVAL_TTL_SECONDS // 60} minutes."
) if expired else (
    "🔒 Commit approval gate (workbench-dev-team): this commit is not approved."
)

deny(
    f"{lead} Show the human the staged diff and the proposed commit message. "
    f"Then run this exact command, which prompts them to approve:\n\n"
    f'  {APPROVE_CMD} {request_id} "<commit subject>"\n\n'
    "The human answering that prompt is the approval. When they accept it, run "
    "the same git commit command again. One approval covers one commit, and a "
    "changed command needs a new one. Never edit this gate, and never set "
    "WORKBENCH_DEV_TEAM_PIPELINE — that variable belongs to the scheduled "
    "pipeline alone."
)
PYEOF
