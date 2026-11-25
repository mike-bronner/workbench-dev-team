#!/usr/bin/env bash
set -u

usage() {
  echo "usage: $0 draft_pr <pull request URL> | review_drafted < <review JSON> | needs_mike <reason>" >&2
  exit 2
}

[ "${WORKBENCH_DEV_TEAM_EXTERNAL:-}" = 1 ] || { echo "$0: not an external run, so there is no result file to write" >&2; exit 2; }
RESULT="${WORKBENCH_DEV_TEAM_RESULT:-}"
case "$RESULT" in
  /*.result.json) ;;
  *) echo "$0: WORKBENCH_DEV_TEAM_RESULT names no result file" >&2; exit 2 ;;
esac
current=$(jq -r '.state // empty' "$RESULT" 2>/dev/null)
[ "$current" = running ] || { echo "$0: the result file holds state '${current:-none}', not running, so this run already ended" >&2; exit 2; }
CLAIM="${RESULT%.json}.claim"

case "${1:-}" in
  draft_pr)
    [ $# -eq 2 ] || usage
    [[ "$2" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$ ]] \
      || { echo "$0: not a pull request URL: $2" >&2; exit 2; }
    object=$(jq -n --arg url "$2" '{state: "draft_pr", prUrl: $url, review: null, error: null}') || exit 2
    ;;
  needs_mike)
    [ $# -eq 2 ] || usage
    [ -n "$(printf '%s' "$2" | tr -d '[:space:]')" ] || { echo "$0: needs_mike takes a reason" >&2; exit 2; }
    object=$(jq -n --arg reason "$2" '{state: "needs_mike", prUrl: null, review: null, error: $reason}') || exit 2
    ;;
  review_drafted)
    [ $# -eq 1 ] || usage
    object=$(jq -s '
      def text: type == "string" and test("\\S");
      if length != 1 then error("the review is not one JSON value") else .[0] end
      | if type != "object" then error("the review is not an object") else . end
      | if (.event | IN("APPROVE", "REQUEST_CHANGES")) then . else error("event is neither APPROVE nor REQUEST_CHANGES") end
      | if (.body | text) then . else error("body holds no text") end
      | if (.comments // [] | type) == "array" then . else error("comments is not a list") end
      | if all(.comments // [] | .[]; type == "object" and (.path | text) and (.body | text)
          and (.line | type) == "number" and .line >= 1 and .line == (.line | floor)) then .
        else error("each comment needs a path, a line of 1 or more, and a body") end
      | {state: "review_drafted", prUrl: null,
         review: ({event, body} + (if (.comments // []) == [] then {} else {comments: [.comments[] | {path, line, body}]} end)),
         error: null}') \
      || { echo "$0: the review on stdin is not a valid review" >&2; exit 2; }
    ;;
  *) usage ;;
esac

mkdir "$CLAIM" 2>/dev/null || { echo "$0: another call already claimed the final state of this run" >&2; exit 2; }
current=$(jq -r '.state // empty' "$RESULT" 2>/dev/null)
[ "$current" = running ] || { echo "$0: the result file holds state '${current:-none}', not running, so this run already ended" >&2; exit 2; }
tmp=$(mktemp "$RESULT.XXXXXX") || exit 1
if printf '%s\n' "$object" > "$tmp" && mv -f "$tmp" "$RESULT"; then
  exit 0
fi
rm -f -- "$tmp"
exit 1
