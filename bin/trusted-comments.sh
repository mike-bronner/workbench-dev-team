#!/usr/bin/env bash
set -u

REPO="${1:-}" NUMBER="${2:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$NUMBER" =~ ^[0-9]+$ ]] \
  || { echo "usage: $0 <owner/repo> <issue_or_pr_number> [--no-issue-author] [app-slug]..." >&2; exit 2; }
shift 2
trust_author=1
[ "${1:-}" = --no-issue-author ] && { trust_author=0; shift; }
for slug in "$@"; do
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "$0: not an App slug: $slug" >&2; exit 2; }
done

codeowners=
for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
  if file=$(gh api "repos/$REPO/contents/$path"); then
    codeowners=$(jq -r 'if .type == "file" then .content | gsub("\\s"; "") | @base64d else error("not a file") end' <<< "$file") || exit 2
    break
  fi
  jq -e '.message == "Not Found"' <<< "$file" >/dev/null 2>&1 || exit 2
done

owners=()
while read -r owner; do
  if [[ "$owner" =~ ^[a-z0-9-]+$ ]]; then
    owners+=("$owner")
  elif [[ "$owner" =~ ^([a-z0-9_.-]+)/([a-z0-9_.-]+)$ ]]; then
    members=$(gh api --paginate "orgs/${BASH_REMATCH[1]}/teams/${BASH_REMATCH[2]}/members?per_page=100" --jq '.[].login') \
      || { echo "team @$owner: members unreadable, so it grants no trust" >&2; continue; }
    while read -r login; do [ -n "$login" ] && owners+=("$(tr '[:upper:]' '[:lower:]' <<< "$login")"); done <<< "$members"
  fi
done < <(sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' <<< "$codeowners" \
  | awk '{ for (i = 2; i <= NF; i++) if ($i ~ /^@/) print tolower(substr($i, 2)) }' | sort -u)

author=
if [ "$trust_author" = 1 ]; then
  issue=$(gh api "repos/$REPO/issues/$NUMBER") || exit 2
  author=$(jq -r 'if type != "object" then error("not an issue")
    elif has("pull_request") or .user.type? != "User" then "" else .user.login // "" end' <<< "$issue") || exit 2
fi

pages=$(gh api --paginate "repos/$REPO/issues/$NUMBER/comments?per_page=100") || exit 2
jq -s --arg author "$author" --args '($ARGS.positional | map(select(startswith("owner:")) | ltrimstr("owner:"))) as $owners
  | ($ARGS.positional | map(select(startswith("app:")) | ltrimstr("app:") + "[bot]")) as $apps
  | [.[] | if type == "array" then .[] else error("not a comment list") end
  | (.user.login? // "") as $login
  | select((.user.type? == "Bot" and ($login | IN($apps[])))
      or (.user.type? == "User" and ($login == "mikebronner" or ($author != "" and $login == $author) or ($login | ascii_downcase | IN($owners[])))))
  | {author: .user.login, created_at, body}]' \
  "${@/#/app:}" "${owners[@]/#/owner:}" <<< "$pages" || exit 2
