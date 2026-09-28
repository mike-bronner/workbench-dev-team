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
#   ENFORCE PreToolUse on Bash, Edit, Write, and NotebookEdit. A call from a
#           SUB-AGENT of an armed session is refused when it writes into the
#           tree under review. Reads and test runs are untouched.
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
# ── WHAT COUNTS AS MUTATION ──────────────────────────────────────────────────
#
# A local review reads the tree constantly and runs the repository's own suite.
# A rule that stops either one makes the mode useless and gets switched off, so
# the line is drawn at commands whose PURPOSE is to change a file's content,
# location, existence, or metadata. Rule 1 is a true rule. Rules 2 and 3 are
# fixed lists, and "WHAT IT DOES NOT COVER" below states what that costs:
#
#   1. git, inverted. GIT_READ_ONLY below lists the verbs that only read; every
#      other git verb is refused. The inversion is the point. A roster of
#      forbidden spellings rots as tooling adds synonyms — `git restore` shipped
#      years after `git checkout --` and slipped through the roster this guard
#      replaces, while being the single most destructive command available here:
#      it discards precisely the uncommitted change the mode exists to read. A
#      verb git invents tomorrow is refused by this rule on the day it ships,
#      and a verb missing from the read-only set costs a denied read, never an
#      allowed write. A few verbs that both read and write (branch, tag, remote,
#      config, stash, worktree) are allowed in their listing forms only, by
#      git_reads() — `git branch --show-current`, never `git branch -D x`.
#   2. Commands that write or remove files, from the fixed list
#      MUTATING_COMMANDS: chmod, chown, chgrp, rm, rmdir, unlink, mv, shred,
#      truncate, touch, tee, cp, ln, install, dd, patch, mkdir, rsync, tar,
#      unzip, sort, and uniq. `chmod` is in there because it is what the
#      measured breach used. The paths each one writes are read per command:
#      rsync's destination, the directory tar and unzip extract into (the
#      working directory when none is named) and the archive tar creates,
#      sort's -o value, and uniq's second operand. A listing form writes
#      nothing, so `tar -tf` and `unzip -l` stay allowed. Each is judged by the paths it writes, resolved
#      two ways: through every symlink, and with only the final name left
#      unresolved, because `rm <tree>/link` removes a link that lives in the
#      tree wherever it points. Refused when either is inside the tree under review or
#      contains it (`rm -rf ..`), and refused when a path cannot be resolved at
#      all — a variable, a glob, a quote, a relative path with no cwd, or
#      arguments fed by xargs. So `rm -rf /tmp/scratch` runs, and `rm -rf
#      "$DIR"` does not. An option's value is read as a path too, which can
#      only refuse more. With no tree named, nothing can be judged, so every
#      write is refused.
#   3. In-place rewriting: a formatter or linter run with --write / --fix /
#      --in-place; a common formatter run with its short write flag (gofmt,
#      goimports, gofumpt, shfmt, and prettier -w; clang-format, autopep8,
#      yapf, and swift-format -i; rubocop -a, -A, -x, and their long forms),
#      read anywhere in a single-dash cluster for the four whose parsers
#      bundle short flags (yapf, autopep8, prettier, rubocop), so `yapf -ir .`
#      and `rubocop -Da` are refused while `clang-format -sort-includes` is not;
#      a common formatter that writes with no flag at all and was not put in
#      check mode (black, rustfmt, cargo fmt, go fmt, ruff format, isort,
#      terraform fmt, mix format, dotnet format, deno fmt, zig fmt, stylua,
#      pint, php-cs-fixer fix), so `black --check`, `pint --test`, and
#      `cargo fmt --check` stay allowed, and so do their help and
#      config-printing forms and their stdin forms (`black -`, a bare
#      `rustfmt`), which write only to stdout; and sed / perl / ruby with -i.
#      A formatter is found behind a wrapper (`npx`, `env`) and behind a
#      project runner's run form (`bundle exec`, `uv run`, `poetry run`,
#      `pipx run`, `pnpm exec` and `dlx`, `npm exec`, `composer exec`, and
#      `yarn` with or without `exec`, `dlx`, or `run`). `command -v` is a lookup and runs
#      nothing, so it is never judged as the program it names.
#      Unlike rule 2, rule 3 is not judged by path: a formatter asked to write
#      is refused wherever it points. Bare `-i` is checked ONLY for
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
#      ordinary review work. The target goes through resolve(), as every write
#      path does: `~` is expanded, a relative target is resolved against the
#      payload's `cwd`, and a quoted, `$HOME`, or other shell-built target is
#      refused. When no cwd is known it is refused too, because the safe answer
#      to "which tree is this relative to?" is the one under review. A `cd`,
#      `pushd`, or `popd` makes cwd unknown for every segment after it.
#
# ── WHAT IT DOES NOT COVER ────────────────────────────────────────────────────
#
# Stated plainly, because a guard whose limits are unwritten gets trusted past
# them:
#
#   • It does not catch every program that writes. Rules 2 and 3 name the
#     ordinary file writers and the common formatters, and that is where they
#     stop: a program on neither list that writes into the tree runs silently.
#     The same holds for runners: a listed writer behind a runner not named in
#     RUNNERS (`uvx`, `bun x`, `pnpm <bin>`), or inside a package script
#     (`npm run format`), runs silently.
#     Code run inside an interpreter (`python -c`, `node -e`) is out of scope
#     for the reason the next point gives. The backstop for both is the lens
#     prompts' no-mutation rule and the human review of the diff. The rejected
#     alternative was a read allowlist, which refuses every command it does not
#     know. It would refuse reads too, and a guard that blocks reading gets
#     switched off. A writer found missing is added to the list.
#     Short write flags are read inside a cluster only for the four formatters
#     in FORMATTER_CLUSTER_FLAGS. A tool added to FORMATTER_WRITE_FLAGS whose
#     parser bundles short flags needs a row there too, or its clustered write
#     runs silently. A stdin form is read by its operands alone, so `black -l
#     88 -` is refused: `88` looks like a file operand.
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
#   • Editing tools are matched by path. Holmes and his lenses hold no Edit,
#     Write, or NotebookEdit grant, but any other sub-agent of the armed session
#     might, so an edit whose file path is inside the tree is refused, and so is
#     one whose path cannot be resolved or that arrives with no tree named.
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

# Fast path. With no review record anywhere on this host, nothing below can
# refuse a call or release a hold, so the one thing python3 is needed for is
# ARMING, and that takes an Agent call naming holmes. Everything else exits
# here, before python3 starts (about 48 ms on every Bash, Agent, and edit call).
# It errs toward the full check: a state directory it cannot list, a `\u`
# escape, or any non-ASCII byte (python folds `ſ` into `s`) goes on to python3.
#
# guard_has_records is true when the state directory holds any entry, or cannot
# be listed. It is host-wide on purpose: telling one session's record from
# another's takes python3.
guard_has_records() {
  local LC_ALL=C entry
  [ -d "$GUARD_STATE_DIR" ] || return 1
  [ -r "$GUARD_STATE_DIR" ] || return 0
  for entry in "$GUARD_STATE_DIR"/* "$GUARD_STATE_DIR"/.[!.]* "$GUARD_STATE_DIR"/..?*; do
    { [ -e "$entry" ] || [ -L "$entry" ]; } && return 0
  done
  return 1
}

if [ "$GUARD_MODE" = hook ]; then
  guard_needs_python() {
    guard_has_records && return 0
    local LC_ALL=C holmes_re='[Hh][Oo][Ll][Mm][Ee][Ss]' escape_re='\\u' wide_re='[^ -~]'
    [[ $GUARD_STDIN =~ $holmes_re || $GUARD_STDIN =~ $escape_re || $GUARD_STDIN =~ $wide_re ]]
  }
  guard_needs_python || exit 0
fi

# Without a working python3 the classifier never runs, and a hook that errors is
# a non-blocking error to the harness: the call runs as if no guard existed. So
# this path refuses on its own terms, and they are the guard's, not the commit
# gate's. The gate's fallback refuses text that names git, which is what the gate
# guards. This guard stops rm, mv, chmod, redirects, and edits into the tree, and
# none of those name git.
#
# Without python3 nothing can be judged: not the command, not the session a
# record belongs to, not its TTL. So while ANY record is on the host, every Bash
# and editing call from a sub-agent is refused. The main thread keeps its tools,
# as it always does. The three fields are read from the raw payload, where a
# quote inside a string is escaped, so command text cannot supply them.
#
# The cost is stated plainly: a stale record, or another session's, holds every
# sub-agent on the host to no Bash until python3 is fixed. That is a broken
# install, the refusal names the fix, and it is the direction this guard already
# fails in.
guard_python_fallback() {
  local p="$GUARD_STDIN"
  local event_re='"hook_event_name" *: *"PreToolUse"'
  local tool_re='"tool_name" *: *"(Bash|Edit|Write|NotebookEdit)"'
  local agent_re='"agent_id" *: *"[^"]'
  if guard_has_records && [[ $p =~ $event_re ]] && [[ $p =~ $tool_re ]] && [[ $p =~ $agent_re ]]; then
    printf '%s\n' "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"🛑 Blocked: this call. python3 is missing or failed, so the local-review guard cannot judge it.\", \"additionalContext\": \"Local-review guard (workbench-dev-team). A local review record exists on this host, and this hook judges calls with python3, which is not on PATH or exited with an error. It cannot tell a read from a write, or this session's review from another's, so it refuses every Bash and editing call from a sub-agent until python3 works. Report this to the human: python3 is a prerequisite of workbench-dev-team (see its README). Do not try another spelling of the call.\"}}"
  fi
  exit 0
}

# --classify is the lint's entry point, not a hook, so it reports the failure.
if ! command -v python3 >/dev/null 2>&1; then
  [ "$GUARD_MODE" = classify ] && { echo "python3 is missing" >&2; exit 2; }
  guard_python_fallback
fi

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
    "verify-commit", "verify-tag", "whatchanged", "ls-remote",
}

# Verbs that read in their listing forms and write in every other. git_reads()
# admits the listing form and nothing else, so a new flag is refused until it is
# named here.
BRANCH_READ_FLAGS = {"--show-current", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose",
                     "-l", "--list", "--no-color", "--contains", "--no-contains", "--merged",
                     "--no-merged", "--points-at"}
TAG_READ_FLAGS = {"-l", "--list", "-n", "--no-color", "--contains", "--no-contains", "--merged",
                  "--no-merged", "--points-at"}
LIST_VALUE_PREFIXES = ("--format=", "--sort=", "--contains=", "--no-contains=", "--merged=",
                       "--no-merged=", "--points-at=")
# The same options spelled with their value as the next word. git takes that
# word as the value (`git branch --contains <sha>`), so it is not a positional.
LIST_VALUE_FLAGS = {prefix[:-1] for prefix in LIST_VALUE_PREFIXES}
CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
                     "--get-color", "--get-colorbool"}
CONFIG_WRITE_FLAGS = {"--add", "--unset", "--unset-all", "--replace-all", "--rename-section",
                      "--remove-section", "--edit", "-e"}

# Commands whose purpose is to change a file's content, location, existence, or
# metadata. `chmod` heads the list because it is what the measured breach used.
# Each is judged by the paths write_targets() says it writes.
MUTATING_COMMANDS = {
    "chmod", "chown", "chgrp", "rm", "rmdir", "unlink", "mv", "shred", "truncate",
    "touch", "tee", "cp", "ln", "install", "dd", "patch",
    "mkdir", "rsync", "tar", "unzip", "sort", "uniq",
}

# Options that take the next word as their value, on both GNU and BSD, so the
# value is not read as a path. Only options that take a value on BOTH belong
# here: skipping a word after a flag that takes none would skip a real target.
# uniq's `-w` and the long forms are GNU only, and BSD uniq rejects them, so
# skipping their value can never skip a target there.
VALUE_OPTIONS = {
    "install": {"-m", "-o", "-g"},
    "truncate": {"-s", "-r"},
    "touch": {"-r", "-t", "-d"},
    "mkdir": {"-m"},
    "rsync": {"-e", "-f", "-T"},
    "uniq": {"-f", "-s", "-w", "--skip-fields", "--skip-chars", "--check-chars"},
}

# unzip options that only list, test, print, or show help, so nothing is extracted.
UNZIP_READ_FLAGS = set("lptvcZh")

# Formatters that rewrite files only when handed a write flag. IN_PLACE_FLAGS
# catches `--write`, `--fix`, and `--in-place` for every command, and nothing
# else, so any other spelling a formatter uses to write is listed here.
FORMATTER_WRITE_FLAGS = {
    "gofmt": {"-w"}, "goimports": {"-w"}, "gofumpt": {"-w"}, "shfmt": {"-w"},
    "prettier": {"-w"}, "clang-format": {"-i"}, "autopep8": {"-i"}, "yapf": {"-i"},
    "swift-format": {"-i"},
    "rubocop": {"-a", "-A", "-x", "--autocorrect", "--autocorrect-all", "--auto-correct",
                "--auto-correct-all", "--safe-auto-correct", "--fix-layout"},
}

# The formatters whose option parsers accept bundled short flags, so a write
# letter counts anywhere in a single-dash cluster (`yapf -ir`, `rubocop -Da`),
# read like IN_PLACE_EDITORS: (write letters, letters that take the rest of the
# token as their value). yapf and autopep8 use argparse, prettier minimist, and
# rubocop OptionParser. The cluster walk stops at a value letter, so the `i` in
# `yapf -l1-9i` is part of a line range. The Go-flag tools, clang-format, and
# swift-format do not bundle, and are matched on whole tokens only:
# `clang-format -sort-includes` is one long flag, not an `-i` in a cluster.
FORMATTER_CLUSTER_FLAGS = {
    "yapf": (set("i"), set("le")),
    "autopep8": (set("i"), set("jp")),
    "prettier": (set("w"), set()),
    "rubocop": (set("aAx"), set("corfCs")),
}

# Options naming the file a formatter reading stdin reports on. Their value is
# a label, not a file operand, so `black --stdin-filename x.py -` still writes
# only to stdout.
STDIN_NAME_OPTIONS = {"--stdin-filename", "--filename"}

# Formatters that rewrite files with no flag at all, keyed by program or by
# program and subcommand, each with the options that make it only check. An
# option with its value is matched as `option=value` whichever way it was typed,
# and an option listed bare matches whatever value it carries. Printing a
# formatter's config, or formatting a string it was handed, rewrites no file.
FORMATTERS_WRITING_BY_DEFAULT = {
    "black": {"--check", "--diff", "-c", "--code"},
    "rustfmt": {"--check", "--emit=stdout", "--print-config"},
    "cargo fmt": {"--check"},
    "go fmt": {"-n"},
    "ruff format": {"--check", "--diff"},
    "isort": {"--check-only", "--check", "-c", "--diff", "--show-config", "--show-files",
              "--stdout", "-d"},
    "terraform fmt": {"-check", "-write=false"},
    "mix format": {"--check-formatted", "--dry-run"},
    "dotnet format": {"--verify-no-changes"},
    "deno fmt": {"--check"},
    "zig fmt": {"--check"},
    "stylua": {"--check"},
    "pint": {"--test"},
    "php-cs-fixer fix": {"--dry-run"},
}

# `rustfmt --print-config default|minimal PATH` writes the config to PATH. Only
# `current`, or no PATH, prints it.
RUSTFMT_CONFIG_FILE_KINDS = {"default", "minimal"}

# Values that turn a boolean option off.
OFF_VALUES = {"false", "f", "0", "no", "off"}

# Asking a formatter about itself writes nothing.
FORMATTER_INFO_FLAGS = {"-h", "--help", "-V", "--version"}

# A path holding any of these is shell the guard does not expand: a variable, a
# substitution, a glob, a brace, a quote, or an escape. It cannot be resolved,
# so the write it names is refused.
UNRESOLVABLE = re.compile(r"[$`*?\[\]{}()'\"\\<>]")

# The editing tools, and the input field each one names its file in.
EDIT_TOOLS = {"Edit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path"}

# Commands that run another command, and are stepped through to find it.
PASS_THROUGH = {"command", "builtin", "exec", "sudo", "nohup", "time", "env", "xargs",
                "npx", "bunx", "pnpx"}

# Project runners, each with the subcommands that run another command. The pair
# is stepped through like a wrapper, so `bundle exec rubocop -a` is seen as
# `rubocop -a`. Any other subcommand is the runner's own (`npm test`, `uv sync`),
# and the runner is the command. yarn also runs a program with no subcommand
# (`yarn prettier -w .`), so its next word is the command unless it is one of
# yarn's own commands that shares a name with a listed writer.
RUNNERS = {
    "bundle": {"exec"}, "uv": {"run"}, "poetry": {"run"}, "pipx": {"run"},
    "pnpm": {"exec", "dlx"}, "npm": {"exec", "x"}, "yarn": {"exec", "dlx", "run"},
    "composer": {"exec"},
}
YARN_OWN_WRITER_NAMES = {"install", "unlink", "patch"}

# Wrapper options whose value is the next word, so that word is stepped over
# with the option rather than read as the command. Over-listing is the safe
# direction here: a flag listed that takes no value skips the real command.
# That is why each entry takes a value on every platform that knows it.
WRAPPER_VALUE_OPTIONS = {
    "env": {"-u", "--unset", "-P", "-C", "--chdir"},
    "sudo": {"-u", "--user", "-g", "--group", "-C", "--close-from", "-D", "--chdir",
             "-h", "--host", "-p", "--prompt", "-r", "--role", "-t", "--type", "-U",
             "--other-user", "-T", "--command-timeout"},
    "xargs": {"-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s", "-E", "-a", "-d"},
    "time": {"-o", "--output", "-f", "--format"},
    "npx": {"-p", "--package"},
    "uv": {"-w", "--with", "--with-editable", "--with-requirements", "-p", "--python",
           "--package", "--extra", "--group", "--env-file", "--index", "-i", "--index-url",
           "--directory", "--project"},
    "poetry": {"-C", "--directory", "-P", "--project"},
    "pipx": {"--spec", "--python", "--pip-args", "--index-url"},
    "pnpm": {"-C", "--dir", "-F", "--filter", "--package"},
    "npm": {"-p", "--package", "--prefix", "-w", "--workspace"},
    "yarn": {"--cwd", "-p", "--package"},
    "composer": {"-d", "--working-dir"},
}

# Wrapper options that run the command in another directory, like `cd`.
WRAPPER_CHDIR_OPTIONS = {"env": {"-C", "--chdir"}, "sudo": {"-D", "--chdir"},
                         "uv": {"--directory"}, "poetry": {"-C", "--directory"},
                         "pnpm": {"-C", "--dir"}, "npm": {"-w", "--workspace"},
                         "yarn": {"--cwd"}, "composer": {"-d", "--working-dir"}}

# env's `-S` and npm exec's `-c` take the command line itself as their value,
# so that value is read as the command rather than stepped over.
WRAPPER_SPLIT_OPTIONS = {"env": {"-S", "--split-string"}, "npm": {"-c", "--call"}}

# Shell keywords that can open a segment before its command, stepped over the
# same way, so `then cd <tree>` and `{ cd <tree>; }` are seen as `cd`.
SHELL_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "(", ")"}

# Builtins that change the directory later segments run in. zsh's `chdir` is `cd`.
DIRECTORY_CHANGES = {"cd", "pushd", "popd", "chdir"}

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

# A `|` or `&` straight after `>` or `<` belongs to a redirect operator (`>|`,
# `2>&1`, `<&0`), not a pipe or a background job, so it does not split.
SEGMENT_SPLIT = re.compile(r"\|\||&&|(?<![<>])[|&]|[;\n]")

# A redirect and its target. Any descriptor number before `>` is still a file
# redirect (`2> f`, `1>> f`), and so are `>| f`, zsh's `>! f` and `>>! f`, and
# `>& f`. Only `>&` followed
# by a descriptor number or `-` duplicates or closes a descriptor. That form
# leaves the `&` unconsumed, and the target class cannot start with `&`, so it
# never matches. A target
# starting with `(` is a process substitution rather than a file.
REDIRECT = re.compile(r">>?(?:[|!]|&(?!\s*(?:[0-9]+-?|-)(?:[\s;|&<>]|$)))?\s*([^\s;|&<>]+)")

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


def under(path: str, root: str, follow: bool = True) -> bool:
    """True when `path` is `root` or sits inside it, both resolved through
    symlinks, so `/tmp/link-into-tree/x` is inside the tree it points at.

    With follow=False the final name is left unresolved: only its parent
    directory is, so a link inside the tree is judged where the link itself
    lives, not where it points. That is the path `rm`, `mv`, and `chmod -h` act
    on."""
    if follow:
        path = os.path.realpath(path)
    else:
        head, name = os.path.split(path)
        # `x/`, `x/.`, and `x/..` go through the link, so they resolve in full.
        path = (os.path.realpath(path) if name in ("", ".", "..")
                else os.path.join(os.path.realpath(head or "."), name))
    root = os.path.realpath(root)
    return path == root or path.startswith(root.rstrip("/") + "/")


def resolve(target: str, cwd: str):
    """The absolute path a command names, or None when it cannot be known."""
    if target.startswith("~"):
        target = os.path.expanduser(target)
    if not target or target.startswith("~") or UNRESOLVABLE.search(target):
        return None
    if not os.path.isabs(target):
        if not cwd:
            return None
        target = os.path.join(cwd, target)
    return target


def git_verb(args: list):
    """(verb, the words after it), stepping over git's own options."""
    i = 0
    while i < len(args):
        tok = args[i]
        if tok.split("=", 1)[0] in GIT_OPTS_WITH_ARG and "=" not in tok:
            i += 2
        elif tok.startswith("-"):
            i += 1
        else:
            return tok, args[i + 1:]
    return None, []


def git_reads(verb: str, rest: list) -> bool:
    """True when `git <verb> <rest>` only reads. See rule 1 in the header."""
    if verb in GIT_READ_ONLY:
        return True
    flags = [a for a in rest if a.startswith("-")]
    positionals = [a for a in rest if not a.startswith("-")]
    listing = "-l" in flags or "--list" in flags
    if verb in ("branch", "tag"):
        positionals = [a for i, a in enumerate(rest) if not a.startswith("-")
                       and not (i and rest[i - 1] in LIST_VALUE_FLAGS)]
        allowed = BRANCH_READ_FLAGS if verb == "branch" else TAG_READ_FLAGS
        return (all(f in allowed or f.startswith(LIST_VALUE_PREFIXES)
                    or (verb == "tag" and re.fullmatch(r"-n\d+", f)) for f in flags)
                and (not positionals or listing))
    if verb == "remote":
        return (all(f in ("-v", "--verbose", "--all", "--push", "-n") for f in flags)
                and (positionals[:1] in ([], ["get-url"], ["show"])))
    if verb == "config":
        if any(f.split("=", 1)[0] in CONFIG_WRITE_FLAGS for f in flags):
            return False
        return bool(CONFIG_READ_FLAGS.intersection(flags)) or positionals[:1] in (["get"], ["list"])
    if verb == "stash":
        return positionals[:1] in (["list"], ["show"])
    if verb == "worktree":
        return positionals[:1] == ["list"]
    return False


def write_targets(name: str, args: list, cwd: str) -> list:
    """The paths a MUTATING_COMMANDS command writes, as written. Over-reading is
    the safe direction: an extra path can only refuse more."""
    operands, done, skip = [], False, False
    for arg in args:
        if skip:
            skip = False
        elif not done and arg == "--":
            done = True
        elif done or not arg.startswith("-") or arg == "-":
            operands.append(arg)
        else:
            skip = arg in VALUE_OPTIONS.get(name, ())
    if name == "dd":
        return [a[3:] for a in args if a.startswith("of=")]
    if name in ("cp", "ln", "install"):
        for i, arg in enumerate(args):
            if arg.startswith("--target-directory="):
                return [arg.split("=", 1)[1]]
            if re.fullmatch(r"-[A-Za-z]*t", arg):
                return args[i + 1:i + 2] or [""]
            if re.fullmatch(r"-[A-Za-z]*t.+", arg) and not arg.startswith("--"):
                return [arg[arg.index("t") + 1:]]
        if name == "ln" and len(operands) == 1:
            return [cwd]  # the link lands in the working directory
        # Every operand after the first: the destination is always among them,
        # whichever option order the command used.
        return operands[1:] if name != "install" or "-d" not in args else operands
    if name in ("chmod", "chown", "chgrp"):
        return operands if any(a.startswith("--reference") for a in args) else operands[1:]
    if name == "rsync":
        if "--remove-source-files" in args:
            return operands
        return operands[-1:] if len(operands) > 1 else []  # one operand only lists
    if name == "tar":
        return tar_targets(args, cwd)
    if name == "unzip":
        return unzip_targets(args, cwd)
    if name == "sort":
        return sort_targets(args)
    if name == "uniq":
        return operands[1:]  # the second operand is the output file
    if name == "patch":
        directory = cwd
        for i, arg in enumerate(args):
            if arg in ("-d", "--directory"):
                directory = args[i + 1] if i + 1 < len(args) else ""
            elif arg.startswith("--directory="):
                directory = arg.split("=", 1)[1]
            elif arg.startswith("-d") and len(arg) > 2:
                directory = arg[2:]
        return operands + [directory]
    return operands


# tar's long mode options, mapped to the short letter each one means.
TAR_LONG_MODES = {"--extract": "x", "--get": "x", "--create": "c", "--append": "r",
                  "--update": "u", "--catenate": "A", "--concatenate": "A", "--delete": "r"}


def tar_targets(args: list, cwd: str) -> list:
    """What tar writes: the directory it extracts into, and the archive it
    creates or changes. Listing, comparing, and extracting to stdout write
    nothing. The first word may carry bundled letters with no dash
    (`tar xzf a.tar`), and each of `f` and `C` there takes the next word."""
    modes, archives, dirs, to_stdout = set(), [], [], False
    i = 0
    while i < len(args):
        arg = args[i]
        if arg.startswith("--"):
            key, eq, value = arg.partition("=")
            modes.update(TAR_LONG_MODES.get(key, ""))
            to_stdout = to_stdout or key == "--to-stdout"
            if key in ("--file", "--directory"):
                if not eq:
                    i += 1
                    value = args[i] if i < len(args) else ""
                (archives if key == "--file" else dirs).append(value)
        elif (arg.startswith("-") and arg != "-") or i == 0:
            letters = arg.lstrip("-")
            for j, char in enumerate(letters):
                if char in "fC":
                    value = letters[j + 1:] if arg.startswith("-") else ""
                    if not value:
                        i += 1
                        value = args[i] if i < len(args) else ""
                    (archives if char == "f" else dirs).append(value)
                    if arg.startswith("-"):
                        break
                else:
                    modes.update(char if char in "xcruA" else "")
                    to_stdout = to_stdout or char == "O"
        i += 1
    targets = []
    if modes & set("cruA"):
        targets += [a for a in archives if a != "-"]
    if "x" in modes and not to_stdout:
        targets += dirs or [cwd]
    return targets


def unzip_targets(args: list, cwd: str) -> list:
    """The directory unzip extracts into: `-d`'s value, or the working
    directory. A listing, testing, or printing form extracts nothing."""
    letters, dest, operands, i = "", None, [], 0
    while i < len(args):
        arg = args[i]
        if arg.startswith("-") and not arg.startswith("--") and len(arg) > 1:
            for j, char in enumerate(arg[1:]):
                if char == "d":
                    dest = arg[j + 2:]
                    if not dest:
                        i += 1
                        dest = args[i] if i < len(args) else ""
                    break
                letters += char
        elif not arg.startswith("-"):
            operands.append(arg)
        i += 1
    if not operands or UNZIP_READ_FLAGS.intersection(letters):
        return []  # with no archive named, unzip prints its usage
    return [dest if dest is not None else cwd]


def sort_targets(args: list) -> list:
    """The file `sort -o` writes. Without `-o`, sort only prints."""
    targets = []
    for i, arg in enumerate(args):
        nxt = args[i + 1:i + 2] or [""]
        if arg.startswith("--output"):
            targets.append(arg.partition("=")[2] if "=" in arg else nxt[0])
        elif re.fullmatch(r"-[A-Za-z]*o", arg):
            targets += nxt
        elif re.fullmatch(r"-[A-Za-z]*o.+", arg):
            targets.append(arg[arg.index("o") + 1:])
    return targets


def formatter_writes(name: str, args: list):
    """The formatter's name when this call rewrites files, else None. See rule
    3 in the header: a short write flag, or a formatter that writes by default
    and was not put in check mode."""
    if re.fullmatch(r"python[0-9.]*", name) and args[:1] == ["-m"] and len(args) > 1:
        name, args = args[1], args[2:]
    for arg in args:
        key = arg.split("=", 1)[0]
        if len(key) == 3 and key.startswith("--"):
            key = key[1:]  # Go's flag package reads `--w` as `-w`
        if key in FORMATTER_WRITE_FLAGS.get(name, ()):
            return name
    if name in FORMATTER_CLUSTER_FLAGS:
        write, takes_value = FORMATTER_CLUSTER_FLAGS[name]
        for arg in args:
            if arg.startswith("--") or not arg.startswith("-"):
                continue
            for char in arg[1:]:
                if char in write:
                    return name
                if char in takes_value:
                    break
    sub = next((a for a in args if not a.startswith(("-", "+"))), "")
    key = name if name in FORMATTERS_WRITING_BY_DEFAULT else f"{name} {sub}"
    if key not in FORMATTERS_WRITING_BY_DEFAULT:
        return None
    # `--code=x` matches a bare `--code`. A value that switches a check off
    # (`-check=false`) never does.
    words = (set(args) | {f"{a}={b}" for a, b in zip(args, args[1:])}
             | {a.split("=", 1)[0] for a in args
                if "=" in a and a.split("=", 1)[1].lower() not in OFF_VALUES})
    if key == "rustfmt" and "--print-config" in words:
        operands = [a for a in args if not a.startswith("-")]
        joined = [a.split("=", 1)[1] for a in args if a.startswith("--print-config=")]
        kind = joined[0] if joined else (operands.pop(0) if operands else "")
        return key if operands and kind in RUSTFMT_CONFIG_FILE_KINDS else None
    if words & (FORMATTERS_WRITING_BY_DEFAULT[key] | FORMATTER_INFO_FLAGS):
        return None
    # A formatter reading stdin writes only to stdout: `-` with no file operand,
    # or rustfmt with no operand at all. Any file operand beside it is written.
    operands = [a for i, a in enumerate(args) if not a.startswith(("-", "+"))
                and (i == 0 or args[i - 1] not in STDIN_NAME_OPTIONS)]
    if " " in key:
        operands.remove(sub)
    if not operands and ("-" in args or key == "rustfmt"):
        return None
    return key


def refuses_write(name: str, args: list, roots: list, cwd: str, via_xargs: bool):
    """(action, reason) when a file-writing command touches the tree, else None."""
    targets = write_targets(name, args, cwd)
    if via_xargs:
        targets.append("$xargs")  # its paths arrive on stdin, where nothing reads them
    if not targets:
        return None
    base = f"`{name}` changes a file's content, location, existence, or metadata"
    if not roots:
        return (f"`{name}`", base + ", and no tree was named to judge its paths against.")
    for raw in targets:
        path = resolve(raw, cwd)
        if path is None:
            return (f"`{name}`", base + f", and the path `{raw or '(none)'}` cannot be resolved.")
        # Judged both ways: where a link points, for the writers that follow it
        # (cp, tee, touch), and where the link itself lives, for the ones that
        # act on the entry (rm, mv, chmod -h). Checking both for every command
        # needs no per-command table, and it can only refuse more.
        if any(under(path, root) or under(path, root, follow=False) or under(root, path)
               for root in roots):
            return (f"`{name}`", base + f", and `{raw}` is the tree under review or holds it.")
    return None


def runs_command(tokens: list) -> bool:
    """True when `tokens` open a RUNNERS run form. The run subcommand is removed
    in place, so the runner is then stepped over like any wrapper, its own
    options included."""
    subcommands = RUNNERS.get(tokens[0])
    if subcommands is None:
        return False
    i = 1
    while i < len(tokens) and tokens[i].startswith("-"):
        i += 2 if tokens[i] in WRAPPER_VALUE_OPTIONS.get(tokens[0], ()) else 1
    if i >= len(tokens):
        return False
    if tokens[i] in subcommands:
        del tokens[i]
        return True
    return tokens[0] == "yarn" and tokens[i] not in YARN_OWN_WRITER_NAMES


def classify(command: str, roots: list, cwd: str):
    """`(action, reason)` for a refused command, or None when it may run.

    `action` is the short label the human line names — what they tried to do,
    in two or three words. `reason` is the sentence explaining it, which goes to
    the model. Adding a rule here means writing both.

    Every segment is examined, never only the first: `git status && chmod 644 x`
    mutates the tree as surely as `chmod` alone does.

    A `cd`, `pushd`, `popd`, zsh `chdir`, `env -C`, or `sudo -D` moves the
    directory the later segments run in to one this guard does not follow, so
    from there on cwd is unknown and every relative path is unresolvable:
    `cd <tree> && rm README.md` is refused. It is found after wrappers and shell keywords are stepped over,
    so `builtin cd`, `( cd`, and `then cd` count too.
    """
    for segment in SEGMENT_SPLIT.split(command):
        tokens = segment.strip().split()
        # Step over environment assignments, wrappers, and shell keywords to
        # reach the real command. A `(` or `{` glued to the command is dropped.
        # A wrapper's own flags are stepped over too, so `xargs -0 rm` is seen as
        # `rm`, and so is the value of a flag WRAPPER_VALUE_OPTIONS names, so
        # `env -u FOO chmod` is seen as `chmod`. `env -C` and `sudo -D` change
        # the directory the way `cd` does, and `env -S` hands over the command
        # line itself as its value.
        wrapper, via_xargs = "", False
        while tokens:
            tokens[0] = tokens[0].lstrip("({") or tokens[0]
            if wrapper == "command" and re.fullmatch(r"-[pvV]*[vV][pvV]*", tokens[0]):
                tokens = []  # `command -v` looks a name up and runs nothing
                break
            if wrapper and tokens[0].startswith("-"):
                option, joined = tokens[0].split("=", 1)[0], "=" in tokens[0]
                short = option[:2] if not option.startswith("--") else option
                if short in WRAPPER_CHDIR_OPTIONS.get(wrapper, ()):
                    cwd = ""  # the command runs in another directory, as after `cd`
                if short in WRAPPER_SPLIT_OPTIONS.get(wrapper, ()):
                    # The value is the command line: read it as the command.
                    word = tokens.pop(0)
                    value = (word.split("=", 1)[1] if joined
                             else word[2:] if not word.startswith("--") else "")
                    if value:
                        tokens.insert(0, value)
                    if tokens:
                        tokens[0] = tokens[0].lstrip("'\"")
                    continue
                if (option in WRAPPER_VALUE_OPTIONS.get(wrapper, ()) and not joined
                        and len(tokens) > 1):
                    tokens.pop(0)  # the option's value, not the command
            elif (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]) or tokens[0] in PASS_THROUGH
                  or runs_command(tokens)):
                if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
                    wrapper = tokens[0]
                via_xargs = via_xargs or tokens[0] == "xargs"
            elif tokens[0] not in SHELL_KEYWORDS:
                break
            tokens.pop(0)
        if tokens and os.path.basename(tokens[0]) in DIRECTORY_CHANGES:
            cwd = ""
        if tokens:
            name = os.path.basename(tokens[0])
            args = tokens[1:]

            if name == "git":
                verb, rest = git_verb(args)
                if verb and not git_reads(verb, rest):
                    return (
                        f"`git {verb}`",
                        f"`git {verb}` is not one of git's read-only forms, so it is "
                        "refused. `git restore`, `checkout`, `switch`, `reset`, `clean`, "
                        "and `stash` all discard exactly the uncommitted change you were "
                        "sent to read.",
                    )
            elif name in MUTATING_COMMANDS:
                found = refuses_write(name, args, roots, cwd, via_xargs)
                if found:
                    return found
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
            formatter = formatter_writes(name, args)
            if formatter:
                return (
                    f"`{formatter}` rewriting files",
                    f"`{formatter}` rewrites files unless it runs in check mode. Run "
                    "formatters and linters in check mode only, such as `--check`.",
                )

        # Only meaningful once a tree is named. With no root to compare against,
        # a redirect has nothing it could be inside of. A target goes through
        # resolve(), as a write_targets path does, so a quoted, `~`, or `$HOME`
        # target is expanded or refused rather than joined onto cwd as text.
        for target in REDIRECT.findall(segment) if roots else []:
            if target.startswith(("&", "(")):
                continue
            path = resolve(target, cwd)
            if path is None:
                return (
                    "redirecting output into the tree under review",
                    f"the output is redirected to `{target}`, which cannot be "
                    "resolved: it holds shell the guard does not expand, or it is "
                    "relative with no known working directory.",
                )
            if any(under(path, root) for root in roots):
                return (
                    "redirecting output into the tree under review",
                    f"the output is redirected into the tree under review (`{path}`).",
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
if event != "PreToolUse" or (tool_name != "Bash" and tool_name not in EDIT_TOOLS):
    sys.exit(0)

# A main session is never gagged. The human keeps working in the window that
# dispatched the review; only its sub-agents are held to reading.
if not str(payload.get("agent_id") or ""):
    sys.exit(0)

record = read_record()
if not record:
    sys.exit(0)

roots = [r for r in record.get("roots", []) if isinstance(r, str)]
cwd = str(payload.get("cwd") or "")
if tool_name in EDIT_TOOLS:
    raw = str(tool_input.get(EDIT_TOOLS[tool_name]) or "")
    path = resolve(raw, cwd)
    found = None
    if not roots or path is None:
        found = (f"`{tool_name}`", f"`{tool_name}` writes to `{raw or '(no path)'}`, and "
                 "no tree or no resolvable path was given to judge it against.")
    elif any(under(path, root) for root in roots):
        found = (f"`{tool_name}`", f"`{tool_name}` writes to `{raw}`, inside the tree under review.")
else:
    found = classify(str(tool_input.get("command") or ""), roots, cwd)
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
status=$?
# --classify exits 1 to mean "refused", which is not a crash.
[ "$GUARD_MODE" = classify ] && exit "$status"
[ "$status" -eq 0 ] || guard_python_fallback
