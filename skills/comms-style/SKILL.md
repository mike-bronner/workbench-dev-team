---
name: comms-style
description: How Lestrade, Watson, and Holmes write every piece of prose that isn't code — ticket comments, PR/issue descriptions, review verdicts, escalation notes, AC checklists. Modeled on ASD-STE100 (Simplified Technical English). This is a standing way of writing, not a checklist to run after drafting — apply it as you compose, no separate lint step.
---

# Comms Style

Banning individual words ("no em dashes," "no 'delve'") is whack-a-mole: the
model was never choosing those words on purpose, so banning one just lets
the others through. What holds up instead is a positive system you write
*by*, not a blacklist you check *against*. This skill's system is modeled on
a real one: **ASD-STE100, Simplified Technical English** — the
aerospace-maintenance writing standard (Issue 9, Jan 2025,
[asd-ste100.org](https://www.asd-ste100.org/)), 53 rules across 9 sections
plus a Grammar Reference appendix, built so a maintenance step is never
misread.

**How to use this.** There is no separate checking tool and nothing to run.
Read the principles below, hold them in mind, and write the comment/PR
body/verdict directly in this voice from the first draft. `references/rules.md`
gives the full rule-by-rule detail, restated in original wording (never
ASD's copyrighted text) with how each one translates into a writing
principle here, or why it doesn't apply to this domain. Read it if you want
the full picture; the summary below is enough for day-to-day writing.

**The bar is "doing your best," not strict compliance.** Some of these
rules ask for real linguistic judgment — is this word's meaning restricted
to one sense, does this paragraph really have one topic — and getting one
sentence not-quite-right is fine. A real aircraft-maintenance misread
manual can hurt someone; a GitHub comment that's 90% there instead of 100%
costs nothing. Apply the intent, don't agonize over the letter.

## The principles

**Vocabulary — one word per concept, no synonyms.** Don't call the same
thing three different things in one comment ("the item," "the issue," "the
ticket" — in this repo those are three genuinely different things, so
mixing them isn't just sloppy, it's actively confusing). Don't hedge
("it's important to note that this may potentially help") — say what's
true. Don't freeze a verb into a noun ("perform an analysis of" instead of
"analyze," "provide assistance" instead of "help"). Don't reach for a
marketing adjective ("seamless," "robust," "cutting-edge") — show quality
with a file:line or a number instead of asserting it. Don't build a
phrasal verb where a precise one exists ("reach out" → ask/contact, "circle
back" → follow up, "spin up" → start). Use American spelling. Skip Latin
abbreviations (e.g., i.e., etc.) — just say "for example," "that is," "and
so on." Use established inclusive terms (allowlist/denylist, not
whitelist/blacklist).

**Sentences — short, direct, one thing at a time.** Keep instructions
(verdicts, status text) to roughly 20 words; narrative prose to roughly 25.
Write full sentences — no contractions, nothing omitted. One instruction or
one topic per sentence; if you're stringing two together with "and" or
"then," that's two sentences. If a condition matters, state it before the
instruction ("If CI passes, merge the PR," not "Merge the PR if CI
passes"). No semicolons — if you want one, you have two sentences. No more
than three nouns in a row without a linking word. Prefer a markdown list
over a sentence stuffed with four comma-separated items.

**Verbs — active, direct, simple tense.** Write instructions as commands
("Fix the failing test," not "You must fix the failing test"). Use active
voice; passive only when you genuinely don't know who or what did it.
Avoid "-ing" as your main verb ("is reviewing" → "reviewed" or "review") and
avoid perfect tense ("has fixed" → "fixed") — STE's own reasoning is that
simple tenses are harder to misread, and that holds for a fast-scanned
comment too.

**Paragraphs.** Group related sentences; keep each paragraph under about
six sentences and about one topic.

**Out of scope.** Section 7 of the real standard (Safety instructions —
signal words for physical risk, hazard explanations) has no equivalent
here. Nothing in a code review or a ticket comment is a physical hazard;
don't force that framing onto this domain.

## Two registers, not two gates

- **Procedural** — verdicts, status text, AC checklists: content a
  decision or a pipeline depends on. Tighter, more command-like. Misreading
  these has a real cost.
- **Descriptive** — PR/issue descriptions, "Issues Found" / "What's Good,"
  escalation framing, coordination comments: narrative, a little more
  latitude.

These are a difference in *degree of care*, not a tool mode to select —
just write procedural content a bit tighter than descriptive content.

## What this doesn't do

None of this makes a comment worth reading — it only makes a comment that's
worth reading easier to read. Say something real first. A clean, direct,
well-structured comment with nothing to say is still a comment with nothing
to say.
