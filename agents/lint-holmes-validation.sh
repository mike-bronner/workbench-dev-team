#!/bin/bash
# Holmes validates in place. Run directly: bash agents/lint-holmes-validation.sh
#
# A LINTER, not a test: it reads English prose in the shipped Markdown and runs
# none of the plugin's shell logic.
#
# Why: on 2026-10-09 Mike asked why Holmes worked in scratch folders and not on
# the project, then ruled that a reviewer never changes code to validate it: it
# runs the existing tests in place and inspects them for validity, and a hole no
# test covers is a finding that names the missing test, which the builder adds.
# The prompts used to
# send every lens, skeptic and panel role to "a probe on a copy in your own
# scratch folder", and the reviewers did exactly that.
#
# FAIL CLOSED, BY CLASS. A list of forbidden spellings loses to the next
# spelling, so this lint names the topics instead. In every Holmes and lens
# prompt (FILES below), each sentence that mentions any of these:
#   - a probe (probe, probes, probed, probing);
#   - a copy (copy, copies, copied, copying);
#   - mutation (mutate, mutation, mutating, and the rest);
#   - a code change: change, edit, invert, delete, remove, modify, patch,
#     alter, tweak, break or comment out, with code, a check, a guard, a line,
#     a condition, a branch or the source as its object ("the change" as a noun
#     is the diff under review, not an instruction);
# must be a prohibition, or the lint fails. A prohibition has a negation (no,
# never, not, don't, nothing, nor, without, cannot) that governs the topic
# word: within the three words before it ("never change code"), or in the two
# words right after it ("copy no repository"). A negation does not govern it
# when:
#   - a comma, semicolon or colon stands between them ("If no test covers the
#     branch, invert the condition");
#   - an if, when or unless clause stands between them, or holds the negation
#     with no comma to close it ("Unless no suite exists edit the line");
#   - a reversing verb (forget, hesitate, fail, skip, omit, neglect) follows
#     the negation ("Don't forget to probe the path");
#   - it comes later in the sentence ("Edit the line, and do not forget to put
#     it back").
#
# ACCEPTED LIMITS (Mike, 2026-10-09). The topic lists are finite, so an ask
# worded around them passes: a verb off the list (flip, replace, rewrite, stub
# and the like), an object off the list (a function, a file, an assertion),
# and a probe called something else, such as "a script". Mike chose to fix the
# negation scope and stop there, rather than chase each new spelling. The
# prompts' own prohibitions and Holmes's review of a prompt change are the
# backstop for those.
#
# Also checked:
#   - Each file states the rule: run the existing tests, copy no repository,
#     and report a hole no test covers as a finding that names the missing test.
#   - Self-check: every MUST_FAIL sample is caught, and every MUST_PASS sample,
#     the prohibitions the prompts carry, passes. A rule that catches nothing
#     would hold this lint green over any regression.
#
# Sentences: each paragraph, and each list item in it, is joined onto one line,
# then split after . ! ? or : where the next sentence starts. Fenced blocks are
# read too, because the helper prompt skeletons live in them.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  ❌ python3 is not on PATH, so the validation lint cannot run"
  exit 1
fi

python3 - "$ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
FILES = [
    "agents/holmes.md",
    "agents/holmes-local.md",
    "agents/holmes-index.md",
    "agents/holmes-lens.md",
    "references/holmes/local-review.md",
    "references/holmes/review-phases.md",
]

TOPIC = re.compile(
    r"\bprob(?:e|es|ed|ing)\b"
    r"|\bcop(?:y|ies|ied|ying)\b"
    r"|\bmutat\w*"
    r"|(?<!the )(?<!this )(?<!that )(?<!'s )(?<!a )"
    r"\b(?:chang|edit|invert|delet|remov|modif|patch|alter|tweak|break|comment(?:s|ed|ing)?\s+out)\w*"
    r"(?:\s+\S+){0,3}?\s+(?:code|checks?|guard\w*|lines?|conditions?|branch\w*|source)\b",
    re.I,
)
NEGATION = re.compile(r"\b(?:no|never|not|don't|do not|nothing|nor|without|cannot)\b|n't\b", re.I)
# A clause boundary ends a negation's reach.
BOUNDARY = re.compile(r"[,;:]|\b(?:if|when|unless)\b", re.I)
# A verb that turns a negation into an ask ("don't forget to probe").
REVERSAL = re.compile(r"\b(?:forget|hesitate|fail|skip|omit|neglect)\b", re.I)

MUST_FAIL = [
    # Mike's review of this lint (2026-10-09): asks the first version missed.
    "Write a short throwaway probe in scratch.",
    "Run the probe on the checkout.",
    "Probe the fail-open path on a copy of the checkout.",
    "Edit the guarded line, run the tests, and put it back.",
    "Comment out the check and confirm the test goes red.",
    "Run a mutation sweep over the new tests.",
    # The wording the prompts carried before the rule.
    "A probe that needs a mutated tree runs on a copy you make in your own scratch folder, and you change only that copy.",
    "That covers a clone, a probe copy, and a place for intermediate output.",
    "At most, write one small probe script in scratch.",
    "Copy the repository into scratch and trim the test files.",
    "Mutation-test the guard: delete or invert the guarded code and confirm red.",
    "Edit the guarded line, and do not forget to put it back.",
    "Use the project's own runner, then edit the guarded line.",
    "Invert the condition and confirm the test fails.",
    # A negation that governs another clause, or that a verb reverses.
    "If no test covers the branch, invert the condition and confirm red.",
    "Run mutation testing only through the project's own runner, and only when that runner mutates in place without editing a file, such as `pest --mutate` in a Pest project.",
    "Mutation testing runs only through a project's own in-place runner such as `pest --mutate`.",
    "Don't forget to probe the fail-open path on a copy of the checkout.",
]
MUST_PASS = [
    "Write no probe script, copy no repository, make no code change, and trim no test file.",
    "Do not make one even for a change you would undo after, and not even in scratch.",
    "Run no mutation testing of any kind, not even through a project's own runner.",
    "Report a hole no test covers as a finding that names the missing test.",
    "Never change a file in the tree under review, not even for a moment and not even to undo it after.",
    "You never change code to validate it.",
    "Coupling: the change made this code stale, inconsistent, or wrong.",
    "Clone the repo and check out the PR's branch.",
]

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  ✅ {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"  ❌ {msg}")


def chunks(text):
    """Each paragraph, with each list item its own chunk, on one line."""
    for para in re.split(r"\n\s*\n", text):
        item = []
        for line in para.split("\n"):
            if re.match(r"\s*(?:[-*>]|\d+\.)\s", line) and item:
                yield " ".join(item)
                item = []
            item.append(line.strip())
        if item:
            yield " ".join(item)


def sentences(text):
    for chunk in chunks(text):
        for s in re.split(r"(?<=[.!?:])(?:\*\*)?\s+(?=[A-Z`*(\"])", chunk):
            if s.strip():
                yield s.strip()


def governed(sentence, start):
    """Whether a negation governs the topic word at `start`: within the three
    words before it, or the two words right after it, with no clause boundary
    in between, and no reversing verb between a negation and the word."""
    before = sentence[:start]
    cuts = list(BOUNDARY.finditer(before))
    if cuts:
        before = before[cuts[-1].end():]
    # After an if, when or unless with no comma to close it, a negation is
    # the condition's, never the topic word's.
    in_condition = bool(cuts) and cuts[-1].group(0).isalpha()
    window = " ".join(before.split()[-3:])
    negations = list(NEGATION.finditer(window))
    if negations and not in_condition and not REVERSAL.search(window[negations[-1].end():]):
        return True
    first, _, rest = sentence[start:].partition(" ")
    if re.search(r"[,;:]$", first):
        return False
    cut = BOUNDARY.search(rest)
    if cut:
        rest = rest[:cut.start()]
    return bool(NEGATION.search(" ".join(rest.split()[:2])))


def ask(sentence):
    """The first topic word no prohibition governs, or None."""
    for m in TOPIC.finditer(sentence):
        if not governed(sentence, m.start()):
            return m.group(0)
    return None


# Self-check first: the rule must catch what it was written against.
missed = [s for s in MUST_FAIL if ask(s) is None]
flagged = [s for s in MUST_PASS if ask(s) is not None]
for s in missed:
    bad(f"self-check: the rule lets through: {s}")
for s in flagged:
    bad(f"self-check: a prohibition reads as an ask ({ask(s)}): {s}")
if not missed and not flagged:
    ok(f"the rule catches all {len(MUST_FAIL)} asks and passes all {len(MUST_PASS)} prohibitions")

for rel in FILES:
    try:
        text = open(f"{ROOT}/{rel}", encoding="utf-8").read()
    except OSError:
        bad(f"{rel} — missing")
        continue
    hits = [(ask(s), s) for s in sentences(text)]
    hits = [(word, s) for word, s in hits if word is not None]
    for word, s in hits:
        bad(f"{rel} names '{word}' with no prohibition governing it: {s[:180]}")
    if not hits:
        ok(f"{rel}: every probe, copy, mutation or code-change sentence is a prohibition")

    flat = " ".join(text.split())
    missing = []
    if not re.search(r"\brun(?:ning|s)?\b[^.]{0,30}?\bexisting (?:tests|test suites?|suites?)", flat, re.I):
        missing.append("run the existing tests in place")
    if "copy no repository" not in flat.lower():
        missing.append("copy no repository")
    if "names the missing test" not in flat.lower():
        missing.append("a hole no test covers is a finding that names the missing test")
    if "test strength by reading the tests" not in flat.lower():
        missing.append("judge test strength by reading the tests")
    if missing:
        for m in missing:
            bad(f"{rel} — does not state: {m}")
    else:
        ok(f"{rel} states the rule")

CLEANUP_FILES = [
    "agents/holmes.md",
    "agents/holmes-local.md",
    "agents/holmes-index.md",
    "agents/holmes-lens.md",
]
CLEANUP_PHRASES = [
    "create nothing on your own initiative that you cannot remove yourself",
    "what the project's own test runner creates and cleans up stays allowed",
    "never use docker, a vm or a source build to mimic ci or another platform",
]
for rel in CLEANUP_FILES:
    flat = " ".join(open(f"{ROOT}/{rel}", encoding="utf-8").read().replace("*", "").split()).lower()
    absent = [p for p in CLEANUP_PHRASES if p not in flat]
    for p in absent:
        bad(f"{rel} — does not state: {p}")
    if not absent:
        ok(f"{rel} states the self-cleanup and no-CI-copy rule")

MUTATION = re.compile(r"\bmutat\w*", re.I)
shipped = sorted(
    os.path.relpath(os.path.join(d, f), ROOT)
    for top in ("agents", "skills", "references", "commands")
    for d, _, names in os.walk(os.path.join(ROOT, top))
    for f in names
    if f.endswith(".md")
)
asks = []
for rel in shipped:
    text = open(f"{ROOT}/{rel}", encoding="utf-8").read()
    for s in sentences(text):
        m = next((m for m in MUTATION.finditer(s) if not governed(s, m.start())), None)
        if m:
            asks.append((rel, m.group(0), s))
for rel, word, s in asks:
    bad(f"{rel} names '{word}' with no prohibition governing it: {s[:180]}")
if not asks:
    ok(f"no sentence in the {len(shipped)} shipped Markdown files asks for mutation testing")

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
