# shellcheck shell=bash
# Sourced by commit-approval-gate.sh. Not run directly.
#
# The gate classifies the command in python3. When python3 is missing, or exits
# non-zero, the hook would exit with an error status, and the harness treats that
# as a non-blocking error: the call runs as if no hook were installed. For the
# commit gate that is every commit and push unapproved.
#
# So the gate calls python_fallback on that path. It refuses any Bash call whose
# payload names git, gh, or yadm, which covers every command the gate could
# have refused, and it has no opinion on anything else. local-review-guard.sh
# does not use it: that guard stops rm, chmod, redirects, and edits, which name
# no git, so it carries a fallback of its own. The test is
# over the raw payload, so it errs toward refusing: a path that merely contains
# `git` is refused too. That is the right direction for a broken install, and the
# refusal names the fix.
#
# The same test is the commit gate's fast path, run before python3 starts at
# all: a payload that cannot name git, gh, or yadm cannot be refused by the
# gate, so the gate exits with no opinion and saves the interpreter's start-up.
#
# It reads GATE_PAYLOAD, the payload the gate captured before sourcing it.

# payload_may_name_git <payload> — true when the decoded command could name git,
# gh, or yadm as the gate's python reads them. The test runs over the RAW JSON,
# so it has to be a superset of the decoded one, and three things make it so:
#
#   - A JSON escape can stand before the name: `\ngit` is a newline and then git,
#     although the byte before `git` is the letter n. So a backslash and a letter
#     count as a boundary.
#   - `\uXXXX` can spell any character, a letter of the name included. Any
#     `\u` sends the payload to the full check.
#   - python's case-insensitive match folds a few non-ASCII letters into ASCII
#     ones (`gıt` matches `git`). Any byte outside printable ASCII also sends the
#     payload to the full check, so no fold is left for this test to model.
#
# LC_ALL=C makes every byte one character and every bracket a byte set, so no
# locale can widen or narrow what counts as a letter. Every mistake this test can
# make is toward running python3, never away from it.
payload_may_name_git() {
  local LC_ALL=C payload="$1"
  local boundary='(^|[^A-Za-z0-9.]|\\[A-Za-z])'
  local git_re="${boundary}[Gg][Ii][Tt]([^A-Za-z]|\$)"
  local gh_re='(^|[^A-Za-z0-9]|\\[A-Za-z])[Gg][Hh]([^A-Za-z0-9]|$)'
  local yadm_re='[Yy][Aa][Dd][Mm]'
  local escape_re='\\u'
  local wide_re='[^ -~]'
  [[ $payload =~ $git_re || $payload =~ $gh_re || $payload =~ $yadm_re \
     || $payload =~ $escape_re || $payload =~ $wide_re ]]
}

# python_fallback <hook name> — print a deny for git/gh/yadm text, then exit 0.
python_fallback() {
  local payload="${GATE_PAYLOAD:-}"
  if printf '%s' "$payload" | grep -Eq '"tool_name" *: *"Bash"' \
     && payload_may_name_git "$payload"; then
    printf '%s\n' "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"🛑 Blocked: a git command. python3 is missing or failed, so the $1 cannot read it.\", \"additionalContext\": \"$1 (workbench-dev-team). This hook classifies commands with python3, and python3 is not on PATH or exited with an error. Rather than let every git command run unchecked, it refuses any command that names git, gh, or yadm. Report this to the human: python3 and git are prerequisites of workbench-dev-team (see its README). Do not try another spelling of the command.\"}}"
  fi
  exit 0
}
