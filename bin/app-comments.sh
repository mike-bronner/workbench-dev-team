#!/usr/bin/env bash
set -u

REPO="${1:-}" NUMBER="${2:-}" MARKER="${3:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$NUMBER" =~ ^[0-9]+$ ]] && [ -n "$MARKER" ] && [ $# -gt 3 ] \
  || { echo "usage: $0 <owner/repo> <issue_or_pr_number> <marker> <app-slug>..." >&2; exit 2; }
shift 3

me=
if [ "${WORKBENCH_DEV_TEAM_EXTERNAL:-}" = 1 ]; then
  me=$(gh api user --jq .login) || exit 2
  [[ "$me" =~ ^[A-Za-z0-9-]+$ ]] || { echo "$0: gh api user named no login" >&2; exit 2; }
fi

pages=$(gh api --paginate "repos/$REPO/issues/$NUMBER/comments?per_page=100") || exit 2
jq -s --arg marker "$MARKER" --arg me "$me" '{"inspector-g-lestrade": "lestrade", "mr-sherlock-holmes": "holmes", "dr-john-h-watson": "watson"} as $agents
  | [.[] | if type == "array" then .[] else error("not a comment list") end
  | if $me != "" and .user.type? == "User" and (.user.login? // "") == $me then
      select((.body // "") | startswith($marker))
      | ([.body | split("\n")[] | gsub("^\\s+|\\s+$"; "") | capture("^<!-- workbench:(?<a>[a-z]+) -->$").a] | unique) as $marks
      | ([$ARGS.positional[] | select(($marks | length) == 1 and $agents[.] == $marks[0])][0] // empty) as $app
      | {author: ($app + "[bot]"), created_at, body}
    else
      select(.user.type? == "Bot" and ((.user.login? // "") | IN($ARGS.positional[] + "[bot]")))
      | select((.body // "") | startswith($marker))
      | {author: .user.login, created_at, body}
    end]' --args "$@" <<< "$pages" || exit 2
