#!/bin/bash
# Tests for bin/approve-commit.sh. Run directly: ./test-approve-commit.sh
#
# The script's whole value is that it refuses to grant an approval nobody was
# prompted for. Every refusal below is therefore asserted twice: the exit status,
# and the fact that the commit is STILL denied by the real gate afterwards. An
# error message that leaves an approved record behind would be worse than no
# message at all.
#
# Nothing here touches the developer's home. HOME points into a sandbox holding
# its own settings.json, its own installed copy of the script, and its own
# approval records, so a verdict can only come from what the case set up.

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/bin/approve-commit.sh"
GATE="$REPO/hooks/scripts/commit-approval-gate.sh"
PASS=0
FAIL=0

for required in "$SRC" "$GATE"; do
  if [ ! -f "$required" ]; then
    echo "❌ missing $required — cannot test"
    exit 1
  fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/approve-commit.sh.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
HOME_DIR="$SANDBOX/home"
INSTALLED="$HOME_DIR/.claude-workbench/bin/approve-commit.sh"
SETTINGS="$HOME_DIR/.claude/settings.json"
STATE="$HOME_DIR/.claude-workbench/commit-approvals"

mkdir -p "$HOME_DIR/.claude-workbench/bin" "$HOME_DIR/.claude" "$STATE"
install -m 755 "$SRC" "$INSTALLED"

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# The two rules /workbench-dev-team:setup adds. Written here the way setup
# writes them: the "$HOME" spelling a caller types, and the absolute path it
# expands to.
write_settings() { # write_settings <both|home-only|none>
  python3 - "$SETTINGS" "$1" "$HOME_DIR" <<'PY'
import json, sys
path, which, home = sys.argv[1], sys.argv[2], sys.argv[3]
rules = {
    "home": 'Bash(bash "$HOME/.claude-workbench/bin/approve-commit.sh":*)',
    "abs": f'Bash(bash {home}/.claude-workbench/bin/approve-commit.sh:*)',
}
ask = {"both": [rules["home"], rules["abs"]], "home-only": [rules["home"]], "none": []}[which]
with open(path, "w") as handle:
    json.dump({"permissions": {"ask": ask}}, handle)
PY
}

# Ask the real gate about a command, with HOME in the sandbox. The second
# argument is the payload's agent_id — empty (the default) is a foreground
# session, and any value is a sub-agent.
gate_answer() { # gate_answer <command> [agent-id]
  local body
  body=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"session-A","agent_id":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$1" "${2-}")
  printf '%s' "$body" | env -u WORKBENCH_DEV_TEAM_PIPELINE -u WORKBENCH_COMMIT_APPROVAL_DIR \
    -u WORKBENCH_SETTINGS_FILE HOME="$HOME_DIR" TMPDIR="$SANDBOX" "$GATE"
}

gate_verdict() { # gate_verdict <command> [agent-id] -> deny | silent
  if gate_answer "$@" | grep -q '"permissionDecision": *"deny"'; then echo deny; else echo silent; fi
}

# The id the gate prints when it refuses a command, which is what a caller
# pastes. It comes out of additionalContext: an id is something only an agent
# acts on, so it lives in the model's half of the denial and never in the one
# short line the human reads.
gate_request_id() { # gate_request_id <command> [agent-id]
  gate_answer "$@" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"].get("additionalContext",""))' \
    | grep -oE '[0-9a-f]{16}' | head -1
}

# Run the installed copy, the way the permission rules name it.
approve() { # approve <args...> -> status, output on stdout+stderr
  env -u WORKBENCH_COMMIT_APPROVAL_DIR -u WORKBENCH_SETTINGS_FILE \
    HOME="$HOME_DIR" TMPDIR="$SANDBOX" bash "$INSTALLED" "$@" 2>&1
}

expect_status() { # expect_status <desc> <expected-status> <actual-status>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected exit $2, got exit $3"; fi
}

CMD='git commit -m "feat: ✨ The real subject."'

echo "Usage and input:"
write_settings both
OUT=$(approve); STATUS=$?
expect_status "no arguments is a usage error" 2 "$STATUS"
case "$OUT" in *usage:*) ok "...and it prints the usage line" ;; *) bad "no usage line" ;; esac

OUT=$(approve "../../etc/passwd"); STATUS=$?
expect_status "a path-shaped id is refused" 1 "$STATUS"
case "$OUT" in *"not a request id"*) ok "...and it says why" ;; *) bad "no reason given" ;; esac

OUT=$(approve "NOTHEXAT-ALL"); STATUS=$?
expect_status "a non-hex id is refused" 1 "$STATUS"

echo "The permission rules are what make the prompt, so their absence stops everything:"
ID=$(gate_request_id "$CMD")
if [ -n "$ID" ]; then ok "the gate issued a request id"; else bad "the gate issued no request id"; fi

write_settings none
OUT=$(approve "$ID"); STATUS=$?
expect_status "no ask rules in settings, no approval" 1 "$STATUS"
case "$OUT" in *"permission rules"*) ok "...and it names the missing rules" ;; *) bad "it does not name the rules" ;; esac
check_verdict=$(gate_verdict "$CMD")
if [ "$check_verdict" = deny ]; then ok "...and the commit is still denied"; else bad "the commit was approved anyway"; fi

write_settings home-only
OUT=$(approve "$ID"); STATUS=$?
expect_status "one rule of the two is not enough" 1 "$STATUS"
if [ "$(gate_verdict "$CMD")" = deny ]; then ok "...and the commit is still denied"; else bad "the commit was approved anyway"; fi

echo "Only the installed copy can approve — the rules name that path and no other:"
write_settings both
OUT=$(env -u WORKBENCH_COMMIT_APPROVAL_DIR -u WORKBENCH_SETTINGS_FILE HOME="$HOME_DIR" TMPDIR="$SANDBOX" \
  bash "$SRC" "$ID" 2>&1); STATUS=$?
expect_status "the plugin-cache copy refuses to approve" 1 "$STATUS"
case "$OUT" in *"permission rules name"*) ok "...and it says which path is the sanctioned one" ;; *) bad "it does not explain the path" ;; esac
if [ "$(gate_verdict "$CMD")" = deny ]; then ok "...and the commit is still denied"; else bad "the commit was approved anyway"; fi

mv "$INSTALLED" "$INSTALLED.away"
OUT=$(env -u WORKBENCH_COMMIT_APPROVAL_DIR -u WORKBENCH_SETTINGS_FILE HOME="$HOME_DIR" TMPDIR="$SANDBOX" \
  bash "$SRC" "$ID" 2>&1); STATUS=$?
expect_status "an uninstalled gate approves nothing" 1 "$STATUS"
case "$OUT" in *"not installed"*) ok "...and it points at setup" ;; *) bad "it does not point at setup" ;; esac
mv "$INSTALLED.away" "$INSTALLED"

echo "The id must name a commit that is actually waiting:"
OUT=$(approve "0123456789abcdef"); STATUS=$?
expect_status "an id with no pending record is refused" 1 "$STATUS"
case "$OUT" in *"no commit is waiting"*) ok "...and it says so" ;; *) bad "it does not say so" ;; esac

echo "The subject in the prompt has to be the real one:"
OUT=$(approve "$ID" "feat: something else entirely"); STATUS=$?
expect_status "a subject absent from the command is refused" 1 "$STATUS"
case "$OUT" in *"does not appear in the command"*) ok "...and it prints the real command" ;; *) bad "it does not print the real command" ;; esac
if [ "$(gate_verdict "$CMD")" = deny ]; then ok "...and the commit is still denied"; else bad "the commit was approved anyway"; fi

echo "End to end — deny, approve, commit once:"
ID=$(gate_request_id "$CMD")
OUT=$(approve "$ID" "feat: ✨ The real subject."); STATUS=$?
expect_status "a true subject is approved" 0 "$STATUS"
# The receipt names the COMMIT and never the command. The command has already
# been on screen twice by this point, and printing it a third time is how a
# sixty-line heredoc ended up filling the session twice over.
case "$OUT" in
  *"✅ Approved: feat: ✨ The real subject."*) ok "...and the receipt names the commit it covers" ;;
  *) bad "the receipt does not name the commit: $OUT" ;;
esac
case "$OUT" in
  *"$CMD"*) bad "the receipt reprints the whole command again" ;;
  *) ok "...without reprinting the command" ;;
esac
case "$OUT" in
  *"expires in 15 minutes"*) ok "...and still says the approval is one commit, briefly" ;;
  *) bad "the receipt lost the expiry" ;;
esac
if [ "$(gate_verdict "$CMD")" = silent ]; then ok "...and the gate lets that commit through"; else bad "the gate still denied the approved commit"; fi
if [ "$(gate_verdict "$CMD")" = deny ]; then ok "...once, and only once"; else bad "the approval survived the commit it covered"; fi

echo "A sub-agent has nothing here to approve, and nobody else's to spend:"
# The reason this command exists is a prompt a human answers. A sub-agent has no
# human attached, so the gate refuses it outright and issues it no id — there is
# no argument it could pass this script that names a waiting commit of its own.
SUB_CMD='git commit -m "feat: ✨ From a sub-agent."'
SUB_ID=$(gate_request_id "$SUB_CMD" "agent-sub")
if [ -z "$SUB_ID" ]; then
  ok "a refused sub-agent is issued no request id"
else
  bad "the gate issued a sub-agent the request id $SUB_ID"
fi

# The one id that does exist for that command belongs to the foreground session.
# Approving it is legitimate, and it still does the sub-agent no good.
ID=$(gate_request_id "$SUB_CMD")
OUT=$(approve "$ID"); STATUS=$?
expect_status "the foreground can approve that same command" 0 "$STATUS"
if [ "$(gate_verdict "$SUB_CMD" "agent-sub")" = deny ]; then
  ok "...and the sub-agent is refused anyway"
else
  bad "the sub-agent spent an approval granted to the foreground"
fi
if [ "$(gate_verdict "$SUB_CMD")" = silent ]; then
  ok "...while the foreground's own approval survived that attempt"
else
  bad "the sub-agent's attempt burned the foreground's approval"
fi

echo "The subject is optional, and an approval covers only its own command:"
ID=$(gate_request_id "$CMD")
OUT=$(approve "$ID"); STATUS=$?
expect_status "approving without a subject works" 0 "$STATUS"
# With no label to echo, the receipt recovers the subject from the command's own
# -m value, so the human still reads back which commit they approved.
case "$OUT" in
  *"✅ Approved: feat: ✨ The real subject."*) ok "...and the receipt still names the commit" ;;
  *) bad "the receipt lost the commit when no subject was passed: $OUT" ;;
esac
case "$OUT" in
  *"$CMD"*) bad "the receipt reprints the whole command again" ;;
  *) ok "...without reprinting the command" ;;
esac
if [ "$(gate_verdict 'git commit -m "feat: a different commit"')" = deny ]; then
  ok "...and another command is still denied"
else
  bad "the approval leaked to another command"
fi

# A command whose message cannot be recovered still gets a receipt, naming the
# id. Display falls back; nothing about the approval itself depends on it.
AMEND='git -C /tmp/repo commit --amend --no-edit'
ID=$(gate_request_id "$AMEND")
OUT=$(approve "$ID"); STATUS=$?
expect_status "a commit with no -m is still approved" 0 "$STATUS"
case "$OUT" in
  *"✅ Approved request $ID."*) ok "...and the receipt falls back to the request id" ;;
  *) bad "the no-message receipt is not the id fallback: $OUT" ;;
esac

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
