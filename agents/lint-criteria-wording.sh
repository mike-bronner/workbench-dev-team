#!/bin/bash

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  ❌ python3 is not on PATH, so the criteria-wording lint cannot run"
  exit 1
fi

python3 -I - "$ROOT" <<'PY'
import re
import sys

ROOT = sys.argv[1]
passed = failed = 0

GATE = {
    "MUTATION": r"(?<![a-z0-9])muta[nt]",
    "REMOVAL": r"(?<![a-z0-9])(?:(?:remov|delet|revert|restor|invert|undo|drop|disabl)\w*|comment\w*[\s-]+out\b)",
    "FAILURE": r"(?<![a-z0-9])(?:(?:fail|brok|break|redden)\w*|(?:go|goes|going|went|gone|turn|turns|turning|turned)\s+(?:\S+\s+){0,3}?red\b)",
}
STEMS = {
    "REMOVAL": ["remov", "delet", "revert", "restor", "invert", "undo", "drop", "disabl", "comment out"],
    "FAILURE": ["fail", "brok", "break", "redden", "go red", "turn red"],
}
MUTA = "a word starting with `muta` then `n` or `t`, such as mutants"


def ok(msg):
    global passed
    passed += 1
    print(f"  ✅ {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"  ❌ {msg}")


def read(rel):
    try:
        return open(f"{ROOT}/{rel}", encoding="utf-8").read()
    except OSError:
        bad(f"{rel} — missing")
        return ""


def section(text, heading):
    level = len(heading) - len(heading.lstrip("#"))
    out, inside = [], False
    for line in text.split("\n"):
        m = re.match(r"(#+) ", line)
        if inside and m and len(m.group(1)) <= level:
            break
        if line.startswith(heading):
            inside = True
        if inside:
            out.append(line)
    return " ".join(" ".join(out).split())


spawn = read("hooks/mods/spawn.ts")
for name, source in GATE.items():
    m = re.search(rf"^const {name} = /(.+)/iu$", spawn, re.M)
    if m and m.group(1) == source:
        ok(f"hooks/mods/spawn.ts: {name} is the pattern this lint holds")
    else:
        bad(f"hooks/mods/spawn.ts: {name} differs from this lint's copy. Update the docs' word lists, then GATE and STEMS here")
patterns = {name: re.compile(source, re.I) for name, source in GATE.items()}

muta_hits = [w for w in ("mutant", "mutants", "mutation", "mutated") if patterns["MUTATION"].search(w)]
muta_miss = [w for w in ("mutable", "mute", "commutation") if patterns["MUTATION"].search(w)]
if len(muta_hits) == 4 and not muta_miss:
    ok("MUTATION matches exactly the words starting with `muta` then `n` or `t`")
else:
    bad(f"MUTATION no longer matches what the docs say: it matches {muta_hits} of four, and also {muta_miss}")


def banned(item):
    return bool(patterns["MUTATION"].search(item)) or (
        bool(patterns["REMOVAL"].search(item)) and bool(patterns["FAILURE"].search(item))
    )


def words(listed):
    listed = listed.replace("go or turn red", "go red, turn red")
    parts = re.split(r",\s*|\s+and\s+", listed)
    return [re.sub(r"^and\s+", "", p).strip() for p in parts if p.strip()]


def check_list(where, kind, listed):
    name = kind.upper()
    found = words(listed)
    stray = [w for w in found if not patterns[name].search(w)]
    missing = [s for s in STEMS[name] if not any(w.lower().startswith(s) for w in found)]
    if stray:
        bad(f"{where}: the {kind} words name {stray}, which the gate does not match")
    if missing:
        bad(f"{where}: the {kind} words leave out the gate's {missing}")
    if not stray and not missing:
        ok(f"{where}: the {kind} words match the gate's {len(STEMS[name])} stems")


def require(where, text, phrases):
    gaps = [p for p in phrases if p.lower() not in text.lower()]
    for p in gaps:
        bad(f"{where} — does not state: {p}")
    if not gaps:
        ok(f"{where} states the rule")


for rel in ("agents/lestrade.md", "agents/lestrade-item.md"):
    step = section(read(rel), "### 4. Generate acceptance criteria")
    where = f"{rel} step 4"
    require(where, step, [
        "Each criterion states what a test covers.",
        "Never ask for mutation testing",
        "Never put a removal word and a failure word into one criterion",
        "Each word counts in any form.",
        "The rule holds even when the issue asks for such tests",
        "A criterion that must quote such words puts them in backticks",
    ])
    for kind in ("removal", "failure"):
        m = re.search(rf"The {kind} words are (.+?)\.", step)
        if m:
            check_list(where, kind, m.group(1))
        else:
            bad(f"{where} — lists no {kind} words")
    no = re.search(r"`- \[ \] ([^`]+)` — removal wording ❌", step)
    yes = re.search(r"`- \[ \] ([^`]+)` — coverage ✅", step)
    if no and banned(no.group(1)):
        ok(f"{where}: the gate refuses the ❌ example")
    else:
        bad(f"{where}: no ❌ example the gate refuses")
    if yes and not banned(yes.group(1)):
        ok(f"{where}: the gate passes the ✅ example")
    else:
        bad(f"{where}: no ✅ example the gate passes")

lenses = " ".join(read("references/lestrade/ac-verification-lenses.md").split())
where = "references/lestrade/ac-verification-lenses.md"
lens = re.search(r"\*\*Testability lens\*\*(.+?)(?= \d\. \*\*)", lenses)
lens = lens.group(1) if lens else ""
require(f"{where} testability lens", lens, [
    f"flag every checkbox that, outside backticks, holds {MUTA}",
    "every checkbox that, outside backticks, holds both a removal word",
    "Its fix states what a test covers",
])
require(where, lenses, [
    "a wording finding from the testability lens is always real, so rewrite that criterion as the coverage it describes before you score",
])

sweep = " ".join(read("references/lestrade/sweep-mode.md").split())
require("references/lestrade/sweep-mode.md", sweep, [
    "Word each folded case as what a test covers",
    "A folded case never asks for mutation testing or mutants",
    f"Outside backticks, it never holds {MUTA}.",
    "It never holds both a removal word",
    "outside backticks, each in any form, even when the `expand-from` comment does",
])

for where, text in ((f"{where} testability lens", lens), ("references/lestrade/sweep-mode.md", sweep)):
    for kind in ("removal", "failure"):
        m = re.search(rf"a {kind} word \(([^)]+)\)", text)
        if m:
            check_list(where, kind, m.group(1))
        else:
            bad(f"{where} — lists no {kind} words")

watson = section(read("agents/watson-index.md"), "## Rules — The Index mode")
require("agents/watson-index.md Index-mode rules", watson, [
    "Read a removal-worded criterion as the coverage it describes.",
    f"An older item can carry a criterion with {MUTA}, or one that holds both a removal word and a failure word",
    "meet it with a test that covers that behavior",
    "Run no mutation testing of any kind for it",
])

holmes = section(read("agents/holmes-index.md"), "#### 4d. Check conformance against the acceptance criteria")
require("agents/holmes-index.md step 4d", holmes, [
    "Judge a removal-worded criterion as the coverage it describes.",
    f"An older item can carry a criterion with {MUTA}, or one that holds both a removal word and a failure word",
    "It is met when a test covers that behavior, and you judge that by reading the tests.",
    "Run no mutation testing of any kind to judge it",
    "do not escalate it for its wording alone",
])

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
