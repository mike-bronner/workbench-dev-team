# Implementing — each §3 rule in full

On-demand detail for `skills/develop/SKILL.md`, §3. The skill keeps a short form
of every rule here, so the rules survive compaction. This file holds each one in
full, with its reasons and examples. Where the two differ in wording, they state
the same rule.

- **YAGNI — build the least that satisfies the AC.** Implement only what the
  current requirement needs. No speculative abstraction, config knobs,
  extension points, or "future-proofing" nothing asks for yet — that code is
  unproven, untested-against-reality, and a cost the next reader inherits. When
  a need actually arrives, add it then. The simplest thing that passes the AC
  and the tests is the target, not a floor to build past.
- **YAGNI stops at the trust boundary.** Minimalism never means dropping a
  safeguard the AC didn't spell out. A *trust boundary* is any point where data
  crosses from a less-trusted source into your code — user input, request
  payloads, query params, uploaded file contents, external API responses,
  webhook bodies, anything off the wire or out of a DB you don't control.
  Input validation at those boundaries, error handling that prevents data loss,
  authn/authz and other security measures, and accessibility basics are not
  optional scope — build them whether or not the ticket enumerates them. "The
  least that satisfies the AC" means the least *correct and safe* version, not
  the least code that demos.
- **Prefer the most concise solution that stays readable.** Reach for the
  one-liner or the single idiomatic expression over a verbose multi-step
  construct *when it's just as clear*. Concision is a means to readability, never
  an end in itself — never trade clarity for brevity, and never cram unrelated
  logic onto one line to save a line. Plain-and-obvious beats clever-but-opaque
  every time. When two options are the same size, pick the one that's correct
  on the edge cases — concise means less code, never the flimsier algorithm.
- **Prefer the framework's idioms over raw language primitives.** When the
  project runs on a framework, reach for what it already provides instead of
  hand-rolling against the bare language — in Laravel, collections over raw
  arrays, Eloquent over hand-built queries, the framework helper over a
  reimplementation. The provided abstraction is tested, conventional, and
  shorter; the raw-primitive version is more code doing the same job worse.
- **Match the existing style.** Imports, naming, formatting, error handling —
  copy what's already there.
- **One logical change at a time.** If a refactor enables the actual fix, make
  the refactor first, and test it before the fix. That is an order of work, not
  a commit boundary. The commit still takes the whole tree in one commit, in
  every lane, as the `/workbench-dev-team:git-commit` skill says.
- **Don't add dependencies casually.** Each one is a maintenance and supply-chain
  surface that outlives the immediate convenience. Check the project's existing
  deps first — chances are something close already exists. Prefer well-maintained,
  widely-used packages over niche ones. And for tiny utility functions (a few
  lines), a little copying is better than a little dependency.
- **Write no comments in code** unless the project's linter or config requires
  them, such as a PHPCS rule that demands a docblock on every method. Code
  describes itself through names, structure, and tests. A comment is a second
  copy of what the code says, so every change to the code forces a change to the
  comment, and that churn buys nothing. This holds in every project, AI-maintained
  plugin code included. It covers inline comments, block comments, and
  docstrings or JSDoc alike. Functional lines that only look like comments stay:
  a shebang, or a directive a tool reads, such as `phpcs:ignore`.
- **Leave comments in untouched code alone, and delete the ones you make
  wrong.** Do not strip comments from code your change does not touch, because a
  sweep makes the diff noisy. When your change makes an existing comment wrong,
  delete it rather than rewrite it. A wrong comment misleads, because the next
  reader trusts it. If the linter then requires a comment there, write only what
  it requires.
- **Keep docs in sync with the code.** If your change makes a README section or
  a type signature wrong, update it in the same commit. Stale docs actively
  mislead. For external docs (Notion, Confluence, design specs), flag what
  needs updating even if you can't change them yourself.
- **No WebFetch.** Reason from the repo. If you can't, planning missed
  something — go back to §2 of `SKILL.md`.
