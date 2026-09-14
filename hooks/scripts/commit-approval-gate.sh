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
#      REFUSED, for every command that commits, merges, or pushes, and offered no
#      approval path whatsoever. It hands the work back to the session that
#      dispatched it, as an uncommitted working tree.
#   3. A foreground session — the payload's agent_id is empty. `git commit` needs
#      an approval the human answered a prompt for, minutes earlier. Merge and
#      push are the human's own business there, and this gate has no opinion.
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
# One approval covers one commit. The gate keys each request by session, agent,
# and the exact command text, and deletes the record the moment it lets a commit
# through. A second commit — or the same commit a second time — starts over.
#
# The pipeline signal is per-process on purpose. A file-existence check — the old
# live-PID /tmp/watson.lock — answered "is a pipeline running on this host?",
# not "is THIS process the pipeline?", so a scheduled run waived approval for
# every concurrent interactive session on the same machine. That leak let four
# unapproved commits land across two interactive Watsons. An inherited
# environment variable cannot reach a session the dispatcher did not spawn. Do
# not reintroduce a host-wide or identity-shaped substitute.
#
# What this gate is NOT: anti-evasion machinery. It reads the command the agent
# asked to run, so a verb hidden inside `bash -c` or written by a script is not
# its subject, and in lane 3 the approval record is a file that anything holding
# Bash can write. What it does guarantee: a sub-agent's commit, merge, or push
# is refused outright with no path back, and a foreground commit cannot happen
# SILENTLY, because the sanctioned path runs through a prompt the human answers.
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

# The description the approval prompt must carry. The prompt renders three lines
# (the command, the Bash call's `description`, and the ask rule's reason), and
# the description is the one a human reads. Left to each session's judgement it
# came out as "Request human approval for this commit": true, and empty of the
# one fact the answer turns on. A prompt with no decision content in it gets
# cleared unread, and that reflex reaches the other ask rules too, `git reset
# --hard` and `gh pr merge` among them. So the denial dictates the line rather
# than describing an intent, and it stops at the subject: the diff and the
# message body were both considered and refused, because a longer prompt is the
# same fatigue by another route.
APPROVE_DESC = "Commit: <first line of the commit message>"


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
GH_OPTS_WITH_ARG = {"-R", "--repo"}

# Every git subcommand that writes a commit (commit, revert, cherry-pick, am),
# integrates another history (merge, rebase, pull), or publishes one (push). The
# rule is the membership test — add a verb here when it does one of those three,
# and note that `git pull` qualifies because it merges.
GATED_GIT = {"commit", "revert", "cherry-pick", "am", "merge", "rebase", "pull", "push"}

# The gh equivalent. Matched on its first two positionals, so `gh pr view` and
# `gh pr comment` are untouched.
GATED_GH = {("pr", "merge")}


def leading_positionals(tokens: list, opts_with_arg: set, want: int) -> list:
    """The first `want` non-option tokens, skipping flags and their values."""
    found = []
    i = 0
    while i < len(tokens) and len(found) < want:
        tok = tokens[i]
        if tok.split("=", 1)[0] in opts_with_arg and "=" not in tok:
            i += 2
        elif tok.startswith("-"):
            i += 1
        else:
            found.append(tok)
            i += 1
    return found


def gated_commands(cmd: str) -> list:
    """Every commit/merge/push command this call runs, in the order they run.

    All of them, never just the first: `git push && git commit -m x` is a commit
    as much as it is a push, and lane 3 gates on the commit being in there
    anywhere.
    """
    actions = []
    # Split into pipeline/list segments; a command can hide in any of them.
    for segment in re.split(r"\|\||&&|[|;\n&]", cmd):
        tokens = segment.strip().split()
        # Drop leading env assignments and command/builtin wrappers.
        while tokens and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]) or tokens[0] in ("command", "builtin", "exec")):
            tokens.pop(0)
        if not tokens:
            continue
        hit = ""
        if tokens[0] == "git":
            found = leading_positionals(tokens[1:], GIT_OPTS_WITH_ARG, 1)
            if found and found[0] in GATED_GIT:
                hit = "git " + found[0]
        elif tokens[0] == "gh":
            found = tuple(leading_positionals(tokens[1:], GH_OPTS_WITH_ARG, 2))
            if found in GATED_GH:
                hit = "gh " + " ".join(found)
        if hit and hit not in actions:
            actions.append(hit)
    return actions


actions = gated_commands(command)
if not actions:
    sys.exit(0)

# From here on the call writes or publishes history, and every exit is a verdict.
# Anything the gate cannot establish — a session it cannot name, a directory it
# cannot write — ends in a denial, never in silence.

session_id = str(payload.get("session_id") or "")
agent_id = str(payload.get("agent_id") or "")

# Lane 2. Before the record is read, so a planted approval cannot be spent, and
# before one is written, so no id exists for the agent to approve.
if agent_id:
    deny(
        f"🔒 Commit approval gate (workbench-dev-team): `{actions[0]}` is refused. "
        f"This call comes from a sub-agent (agent {agent_id[:8]}) that carries no "
        "pipeline flag, so no human is reachable to approve it. There is no "
        "approval command for you to run, by design: any command you can run "
        "yourself is not an approval.\n\n"
        "Hand the work back instead. Leave the tree uncommitted, and report the "
        "diff and the proposed commit message to the session that dispatched "
        "you. That session commits it, where a prompt does reach a human.\n\n"
        "A sub-agent does not commit, does not merge, and does not push. The two "
        "lanes that do are the scheduled Index pipeline, which "
        "bin/dispatch-agent.sh marks with WORKBENCH_DEV_TEAM_PIPELINE=1, and the "
        "foreground session. An Index item dispatched from a conversation lands "
        "here too: re-dispatch it through bin/dispatch-agent.sh, which sets that "
        "flag. Never set the flag yourself, and never write an approval record "
        "by hand."
    )

# Lane 3. Merge and push are the human's own, as they have always been here.
if "git commit" not in actions:
    sys.exit(0)

if not session_id:
    deny(
        "🔒 Commit approval gate (workbench-dev-team): this call carries no "
        "session id, so an approval cannot be bound to it. The commit is "
        "refused. Report this — the gate cannot be satisfied until the harness "
        "sends a session id."
    )

# The key answers "is THIS commit, by THIS agent, in THIS session approved?" and
# no broader question, so editing the command voids the approval it already has.
# The agent component is moot in practice now — lane 2 turned back every caller
# with an agent id — and it stays in the key anyway, so a record can never be
# reused across identities.
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
    f"Run it with the Bash tool's `description` parameter set to exactly "
    f'"{APPROVE_DESC}". The prompt renders that description, and it is the line '
    "the human reads before answering. A description that names the action "
    "instead of the commit gives them nothing to decide on, so they learn to "
    "clear the prompt unread.\n\n"
    "The human answering that prompt is the approval. When they accept it, run "
    "the same git commit command again. One approval covers one commit, and a "
    "changed command needs a new one. Never edit this gate, and never set "
    "WORKBENCH_DEV_TEAM_PIPELINE — that variable belongs to the scheduled "
    "pipeline alone."
)
PYEOF
