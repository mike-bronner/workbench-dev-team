#!/usr/bin/env bash
set -u

REPO="${1:-}" ISSUE="${2:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$ISSUE" =~ ^[0-9]+$ ]] \
  || { echo "usage: $0 <owner/repo> <issue_number>" >&2; exit 2; }

issue=$(gh issue view "$ISSUE" -R "$REPO" --json body,comments) || exit 2

ac=$(jq -r '[.comments[].body | select(split("\n")[0] | rtrimstr("\r") == "<!-- acceptance-criteria -->")] | last // empty
  | split("\n")[1:] | join("\n")' <<< "$issue") || exit 2
if [ -z "$ac" ]; then
  ac=$(jq -r '.body // ""' <<< "$issue" | awk '
    /^## Acceptance Criteria[[:space:]]*$/ { on = 1; print; next }
    on && /^#{1,2} / { exit }
    on { print }')
fi
[ -n "$(printf '%s' "$ac" | tr -d '[:space:]')" ] || exit 1
printf '%s\n' "$ac"
