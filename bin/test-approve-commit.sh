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

echo "A message that lives in a file, in every spelling git accepts:"
# The shape this covers is the one an agent should prefer: the gate makes the
# commit run twice, so a message written inline is printed twice in full in the
# human's transcript. The subject still has to be the real one, and with the
# message in a file the only place to read it is that file.
MSG_DIR="$SANDBOX/messages"
mkdir -p "$MSG_DIR"
SUBJECT='feat: ✨ A subject that lives in a file.'
printf '%s\n\nA body paragraph no receipt ever shows.\n' "$SUBJECT" > "$MSG_DIR/core.txt"

for SPELLING in "-F \"$MSG_DIR/core.txt\"" "--file=\"$MSG_DIR/core.txt\"" \
                "--file \"$MSG_DIR/core.txt\"" "-aF \"$MSG_DIR/core.txt\""; do
  FILE_CMD="git commit $SPELLING"
  ID=$(gate_request_id "$FILE_CMD")
  OUT=$(approve "$ID" "$SUBJECT"); STATUS=$?
  expect_status "the real subject is approved for ${SPELLING//$MSG_DIR/…}" 0 "$STATUS"
  case "$OUT" in
    *"✅ Approved: $SUBJECT"*) ok "...and the receipt names it" ;;
    *) bad "the receipt does not name the file's subject: $OUT" ;;
  esac
  if [ "$(gate_verdict "$FILE_CMD")" = silent ]; then
    ok "...and the gate lets that commit through"
  else
    bad "the gate still denied the approved commit"
  fi
done

FILE_CMD="git commit -F \"$MSG_DIR/core.txt\""
ID=$(gate_request_id "$FILE_CMD")
OUT=$(approve "$ID"); STATUS=$?
expect_status "approving a file-message commit without a subject works" 0 "$STATUS"
# Without a label there is nothing to echo, so the receipt has to go and find the
# subject — from the file this time, not from a -m value that is not there.
case "$OUT" in
  *"✅ Approved: $SUBJECT"*) ok "...and the receipt still names the file's subject" ;;
  *) bad "the receipt fell back instead of reading the file: $OUT" ;;
esac

echo "The subject is the line git will use, not just the file's first bytes:"
printf '\n\n%s\n' 'feat: ✨ After two blank lines.' > "$MSG_DIR/blanks.txt"
ID=$(gate_request_id "git commit -F \"$MSG_DIR/blanks.txt\"")
OUT=$(approve "$ID" 'feat: ✨ After two blank lines.'); STATUS=$?
expect_status "leading blank lines are skipped, as git's cleanup skips them" 0 "$STATUS"

TRAILING='fix: 🐛 Trailing spaces are not part of it.'
printf '%s   \nbody\n' "$TRAILING" > "$MSG_DIR/trailing.txt"
ID=$(gate_request_id "git commit -F \"$MSG_DIR/trailing.txt\"")
OUT=$(approve "$ID" "$TRAILING"); STATUS=$?
expect_status "trailing whitespace on the subject line does not block a match" 0 "$STATUS"
# git strips it before committing, so a receipt that kept it would be showing a
# subject the commit will not have.
ID=$(gate_request_id "git commit -F \"$MSG_DIR/trailing.txt\" --quiet")
OUT=$(approve "$ID"); STATUS=$?
expect_status "...and the same file approves with no subject passed" 0 "$STATUS"
case "$OUT" in
  *"Approved: $TRAILING   "*) bad "the receipt kept whitespace git will strip" ;;
  *"Approved: $TRAILING"*) ok "...with the receipt naming it as git will commit it" ;;
  *) bad "the receipt does not name the subject: $OUT" ;;
esac

# git's default cleanup for a -F message is `whitespace`, which keeps #commentary.
# So a file whose first line is a comment has that comment as its subject.
printf '# fix: 🐛 A hash is not a comment here.\nbody\n' > "$MSG_DIR/hash.txt"
ID=$(gate_request_id "git commit -F \"$MSG_DIR/hash.txt\"")
OUT=$(approve "$ID" '# fix: 🐛 A hash is not a comment here.'); STATUS=$?
expect_status "a first line starting with # is still the subject" 0 "$STATUS"

echo "A path the command builds out of a variable resolves:"
VAR_CMD="MSG=$MSG_DIR git commit -F \"\$MSG/core.txt\""
ID=$(gate_request_id "$VAR_CMD")
OUT=$(approve "$ID" "$SUBJECT"); STATUS=$?
expect_status "a variable the command assigns in front of git resolves" 0 "$STATUS"

SEMI_CMD="MSG=$MSG_DIR; git commit -F \"\$MSG/core.txt\""
ID=$(gate_request_id "$SEMI_CMD")
OUT=$(approve "$ID" "$SUBJECT"); STATUS=$?
expect_status "...and so does one left by a statement of its own" 0 "$STATUS"

# HOME is in this process's environment, and it is the sandbox's HOME, so a
# $HOME path resolves inside the sandbox and nowhere near the real home.
cp "$MSG_DIR/core.txt" "$HOME_DIR/home-msg.txt"
ID=$(gate_request_id 'git commit -F "$HOME/home-msg.txt"')
OUT=$(approve "$ID" "$SUBJECT"); STATUS=$?
expect_status "a variable from the environment resolves" 0 "$STATUS"

echo "Every path that cannot be resolved or read refuses, and names its case:"
# Same two assertions as every other refusal here: the exit status, and the
# commit still being denied afterwards.
refuses() { # refuses <desc> <command> <expected-phrase> [subject]
  local desc="$1" cmd="$2" phrase="$3" subject="${4-}" id out status
  id=$(gate_request_id "$cmd")
  if [ -n "$subject" ]; then
    out=$(approve "$id" "$subject"); status=$?
  else
    out=$(approve "$id"); status=$?
  fi
  expect_status "$desc" 1 "$status"
  case "$out" in
    *"$phrase"*) ok "...and it names that case" ;;
    *) bad "it does not name the case ($phrase): $out" ;;
  esac
  if [ "$(gate_verdict "$cmd")" = deny ]; then
    ok "...and the commit is still denied"
  else
    bad "the commit was approved anyway"
  fi
}

refuses "an absent message file is refused" \
  "git commit -F \"$MSG_DIR/gone.txt\"" "cannot be read"
refuses "a message file that is a directory is refused" \
  "git commit -F \"$MSG_DIR\"" "cannot be read"
printf '\n   \n\n' > "$MSG_DIR/blank.txt"
refuses "a file with no message in it is refused" \
  "git commit -F \"$MSG_DIR/blank.txt\"" "holds no message"
refuses "a relative path is refused, because the record does not say from where" \
  "git commit -F core.txt" "is relative"
refuses "a path naming a variable nothing here knows is refused" \
  'git commit -F "$NOTHING_SETS_THIS/core.txt"' 'names $NOTHING_SETS_THIS'
refuses "a path the shell would have to build is refused, never run" \
  'git commit -F "$(cat /nowhere/path.txt)"' "built by the shell"
refuses "a message read from standard input is refused" \
  "git commit -F -" "standard input"
refuses "...in the long spelling too" \
  "git commit --file=- --amend" "standard input"

# Each of those refuses whether or not a subject was passed: the refusal is that
# nothing can name the commit, which is true before any label is considered.
refuses "an absent file is refused with a subject passed as well" \
  "git commit -F \"$MSG_DIR/also-gone.txt\"" "cannot be read" "$SUBJECT"

echo "A subject that disagrees with the file is refused, and a path fragment is not a subject:"
refuses "a subject the file does not carry is refused" \
  "git commit -F \"$MSG_DIR/core.txt\" --no-verify" \
  "not the one in this commit's message file" "feat: ✨ Some other commit entirely."
# The old check asked whether the label appears in the command text. Against a
# -F command that text is a path, so "core" would have passed as a subject while
# the commit said something else. With the message in a file, the file's own
# first line is the only thing a label may be.
refuses "a fragment of the path is refused as a subject" \
  "git commit -F \"$MSG_DIR/core.txt\" --quiet" \
  "not the one in this commit's message file" "core"

echo "The file is display; the recorded command is still the decision:"
FILE_CMD="git commit -F \"$MSG_DIR/core.txt\" --signoff"
ID=$(gate_request_id "$FILE_CMD")
OUT=$(approve "$ID" "$SUBJECT"); STATUS=$?
expect_status "a file-message commit is approved" 0 "$STATUS"
if [ "$(gate_verdict "git commit -F \"$MSG_DIR/core.txt\" --signoff --amend")" = deny ]; then
  ok "...and another command naming the same file is still denied"
else
  bad "the approval leaked to another command reading the same file"
fi
# Rewriting the file does not void the approval, because no approval was ever a
# decision about the file's contents. Stated plainly so the trade is on the
# record: between the prompt and the commit, a rewritten file changes the
# message without changing the command, and the command is what was approved.
printf 'feat: ✨ Rewritten after the approval.\n' > "$MSG_DIR/core.txt"
if [ "$(gate_verdict "$FILE_CMD")" = silent ]; then
  ok "...while the approved command itself still goes through"
else
  bad "rewriting the file voided an approval that was never about the file"
fi
printf '%s\n\nA body paragraph no receipt ever shows.\n' "$SUBJECT" > "$MSG_DIR/core.txt"

echo "A message file is caller-controlled input, so the receipt prints it at arm's length:"
printf 'feat: \033[2J and an escape sequence.\nbody\n' > "$MSG_DIR/escape.txt"
ID=$(gate_request_id "git commit -F \"$MSG_DIR/escape.txt\"")
OUT=$(approve "$ID"); STATUS=$?
expect_status "a subject carrying a control character is still approved" 0 "$STATUS"
case "$OUT" in
  *$'\033'*) bad "the receipt passed an escape sequence to the terminal" ;;
  *) ok "...with the escape sequence neutralised in the receipt" ;;
esac
case "$OUT" in
  *"✅ Approved: feat: "*) ok "...and the rest of the subject still shown" ;;
  *) bad "the receipt lost the subject: $OUT" ;;
esac
# ...and passing that same line as the subject does not smuggle it through either:
# with the message in a file, the receipt names the file's line, not the label.
ID=$(gate_request_id "git commit -F \"$MSG_DIR/escape.txt\" --quiet")
OUT=$(approve "$ID" "$(printf 'feat: \033[2J and an escape sequence.')"); STATUS=$?
expect_status "the same subject passed as a label is approved" 0 "$STATUS"
case "$OUT" in
  *$'\033'*) bad "a label echoed the escape sequence straight back" ;;
  *) ok "...with the receipt still naming the file's line, neutralised" ;;
esac

python3 -c 'import sys; sys.stdout.write("feat: " + "x" * 400 + "\n")' > "$MSG_DIR/long.txt"
ID=$(gate_request_id "git commit -F \"$MSG_DIR/long.txt\"")
OUT=$(approve "$ID"); STATUS=$?
expect_status "a runaway first line is still approved" 0 "$STATUS"
case "$OUT" in
  *"…"*) ok "...with the receipt cut short rather than filling the transcript" ;;
  *) bad "the receipt printed the whole runaway line" ;;
esac

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
