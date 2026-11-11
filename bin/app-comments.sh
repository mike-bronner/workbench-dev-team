#!/usr/bin/env bash
set -u

REPO="${1:-}" NUMBER="${2:-}" MARKER="${3:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$NUMBER" =~ ^[0-9]+$ ]] && [ -n "$MARKER" ] && [ $# -gt 3 ] \
  || { echo "usage: $0 <owner/repo> <issue_or_pr_number> <marker> <app-slug>..." >&2; exit 2; }
shift 3

pages=$(gh api --paginate "repos/$REPO/issues/$NUMBER/comments?per_page=100") || exit 2
jq -s --arg marker "$MARKER" '[.[] | if type == "array" then .[] else error("not a comment list") end
  | select(.user.type? == "Bot" and ((.user.login? // "") | IN($ARGS.positional[] + "[bot]")))
  | select((.body // "") | startswith($marker))
  | {author: .user.login, created_at, body}]' --args "$@" <<< "$pages" || exit 2
