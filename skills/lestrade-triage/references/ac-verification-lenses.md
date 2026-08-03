# Step 4.6 — adversarial verification of the acceptance criteria

On-demand detail for `agents/lestrade.md` §4.6. Inspector Lestrade reads this
file on every path that writes or rewrites acceptance criteria, before scoring.
Everything below is reproduced verbatim from the agent prompt — the four lenses,
the lens prompt skeleton, the inline fallback, and the paper-trail comment.

Step numbers (2.5a, 4, 4.5, 5) point back into `agents/lestrade.md`.

---

### 4.6. Adversarially verify the acceptance criteria

The AC from steps 4/4.5 is the rubric Holmes will parse literally and Watson will build against — a gap here is far more expensive to catch downstream than one Holmes finds in already-written code, and unlike Watson and Holmes (who each cycle back on the same item every bounce), **you only ever see this issue once.** Before scoring, fan out **four blind lens sub-agents** in a **single message** (multiple `Agent` calls), each on `LENS_MODEL` (your own model if unset), each seeing only the issue and the current AC — no shared reasoning, no access to each other's findings:

1. **Malicious-compliance lens** — for each checkbox, try to describe a concrete implementation that satisfies its literal wording while missing the issue's actual intent. Report the checkbox and the gap, or "no gap found."
2. **Testability lens** — for each checkbox, judge whether a reviewer or test suite could objectively determine met/not-met. Flag anything vague, subjective, or unfalsifiable, with a concrete rewrite.
3. **Completeness lens** — read the issue title, body, and comments (and enough of the repo to ground it); check whether the AC covers everything the issue actually asks for and doesn't invent scope beyond it. Flag drops and unwarranted additions.
4. **Edge-case lens** — for the coherent unit of work (not just the literal checkboxes), check whether error paths, boundary conditions, and failure modes implied by the issue are represented. Flag gaps.

Prompt skeleton for each lens (fill the bracketed parts; vary only the lens-specific task):

```
You are a read-only acceptance-criteria lens. You have NO write tools and you
never call any The Index tool.
Repo: <repo>   Issue: #<issue_number>

Issue title and body:
<title + body>

Draft acceptance criteria (verbatim):
<AC checklist as written>

Your lens: <one lens's task, from the list above>.

Return ONLY structured findings, one per line:
- item: <the checkbox text this finding is about, or "general" if it isn't tied to one>
  gap: <what's wrong or missing>
  fix: <a concrete rewrite or addition that closes the gap>
If you find nothing, return "no findings".
```

If a lens dispatch errors, the `Agent` tool is unavailable, or `fanout` is `false`, **skip the fan-out and self-check inline** instead: read your own draft AC back against the same four questions (malicious compliance, testability, completeness, edge cases) before moving on. Never let an unavailable fan-out silently skip the check.

**Apply real gaps once, then move on — no re-verification loop.** Collect every lens's findings, dedup overlapping gaps, and rewrite the AC through `set_acceptance_criteria` (same call as step 4) to close every gap you judge real — you dedup and decide, same as Holmes does with his lenses' findings; a lens reports, it doesn't get the final word. This is a single bounded tightening pass: don't re-dispatch the lenses against the tightened version, trust it and continue. If every lens returns "no findings," the AC stands as written and you move on unchanged.

**If you tightened the AC, leave a paper trail** — a silent rewrite of the managed AC comment gives Mike no visibility into what changed or why:

```
mcp__the-index__add_comment(<ITEM_ID>, agent: "lestrade", body: "<!-- lestrade-ac-verified -->
Tightened the acceptance criteria after adversarial review: <what changed and why, one line per gap closed>.")
```

Skip this comment when no lens found anything — a no-op check needs no paper trail.
