#!/usr/bin/env bash
# Run: bash commands/test-dispatch-setup.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SRC="$REPO/commands/setup.md"
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: expected to contain [$2] in [$3]" ;; esac; }

for block in dispatcher-install dispatcher-allow; do
  awk "/# >>> $block >>>/{f=1;next} /# <<< $block <<</{f=0} f" "$SRC" > "$WORK/$block.sh"
  [ -s "$WORK/$block.sh" ] || { echo "FAIL: could not extract the $block block from $SRC"; exit 1; }
done

SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

fake_src() {
  local root="$WORK/src-$1-${2:-pass}-${3:-whole}" f
  mkdir -p "$root/bin"
  printf '%s dispatcher\n' "$1" > "$root/bin/dispatch-agent.sh"
  for f in test-dispatch-agent.sh test-circuit-breaker.sh; do
    printf 'exit %s\n' "$([ "$f" = "${2:-}" ] && echo 1 || echo 0)" > "$root/bin/$f"
  done
  [ -z "${3:-}" ] || rm -f "$root/bin/$3"
  printf '%s' "$root"
}
install_run() { ( HOME="$2" SRC_ROOT="$3" "$1" "$WORK/dispatcher-install.sh" 2>&1 ); }
installed() { cat "$1/.claude-workbench/bin/dispatch-agent.sh" 2>/dev/null; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

for sh in $SHELLS; do
  echo "Testing setup's dispatcher-install, under $sh:"
  home="$WORK/home-install-$sh"; mkdir -p "$home"

  out=$(install_run "$sh" "$home" "$(fake_src v1)"); rc=$?
  expect_eq "a first install exits 0" 0 "$rc"
  expect_eq "and installs the dispatcher" "v1 dispatcher" "$(installed "$home")"
  expect_eq "as an executable" 755 "$(mode_of "$home/.claude-workbench/bin/dispatch-agent.sh")"
  expect_eq "and leaves no staged copy" no "$([ -e "$home/.claude-workbench/bin/dispatch-agent.sh.new" ] && echo yes || echo no)"
  expect_has "and says so" "Dispatcher installed and self-tested" "$out"

  out=$(install_run "$sh" "$home" "$(fake_src v2)"); rc=$?
  expect_eq "a re-run exits 0" 0 "$rc"
  expect_eq "and replaces the dispatcher" "v2 dispatcher" "$(installed "$home")"

  for suite in test-dispatch-agent.sh test-circuit-breaker.sh; do
    out=$(install_run "$sh" "$home" "$(fake_src v3 "$suite")"); rc=$?
    expect_eq "a failing $suite exits 1" 1 "$rc"
    expect_has "and names it" "bin/$suite failed" "$out"
    expect_has "and says nothing changed" "Nothing changed" "$out"
    expect_eq "and the installed dispatcher stays" "v2 dispatcher" "$(installed "$home")"
  done

  for missing in dispatch-agent.sh test-dispatch-agent.sh test-circuit-breaker.sh; do
    out=$(install_run "$sh" "$home" "$(fake_src v3 "" "$missing")"); rc=$?
    expect_eq "a missing $missing exits 1" 1 "$rc"
    expect_has "and names it" "$missing is missing" "$out"
    expect_eq "and the installed dispatcher stays" "v2 dispatcher" "$(installed "$home")"
  done

  out=$(install_run "$sh" "$home" ""); rc=$?
  expect_eq "an empty SRC_ROOT exits 1" 1 "$rc"
  expect_eq "and the installed dispatcher stays" "v2 dispatcher" "$(installed "$home")"

  chmod u-w "$home/.claude-workbench/bin"
  out=$(install_run "$sh" "$home" "$(fake_src v4)"); rc=$?
  chmod u+w "$home/.claude-workbench/bin"
  expect_eq "a write that fails exits 1" 1 "$rc"
  expect_has "and says the old dispatcher still runs" "still runs" "$out"
  expect_eq "and the installed dispatcher stays" "v2 dispatcher" "$(installed "$home")"
done

echo "Testing dispatcher-install with the shipped dispatcher and suites:"
home="$WORK/home-shipped"; mkdir -p "$home"
out=$(install_run bash "$home" "$REPO"); rc=$?
expect_eq "the shipped suites pass, so it exits 0" 0 "$rc"
expect_eq "and installs the shipped dispatcher" yes "$(cmp -s "$REPO/bin/dispatch-agent.sh" "$home/.claude-workbench/bin/dispatch-agent.sh" && echo yes || echo no)"

allow_run() { ( HOME="$2" WORKBENCH_SETTINGS_FILE="$3" "$1" "$WORK/dispatcher-allow.sh" 2>&1 ); }
backups() { ls "$1".bak-dispatcher-* 2>/dev/null | wc -l | tr -d ' '; }

for sh in $SHELLS; do
  echo "Testing setup's dispatcher-allow, under $sh:"
  home="$WORK/home-allow-$sh"; mkdir -p "$home"
  ABS="Bash(bash $home/.claude-workbench/bin/dispatch-agent.sh:*)"
  # shellcheck disable=SC2016  # the rule spells $HOME literally
  HOMEFORM='Bash(bash "$HOME/.claude-workbench/bin/dispatch-agent.sh":*)'
  BOTH=$(jq -nc --arg a "$ABS" --arg h "$HOMEFORM" '[$a, $h]')

  cfg="$WORK/allow-$sh.json"
  jq -n '{model: "x", permissions: {allow: ["Bash(ls:*)", "Read"], ask: ["Bash(git push *)"]}}' > "$cfg"
  out=$(allow_run "$sh" "$home" "$cfg"); rc=$?
  expect_eq "exit 0" 0 "$rc"
  expect_eq "both rules are added after the others" "$(jq -nc --argjson b "$BOTH" '["Bash(ls:*)", "Read"] + $b')" "$(jq -c .permissions.allow "$cfg")"
  expect_eq "every other key stays" '{"ask":["Bash(git push *)"],"model":"x"}' "$(jq -c '{ask: .permissions.ask, model}' "$cfg")"
  expect_eq "a backup is taken" 1 "$(backups "$cfg")"

  before=$(cat "$cfg")
  out=$(allow_run "$sh" "$home" "$cfg"); rc=$?
  expect_eq "a re-run exits 0" 0 "$rc"
  expect_has "and finds both rules" "Both dispatch-agent.sh allow rules are in" "$out"
  expect_eq "and changes nothing" "$before" "$(cat "$cfg")"
  expect_eq "and takes no second backup" 1 "$(backups "$cfg")"

  cfg="$WORK/allow-one-$sh.json"
  jq -n --arg h "$HOMEFORM" '{permissions: {allow: [$h, "Read"]}}' > "$cfg"
  allow_run "$sh" "$home" "$cfg" >/dev/null
  expect_eq "with one rule there, only the other is added" "$(jq -nc --arg a "$ABS" --arg h "$HOMEFORM" '[$h, "Read", $a]')" "$(jq -c .permissions.allow "$cfg")"

  cfg="$WORK/allow-keep-$sh.json"
  jq -n --argjson b "$BOTH" '{permissions: {allow: (["Bash(ls:*)"] + $b + ["Read"]), deny: ["WebFetch"]}}' > "$cfg"
  before=$(cat "$cfg")
  allow_run "$sh" "$home" "$cfg" >/dev/null
  expect_eq "a file with both rules keeps every rule, in its order" "$before" "$(cat "$cfg")"

  cfg="$WORK/allow-noperm-$sh.json"
  printf '{"model": "x"}' > "$cfg"
  allow_run "$sh" "$home" "$cfg" >/dev/null
  expect_eq "a file with no permissions gets both rules" "$BOTH" "$(jq -c .permissions.allow "$cfg")"
  expect_eq "and keeps its keys" '"x"' "$(jq -c .model "$cfg")"

  cfg="$WORK/allow-none-$sh.json"
  out=$(allow_run "$sh" "$home" "$cfg"); rc=$?
  expect_eq "no settings file exits 0" 0 "$rc"
  expect_eq "and is written with both rules" "$BOTH" "$(jq -c .permissions.allow "$cfg" 2>/dev/null)"

  for shape in '["not", "an", "object"]' '{not json'; do
    cfg="$WORK/allow-bad-$sh.json"
    printf '%s' "$shape" > "$cfg"
    out=$(allow_run "$sh" "$home" "$cfg"); rc=$?
    expect_eq "settings of $shape exit 1" 1 "$rc"
    expect_has "and say the file is not a JSON object" "is not a JSON object" "$out"
    expect_eq "and are left untouched" "$shape" "$(cat "$cfg")"
  done

  cfg="$WORK/allow-badallow-$sh.json"
  printf '{"permissions": {"allow": "Read"}}' > "$cfg"
  out=$(allow_run "$sh" "$home" "$cfg"); rc=$?
  expect_eq "an allow list that is not an array exits 1" 1 "$rc"
  expect_eq "and is left untouched" '{"permissions": {"allow": "Read"}}' "$(cat "$cfg")"
done

echo
echo "dispatch setup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
