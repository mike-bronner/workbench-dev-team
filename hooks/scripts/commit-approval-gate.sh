#!/bin/bash
# Commit approval gate (PreToolUse, matcher: Bash).
#
# Forces a permission prompt on every `git commit`, regardless of permission
# mode — commits require explicit human approval, always. The /develop skill
# tells the model to present the diff and proposed message BEFORE attempting
# the commit; this hook is the harness-level backstop for when prose fails.
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
# tell them apart and would re-open the same hole.
#
# Exit 0 with no output = no opinion (normal permission flow applies).
# Exit 0 with permissionDecision "ask" = harness must prompt the human.

set -u

# Pipeline carve-out: the dispatcher's flag, and nothing else.
if [ "${WORKBENCH_DEV_TEAM_PIPELINE:-0}" = "1" ]; then
  exit 0
fi

# Capture the payload before the heredoc below claims stdin for the
# python program itself.
GATE_PAYLOAD="$(cat)"
export GATE_PAYLOAD

python3 - <<'PYEOF'
import json
import os
import re
import sys

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


if is_git_commit(command):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": (
                "🔒 Commit approval gate (workbench-dev-team): every git commit "
                "requires explicit human approval. Review the diff and the "
                "proposed commit message, then approve or deny."
            ),
        }
    }))
sys.exit(0)
PYEOF
