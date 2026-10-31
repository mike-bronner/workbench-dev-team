#!/usr/bin/env bash
set -u

REPO="${1:-}" ISSUE="${2:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$ISSUE" =~ ^[0-9]+$ ]] \
  || { echo "usage: $0 <owner/repo> <issue_number>" >&2; exit 2; }

linked=$(gh issue view "$ISSUE" -R "$REPO" --json closedByPullRequestsReferences \
  --jq '[.closedByPullRequestsReferences[].number] | max // empty') || exit 2
if [ -z "$linked" ]; then
  linked=$(gh pr list -R "$REPO" --state all --limit 200 --json number,headRefName \
    --jq '[.[] | select(.headRefName | test("^(build|chore|ci|docs|feat|feature|fix|perf|refactor|revert|style|test|watson)/'"$ISSUE"'(-|$)"))] | .[0].number // empty') || exit 2
fi
[ -n "$linked" ] || exit 1
printf '%s\n' "$linked"
