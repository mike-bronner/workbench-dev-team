#!/usr/bin/env bash
set -u

REPO="${1:-}" PR="${2:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$PR" =~ ^[0-9]+$ ]] \
  || { echo "usage: $0 <owner/repo> <pr_number>" >&2; exit 2; }

MIKE="${HOLMES_STRIKE_LOGIN:-mikebronner}"
activity=$(gh pr view "$PR" -R "$REPO" --json comments,reviews) || exit 2
inline=$(gh api "repos/$REPO/pulls/$PR/comments?per_page=100") || exit 2

jq -rn --argjson a "$activity" --argjson i "$inline" --arg mike "$MIKE" '
  ([ ($a.comments[] | select(.author.login == $mike) | .createdAt),
     ($a.reviews[]  | select(.author.login == $mike) | .submittedAt),
     ($i[]          | select(.user.login   == $mike) | .created_at) ] | max // "") as $since
  | [ $a.reviews[] | select(.state == "CHANGES_REQUESTED") | select($since == "" or .submittedAt > $since) ]
  | length' || exit 2
