#!/usr/bin/env bash
set -u

FOOTER='🤖 Generated with Claude Code'
NAME='[A-Za-z0-9_.-]+'

usage() {
  {
    echo "usage: $0 comment <owner/repo> <number> <lestrade|watson>   (the body on stdin)"
    echo "       $0 pr <owner/repo> <head branch> <title>              (the body on stdin)"
  } >&2
  exit 2
}
refuse() { echo "$0: $1" >&2; exit 2; }
plain_repo() { [[ "$1" =~ ^$NAME/$NAME$ ]] && ! [[ "$1" =~ ^\.\.?/ || "$1" =~ /\.\.?$ ]]; }

[ "${WORKBENCH_DEV_TEAM_EXTERNAL:-}" = 1 ] || refuse "not an external run. Only an external run posts as the gh user."
case "${CLAUDE_CODE_AGENT:-}" in
  *holmes*) refuse "Holmes never posts to GitHub in external mode. His verdict goes to the result file." ;;
esac
TARGET="${WORKBENCH_DEV_TEAM_EXTERNAL_TARGET:-}"
TARGET_REPO="${TARGET%#*}" TARGET_NUMBER="${TARGET##*#}"
plain_repo "$TARGET_REPO" && [[ "$TARGET_NUMBER" =~ ^[1-9][0-9]*$ ]] && [ "$TARGET" = "$TARGET_REPO#$TARGET_NUMBER" ] \
  || refuse "WORKBENCH_DEV_TEAM_EXTERNAL_TARGET names no <owner/repo#n>, so this run has no repo to write to."

body() {
  local draft
  draft=$(sed -e '/[^[:space:]]/,$!d')
  [ -n "$(printf '%s' "$draft" | tr -d '[:space:]')" ] || refuse "the body is empty"
  if printf '%s\n' "$draft" | grep -q '<!--[[:space:]]*workbench:'; then
    refuse "the body already carries a workbench marker. This script adds the one marker."
  fi
  if printf '%s\n' "$draft" | grep -qF "$FOOTER"; then
    refuse "the body already carries the footer. This script adds it."
  fi
  printf '%s\n\n<!-- workbench:%s -->\n%s\n' "$draft" "$1" "$FOOTER"
}

REPO="${2:-}"
same_repo() {
  plain_repo "$REPO" || usage
  [ "$(printf '%s' "$REPO" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$TARGET_REPO" | tr 'A-Z' 'a-z')" ] \
    || refuse "this run writes only to $TARGET_REPO, its target, not to $REPO."
}

case "${1:-}" in
  comment)
    [ $# -eq 4 ] || usage
    NUMBER="$3" AGENT="$4"
    [[ "$NUMBER" =~ ^[1-9][0-9]*$ ]] || usage
    same_repo
    [ "$NUMBER" = "$TARGET_NUMBER" ] || refuse "this run comments only on #$TARGET_NUMBER, its target, not on #$NUMBER."
    case "$AGENT" in
      lestrade|watson) ;;
      holmes) refuse "Holmes never posts to GitHub in external mode." ;;
      *) usage ;;
    esac
    text=$(body "$AGENT") || exit 2
    jq -n --arg body "$text" '{body: $body}' \
      | gh api --method POST "repos/$REPO/issues/$NUMBER/comments" --input - --jq .html_url
    ;;
  pr)
    [ $# -eq 4 ] || usage
    HEAD="$3" TITLE="$4"
    [[ "$HEAD" =~ ^([A-Za-z0-9-]+:)?[A-Za-z0-9._/-]+$ ]] || usage
    same_repo
    [ -n "$(printf '%s' "$TITLE" | tr -d '[:space:]')" ] && [[ "$TITLE" != *$'\n'* ]] || refuse "the title must be one line of text"
    base=$(gh api "repos/$REPO" --jq .default_branch) || exit 2
    [ -n "$base" ] || refuse "gh named no default branch for $REPO"
    [ "${HEAD#*:}" != "$base" ] || refuse "the head is $base, the default branch. Open the PR from a branch of its own."
    text=$(body watson) || exit 2
    out=$(jq -n --arg title "$TITLE" --arg head "$HEAD" --arg base "$base" --arg body "$text" \
        '{title: $title, head: $head, base: $base, body: $body, draft: true}' \
      | gh api --method POST "repos/$REPO/pulls" --input - --jq '[.draft, .html_url] | @tsv') || exit 1
    draft=${out%%$'\t'*} url=${out#*$'\t'}
    [ "$draft" = true ] || { echo "$0: GitHub opened $url, but not as a draft" >&2; exit 1; }
    printf '%s\n' "$url"
    ;;
  *) usage ;;
esac
