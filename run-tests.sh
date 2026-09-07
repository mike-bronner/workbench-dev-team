#!/usr/bin/env bash
# The whole suite, one entry point. Run: bash run-tests.sh
#
# Usage: bash run-tests.sh [tests|lints|all]     (default: all)
#
# Two groups, deliberately named apart:
#
#   tests — `test-*.sh`. Each one executes shipped shell logic and asserts on
#           its behaviour: two run a shipped `.sh` as a subprocess, three extract
#           the real bash from between sentinel markers in a Markdown prompt and
#           run it against fixtures. All five go red when the shipped logic breaks.
#
#   lints — `lint-*.sh`. Each one greps English prose and YAML frontmatter in the
#           shipped Markdown. Useful, but they guarantee nothing about behaviour,
#           so they do not get to call themselves tests.
#
# Both groups are discovered, never hand-listed: a new script joins the suite by
# being named, not by someone remembering to add it here AND in the workflow.
#
# Discovery asks git for tracked files PLUS untracked ones git would not ignore.
# Tracked alone would silently skip a brand-new script the author had not staged
# yet — a suite that reports green without running the test just written. A bare
# `find` would go the other way and descend into `.claude/worktrees/`, which is
# gitignored and holds ephemeral agent checkouts, running a second stale copy of
# every script below and reporting its verdict as ours.
#
# Exits non-zero if any script in the selected group fails.

set -u

cd "$(dirname "$0")" || exit 1

GROUP="${1:-all}"
case "$GROUP" in
  tests|lints|all) ;;
  *) echo "usage: $0 [tests|lints|all]" >&2; exit 2 ;;
esac

# GitHub Actions folds each script's output behind its name and turns a failure
# into a file annotation. Locally both are no-ops, so a plain run stays plain.
in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }

FAILED=()

# run_group <label> <filename-prefix>
run_group() {
  local label="$1" prefix="$2" script
  local scripts=()
  while IFS= read -r script; do
    [ -n "$script" ] && scripts+=("$script")
  done < <(git ls-files --cached --others --exclude-standard \
    "*/${prefix}-*.sh" "${prefix}-*.sh" | sort -u)

  if [ ${#scripts[@]} -eq 0 ]; then
    # An empty group means discovery stopped matching. A rename that silently
    # emptied the suite looks exactly like a suite that passed, so fail closed.
    echo "❌ $label — no ${prefix}-*.sh scripts found"
    FAILED+=("$label (no scripts found)")
    return
  fi

  echo "── $label (${#scripts[@]}) ──────────────────────────────────────"
  for script in "${scripts[@]}"; do
    in_ci && echo "::group::$script"
    if bash "$script"; then
      in_ci && echo "::endgroup::"
    else
      in_ci && echo "::endgroup::"
      in_ci && echo "::error file=${script}::${label%s} failed"
      FAILED+=("$script")
    fi
    echo
  done
  return 0
}

if [ "$GROUP" = tests ] || [ "$GROUP" = all ]; then
  run_group tests test
fi
if [ "$GROUP" = lints ] || [ "$GROUP" = all ]; then
  run_group lints lint
fi

echo "══════════════════════════════════════════════════════════════"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "✅ suite green"
  exit 0
fi
echo "❌ ${#FAILED[@]} failed:"
for script in "${FAILED[@]}"; do echo "   • $script"; done
exit 1
