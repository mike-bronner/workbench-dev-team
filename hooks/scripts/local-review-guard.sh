#!/bin/bash
# Review guard (PreToolUse: Bash, Edit, Write, NotebookEdit).
#
# Holmes reviews code he must not change. In Local mode the tree he reads is the
# human's live working directory, and the uncommitted change in it is the ONLY
# copy of the work, so a reviewer that writes to it destroys the thing it was
# sent to read. The rule was already stated in Holmes's prompt, in his
# reference, and verbatim in every sub-agent prompt he dispatches — and on the
# mode's first real exercise a lens sub-agent ran `chmod` against that directory
# anyway and changed a script from 755 to 644. Prose in an agent prompt is
# advisory. This hook is not.
#
# It is a sibling of commit-guard.sh, never an extension of it. What is borrowed
# is the reasoning of the commit approval gate that guard replaced, including the
# two traps recorded below.
#
# ── WHAT IT DOES ──────────────────────────────────────────────────────────────
#
# One static rule, with no state: a tool call whose `agent_type` is Holmes
# (`workbench-dev-team:holmes`) or his helper (`workbench-dev-team:holmes-lens`)
# may not write outside the scratch roots. It holds at any time, in both of
# Holmes's modes, on the main thread of a session started with
# `--agent workbench-dev-team:holmes` (the scheduled pipeline), and in every
# sub-agent of either type, at any depth.
#
# The scratch roots are the places a reviewer may write:
#   • $TMPDIR, where `mktemp -d` lands. Holmes's Index-mode clone lives there,
#     and so does a helper's copy of a tree it needs to mutate for a probe.
#   • ~/Developer/scratchpad.
#   • The session scratchpad, /private/tmp/claude-*/*/<session_id>/scratchpad,
#     or the `scratchpad_dir` the payload names.
# The last two are found by name, so a planted symlink could aim them anywhere.
# Each is kept only when its physical path is the path itself, the check
# hooks/scripts/pipeline-scope.sh and workbench-core's scope guard both make. A
# write lands in a root only when it is strictly beneath one, resolved both
# through every symlink and with its final name left unresolved, so no root can
# be removed and no link can lead out of one.
#
# Reads and test runs are untouched. `bash run-tests.sh` is one token here, and
# the temporary files a suite writes are invisible to this hook.
#
# ── WHY IT IS STATIC ──────────────────────────────────────────────────────────
#
# This guard used to arm a per-session hold when a Local-mode Holmes was
# dispatched and release it when the review ended. Every release event the
# harness offers turned out to fire at the wrong time or not at all: a failed or
# classifier-denied dispatch never reached PostToolUse, a background dispatch
# reached it at launch, and SubagentStop could not tell a final stop from a
# paused turn. Each fix added machinery, and each round found a new early
# release. The hold existed only because Holmes's helpers ran on write-capable
# agent types (dev-team/process-insights/holmes-lens-subagent-write-access-2026-08-01.md
# in the memory vault). They now run on their own read-only type,
# agents/holmes-lens.md, which grants no Write, Edit, or NotebookEdit. With every
# reviewer carrying a type of its own, the harness's `agent_type` field names
# the reviewer on every call, and no lifecycle has to be tracked.
#
# ── THE SIGNAL ────────────────────────────────────────────────────────────────
#
# One harness-supplied field decides it: `agent_type`. Claude Code 2.1.284 sets
# it from the running agent's own definition on every hook input — in a
# sub-agent from that sub-agent's type (so a helper's helper carries its own
# type, not its parent's), and on the main thread from the `--agent` the session
# was started with. An interactive main session carries none, so the human's own
# window is never gagged. The agent supplies no part of it, so the command being
# inspected cannot forge it.
#
# Nothing else scopes the rule: not the session, not a Workdir. A host-wide
# marker would be the commit gate's `/tmp/watson.lock` leak with the sign
# flipped, and a per-session record is the machinery this version removed.
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
# A review reads the tree constantly and runs the repository's own suite. A
# rule that stops either one makes the review useless and gets switched off, so
# the line is drawn at commands whose PURPOSE is to change a file's content,
# location, existence, or metadata. Rule 1 is a true rule. Rules 2 and 3 are
# fixed lists, and "WHAT IT DOES NOT COVER" below states what that costs. Rules
# 1 and 3 refuse wherever they point, inside a scratch root too, which is
# stricter than the static rule asks: no reviewer needs a git write or an
# in-place rewrite, and a probe on a copy can write through `cp`, `tee`, or a
# redirect, which rules 2 and 4 judge by path.
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
#      nothing, so `tar -tf` and `unzip -l` stay allowed. Each is judged by
#      the paths it writes, resolved two ways: through every symlink, and with
#      only the final name left unresolved, because `rm <dir>/link` removes a
#      link where it lives, wherever it points. Allowed only when both land
#      strictly beneath a scratch root. Refused otherwise, and refused when a
#      path cannot be resolved at all — a variable, a glob, a quote, a
#      relative path with no cwd, or arguments fed by xargs. So `rm -rf
#      <mktemp path>` runs, and `rm -rf "$DIR"` does not. An option's value is
#      read as a path too, which can only refuse more. With no scratch root
#      found, every write is refused.
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
#   4. Redirection. `> file` is checked by target path, not refused outright,
#      because `git diff HEAD > <mktemp path>/review.diff` is ordinary review
#      work. The target goes through resolve(), as every write path does: `~`
#      is expanded, a relative target is resolved against the payload's `cwd`,
#      and a quoted, `$HOME`, or other shell-built target is refused. It is
#      allowed beneath a scratch root, and into /dev/null, /dev/stdout,
#      /dev/stderr, /dev/tty, and /dev/fd/<n>, which write no file. When no cwd
#      is known a relative target is refused. A `cd`, `pushd`, or `popd` makes
#      cwd unknown for every segment after it.
#
# ── WHAT IT DOES NOT COVER ────────────────────────────────────────────────────
#
# Stated plainly, because a guard whose limits are unwritten gets trusted past
# them:
#
#   • It does not catch every program that writes. Rules 2 and 3 name the
#     ordinary file writers and the common formatters, and that is where they
#     stop: a program on neither list that writes outside the scratch roots
#     runs silently. `gh` is one: `gh pr checkout` is how Index mode fills its
#     clone, so it is left to run. The same holds for runners: a listed writer
#     behind a runner not named in RUNNERS (`uvx`, `bun x`, `pnpm <bin>`), or
#     inside a package script (`npm run format`), runs silently.
#     Code run inside an interpreter (`python -c`, `node -e`) is out of scope
#     for the reason the next point gives. The backstop for both is the
#     reviewer prompts' no-mutation rule and the human review of the diff. The
#     rejected alternative was a read allowlist, which refuses every command it
#     does not know. It would refuse reads too, and a guard that blocks reading
#     gets switched off. A writer found missing is added to the list.
#     Short write flags are read inside a cluster only for the four formatters
#     in FORMATTER_CLUSTER_FLAGS. A tool added to FORMATTER_WRITE_FLAGS whose
#     parser bundles short flags needs a row there too, or its clustered write
#     runs silently. A stdin form is read by its operands alone, so `black -l
#     88 -` is refused: `88` looks like a file operand.
#
#   • It is not anti-evasion machinery. Like its sibling gate it reads the
#     command the agent asked to run, so a verb inside `bash -c`, inside a
#     script, or behind command substitution is not its subject. That is also
#     what lets the repository's own suite run.
#   • It covers only calls whose `agent_type` names a reviewer. A review a
#     foreground session performs inline, with no `--agent`, carries no
#     `agent_type`. So does a reviewer dispatched on some other type, such as
#     `general-purpose`: the holmes-review references name the helper type on
#     every dispatch, and that naming is the prose half this hook stands beside.
#   • Editing tools are matched by path. Holmes and his helper hold no Edit,
#     Write, or NotebookEdit grant, so an edit from either is already refused
#     by the harness. This rule is the backstop for a grant added by mistake:
#     an edit whose path is outside the scratch roots, or cannot be resolved,
#     is refused.
#
# ── HOW THE REFUSAL IS WORDED ─────────────────────────────────────────────────
#
# Split across the two channels a hook has, measured on Claude Code 2.1.274
# (insights/2026-09-17-hook-message-channels-measured.md in the memory vault).
# `permissionDecisionReason` becomes the tool_result and is the text a PERSON
# reads, so it is ONE line naming the action that was gated.
# `additionalContext` survives a deny and arrives in its own block that only the
# model reads, so every recovery instruction lives there. Nothing is cut; it
# stops being in the human's way. Same shape as commit-guard.sh.
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

GUARD_MODE=hook
if [ "${1:-}" = "--classify" ]; then
  GUARD_MODE=classify
fi
export GUARD_MODE

# Capture stdin before the heredoc below claims it for the python program.
GUARD_STDIN="$(cat)"
export GUARD_STDIN

# Fast path. Only a reviewer's call can be refused, and a reviewer's payload
# names holmes in its agent_type. Everything else exits here, before python3
# starts (about 48 ms on every Bash and edit call). It errs toward the full
# check: any mention of holmes, a `\u` escape, or any non-ASCII byte (python
# folds `ſ` into `s`) goes on to python3.
if [ "$GUARD_MODE" = hook ]; then
  guard_needs_python() {
    local LC_ALL=C holmes_re='[Hh][Oo][Ll][Mm][Ee][Ss]' escape_re='\\u' wide_re='[^ -~]'
    [[ $GUARD_STDIN =~ $holmes_re || $GUARD_STDIN =~ $escape_re || $GUARD_STDIN =~ $wide_re ]]
  }
  guard_needs_python || exit 0
fi

# Without a working python3 the classifier never runs, and a hook that errors is
# a non-blocking error to the harness: the call runs as if no guard existed. So
# this path refuses on its own terms. A fallback that refused text naming git
# would miss everything this guard is for: rm, mv, chmod, redirects, and edits
# name no git.
#
# Without python3 nothing can be judged, so every Bash and editing call whose
# agent_type may name a reviewer is refused: one naming holmes, or one carrying
# an escape or a non-ASCII byte that python3 would have had to fold. The fields
# are read from the raw payload, where a quote inside a string is escaped, so
# command text cannot supply them. Every other agent keeps its tools.
guard_python_fallback() {
  local LC_ALL=C p="$GUARD_STDIN"
  local event_re='"hook_event_name" *: *"PreToolUse"'
  local tool_re='"tool_name" *: *"(Bash|Edit|Write|NotebookEdit)"'
  local type_re='"agent_type" *: *"[^"]*([Hh][Oo][Ll][Mm][Ee][Ss]|\\u|[^ -~])'
  if [[ $p =~ $event_re ]] && [[ $p =~ $tool_re ]] && [[ $p =~ $type_re ]]; then
    printf '%s\n' "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"🛑 Blocked: this call. python3 is missing or failed, so the review guard cannot judge it.\", \"additionalContext\": \"Review guard (workbench-dev-team). This call comes from a Holmes reviewer, and this hook judges a reviewer's calls with python3, which is not on PATH or exited with an error. It cannot tell a read from a write, so it refuses every Bash and editing call from a reviewer until python3 works. Report this to the human: python3 is a prerequisite of workbench-dev-team (see its README). Do not try another spelling of the call.\"}}"
  fi
  exit 0
}

# --classify is the lint's entry point, not a hook, so it reports the failure.
if ! command -v python3 >/dev/null 2>&1; then
  [ "$GUARD_MODE" = classify ] && { echo "python3 is missing" >&2; exit 2; }
  guard_python_fallback
fi

python3 - <<'PYEOF'
import glob
import json
import os
import re
import sys

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
# must step over both.
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

# The agent types this guard holds to the static rule: Holmes and his helper.
# Plugin agent types are namespaced (`workbench-dev-team:holmes-lens`), and a
# bare name is matched too. IGNORECASE also folds `ſ` into `s`, which is why the
# fast path sends a non-ASCII payload here.
REVIEWER_AGENT = re.compile(r"(^|[:/])holmes(-lens)?$", re.IGNORECASE)

# Redirect targets that write no file.
DEVICE_TARGET = re.compile(r"/dev/(?:null|stdout|stderr|tty|fd/[0-9]+)")


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


def placed(path: str, follow: bool) -> str:
    """Where `path` lands. With follow=True every symlink is resolved, so a
    link out of a root is judged where it points. With follow=False the final
    name is left unresolved and only its parent directory is, so a link is
    judged where it lives. That is the path `rm`, `mv`, and `chmod -h` act on."""
    if follow:
        return os.path.realpath(path)
    head, name = os.path.split(path)
    # `x/`, `x/.`, and `x/..` go through the link, so they resolve in full.
    return (os.path.realpath(path) if name in ("", ".", "..")
            else os.path.join(os.path.realpath(head or "."), name))


def in_scratch(path: str, roots: list) -> bool:
    """True when `path` lands strictly beneath one scratch root, both through
    every symlink and with its final name unresolved. A root itself is not
    beneath itself, so no command may remove or replace a root."""
    for root in roots:
        prefix = root.rstrip("/") + "/"
        if all(placed(path, follow).startswith(prefix) for follow in (True, False)):
            return True
    return False


def scratch_roots(payload) -> list:
    """The scratch roots, each a physical directory. See the header."""
    roots = []
    tmp = os.environ.get("TMPDIR") or "/tmp"
    if os.path.isdir(tmp):
        roots.append(os.path.realpath(tmp))
    session = str(payload.get("session_id") or "")
    named = [str(payload.get("scratchpad_dir") or "")]
    home = os.environ.get("HOME", "")
    if home:
        named.append(os.path.join(home, "Developer", "scratchpad"))
    # A session id with a separator or a glob character names no scratchpad.
    if session and not re.search(r"[/*?\[\]]", session) and session not in (".", ".."):
        for base in ("/private/tmp", "/tmp"):
            named += glob.glob(os.path.join(base, "claude-*", "*", session, "scratchpad"))
    for candidate in named:
        # Found by name, so kept only when its physical path is the path itself:
        # a planted symlink could aim a named root anywhere.
        if (candidate and os.path.isabs(candidate) and os.path.isdir(candidate)
                and os.path.realpath(candidate) == os.path.normpath(candidate)):
            roots.append(os.path.normpath(candidate))
    return roots


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
    """(action, reason) when a file-writing command writes outside the scratch
    roots, else None."""
    targets = write_targets(name, args, cwd)
    if via_xargs:
        targets.append("$xargs")  # its paths arrive on stdin, where nothing reads them
    if not targets:
        return None
    base = f"`{name}` changes a file's content, location, existence, or metadata"
    if not roots:
        return (f"`{name}`", base + ", and no scratch root was found to judge its paths against.")
    for raw in targets:
        path = resolve(raw, cwd)
        if path is None:
            return (f"`{name}`", base + f", and the path `{raw or '(none)'}` cannot be resolved.")
        # Judged both ways: where a link points, for the writers that follow it
        # (cp, tee, touch), and where the link itself lives, for the ones that
        # act on the entry (rm, mv, chmod -h). Checking both for every command
        # needs no per-command table, and it can only refuse more.
        if not in_scratch(path, roots):
            return (f"`{name}`", base + f", and `{raw}` is outside the scratch roots.")
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


def classify(command: str, roots: list, cwd: str, judge_redirects: bool = True):
    """`(action, reason)` for a refused command, or None when it may run.

    `action` is the short label the human line names — what they tried to do,
    in two or three words. `reason` is the sentence explaining it, which goes to
    the model. Adding a rule here means writing both.

    Every segment is examined, never only the first: `git status && chmod 644 x`
    writes as surely as `chmod` alone does.

    A `cd`, `pushd`, `popd`, zsh `chdir`, `env -C`, or `sudo -D` moves the
    directory the later segments run in to one this guard does not follow, so
    from there on cwd is unknown and every relative path is unresolvable:
    `cd <tree> && rm README.md` is refused. It is found after wrappers and
    shell keywords are stepped over, so `builtin cd`, `( cd`, and `then cd`
    count too.
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
                        "refused wherever it points. `git restore`, `checkout`, `switch`, "
                        "`reset`, `clean`, and `stash` all discard exactly the uncommitted "
                        "change a Local-mode review is sent to read.",
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

        # --classify judges commands with no payload, so it has no scratch root
        # and no cwd, and leaves redirects alone. A target goes through
        # resolve(), as a write_targets path does, so a quoted, `~`, or `$HOME`
        # target is expanded or refused rather than joined onto cwd as text.
        for target in REDIRECT.findall(segment) if judge_redirects else []:
            if target.startswith(("&", "(")) or DEVICE_TARGET.fullmatch(target):
                continue
            path = resolve(target, cwd)
            if path is None:
                return (
                    "redirecting output outside the scratch roots",
                    f"the output is redirected to `{target}`, which cannot be "
                    "resolved: it holds shell the guard does not expand, or it is "
                    "relative with no known working directory.",
                )
            if not in_scratch(path, roots):
                return (
                    "redirecting output outside the scratch roots",
                    f"the output is redirected to `{path}`, which is outside the scratch roots.",
                )
    return None


# --classify: commands on stdin, one line each, every refusal on stdout. The
# lint's entry point. It has no payload, so no scratch root and no cwd: every
# file write is refused, the redirect rule sits this one out, and the
# command-position rules — which is what documentation can get wrong — are what
# answer.
if os.environ.get("GUARD_MODE") == "classify":
    refused = []
    for line in os.environ.get("GUARD_STDIN", "").splitlines():
        found = classify(line, [], "", judge_redirects=False)
        if found:
            refused.append(f"{line.strip()} — {found[1]}")
    for line in refused:
        print(line)
    sys.exit(1 if refused else 0)

try:
    payload = json.loads(os.environ.get("GUARD_STDIN", ""))
except (json.JSONDecodeError, ValueError):
    sys.exit(0)  # unparseable input -> no opinion
if not isinstance(payload, dict):
    sys.exit(0)

tool_name = str(payload.get("tool_name") or "")
tool_input = payload.get("tool_input") or {}
if not isinstance(tool_input, dict):
    tool_input = {}

# ── ENFORCE ───────────────────────────────────────────────────────────────────
if payload.get("hook_event_name") != "PreToolUse" or (
        tool_name != "Bash" and tool_name not in EDIT_TOOLS):
    sys.exit(0)

# Only a reviewer is held to the rule. The harness sets agent_type from the
# running agent's own definition, so every other agent, and a main session with
# no --agent, keeps its tools.
if not REVIEWER_AGENT.search(str(payload.get("agent_type") or "").strip()):
    sys.exit(0)

roots = scratch_roots(payload)
cwd = str(payload.get("cwd") or "")
if tool_name in EDIT_TOOLS:
    raw = str(tool_input.get(EDIT_TOOLS[tool_name]) or "")
    path = resolve(raw, cwd)
    found = None
    if path is None:
        found = (f"`{tool_name}`", f"`{tool_name}` writes to `{raw or '(no path)'}`, "
                 "which cannot be resolved.")
    elif not in_scratch(path, roots):
        found = (f"`{tool_name}`", f"`{tool_name}` writes to `{raw}`, outside the scratch roots.")
else:
    found = classify(str(tool_input.get("command") or ""), roots, cwd)
if not found:
    sys.exit(0)

action, reason = found
where = ", ".join(f"`{root}`" for root in roots) or "none could be found on this host"

# The refusal is split across the two channels a hook has, measured on Claude
# Code 2.1.274 (insights/2026-09-17-hook-message-channels-measured.md in the
# memory vault). `permissionDecisionReason` becomes the tool_result and is the
# text a PERSON reads, so it is ONE line naming the action that was gated.
# `additionalContext` survives a deny and reaches only the model, so the reason,
# the scratch roots, and the allowed alternatives live there. No Markdown
# emphasis: whether a client renders it is unsettled, so the action is
# emphasised by position and by backticks, which read either way.
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"🛑 Blocked: {action}. A Holmes reviewer writes only in scratch."
        ),
        "additionalContext": (
            f"Review guard (workbench-dev-team). This command is refused, because "
            f"{reason}\n\n"
            "You are running as a Holmes reviewer, and a reviewer writes nothing outside "
            f"the scratch roots. The scratch roots here are: {where}. The code under review "
            "is read, never changed: in Local mode it is the human's live working "
            "directory, and the uncommitted change in it is the only copy of the work.\n\n"
            "Read it instead. `git status`, `git diff HEAD`, `git ls-files --others "
            "--exclude-standard`, and `git show` are all allowed, and so is the test suite. "
            "A probe that needs a changed tree runs on a copy in your own `mktemp -d` "
            "directory. If a failure looks pre-existing, say so in your findings — never "
            "isolate it by changing the tree.\n\n"
            "There is no flag to clear and no path around this. If you believe you are not "
            "a reviewer, report that to the session that dispatched you and stop."
        ),
    }
}))
sys.exit(0)
PYEOF
status=$?
# --classify exits 1 to mean "refused", which is not a crash.
[ "$GUARD_MODE" = classify ] && exit "$status"
[ "$status" -eq 0 ] || guard_python_fallback
