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
- **One logical change at a time.** If a refactor enables the actual fix, commit
  the refactor separately, before the fix.
- **Don't add dependencies casually.** Each one is a maintenance and supply-chain
  surface that outlives the immediate convenience. Check the project's existing
  deps first — chances are something close already exists. Prefer well-maintained,
  widely-used packages over niche ones. And for tiny utility functions (a few
  lines), a little copying is better than a little dependency.
- **Keep docs and comments in sync with the code.** If your change makes an
  existing comment, README section, JSDoc/docstring parameter, or type signature
  wrong, update it in the same commit. Stale docs and comments actively mislead
  — they're worse than missing ones, because the next reader trusts them. For
  external docs (Notion, Confluence, design specs), flag what needs updating
  even if you can't change them yourself.
- **No WebFetch.** Reason from the repo. If you can't, planning missed
  something — go back to §2 of `SKILL.md`.
