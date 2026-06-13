#!/bin/bash
# Commit approval gate (PreToolUse, matcher: Bash).
#
# Forces a permission prompt on every `git commit`, regardless of permission
# mode — commits require explicit human approval, always. The /develop skill
# tells the model to present the diff and proposed message BEFORE attempting
# the commit; this hook is the harness-level backstop for when prose fails.
#
# Carve-out — the autonomous Index pipeline, where no human is present and
# Holmes review + human PR merge is the approval gate:
#   * WORKBENCH_DEV_TEAM_PIPELINE=1 in the environment, or
#   * /tmp/watson.lock holding a live PID (Watson Index mode writes it first).
#     The lock path defaults to /tmp/watson.lock and can be overridden with
#     WORKBENCH_DEV_TEAM_WATSON_LOCK — the test suite uses this to isolate from
#     (and avoid clobbering) a real lock held by a concurrent pipeline run.
#
# Exit 0 with no output = no opinion (normal permission flow applies).
# Exit 0 with permissionDecision "ask" = harness must prompt the human.

set -u

# Pipeline carve-out: explicit env flag.
if [ "${WORKBENCH_DEV_TEAM_PIPELINE:-0}" = "1" ]; then
  exit 0
fi

# Pipeline carve-out: live Watson lock (Index mode acquires it before any work).
# Path overridable (WORKBENCH_DEV_TEAM_WATSON_LOCK) so tests don't depend on —
# or clobber — a real /tmp/watson.lock a concurrent pipeline run may hold.
WATSON_LOCK="${WORKBENCH_DEV_TEAM_WATSON_LOCK:-/tmp/watson.lock}"
if [ -f "$WATSON_LOCK" ] && kill -0 "$(cat "$WATSON_LOCK" 2>/dev/null)" 2>/dev/null; then
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
