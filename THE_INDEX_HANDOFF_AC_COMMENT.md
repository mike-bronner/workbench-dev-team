# The Index handoff: acceptance criteria as a managed issue comment

> **✅ IMPLEMENTED — 2026-06-24** (branch `feature/ac-as-comment`; pending merge
> + redeploy to `the-index.mikebronner.dev`). Moves where `set_acceptance_criteria` lands its output. Today
> the tool merges the AC checklist into the issue **description**; this change
> makes it maintain a single managed follow-up **comment** on the issue instead,
> identified by a marker on its first line and updated find-or-update
> (idempotent). The issue description is never read or written again. The change
> is **forward-only** — legacy issues that already carry AC in their body keep
> working because Holmes falls back to the body when no marked comment exists.
> Lestrade's prompt does **not** change its call shape: it still passes the bare
> `- [ ]` checklist to `set_acceptance_criteria` and the server owns placement.

**Audience:** a Claude Code session running in `/Users/mike/Developer/Sites/the-index`.
Paste everything from `---` down into The Index session. The preamble above
this line is for humans reading the plugin repo.

---

## Context

The `workbench-dev-team` plugin (github.com/mike-bronner/workbench-dev-team)
triages project items through Inspector Lestrade. Lestrade authors acceptance
criteria and writes them through exactly one tool — `set_acceptance_criteria(id,
agent, criteria)` — passing only the `- [ ]` checklist lines (no heading; the
server supplies `## Acceptance Criteria`). The agent never hand-edits the issue;
the server owns where the AC lands.

Today the server merges that checklist into the issue **description**: it
preserves the original body byte-for-byte and replaces any existing
`## Acceptance Criteria` section inside it. The human wants the AC to stop living
in the description. Mixing the AC into the body couples a machine-managed section
to human-authored prose, makes the body diff noisy on every re-triage, and means
a body edit and an AC edit fight over the same text.

This change relocates the AC to a dedicated, server-managed **comment** on the
issue — one comment per issue, found-or-updated by a marker, leaving the
description untouched forever.

**Design decisions already made (do not relitigate):**

- The AC lives in **one managed comment per issue**, never the body. The comment
  is identified by a marker on its **first line** and maintained find-or-update
  (idempotent): re-running `set_acceptance_criteria` updates the same comment in
  place rather than appending a second one.
- The issue **description is never read and never written** by this tool after
  the change. No body parsing, no body edit, no "preserve the original body"
  step — the body is simply out of scope.
- **Forward-only. No data migration.** Legacy issues triaged before this change
  keep their AC in the body. Holmes reads the marked comment first and **falls
  back** to the body's `## Acceptance Criteria` section when no marked comment
  exists — so legacy items and any deploy-order skew keep working untouched.

## Ground truth

- `set_acceptance_criteria(id, agent, criteria)` is the **only** path the plugin
  uses to write AC. Its call shape does not change: callers still pass the bare
  `- [ ]` checklist with no heading. Only the server-side placement changes.
- `get_item` already returns `content_node_id` (the issue's node id, `I_kwDO…`)
  and the `issue_number`. Either is enough to address the issue when listing or
  writing comments.
- The marked comment is authored by the same GitHub App that signs the agent's
  other writes (`lestrade`). Listing the issue's comments and matching the marker
  must therefore tolerate comments from other authors and match on the marker
  text alone, not on author.
- PR-type project items have no acceptance criteria. The AC-comment path is for
  issues only.

## The canonical contract (must match the plugin prompts verbatim)

The plugin's agent prompts (`agents/lestrade.md`, `agents/holmes.md`) are being
updated in lockstep with this change and assume **exactly** the following. The
marker string is load-bearing on both sides — it must be byte-identical.

- `set_acceptance_criteria` maintains **exactly ONE** acceptance-criteria comment
  per issue, identified by the marker

  ```
  <!-- acceptance-criteria -->
  ```

  on its **first line**. Find-or-update: if a comment whose first line is that
  marker exists, update it in place; otherwise create one. Idempotent — running
  twice leaves exactly one comment.
- **Comment body format**, in order:

  ```
  <!-- acceptance-criteria -->
  ## Acceptance Criteria
  - [ ] First criterion
  - [ ] Second criterion
  ```

  marker line → the `## Acceptance Criteria` heading → the `- [ ]` checklist the
  caller supplied. The server adds the marker and the heading; the caller passes
  only the checklist lines.
- The issue **DESCRIPTION is never read or written** — AC no longer touches the
  body, in any path.
- **Holmes reads the marked comment FIRST**, and **FALLS BACK** to the issue
  body's `## Acceptance Criteria` section when no marked comment exists (legacy
  items triaged before this change, plus deploy-order safety).
- **Forward-only**: no data migration; legacy AC-in-body issues keep working via
  Holmes's fallback.

## GraphQL surface

Find-or-update needs two reads-then-write primitives: list the issue's comments
to locate the marked one, then either update it or create a new one.

```graphql
# List the issue's comments to find the marked AC comment (match the first line
# against the marker). Page if an issue can carry more than `first` comments.
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    issue(number:$number) {
      id
      comments(first:100) {
        nodes { id body }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}

# Update the existing marked comment in place (the find-or-update "update" arm).
mutation($id:ID!, $body:String!) {
  updateIssueComment(input:{ id:$id, body:$body }) {
    issueComment { id }
  }
}

# Create the marked comment when none exists yet (the "create" arm).
mutation($issue:ID!, $body:String!) {
  addComment(input:{ subjectId:$issue, body:$body }) {
    commentEdge { node { id } }
  }
}
```

`updateIssueComment` takes the comment node id from the list query;
`addComment`'s `subjectId` is the issue node id (`content_node_id` from
`get_item`). The body for both is the canonical comment-body format above, fully
assembled server-side (marker + heading + checklist).

## Tasks

1. **Repoint `set_acceptance_criteria` from the body to a managed comment.** Stop
   reading or writing the issue description entirely. Assemble the comment body in
   the canonical format (marker line → `## Acceptance Criteria` → the caller's
   checklist). List the issue's comments, find the one whose **first line** is the
   marker, and either `updateIssueComment` it or `addComment` a new one. The
   operation is idempotent — exactly one marked comment survives any number of
   runs.
2. **Match on the marker, not the author or position.** A robust find keys only on
   the first line equalling `<!-- acceptance-criteria -->`. Page through comments
   if necessary so the match isn't missed on long threads.
3. **Leave the description alone.** Remove the body-preserve / AC-section-replace
   logic from this path. The body is no longer this tool's concern.
4. **Confirm Holmes's read path needs no server work** — Holmes reads the marked
   comment (and falls back to the body) entirely on the plugin side via `gh issue
   view … --json comments`; the server only needs to write the comment in the
   canonical shape so Holmes's marker match succeeds. No server change is required
   for the fallback.

## Acceptance criteria

- [ ] `set_acceptance_criteria` writes the AC to a comment whose first line is
      exactly `<!-- acceptance-criteria -->`, followed by `## Acceptance Criteria`
      and the caller-supplied `- [ ]` checklist.
- [ ] The tool no longer reads or writes the issue description in any code path.
- [ ] Find-or-update is idempotent: running `set_acceptance_criteria` twice on the
      same issue leaves exactly one marked comment, updated in place.
- [ ] The marker match keys on the comment's first line only — independent of
      comment author or position — and pages through long comment threads.
- [ ] A legacy issue with AC in its body is left untouched by this tool (no body
      edit), and Holmes's body fallback still finds that AC.
- [ ] PR-type items take no AC-comment path.
- [ ] Full Pest suite green; all access via the GitHub App, scopes intact.

## Constraints

- **Follow The Index's `CLAUDE.md`** for Laravel conventions (Pest, layout,
  naming). No raw DB access — models/scopes only.
- **The marker is byte-identical to the plugin's.** `<!-- acceptance-criteria -->`
  on the comment's first line — do not paraphrase, re-case, or re-space it. The
  plugin's Holmes prompt matches the exact same string.
- **Forward-only — no migration.** Do not backfill or rewrite legacy AC-in-body
  issues. They keep working via Holmes's body fallback; touching them is out of
  scope.
- **Resolve the comment by marker, live.** No stored comment-id cache that could
  go stale against GitHub — list and match on each write.
- **Plan before code.** Surface a plan for where the comment-find-or-update hooks
  into the existing `set_acceptance_criteria` flow before implementing.
