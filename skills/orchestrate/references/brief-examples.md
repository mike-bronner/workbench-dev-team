# Worked briefs

On-demand examples for `skills/orchestrate/SKILL.md`. The skill states the
brief contract and the dispatch protocol; this file shows them applied. Nothing
here is a rule, and nothing here needs reading to dispatch correctly.

## A Watson Direct-mode dispatch

Example — ad-hoc dev work. The prompt is the six-slot brief, contract in
`SKILL.md`:

```
Agent(
  subagent_type: "workbench-dev-team:watson",
  // no model: Watson's frontmatter carries claude-opus-5-5[1m], and the alias-only
  // parameter would override that exact ID. Never pass one to a dev-team agent.
  run_in_background: true,
  description: "Expire stale cache entries",
  prompt: "Workdir: /Users/mike/Developer/bar (branch: fix/cache-expiry,
           off main — agreed in chat before dispatch)
           Goal: Cached API responses expire instead of being served
           indefinitely after the upstream record changes.
           Context: A stale price was served for two days after the
           upstream correction, and support caught it before we did. The
           cache predates the upstream's change feed, so nothing invalidates
           an entry today except a restart.
           Constraints:
           - No new dependencies. This service ships to air-gapped hosts,
             and every dependency is a manual review there.
           - Do not change the shape of the cache interface. Three other
             services call it and none of them are in this repo.
           Acceptance:
           - AC1: A cached response is not served once its upstream record
             has changed.
           - AC2: The cache interface the other services call is unchanged.
           - AC3: No dependency is added.
           Done when: Expiry is covered by tests, the suite is green, and the
           change comes back uncommitted with a proposed commit message."
)
```

## One task, both ways

❌ **Scripted** — most of it tells Watson what the repo already answers:

```
Workdir: /Users/mike/Developer/foo
1. Open src/retry.ts and find the backoff loop.
2. Set the base delay to 250ms and cap attempts at 5.
3. Add tests to tests/unit/retry.test.ts with Vitest describe/it.
4. Run `npx vitest run tests/unit/retry.test.ts` until green.
5. Then `npm run lint -- --fix` and `npm run build`.
6. Commit as "fix: retry backoff" and open a PR.
```

✅ **Briefed** — same task, six slots, and longer on the page for saying far
less about how:

```
Workdir: /Users/mike/Developer/foo (branch: fix/retry-backoff, off main —
you were on main and agreed to the branch before this dispatch)
Goal: The HTTP client retries a failed request on capped exponential
backoff instead of retrying immediately.
Context: Immediate retries turned a partial upstream outage into a full
one last Thursday: every client in the fleet re-hit a recovering service
in lockstep and put it back down. The cap of 5 is what the upstream's
rate limit tolerates before it starts refusing us outright.
Constraints:
- Keep the public client API unchanged. It ships in a released package
  and callers outside this repo are on the current signature.
- Never exceed 5 attempts. Past that the upstream stops answering us at
  all, which is worse than the failure being retried.
- No new dependencies. The retry helpers on offer all pull a scheduler
  we would then have to keep.
Acceptance:
- AC1: A failed request is retried on exponential backoff, never at once.
- AC2: No request is attempted more than 5 times.
- AC3: The public client API is unchanged.
- AC4: No dependency is added.
Done when: Retry timing and the attempt cap are covered by tests, the
full suite is green, and the change comes back uncommitted with a
proposed commit message.
```

The scripted version pins the file, the runner, the command order, and the
commit message. Watson reads all four out of the repo. The briefed version keeps
what is genuinely upstream of the repo — the cap of 5, the frozen API, the
dependency ban, and the branch you agreed to — and hands the rest back. The
branch is upstream of the repo like the rest of them: Watson cannot read which
one you picked. Each of the three constraints carries its reason, so none of
them reads as arbitrary, and an arbitrary-looking limit is the kind a sub-agent
negotiates with when the code makes it awkward. The `Acceptance:` list restates
the goal and those limits as results, so Watson grades its forks against them
and Holmes can check each one without asking.
