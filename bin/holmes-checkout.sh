#!/usr/bin/env bash
set -u

usage() { echo "usage: $0 open <owner/repo> <pr_number> <scratch root> | close <path>" >&2; exit 2; }

is_scratch_root() {
  local dir home
  dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  home=$(cd "$HOME/Developer/scratchpad" 2>/dev/null && pwd -P) && [ "$dir" = "$home" ] && return 0
  case "$dir" in
    /private/tmp/claude-*/*/*/scratchpad|/tmp/claude-*/*/*/scratchpad) return 0 ;;
  esac
  return 1
}

case "${1:-}" in
  open)
    REPO="${2:-}" PR="${3:-}" ROOT="${4:-}"
    [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$PR" =~ ^[0-9]+$ ]] || usage
    is_scratch_root "$ROOT" || { echo "$0: not a scratch root: $ROOT" >&2; exit 2; }
    dir=$(mktemp -d "${ROOT%/}/holmes.XXXXXX") || exit 1
    if gh repo clone "$REPO" "$dir" -- --quiet >&2 && (cd "$dir" && gh pr checkout "$PR" >&2); then
      printf '%s\n' "$dir"
      exit 0
    fi
    rm -rf -- "$dir"
    exit 1
    ;;
  close)
    dir="${2:-}"
    [ -n "$dir" ] || usage
    [[ "$(basename -- "$dir")" =~ ^holmes\.[A-Za-z0-9]{6}$ ]] && is_scratch_root "$(dirname -- "$dir")" \
      || { echo "$0: not a holmes checkout under a scratch root: $dir" >&2; exit 2; }
    [ -d "$dir" ] || exit 0
    rm -rf -- "$dir"
    ;;
  *) usage ;;
esac
