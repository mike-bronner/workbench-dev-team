#!/bin/bash
# A vault note written by a path an agent built never replaces an existing note.
# Run directly: bash agents/lint-vault-note-paths.sh
#
# A LINTER, not a test: it reads the fenced call blocks and the prose in the
# shipped Markdown, and runs none of the plugin's shell logic.
#
# Why: on 2026-10-08 a Holmes Local-mode review wrote its learnings note to a
# path an earlier review had used that morning. The memory MCP's `write`
# replaces the whole file, so the earlier note was lost until it was restored
# from the vault's git history. The write answered `created: false`, and that
# was the only sign. The agent builds every such path itself, so nothing but its
# own instruction stops a repeat.
#
# A read cannot prove a path is free. The server (markdown-vault-mcp 4.1.0)
# answers `Document not found: <path>` both for a missing file and for a note it
# cannot parse: managers/document.py read() returns None for either, and
# _server_tools/reader.py turns None into that one error. So the name itself
# must be unique: the time to the second and a token from `openssl rand -hex 3`.
# The read stays as a check, and `created: false` stays as the backstop.
#
# Checks, over every Markdown file in the repo (agents, references, skills,
# commands, hooks, the root, and anywhere else git sees one):
#   1. No `memory__write(` call stands outside a code fence. Prose cannot carry
#      the read and the unique name beside the call, so a call there is unchecked.
#   2. Every fenced `memory__write(` whose path is built (it holds `<`, `{` or
#      `$`) ends in `-<hhmmss>-<token>.md`, is preceded in the same block by a
#      `memory__read(` of the same path, and names `created: false`. A write to a
#      fixed path, such as the top-lessons digest, is read and updated in place
#      on purpose, and is not held to this.
#   3. Each file with such a write states the rule in prose: the two commands
#      that make the name, what the read proves, and what `created: false` means.
#   4. The three known note writes are still found: two in holmes.md, one in
#      local-review.md, and the composed holmes-index.md carries holmes.md's two.
#      A rename that hid them from this scan must fail, never pass empty.
#   5. Both composed Holmes modes carry the Rules pointer.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# One record per note write, tab-separated: <line> <verdict> <detail>.
# The verdict is `ok` or `bad`. A fenced write to a fixed path prints nothing.
scan() {
  awk '
    function finish(   built) {
      if (pending == "") return
      pending = ""
      if (wpath == "") { print wline "\tbad\tno path after the write call"; return }
      built = (wpath ~ /[<{$]/)
      if (!built) return
      if (wpath !~ /-<hhmmss>-<token>\.md$/)
        print wline "\tbad\tthe built path does not end in -<hhmmss>-<token>.md, so it is not unique: " wpath
      else if (!(wpath in reads))
        print wline "\tbad\tno read of " wpath " before the write in this block"
      else if (wnote !~ /created: false/)
        print wline "\tbad\tthe write does not say what to do on created: false"
      else
        print wline "\tok\t" wpath
    }
    /^[ \t]*```/ { finish(); inblock = !inblock; delete reads; next }
    !inblock && /memory__write\(/ {
      print NR "\tbad\ta note write outside a code fence, where no check reaches it"; next
    }
    !inblock { next }
    /memory__read\("/ {
      p = $0; sub(/.*memory__read\("/, "", p); sub(/".*/, "", p); reads[p] = 1
    }
    /memory__write\(/ { finish(); pending = 1; wline = NR; wpath = ""; wnote = "" }
    pending && wpath == "" && /path[:=] *"/ {
      wpath = $0; sub(/.*path[:=] *"/, "", wpath); sub(/".*/, "", wpath); wnote = $0
    }
    pending && /^\)/ { finish() }
    END { finish() }
  ' "$1"
}

files=()
while IFS= read -r f; do files+=("$f"); done < <(cd "$ROOT" && git ls-files --cached --others --exclude-standard '*.md' | sort -u)
[ "${#files[@]}" -ge 10 ] && ok "${#files[@]} Markdown files scanned" || bad "only ${#files[@]} Markdown files found"

count_holmes=0; count_index=0; count_local=0
for rel in "${files[@]}"; do
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  records="$(scan "$f")"
  [ -n "$records" ] || continue
  n=0
  while IFS=$'\t' read -r line verdict detail; do
    if [ "$verdict" = ok ]; then n=$((n + 1)); ok "$rel:$line — unique name, read before the write of $detail"
    else bad "$rel:$line — $detail"; fi
  done <<< "$records"
  case "$rel" in
    agents/holmes.md) count_holmes=$n ;;
    agents/holmes-index.md) count_index=$n ;;
    references/holmes/local-review.md) count_local=$n ;;
  esac
  [ "$n" -gt 0 ] || continue

  # ── 3. The rule, in prose, beside the writes ──────────────────────────────
  prose="$(tr '\n' ' ' < "$f" | tr -s ' ')"
  for phrase in 'date +%H%M%S' 'openssl rand -hex 3' 'Never make up the token yourself.' \
                'answers `Document not found: <path>` both for a missing file and for a note it cannot parse' \
                'This is the only answer that counts as free.' \
                '**`created: false` means the write replaced an existing note.**' \
                'Vault note replaced: <path> (created: false).'; do
    [[ $prose == *"$phrase"* ]] || bad "$rel — the note-writing rule lacks: $phrase"
  done
done

# ── 4. The known writes are still found ─────────────────────────────────────
[ "$count_holmes" -eq 2 ] && ok "holmes.md — both §5.5 note writes found" \
  || bad "holmes.md — expected 2 checked note writes by a built path, found $count_holmes"
[ "$count_index" -eq 2 ] && ok "holmes-index.md — both composed §5.5 note writes found" \
  || bad "holmes-index.md — expected 2 checked note writes by a built path, found $count_index"
[ "$count_local" -eq 1 ] && ok "local-review.md — the §L5.5 note write found" \
  || bad "local-review.md — expected 1 checked note write by a built path, found $count_local"

# ── 5. The Rules pointer reaches both composed modes ────────────────────────
for mode in holmes-index holmes-local; do
  grep -Fq '**A new vault note never replaces an existing one.**' "$DIR/$mode.md" \
    && ok "$mode.md carries the Rules pointer" \
    || bad "$mode.md — the Rules pointer to the note-naming rule is gone"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
