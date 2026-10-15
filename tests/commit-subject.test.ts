import { describe, expect, test } from 'claude-code/testing'

import { GITMOJI, TYPES, subjectFault } from '../hooks/mods/commit-subject'
import { world } from './world'

const bash = (command: string, agentId?: string) =>
  ({ tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command, ...(agentId === undefined ? {} : { agentId }) }) as never

type Answer = { deny?: string }

const LANES = {
  main: { lane: () => 'main' as const, unattended: false },
  pipeline: { lane: () => 'top-level-agent' as const, unattended: true },
}

describe('commit subject — the hook holds a main or pipeline commit to the format', () => {
  for (const [line, why] of [
    ['git commit -m x', 'does not start with a type and a colon'],
    ['git commit -m "fix: 🐛 Fix x"', 'does not end with a period'],
  ] as const) {
    for (const lane of ['main', 'pipeline'] as const) {
      test(`refused [${lane}]: ${JSON.stringify(line)}`, async ($, on) => {
        const w = world(on, LANES[lane])
        const answer = (await $.tool.call(bash(line))) as Answer
        expect(answer.deny).toContain('a commit subject that breaks the git-commit format')
        expect(answer.deny).toContain(why)
        expect(answer.deny).toContain('"<type>: <gitmoji> <Description>."')
        expect(answer.deny).toContain('Commit guard (workbench-dev-team)')
        expect(w.ran).toEqual([])
      })
    }
  }

  for (const line of ['git commit -m "fix: 🐛 Fix x."', 'git log -m --oneline']) {
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
})
