#!/usr/bin/env bash
set -u

REPO="${1:-}" PR="${2:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$PR" =~ ^[0-9]+$ ]] \
  || { echo "usage: $0 <owner/repo> <pr_number>" >&2; exit 2; }

POLICY=.workbench/approval-policy.json
person() { printf 'person\n- %s\n' "$1"; exit 0; }

pull=$(gh api "repos/$REPO/pulls/$PR") || person "the PR could not be read"
base=$(jq -r '.base.ref | strings' <<< "$pull" 2>/dev/null)
[ -n "$base" ] || person "the PR names no base branch"
count=$(jq -r '.changed_files | numbers' <<< "$pull" 2>/dev/null)
[[ "$count" =~ ^[0-9]+$ ]] || person "the PR names no count of changed files"

pages=$(gh api --paginate "repos/$REPO/pulls/$PR/files?per_page=100") || person "the changed files could not be read"
files=$(jq -cs '[.[] | if type == "array" then .[] else error("not a file list") end]' <<< "$pages" 2>/dev/null) \
  || person "the changed files could not be read"
listed=$(jq length <<< "$files")
[ "$count" -gt 0 ] && [ "$listed" = "$count" ] || person "the file list holds $listed of the PR's $count changed files"

ref=$(jq -rn --arg b "$base" '$b | @uri')
if ! file=$(gh api "repos/$REPO/contents/$POLICY?ref=$ref"); then
  jq -e '.message == "Not Found"' <<< "$file" >/dev/null 2>&1 && person "$base has no $POLICY"
  person "the $POLICY on $base could not be read"
fi
policy=$(jq -r 'if .type == "file" then .content | gsub("\\s"; "") | @base64d else error("not a file") end' <<< "$file" 2>/dev/null) \
  || person "the $POLICY on $base is not a file"

jq -r --arg policy "$policy" --arg base "$base" --arg name "$POLICY" '
  def pattern: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
  def valid: type == "object" and (.rules | type) == "array" and (.rules | length) > 0
    and all(.rules[]; type == "object" and (.approval | IN("holmes", "person"))
      and (.paths | type) == "array" and (.paths | length) > 0 and all(.paths[]; type == "string" and . != ""));
  ($policy | try fromjson catch null) as $p
  | if ($p | valid | not) then "person\n- the \($name) on \($base) is not valid"
    else
      ([.[] | .filename, (.previous_filename // empty)] | unique) as $paths
      | [$paths[] as $path
          | [$p.rules[] | select(any(.paths[]; . as $glob | $path | test($glob | pattern))) | .approval] as $verdicts
          | if $verdicts == [] then "- \($path): no rule matches it"
            elif any($verdicts[]; . == "person") then "- \($path): a rule needs a person"
            else empty end] as $why
      | if $why == [] then "holmes" else (["person"] + $why | join("\n")) end
    end' <<< "$files" 2>/dev/null || person "the $POLICY on $base could not be applied"
