#!/usr/bin/env bash
set -u

REPO="${1:-}" PR="${2:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$PR" =~ ^[0-9]+$ ]] \
  || { echo "usage: $0 <owner/repo> <pr_number>" >&2; exit 2; }

size=$(gh pr view "$PR" -R "$REPO" --json additions,deletions) || exit 2
asks=$(bash "$(dirname "$0")/app-comments.sh" "$REPO" "$PR" "<!-- watson-blocked: tactical -->" dr-john-h-watson) || exit 2
jq -r --argjson asks "$asks" \
  'if ($asks | length > 0) and ((.additions + .deletions) < 5) then "decision-request" else "review" end' <<< "$size" || exit 2
