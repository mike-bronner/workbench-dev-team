#!/usr/bin/env bash
set -u

REPO="${1:-}" PR="${2:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$PR" =~ ^[0-9]+$ ]] \
  || { echo "usage: $0 <owner/repo> <pr_number>" >&2; exit 2; }

gh pr view "$PR" -R "$REPO" --json additions,deletions,comments \
  --jq 'if ([.comments[].body] | any(test("<!-- watson-blocked: tactical -->"))) and ((.additions + .deletions) < 5) then "decision-request" else "review" end' || exit 2
