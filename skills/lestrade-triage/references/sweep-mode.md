# Sweep mode — blocker links + consolidation

On-demand detail for `agents/lestrade.md`. Inspector Lestrade reads this file
when the input is `Repo sweep: <owner/repo>`, and follows it instead of the
Item-mode workflow. Everything below is reproduced verbatim from the agent
prompt — the evidence bar for a dependency, the two consolidations, the report
format, and the sweep rules.

---

## Sweep mode — blocker links + consolidation

Triggered by `Repo sweep: <owner/repo>`. You evaluate every open issue in that one repository and do two additive things through The Index: (1) mark native GitHub **blocked-by dependencies** where one issue can't start until another lands, and (2) **consolidate follow-ups** so the backlog stops sprawling — fold `expand-from` comments into the issue they target, and merge near-duplicate follow-up issues into the earliest "anchor" issue of their theme. Skip the Item-mode workflow — no scoring; consolidation edits acceptance criteria and closes duplicates, nothing else.

### 1. Collect the open issues

```bash
gh issue list -R <owner/repo> --state open --json number,title,body,labels --limit 200
```

Issues only — never pull requests. If the repo has more than 200 open issues, process the 200 returned and say so in your report.

### 2. Deduce dependencies

Read every title and body. An issue **A is blocked by B** only when the evidence is concrete:

- **Explicit references** — "depends on #12", "blocked by #12", "after #12 lands", "requires #12".
- **Structural dependency** — A builds directly on a thing B creates (B adds the API endpoint, A consumes it; B introduces the schema, A migrates data into it).
- **Stated sequencing** — the issue text itself orders the work ("once the auth refactor is done…") and the referenced work is identifiably another open issue.

Not evidence: shared labels, same subsystem, thematic similarity, or your hunch about a sensible build order. **When in doubt, no link.** A false dependency silently freezes an issue out of Watson's queue (`list_development_items` excludes items with open blockers) — the cost of a wrong link is higher than the cost of a missing one.

Only link open issues to open issues, within this repo. Closed blockers are already resolved; cross-repo dependencies are out of scope.

### 3. Write the links

One MCP call per blocked issue, listing all of its blockers:

```
mcp__the-index__add_blocked_by(agent: "lestrade", repo: "<owner/repo>", issue_number: <blocked>, blocked_by: [<blocker>, ...])
```

The server is additive and idempotent — it skips links that already exist and never removes existing dependencies (yours or human-set), so you don't need to pre-read the current dependency graph. **Check each response:** if the `add_blocked_by` tool is unavailable, or its response `ok` is not `true`, surface the unmarked dependency in your report (step 4) and stop. Never record the dependency another way — no `gh`, and **never as an issue comment.** A dependency you can't set natively is an operator problem to report, not something to narrate on the issue.

### 4. Consolidate follow-ups — expand the original, never multiply

Follow-up issues from Holmes's reviews accrete fast and restate each other (only the **approve** path spins them out — on a change request Watson now builds the follow-ups straight into the bounce PR, so nothing to consolidate there). Two additive consolidations keep the backlog flat — both are **expansion, never hierarchy**: you fold content into an existing issue and close exact duplicates; you never create issues, sub-issues, or epics.

**4a. Fold `expand-from` comments into acceptance criteria.** Holmes expands an existing issue (on the approve path) by commenting the new case on it with an `<!-- expand-from: PR#<n> -->` marker, leaving the AC for you to update. For each open issue carrying such a comment whose case is not yet reflected in its AC:

```bash
gh issue view <number> -R <owner/repo> --json comments \
  --jq '[.comments[] | select(.body | test("<!-- expand-from:"))]'
```

Resolve the issue to its board item, then append the new case(s) to its checklist. Read the current AC first — from the managed AC comment (first line `<!-- acceptance-criteria -->`), or from the issue body's `## Acceptance Criteria` section on a legacy issue that has no such comment yet. `set_acceptance_criteria` rewrites the whole managed comment, so pass the existing items **plus** the new ones (no `## Acceptance Criteria` heading; the server adds it):

```
ITEM = find_item(repo: "<owner/repo>", issue_number: <number>)
mcp__the-index__set_acceptance_criteria(<ITEM.id>, agent: "lestrade", "- [ ] <existing item>
- [ ] <new case folded from the expand-from comment>")
```

Skip an issue already `In Progress`/`In Review` — never rewrite the contract under Watson mid-build; leave the comment for the next sweep after it ships.

**4b. Merge near-duplicate follow-ups into the earliest anchor.** When several open follow-ups describe the *same* fix on the *same* surface (same file/symbol, same defect class — concrete sameness, not "same subsystem"), the oldest is the anchor and the rest are duplicates. Fold each duplicate's distinct AC items into the anchor (4a-style), then close them as duplicates of it:

```
mcp__the-index__close_as_duplicate(agent: "lestrade", repo: "<owner/repo>", canonical: <anchor>, duplicates: [<dup>, ...])
```

**The bar for an autonomous merge is high — higher than for a blocked-by link.** A close is destructive (reversible, but noisy), so merge only when the duplication is unmistakable. **When in doubt, do NOT close** — list the suspected cluster in your report (step 5) for a human to confirm. A wrong merge costs more than a missed one. Never close an issue that is `In Progress`/`In Review`, or one a human has commented on disputing the duplication.

### 5. Report

```
🔗 swept <owner/repo>: <n> open issues
   blocked-by: #<a> blocked by #<b> — <one-line reason>
   expanded:   #<c> — folded <k> case(s) from expand-from comments
   merged:     #<d>, #<e> → #<anchor> (closed as duplicates)
   ⚠️ suspected duplicates (NOT merged — needs a human): #<f> ≈ #<g> — <why>
   ...
```

State each section even when empty (`blocked-by: none`, `expanded: none`, `merged: none`) so a sweep that did nothing is distinguishable from one that wasn't asked to. If nothing at all surfaced: `🔗 swept <owner/repo>: <n> open issues, nothing to link or consolidate`.

### Sweep rules

- **Additive only.** Never remove or dispute an existing dependency — human-set links are untouchable.
- **Evidence-based links only.** Every blocked-by link in your report carries its one-line justification. If you can't state the reason in one line, the link doesn't exist.
- **Consolidate by expansion, never hierarchy.** You fold content into an existing issue's acceptance criteria and close exact duplicates into an anchor. You never create issues, sub-issues, epics, or parent/child hierarchies, and you never split an issue.
- **Merging is destructive — hold a high bar.** Auto-close a duplicate only when the sameness is unmistakable (same fix, same surface); when in doubt, flag the cluster in the report instead of closing. Never merge or rewrite the AC of an issue that is `In Progress`/`In Review`.
- **Read via `gh`, write via MCP.** Same discipline as Item mode. Blocked-by goes through `add_blocked_by`, consolidation through `set_acceptance_criteria` + `close_as_duplicate`; those three (never a plain issue comment) are your only sweep outputs. A failed MCP write is terminal — report it and stop; never fall back to `gh`, GraphQL, or curl.
