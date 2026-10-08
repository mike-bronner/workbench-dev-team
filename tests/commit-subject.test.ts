// hooks/register.ts with hooks/mods/commit-subject.ts: a main-loop or pipeline
// `git commit -m` subject is held to the git-commit skill's format, and a
// commit whose message is not on the line is not judged.

import { describe, expect, test } from 'claude-code/testing'

import { GITMOJI, TYPES, subjectFault, subjectVerdict } from '../hooks/mods/commit-subject'
import { parseShell } from './core/hooks/mods/shell'
import { world } from './world'

const bash = (command: string, agentId?: string) =>
  ({ tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command, ...(agentId === undefined ? {} : { agentId }) }) as never

type Answer = { deny?: string }

const LANES = {
  main: { lane: () => 'main' as const, unattended: false },
  pipeline: { lane: () => 'top-level-agent' as const, unattended: true },
}

describe('commit subject — a subject that breaks the format is refused with the expected shape', () => {
  for (const [line, why] of [
    ['git commit -m x', 'does not start with a type and a colon'],
    ['git commit -m "fix: x"', '"x" is not a gitmoji'],
    ['git commit -m "fix: 🐛 Fix x"', 'does not end with a period'],
    ['git commit -m "fix(api): 🐛 Fix x."', 'it has a scope, (api)'],
    ['git commit -m "feature: ✨ Add x."', '"feature" is not a type'],
    ['git commit -m "fix:🐛 Fix x."', 'not followed by exactly one space'],
    ['git commit -m "fix:  🐛 Fix x."', 'not followed by exactly one space'],
    ['git commit -m "fix: 🐛  Fix x."', 'one space and a description'],
    ['git commit -m "fix: 🐛 ."', undefined],
    ['git commit -m "fix: 🦄 Fix x."', '"🦄" is not a gitmoji'],
    ['git commit -m "Fix: 🐛 Fix x."', '"Fix" is not a type'],
    ['git commit -am "fix: Fix x."', 'is not a gitmoji'],
    ['git commit --message "fix: 🐛 Fix x"', 'does not end with a period'],
    ['git commit --message="fix: 🐛 Fix x"', 'does not end with a period'],
    ['git commit -m"fix: 🐛 Fix x"', 'does not end with a period'],
    ['git -C /repo commit -m "wip"', 'does not start with a type'],
    ['git commit --amend -m "wip"', 'does not start with a type'],
    ['git add . && git commit -m "wip" && git push', 'does not start with a type'],
    // After an attached-value option, the -m is still read.
    ['git commit -unormal -m "wip"', 'does not start with a type'],
    ['git commit -Sabc123 -m "wip"', 'does not start with a type'],
    ['git commit -m "wip" -m "feat: ✨ Add x."', 'does not start with a type'],
    ["git commit -m \"$(cat <<'EOF'\nfix: 🐛 Fix x\n\nBody.\nEOF\n)\"", 'does not end with a period'],
  ] as const) {
    for (const lane of ['main', 'pipeline'] as const) {
      test(`refused [${lane}]: ${JSON.stringify(line)}`, async ($, on) => {
        const w = world(on, LANES[lane])
        const answer = (await $.tool.call(bash(line))) as Answer
        expect(answer.deny).toContain('a commit subject that breaks the git-commit format')
        if (why !== undefined) expect(answer.deny).toContain(why)
        expect(answer.deny).toContain('"<type>: <gitmoji> <Description>."')
        expect(answer.deny).toContain('Commit guard (workbench-dev-team)')
        expect(w.ran).toEqual([])
      })
    }
  }

  for (const line of [
    'git commit -m "fix: 🐛 Fix x."',
    'git commit -m "feat!: 💥 Drop the old endpoint."',
    'git commit -m "refactor: ♻️ Extract the service."',
    'git commit -m "refactor: ♻ Extract the service."',
    'git commit -m "perf: ⚡ Cache the parse."',
    'git commit -m "chore: 🧑‍💻 Improve the dev loop."',
    'git commit -m "fix: 🐛 Fix x.  "',
    'git commit -m "fix: 🐛 Fix x." -m "Body without a period"',
    'git commit -m "fix: 🐛 Fix x.\n\nBody line."',
    "git commit -m \"$(cat <<'EOF'\nfix: 🐛 Fix x.\n\nBody.\nEOF\n)\"",
    'git -c user.name=x commit -m "docs: 📝 Document x."',
    // A short option whose value is attached takes the rest of its word.
    'git commit -unormal -m "feat: ✨ Add x."',
    'git commit -uall -m "feat: ✨ Add x."',
    'git commit -Sabc123 -m "feat: ✨ Add x."',
    'git commit -aS -m "feat: ✨ Add x."',
    'git commit -aSmine -m "feat: ✨ Add x."',
    'git commit -u -m "feat: ✨ Add x."',
    // Not judged: the message is not on the line.
    'git commit -F msg.txt',
    'git commit --file=msg.txt',
    'git commit -m "wip" -F msg.txt',
    'git commit -C HEAD',
    'git commit --fixup=abc123',
    'git commit --squash abc123 -m "wip"',
    'git commit',
    'git commit --amend --no-edit',
    'git commit -m "$MSG"',
    'git commit -m "$(cat msg.txt)"',
    'git commit -m "fix: 🐛 Fix $X"',
    // A message read from a heredoc that is not cat's is not judged.
    "git commit -m \"$(sed -n 1p <<'EOF'\nwip\nEOF\n)\"",
    // Not a commit.
    'git log -m --oneline',
    'echo "git commit -m wip"',
    'git merge -m "wip" feat/x',
  ]) {
    for (const lane of ['main', 'pipeline'] as const) {
      test(`passes [${lane}]: ${JSON.stringify(line)}`, async ($, on) => {
        const w = world(on, LANES[lane])
        expect(((await $.tool.call(bash(line))) as Answer).deny).toBeUndefined()
        expect(w.ran).toEqual([`Bash: ${line}`])
      })
    }
  }

  test("a sub-agent's commit is refused as a commit, before its subject is read", async ($, on) => {
    world(on, { lane: () => 'sub-agent', agents: [{ id: 'agent-1', type: 'workbench-dev-team:watson-direct' }] })
    const answer = (await $.tool.call(bash('git commit -m wip', 'agent-1'))) as Answer
    expect(answer.deny).toContain('a sub-agent does not commit or push')
    expect(answer.deny).not.toContain('git-commit format')
  })
})

describe('commit subject — the pure rules', () => {
  test('the types are the ten the skill lists', () => {
    expect(TYPES).toEqual(['feat', 'fix', 'docs', 'style', 'refactor', 'perf', 'test', 'build', 'ci', 'chore'])
  })

  test('every gitmoji in the list passes, with or without its U+FE0F', () => {
    for (const emoji of GITMOJI) {
      expect(subjectFault(`chore: ${emoji} Do x.`)).toBeUndefined()
      expect(subjectFault(`chore: ${emoji.replace(/\uFE0F/g, '')} Do x.`)).toBeUndefined()
    }
  })

  test('a line with two commits is refused for the one that breaks the format', () => {
    expect(subjectVerdict(parseShell('git commit -m "fix: 🐛 A." && git commit -m b'))).toHaveProperty('deny')
    expect(subjectVerdict(parseShell('git commit -m "fix: 🐛 A." && git commit -m "fix: 🐛 B."'))).toBeUndefined()
  })
})
