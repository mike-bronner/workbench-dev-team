#!/bin/bash
# Local-review guard (PreToolUse: Agent and Bash; PostToolUse: Agent).
#
# Holmes's Local mode reviews the human's live working directory. The
# uncommitted change in that directory is the ONLY copy of the work, so a
# reviewer that writes to it destroys the thing it was sent to read. The rule
# was already stated in Holmes's prompt, in his reference, and verbatim in every
# sub-agent prompt Local mode dispatches — and on the mode's first real exercise
# a lens sub-agent ran `chmod` against that directory anyway and changed a
# script from 755 to 644. Prose in an agent prompt is advisory. This hook is not.
#
# It is a sibling of commit-approval-gate.sh, never an extension of it: that
# gate's lanes and its approval records are load-bearing for every commit in
# this repository, and they are left exactly as they are. What is borrowed is
# its reasoning, including the two traps its header records.
#
# ── WHAT IT DOES ──────────────────────────────────────────────────────────────
#
#   ARM     PreToolUse on the Agent tool. When a session dispatches Holmes with
#           a prose brief (Local mode), a record is written for that SESSION,
#           naming the `Workdir:` the brief protects.
#   ENFORCE PreToolUse on Bash. A Bash call from a SUB-AGENT of an armed session
#           is refused when the command mutates a working tree. Reads and test
#           runs are untouched.
#   DISARM  PostToolUse on the Agent tool. The Holmes dispatch returned, so the
#           record is released. A TTL covers the run that never returns.
#
# ── THE SIGNAL, AND WHY IT IS NOT A MARKER FILE ───────────────────────────────
#
# Two harness-supplied fields decide it, and nothing else: `session_id` and
# `agent_id`. The agent supplies neither, so neither can be forged by the
# command being inspected.
#
# The record is keyed by session id, so it binds the session that dispatched the
# review and no other. A bare "a local review is in progress" marker would be
# the commit gate's `/tmp/watson.lock` leak with the sign flipped: that file
# answered "is a pipeline running on this host?" instead of "is THIS process the
# pipeline?", and wrongly EXEMPTED every concurrent session. A host-wide review
# marker would wrongly GAG them — the human's own editing in another window
# would start failing while a review ran. Do not reintroduce one. The state
# directory is shared, but every record in it is answerable only to one session
# id; a record grants nothing, so sharing the directory cannot leak a capability
# the way a shared approval directory would.
#
# Enforcement also requires a non-empty `agent_id`, which means a sub-agent. The
# main thread of the dispatching session keeps editing its own tree while the
# review reads it, which is the difference between a guard and a lock. `agent_id`
# is the same field the commit gate settled on, for the same reason: the harness
# supplies it, and it is empty for a main session and non-empty for every
# sub-agent.
#
# ── THE VERDICT IS "deny" ─────────────────────────────────────────────────────
#
# Of the three verdicts a hook can return, only "deny" binds. The commit gate
# returned "ask" for its entire life and never stopped a single commit: a hook's
# "ask" is classifier-approvable, so under permissions.defaultMode "auto" the
# auto-mode classifier answered it and no human was ever prompted. The same is
# true here, so nothing below ever returns "ask".
#
# ── WHAT COUNTS AS MUTATION: A RULE, NOT A ROSTER ─────────────────────────────
#
# A local review reads the tree constantly and runs the repository's own suite.
# A rule that stops either one makes the mode useless and gets switched off, so
# the line is drawn at commands whose PURPOSE is to change a file's content,
# location, existence, or metadata:
#
#   1. git, inverted. GIT_READ_ONLY below lists the verbs that only read; every
#      other git verb is refused. The inversion is the point. A roster of
#      forbidden spellings rots as tooling adds synonyms — `git restore` shipped
#      years after `git checkout --` and slipped through the roster this guard
#      replaces, while being the single most destructive command available here:
#      it discards precisely the uncommitted change the mode exists to read. A
#      verb git invents tomorrow is refused by this rule on the day it ships,
#      and a verb missing from the read-only set costs a denied read, never an
#      allowed write.
#   2. Metadata and destruction, whatever the tool: chmod, chown, chgrp, rm,
#      rmdir, unlink, mv, shred, truncate. `chmod` is in there because it is
#      what the measured breach used. A review has no legitimate call for any of
#      them, so these are refused outright rather than by target path — parsing
#      which path an arbitrary command writes to is where the false negatives
#      hide.
#   3. In-place rewriting: a formatter or linter run with --write / --fix /
#      --in-place, and sed / perl / ruby with -i. Bare `-i` is checked ONLY for
#      those three commands, because `grep -i` is a legitimate review command
#      and a blanket `-i` rule would break the mode it protects. Within those
#      three it is checked wherever it sits in a single-dash cluster, not only
#      as a whole token: `perl -pi -e` is the commonest spelling of an in-place
#      Perl edit, and a whole-token match let every clustered form through. The
#      cluster is read left to right and stops at the first switch that takes
#      the rest of the token as its value, so `perl -pes/i/j/` stays allowed —
#      that `i` is program text, not a flag. Which letter means in-place is read
#      per interpreter from the same table as those terminators, because the
#      interpreters disagree: `-I` is an in-place edit to BSD and macOS sed and
#      is refused there, while to perl and ruby it names an include directory,
#      so `perl -Ilib -ne print` stays allowed.
#   4. Redirection into a protected tree. `> file` is checked by target path,
#      not refused outright, because `git diff HEAD > /tmp/scratch.diff` is
#      ordinary review work. A relative target is resolved against the payload's
#      `cwd`; when no cwd is supplied it is treated as inside the tree, because
#      the safe answer to "which tree is this relative to?" is the one under
#      review.
#
# ── WHAT IT DOES NOT COVER ────────────────────────────────────────────────────
#
# Stated plainly, because a guard whose limits are unwritten gets trusted past
# them:
#
#   • It is not anti-evasion machinery. Like its sibling gate it reads the
#     command the agent asked to run, so a verb inside `bash -c`, inside a
#     script, or behind command substitution is not its subject. That is also
#     what lets the repository's own suite run: `bash run-tests.sh` is one
#     token here, and the temporary files the suite writes are invisible to it.
#     A guard tight enough to see them would be tight enough to stop the suite.
#   • It does not cover a local review a foreground session performs inline,
#     because such a call carries no agent_id. Local mode is dispatched as a
#     sub-agent, so this is the shape the mode does not have rather than a hole
#     in the shape it does.
#   • It does not cover a review that was never armed — a Holmes dispatch whose
#     brief carries no recognizable prompt, or an Agent tool that stops
#     reporting `subagent_type` and `prompt` in `tool_input`. Both fail open,
#     silently, and the prose prohibition is what stands in those cases. That is
#     why this hook was added BESIDE the prose and not instead of it.
#   • While a record is live, EVERY sub-agent of that session is held to the
#     read-only rule, not only the review's own. Two agents mutating the tree a
#     third is reviewing is not a workflow worth protecting, and the window is
#     bounded by the disarm and by GUARD_TTL_SECONDS.
#   • Editing tools are not matched, only Bash. Holmes holds no Edit, Write, or
#     NotebookEdit grant, and neither do the lenses he dispatches, so Bash is
#     the whole surface. Grant him one and this matcher must widen with it.
#
# ── HOW THE REFUSAL IS WORDED ─────────────────────────────────────────────────
#
# Split across the two channels a hook has, measured on Claude Code 2.1.274
# (insights/2026-09-17-hook-message-channels-measured.md in the memory vault).
# `permissionDecisionReason` becomes the tool_result and is the text a PERSON
# reads, so it is ONE line naming the action that was gated.
# `additionalContext` survives a deny and arrives in its own block that only the
# model reads, so every recovery instruction lives there. Nothing is cut; it
# stops being in the human's way. Same shape as commit-approval-gate.sh, which
# is the sibling this borrows its reasoning from.
#
# Exit 0 with no output = no opinion (normal permission flow applies).
# Exit 0 with permissionDecision "deny" = the harness refuses the call.
#
# `--classify` reads one command on stdin and exits 0 (allowed) or 1 (refused),
# printing the REASON half — the sentence, not the short action label. It is the
# same classifier the enforce path runs, exposed so
# agents/lint-holmes-local-mode.sh can hold the shipped documentation to the
# shipped rule instead of keeping a second copy of the roster.

set -u

# Pipeline carve-out, checked first and for the same reason as the commit gate's:
# the scheduled Index pipeline is the board's only review path, it never reviews
# a live working tree, and it must not inherit a rule written for one.
if [ "${WORKBENCH_DEV_TEAM_PIPELINE:-0}" = "1" ]; then
  exit 0
fi

GUARD_MODE=hook
if [ "${1:-}" = "--classify" ]; then
  GUARD_MODE=classify
fi
export GUARD_MODE

# Capture stdin before the heredoc below claims it for the python program.
GUARD_STDIN="$(cat)"
export GUARD_STDIN

# HOME is the normal home for this state. Unlike the commit gate, an unaddressable
# HOME falls back to the temp directory rather than refusing: a record here is a
# RESTRICTION keyed to one session, so a shared directory cannot hand anybody a
# capability. The worst a planted record does is hold one session's sub-agents to
# reading, which is the direction this guard already fails in.
if [ -n "${WORKBENCH_LOCAL_REVIEW_DIR:-}" ]; then
  GUARD_STATE_DIR="$WORKBENCH_LOCAL_REVIEW_DIR"
elif [ -n "${HOME:-}" ]; then
  GUARD_STATE_DIR="$HOME/.claude-workbench/local-reviews"
else
  GUARD_STATE_DIR="${TMPDIR:-/tmp}/workbench-local-reviews"
fi
export GUARD_STATE_DIR

python3 - <<'PYEOF'
import hashlib
import json
import os
import re
import sys
import time

# How long a record stands without being released. It only has to outlast the
# slowest review — a fan-out review is budget-capped and measures in minutes,
# not hours — and its only cost is that a review which died without returning
# holds that one session's sub-agents to reading for the remainder.
GUARD_TTL_SECONDS = 7200

# Swept on any run. Every record this old is long dead, and the sweep keeps the
# directory from growing by one file per review forever.
RECORD_MAX_AGE_SECONDS = 86400

# git verbs that only read. This set is the rule's membership, and it is the only
# place it is enumerated: every other git verb is refused. Adding a verb here is
# a claim that it cannot change a file, an index, or a ref.
GIT_READ_ONLY = {
    "annotate", "blame", "cat-file", "check-attr", "check-ignore", "count-objects",
    "describe", "diff", "diff-index", "diff-tree", "for-each-ref", "grep", "log",
    "ls-files", "ls-tree", "merge-base", "name-rev", "reflog", "rev-list",
    "rev-parse", "shortlog", "show", "show-ref", "status", "symbolic-ref", "var",
    "verify-commit", "verify-tag", "whatchanged",
}

# Commands whose purpose is to change a file's content, location, existence, or
# metadata. `chmod` heads the list because it is what the measured breach used.
MUTATING_COMMANDS = {
    "chmod", "chown", "chgrp", "rm", "rmdir", "unlink", "mv", "shred", "truncate",
}

# Commands that run another command, and are stepped through to find it.
PASS_THROUGH = {"command", "builtin", "exec", "sudo", "nohup", "time", "env", "xargs"}

# Rewrite-in-place flags, in their unambiguous long forms. `-i` is NOT here: it
# means "ignore case" to grep and "in place" to sed, and refusing it everywhere
# would break the reading this guard exists to permit.
IN_PLACE_FLAGS = {"--write", "--fix", "--in-place"}

# The three commands where a bare `-i` does mean "edit the file in place". Each
# is mapped to BOTH halves of the rule at once: the letters that mean in-place
# for that interpreter, and the single-letter switches that take the REST OF
# THEIR TOKEN as a value. One table, not three rosters — every half of the rule
# is read from a single subscript, so a fourth interpreter added here cannot be
# present in one lookup and missing from another. That drift raises KeyError,
# which crashes a PreToolUse hook, and a crashed hook fails OPEN.
#
# Both halves are per-interpreter for the same reason: the interpreters differ.
#
# IN-PLACE LETTERS. `i` everywhere. `I` for sed ONLY, where BSD and macOS sed
# make `-I` an in-place edit exactly like `-i` and neither GNU nor BSD sed has
# any other meaning for it — GNU sed rejects `-I` outright, so refusing it costs
# nothing there either. `I` is deliberately NOT an in-place letter for perl or
# ruby, where it is an include directory: refusing `perl -Ilib -ne print` would
# break the legitimate reading this guard exists to permit.
#
# TERMINATORS. These end the flag part of a cluster. After one of them the
# remaining characters are an argument, so an `i` among them is not a flag.
# `perl -pes/i/j/` is the case that makes this necessary — the joined form of a
# read-only one-liner, where `e` takes `s/i/j/` as the program. Worked out from
# each interpreter's documented switches: perl's -e/-E/-F/-I/-m/-M/-x (perlrun),
# ruby's -e/-C/-E/-F/-I/-r/-x, and sed's -e/-f.
#
# Switches that consume only digits or a fixed letter set are deliberately
# ABSENT — perl's -0/-l/-C, ruby's -K/-T/-W, and sed's -l. More flags can follow
# them inside the same token (`perl -lpi -e` is a real in-place edit), so
# treating them as terminators would reopen the hole this closes. sed's `-l` is
# the measured case: GNU `sed -l N` takes a line length, but BSD and macOS sed
# make `-l` line-buffered and take no argument at all, so a joined `sed -li` is
# a genuine in-place edit. Listing `l` as a terminator let it through. A joined
# GNU `-l` can only be followed by digits, and no digit is an `i`, so dropping
# it refuses nothing a reader would type. Leaving a terminator out costs a
# refused read, never an allowed write, which is the direction this guard
# already fails in.
IN_PLACE_EDITORS = {
    "sed": (set("iI"), set("ef")),
    "perl": (set("i"), set("eEFImMx")),
    "ruby": (set("i"), set("eCEFIrx")),
}

# git options that consume the next token as their value, so the verb search
# must step over both. Same shape as the commit gate's.
GIT_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}

SEGMENT_SPLIT = re.compile(r"\|\||&&|[|;\n&]")

# A redirect and its target. The lookbehind drops `2>&1`-style descriptor
# duplication, and targets starting with `&` or `(` are a descriptor and a
# process substitution rather than a file.
REDIRECT = re.compile(r"(?<![0-9<>])>>?\s*([^\s;|&<>]+)")

HOLMES_AGENT = re.compile(r"(^|[:/])holmes$", re.IGNORECASE)

# Holmes's own mode detection, as agents/holmes.md states it: The Index mode on
# an explicit item-id token, Local mode on everything else. Ambiguity resolving
# to Local is the safe direction here as well — Local is the mode that needs
# guarding, so the reading that arms is the reading that protects.
ITEM_ID_TOKEN = re.compile(r"^\s*Item\s+ID:\s*\d+\b", re.IGNORECASE | re.MULTILINE)
BARE_ID_TOKEN = re.compile(
    r"^(?:\d+|PVTI_[A-Za-z0-9_-]+|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$",
    re.IGNORECASE,
)
WORKDIR_SLOT = re.compile(r"^[ \t]*Workdir:[ \t]*(\S+)", re.MULTILINE)

STATE_DIR = os.environ.get("GUARD_STATE_DIR", "")


def leading_positionals(tokens, opts_with_arg, want):
    """The first `want` non-option tokens, stepping over flags and their values."""
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


def rewrites_in_place(name: str, args: list) -> bool:
    """True when a sed/perl/ruby argument list carries the in-place switch.

    Every single-dash cluster is walked left to right. An in-place letter counts
    while the characters before it are still flags, and stops counting once a
    switch that swallows the rest of the token has been passed — at that point
    the letter is inside that switch's value. So `perl -pi -e`, `perl -lpi -e`,
    `sed -ie`, `sed -I`, `sed -li` and `perl -pi.bak -e` are all in-place edits,
    while `perl -pes/i/j/` and `perl -Ilib -ne print` are read-only one-liners
    and stay allowed.

    Both letter sets come from one subscript, so neither can be looked up for an
    interpreter the other does not know.
    """
    in_place, terminators = IN_PLACE_EDITORS[name]
    for arg in args:
        if arg.startswith("--"):
            # IN_PLACE_FLAGS below catches `--in-place` for any command. It is
            # answered here as well so these three keep the `sed -i` action
            # label rather than the generic rewrite-flag one.
            if arg.startswith("--in-place"):
                return True
            continue
        if not arg.startswith("-"):
            continue
        for char in arg[1:]:
            if char in in_place:
                return True
            if char in terminators:
                break
    return False


def under(path: str, root: str) -> bool:
    """True when `path` is `root` or sits inside it."""
    path = os.path.normpath(path)
    root = os.path.normpath(root)
    return path == root or path.startswith(root.rstrip("/") + "/")


def classify(command: str, roots: list, cwd: str):
    """`(action, reason)` for a refused command, or None when it may run.

    `action` is the short label the human line names — what they tried to do,
    in two or three words. `reason` is the sentence explaining it, which goes to
    the model. Adding a rule here means writing both.

    Every segment is examined, never only the first: `git status && chmod 644 x`
    mutates the tree as surely as `chmod` alone does.
    """
    for segment in SEGMENT_SPLIT.split(command):
        tokens = segment.strip().split()
        # Step over environment assignments and wrappers to reach the real command.
        # A wrapper's own flags are stepped over too, so `xargs -0 rm` is seen as
        # `rm`; a wrapper flag that takes a separate value is not, and sits on the
        # far side of the boundary this guard already declines to police.
        wrapped = False
        while tokens:
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]) or tokens[0] in PASS_THROUGH:
                wrapped = wrapped or tokens[0] in PASS_THROUGH
            elif not (wrapped and tokens[0].startswith("-")):
                break
            tokens.pop(0)
        if tokens:
            name = os.path.basename(tokens[0])
            args = tokens[1:]

            if name == "git":
                verb = leading_positionals(args, GIT_OPTS_WITH_ARG, 1)
                if verb and verb[0] not in GIT_READ_ONLY:
                    return (
                        f"`git {verb[0]}`",
                        f"`git {verb[0]}` is not one of git's read-only verbs, so it is "
                        "refused. `git restore`, `checkout`, `switch`, `reset`, `clean`, "
                        "and `stash` all discard exactly the uncommitted change you were "
                        "sent to read.",
                    )
            elif name in MUTATING_COMMANDS:
                return (
                    f"`{name}`",
                    f"`{name}` changes a file's content, location, existence, or "
                    "metadata. A review does none of those.",
                )
            elif name == "find" and ("-delete" in args or "-exec" in args or "-execdir" in args):
                return (
                    "`find` deleting or executing",
                    "`find` is deleting or executing against the files it matches.",
                )

            if name in IN_PLACE_EDITORS and rewrites_in_place(name, args):
                return (f"`{name} -i`", f"`{name} -i` rewrites the file in place.")
            if any(a.split("=", 1)[0] in IN_PLACE_FLAGS for a in args):
                return (
                    f"`{name}` with a rewrite flag",
                    f"`{name}` is being run with a rewrite flag. Run formatters and "
                    "linters in check mode only.",
                )

        # Only meaningful once a tree is named. With no root to compare against,
        # a redirect has nothing it could be inside of.
        for target in REDIRECT.findall(segment) if roots else []:
            if target.startswith(("&", "(")):
                continue
            if not os.path.isabs(target):
                if not cwd:
                    return (
                        "redirecting output into the tree under review",
                        f"the output is redirected to `{target}`, and no working "
                        "directory was supplied to resolve it against.",
                    )
                target = os.path.join(cwd, target)
            if any(under(target, root) for root in roots):
                return (
                    "redirecting output into the tree under review",
                    f"the output is redirected into the tree under review (`{target}`).",
                )
    return None


# --classify: commands on stdin, one line each, every refusal on stdout. The
# lint's entry point. No tree is named, so the redirect rule sits this one out
# and the command-position rules — which is what documentation can get wrong —
# are what answer.
if os.environ.get("GUARD_MODE") == "classify":
    refused = []
    for line in os.environ.get("GUARD_STDIN", "").splitlines():
        found = classify(line, [], "")
        if found:
            refused.append(f"{line.strip()} — {found[1]}")
    for line in refused:
        print(line)
    sys.exit(1 if refused else 0)

try:
    payload = json.loads(os.environ.get("GUARD_STDIN", ""))
except (json.JSONDecodeError, ValueError):
    sys.exit(0)  # unparseable input -> no opinion

session_id = str(payload.get("session_id") or "")
if not session_id or not STATE_DIR:
    # Without a session id there is nothing to key a record to, and no way to
    # tell a review's sub-agent from any other. Refusing every agent on the host
    # to cover a shape the harness has never produced is not the safe direction,
    # it is an outage.
    sys.exit(0)

record_path = os.path.join(
    STATE_DIR, hashlib.sha256(session_id.encode("utf-8", "surrogatepass")).hexdigest()[:16]
)


def read_record():
    try:
        with open(record_path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(record, dict):
        return {}
    try:
        if time.time() - float(record.get("armed_at", 0)) > GUARD_TTL_SECONDS:
            return {}
    except (TypeError, ValueError):
        return {}
    return record


def sweep():
    cutoff = time.time() - RECORD_MAX_AGE_SECONDS
    try:
        entries = os.listdir(STATE_DIR)
    except OSError:
        return
    for name in entries:
        stale = os.path.join(STATE_DIR, name)
        try:
            if os.path.isfile(stale) and os.path.getmtime(stale) < cutoff:
                os.unlink(stale)
        except OSError:
            continue


def write_record(record) -> None:
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        sweep()
        with open(record_path, "w", encoding="utf-8") as handle:
            json.dump(record, handle)
    except OSError:
        # Arming is best-effort, and a failure here fails open by design: the
        # prose prohibition still stands, and refusing the dispatch would turn
        # an unwritable directory into "no reviews run on this machine".
        pass


def is_local_holmes_dispatch(tool_input) -> bool:
    if not HOLMES_AGENT.search(str(tool_input.get("subagent_type") or "").strip()):
        return False
    prompt = str(tool_input.get("prompt") or "")
    if ITEM_ID_TOKEN.search(prompt):
        return False
    return not BARE_ID_TOKEN.match(prompt.strip())


event = str(payload.get("hook_event_name") or "")
tool_name = str(payload.get("tool_name") or "")
tool_input = payload.get("tool_input") or {}
if not isinstance(tool_input, dict):
    tool_input = {}

# ── ARM ───────────────────────────────────────────────────────────────────────
if event == "PreToolUse" and tool_name == "Agent":
    if is_local_holmes_dispatch(tool_input):
        record = read_record()
        roots = [r for r in record.get("roots", []) if isinstance(r, str)]
        found = WORKDIR_SLOT.search(str(tool_input.get("prompt") or ""))
        # A workdir only narrows the redirect check. A brief that states none
        # still arms; every other rule below is independent of the path.
        if found and os.path.isabs(found.group(1)) and found.group(1) not in roots:
            roots.append(found.group(1))
        try:
            holds = int(record.get("holds", 0))
        except (TypeError, ValueError):
            holds = 0
        write_record({
            "session_id": session_id,
            "roots": roots,
            # Counted, not flagged: a session can have two reviews in flight, and
            # the first to return must not release the second one's guard.
            "holds": max(holds, 0) + 1,
            "armed_at": time.time(),
        })
    sys.exit(0)

# ── DISARM ────────────────────────────────────────────────────────────────────
if event == "PostToolUse" and tool_name == "Agent":
    # Only a Holmes dispatch releases a hold. The lens sub-agents Holmes fans out
    # are Agent calls too, and one of them returning mid-review must not unlock
    # the tree the rest of them are still reading.
    if is_local_holmes_dispatch(tool_input):
        record = read_record()
        if record:
            try:
                holds = int(record.get("holds", 1)) - 1
            except (TypeError, ValueError):
                holds = 0
            if holds > 0:
                record["holds"] = holds
                write_record(record)
            else:
                try:
                    os.unlink(record_path)
                except OSError:
                    pass
    sys.exit(0)

# ── ENFORCE ───────────────────────────────────────────────────────────────────
if event != "PreToolUse" or tool_name != "Bash":
    sys.exit(0)

# A main session is never gagged. The human keeps working in the window that
# dispatched the review; only its sub-agents are held to reading.
if not str(payload.get("agent_id") or ""):
    sys.exit(0)

record = read_record()
if not record:
    sys.exit(0)

roots = [r for r in record.get("roots", []) if isinstance(r, str)]
command = str((tool_input or {}).get("command") or "")
found = classify(command, roots, str(payload.get("cwd") or ""))
if not found:
    sys.exit(0)

action, reason = found
target = roots[0] if roots else "the working directory under review"

# The refusal is split across the two channels a hook has, measured on Claude
# Code 2.1.274 (insights/2026-09-17-hook-message-channels-measured.md in the
# memory vault). `permissionDecisionReason` becomes the tool_result and is the
# text a PERSON reads, so it is ONE line naming the action that was gated.
# `additionalContext` survives a deny and reaches only the model, so the reason,
# the tree's path, and the allowed alternatives live there. No Markdown
# emphasis: whether a client renders it is unsettled, so the action is
# emphasised by position and by backticks, which read either way.
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"🛑 Blocked: {action}. A local review is reading this working tree."
        ),
        "additionalContext": (
            f"Local-review guard (workbench-dev-team). This command is refused, because "
            f"{reason}\n\n"
            f"A local review is in flight in this session, over `{target}`. That tree is the "
            "human's live working directory, and the uncommitted change in it is the only "
            "copy of the work — there is no branch, no clone, and no push to recover it "
            "from. A review reads it and runs the repository's suite. It writes nothing.\n\n"
            "Read it instead. `git status`, `git diff HEAD`, `git ls-files --others "
            "--exclude-standard`, and `git show` are all allowed, and so is the test suite. "
            "If a failure looks pre-existing, say so in your findings — never isolate it by "
            "changing the tree.\n\n"
            "There is no flag to clear and no path around this. If you believe you are not "
            "part of a local review, report that to the session that dispatched you and "
            "stop."
        ),
    }
}))
sys.exit(0)
PYEOF
