import { describe, expect, test } from 'claude-code/testing'

import type { Call, Facts, Ledger } from '../hooks/mods/verdict-guard'
import {
  CHECKS_ARGV,
  EMPTY_LEDGER,
  bodyFault,
  checksOf,
  disputeFault,
  factOf,
  judgeBoard,
  judgeDigestEdit,
  judgeDigestWrite,
  judgeNote,
  observe,
  vaultOf,
  verdictFailed,
} from '../hooks/mods/verdict-guard'
import { complete, world } from './world'

const notFound = (path: string) => {
  const text = `Document not found: '${path}'. Find the path with search or list_documents.`
  return { isError: true, result: [{ type: 'text', text }], text }
}

const T = (name: string) => `workbench-dev-team:${name}`
const IDX = (name: string) => `mcp__the-index__${name}`
const MEM = (name: string) => `mcp__plugin_workbench-core_memory__${name}`

const READY: Ledger = { ...EMPTY_LEDGER, seq: 5, itemId: '7', repo: 'o/r', issue: 42, status: 'In Review', lastGetItemAt: 5, feedbackSearches: 2 }
const FACTS: Facts = { pr: 9, decision: 'review', checks: 'pass', strikes: 0 }

const APPROVE_BODY = [
  '✅ **Approved**',
  '',
  '## Review Summary',
  '- reviewed',
  '',
  '## 📋 Non-blocking follow-ups',
  '- None.',
  '',
  'Ready for @mikebronner to merge.',
].join('\n')

const CHANGES_BODY = [
  '🔄 **Changes Requested**',
  '',
  '## Issues Found',
  '- a bug',
  '',
  "## What's Good",
  '- tests',
  '',
  '## 📋 Non-blocking follow-ups',
  '- None.',
  '',
  'Please address the above and re-request review.',
].join('\n')

const DISPUTE_BODY = [
  '<!-- holmes-ac-dispute -->',
  '@mikebronner AC #2 says "x" but the implementation does y.',
  '',
  '| Option | Pros | Cons | Grade |',
  '|---|---|---|---|',
  '| 1: keep | a | b | All met |',
  '| 2: amend | a | b | AC2 partly met: c |',
  '| 3: revert | a | b | AC2 not met: d |',
  '',
  '**Recommendation:** option 1 (all met), because it holds.',
].join('\n')

const STRIKE_BODY = ['🛑 **Escalating to @mikebronner — this review still found blockers.**', '', '## Issues Found This Round', '- x', '', "## What's Good", '- y'].join('\n')

const review = (decision: string, body: string, extra: Record<string, unknown> = {}): Call => ({
  tool: IDX('submit_review'),
  id: '7',
  agent: 'holmes',
  pr_number: 9,
  decision,
  body,
  ...extra,
})
const comment = (body: string, extra: Record<string, unknown> = {}): Call => ({ tool: IDX('add_comment'), id: '7', agent: 'holmes', pr_number: 9, body, ...extra })
const move = (column: string): Call => ({ tool: IDX('move'), id: '7', agent: 'holmes', column })

describe('verdict guard — board writes (C1, C5–C8, C12–C14, C16)', () => {
  test('a well-formed approve on a fresh, In Review item passes', () => {
    expect(judgeBoard(READY, review('approve', APPROVE_BODY), FACTS)).toBeUndefined()
  })

  test('a well-formed request-changes below three strikes passes', () => {
    expect(judgeBoard(READY, review('request_changes', CHANGES_BODY), { ...FACTS, strikes: 2 })).toBeUndefined()
  })

  for (const [label, ledger, call, facts, rule] of [
    ['a write signed as another agent', READY, review('approve', APPROVE_BODY, { agent: 'watson' }), FACTS, 'C7'],
    ['a write before any get_item', { ...READY, itemId: undefined }, review('approve', APPROVE_BODY), FACTS, 'C8'],
    ['a write on an item no longer In Review', { ...READY, status: 'Done' }, review('approve', APPROVE_BODY), FACTS, 'C8'],
    ['a write on an item whose status could not be read', { ...READY, status: undefined }, review('approve', APPROVE_BODY), FACTS, 'C8'],
    ['a write on an item read before the helpers ran', { ...READY, lastAgentAt: 6 }, review('approve', APPROVE_BODY), FACTS, 'C8'],
    ['a write after one feedback search', { ...READY, feedbackSearches: 1 }, review('approve', APPROVE_BODY), FACTS, 'C16'],
    ['a review of another item', READY, review('approve', APPROVE_BODY, { id: '8' }), FACTS, 'C7'],
    ['a second review', { ...READY, reviewed: 'request_changes' }, review('approve', APPROVE_BODY), FACTS, 'C7'],
    ['a review when no PR is linked', READY, review('approve', APPROVE_BODY), { ...FACTS, pr: null }, 'C13'],
    ['a review when the PR could not be resolved', READY, review('approve', APPROVE_BODY), { ...FACTS, pr: undefined }, 'C13'],
    ['a review naming a PR that is not the linked one', READY, review('approve', APPROVE_BODY, { pr_number: 420 }), FACTS, 'C13'],
    ['a review of a decision request', READY, review('approve', APPROVE_BODY), { ...FACTS, decision: 'decision-request' }, 'C14'],
    ['a review when the decision check could not run', READY, review('approve', APPROVE_BODY), { ...FACTS, decision: undefined }, 'C14'],
    ['an approve while a check is pending', READY, review('approve', APPROVE_BODY), { ...FACTS, checks: 'pending' }, 'C12'],
    ['an approve while a check fails', READY, review('approve', APPROVE_BODY), { ...FACTS, checks: 'fail' }, 'C12'],
    ['an approve when the checks could not be read', READY, review('approve', APPROVE_BODY), { ...FACTS, checks: undefined }, 'C12'],
    ['an approve with no follow-ups section', READY, review('approve', APPROVE_BODY.replace('## 📋 Non-blocking follow-ups', '')), FACTS, 'C5'],
    ['an approve with the request-changes head', READY, review('approve', APPROVE_BODY.replace('✅ **Approved**', '🔄 **Changes Requested**')), FACTS, 'C5'],
    ["a request-changes with no What's Good", READY, review('request_changes', CHANGES_BODY.replace("## What's Good", '')), FACTS, 'C5'],
    ['a request-changes at three strikes', READY, review('request_changes', CHANGES_BODY), { ...FACTS, strikes: 3 }, 'C1'],
    ['a request-changes when the strike count could not run', READY, review('request_changes', CHANGES_BODY), { ...FACTS, strikes: undefined }, 'C1'],
  ] as [string, Ledger, Call, Facts, string][]) {
    test(`${label} is refused under ${rule}`, () => {
      expect(judgeBoard(ledger, call, facts)).toContain(`Verdict guard (workbench-dev-team), ${rule}.`)
    })
  }

  test('the stale refusal tells Holmes to write nothing and report the stale exit', () => {
    expect(judgeBoard({ ...READY, status: 'Done' }, move('Approved'), FACTS)).toContain('⏭️ reviewed #<issue_number>')
  })

  test('the required checks decide an approve: failed and cancelled are blockers, pending waits, none required passes', () => {
    const approve = review('approve', APPROVE_BODY)
    expect(judgeBoard(READY, approve, { ...FACTS, checks: 'fail', why: { checks: 'build' } })).toContain('A failed required check is a blocker: request changes and name the failing job.')
    expect(judgeBoard(READY, approve, { ...FACTS, checks: 'cancelled', why: { checks: 'build' } })).toContain('Neither approve nor request changes, and count no strike. Escalate')
    expect(judgeBoard(READY, approve, { ...FACTS, checks: 'pending', why: { checks: 'build' } })).toContain('Do not approve yet: leave the item In Review')
    expect(judgeBoard(READY, approve, { ...FACTS, checks: 'none' })).toBeUndefined()
  })

  test('a cancelled-check escalation passes while a required check is cancelled, and is held to its own shape', () => {
    const body = '<!-- holmes-ci-cancelled -->\n@mikebronner The required check build was cancelled on PR #9. Please re-run it.'
    const cancelled: Facts = { ...FACTS, checks: 'cancelled', why: { checks: 'build' } }
    expect(judgeBoard(READY, comment(body), cancelled)).toBeUndefined()
    expect(judgeBoard(READY, comment(body), { ...cancelled, strikes: undefined })).toBeUndefined()
    expect(judgeBoard(READY, comment(body), { ...FACTS, checks: 'pass' })).toContain('no required check on PR #9 is cancelled')
    expect(judgeBoard(READY, comment(body.replace('build', 'lint')), cancelled)).toContain('the cancelled job build')
    expect(judgeBoard(READY, comment(body.replace('Please re-run it.', 'Thoughts?')), cancelled)).toContain('a request to re-run the job')
    expect(judgeBoard(READY, comment(body.replace('@mikebronner ', '')), cancelled)).toContain('@mikebronner')
  })

  test('a move to Escalated follows a cancelled-check escalation', () => {
    expect(observe(READY, comment('<!-- holmes-ci-cancelled -->\n@mikebronner re-run build'), {}, false).escalated).toBe(true)
  })

  test('with no memory tool, the feedback-search gate does not apply', () => {
    const none = { ...READY, feedbackSearches: 0 }
    expect(judgeBoard(none, review('approve', APPROVE_BODY), { ...FACTS, memoryAvailable: false })).toBeUndefined()
    expect(judgeBoard(none, review('approve', APPROVE_BODY), { ...FACTS, memoryAvailable: true })).toContain('C16')
  })

  test('a holmes-answer passes on a decision request, and is refused on finished work', () => {
    const answer = comment('<!-- holmes-answer -->\nOption 2, because it is smaller.')
    expect(judgeBoard(READY, answer, { ...FACTS, decision: 'decision-request' })).toBeUndefined()
    expect(judgeBoard(READY, answer, FACTS)).toContain('C14')
  })

  test('a well-formed AC-dispute escalation passes', () => {
    expect(judgeBoard(READY, comment(DISPUTE_BODY), FACTS)).toBeUndefined()
  })

  for (const [label, body] of [
    ['two option rows', DISPUTE_BODY.replace(/\n\| 3: revert[^\n]*/u, '')],
    ['no recommendation', DISPUTE_BODY.replace('**Recommendation:**', 'Recommendation:')],
    ['no table header', DISPUTE_BODY.replace('| Option | Pros | Cons | Grade |', '| Choice | Pros | Cons |')],
    ['the marker below the first line', `Hi\n${DISPUTE_BODY}`],
  ] as const) {
    test(`an AC-dispute escalation with ${label} is refused under C6`, () => {
      expect(judgeBoard(READY, comment(body), FACTS)).toContain('C6')
    })
  }

  test('a strike escalation passes at three strikes, and is refused below three or without its sections', () => {
    expect(judgeBoard(READY, comment(STRIKE_BODY), { ...FACTS, strikes: 3 })).toBeUndefined()
    expect(judgeBoard(READY, comment(STRIKE_BODY), { ...FACTS, strikes: 2 })).toContain('C1')
    expect(judgeBoard(READY, comment(STRIKE_BODY.replace('## Issues Found This Round', '')), { ...FACTS, strikes: 3 })).toContain('C6')
  })

  test('any other comment on the PR, or one on the issue, is refused', () => {
    expect(judgeBoard(READY, comment('LGTM'), FACTS)).toContain('C6')
    expect(judgeBoard(READY, comment('<!-- holmes-answer -->\nx', { pr_number: undefined }), FACTS)).toContain('C7')
  })

  test('an expansion comment passes only on an item find_item returned', () => {
    const expand = comment('<!-- expand-from: PR#9 -->\nmore', { id: '30', pr_number: undefined })
    expect(judgeBoard({ ...READY, expandable: ['30'] }, expand, FACTS)).toBeUndefined()
    expect(judgeBoard(READY, expand, FACTS)).toContain('C7')
  })

  test('a follow-up issue passes once the item is fresh, and is held to the freshness rule', () => {
    const issue: Call = { tool: IDX('create_issue'), agent: 'holmes', repo: 'o/r', title: 't', body: 'b' }
    expect(judgeBoard(READY, issue, FACTS)).toBeUndefined()
    expect(judgeBoard({ ...READY, status: 'Done' }, issue, FACTS)).toContain('C8')
  })

  for (const [column, ledger, ok] of [
    ['Approved', { ...READY, reviewed: 'approve' }, true],
    ['Approved', { ...READY, reviewed: 'request_changes' }, false],
    ['In Progress', { ...READY, reviewed: 'request_changes' }, true],
    ['In Progress', { ...READY, answered: true }, true],
    ['In Progress', { ...READY, reviewed: 'approve' }, false],
    ['Escalated', { ...READY, escalated: true }, true],
    ['Escalated', READY, false],
    ['Done', { ...READY, reviewed: 'approve' }, false],
    ['Approved', { ...READY, reviewed: 'approve', moved: 'Approved' }, false],
  ] as [string, Ledger, boolean][]) {
    test(`a move to ${column} after ${ledger.reviewed ?? (ledger.answered ? 'an answer' : ledger.escalated ? 'an escalation' : 'no verdict')}${ledger.moved ? ' and a move' : ''} ${ok ? 'passes' : 'is refused'}`, () => {
      const result = judgeBoard(ledger, move(column), FACTS)
      if (ok) expect(result).toBeUndefined()
      else expect(result).toContain('C7')
    })
  }

  test('a move with no linked PR is refused, so the broken state stays visible', () => {
    expect(judgeBoard({ ...READY, reviewed: 'approve' }, move('Approved'), { ...FACTS, pr: null })).toContain('no PR for #42')
  })
})

describe('verdict guard — body shapes', () => {
  test('bodyFault names each missing part', () => {
    expect(bodyFault('approve', APPROVE_BODY)).toBeUndefined()
    expect(bodyFault('approve', APPROVE_BODY.replace('Ready for @mikebronner to merge.', ''))).toContain('Ready for @mikebronner to merge.')
    expect(bodyFault('request_changes', CHANGES_BODY)).toBeUndefined()
    expect(bodyFault('request_changes', CHANGES_BODY.replace('## Issues Found', '## Problems'))).toContain('## Issues Found')
  })

  test('disputeFault accepts the shape and names a missing separator row', () => {
    expect(disputeFault(DISPUTE_BODY)).toBeUndefined()
    expect(disputeFault(DISPUTE_BODY.replace('|---|---|---|---|\n', ''))).toContain('separator')
  })
})

describe('verdict guard — what the run did (observe)', () => {
  const call = (tool: string, fields: Record<string, unknown> = {}): Call => ({ tool, ...fields })

  test('get_item of the item records its repo, issue and status, and when it was read', () => {
    const after = observe(EMPTY_LEDGER, call(IDX('get_item'), { id: 7 }), { text: JSON.stringify({ id: 7, repo: 'o/r', issue_number: 42, status: 'In Review' }) }, false)
    expect([after.itemId, after.repo, after.issue, after.status, after.lastGetItemAt]).toEqual(['7', 'o/r', 42, 'In Review', 1])
  })

  test('get_item of another item changes nothing, and an unreadable answer leaves the status unknown', () => {
    const own = observe(EMPTY_LEDGER, call(IDX('get_item'), { id: '7' }), { text: '{"status":"In Review"}' }, false)
    expect(observe(own, call(IDX('get_item'), { id: '8' }), { text: '{"status":"Done"}' }, false).status).toBe('In Review')
    expect(observe(own, call(IDX('get_item'), { id: '7' }), { text: 'not json' }, false).status).toBeUndefined()
  })

  test('an Agent call marks the helpers as later than the last read', () => {
    const read = observe(EMPTY_LEDGER, call(IDX('get_item'), { id: '7' }), { text: '{"status":"In Review"}' }, false)
    const after = observe(read, call('Agent'), {}, false)
    expect(after.lastAgentAt > after.lastGetItemAt).toBe(true)
  })

  test('every attempted search in the feedback folder counts, an errored one too, and no other search', () => {
    let ledger = observe(EMPTY_LEDGER, call(MEM('search'), { folder: 'feedback', query: 'repo' }), { text: '[]' }, false)
    ledger = observe(ledger, call(MEM('search'), { query: 'repo' }), { text: '[]' }, false)
    ledger = observe(ledger, call(MEM('search'), { folder: 'feedback', query: 'x' }), { isError: true, text: 'down' }, true)
    expect(ledger.feedbackSearches).toBe(2)
  })

  test('the memory server\'s not-found error, quoted as it really answers, records the path as free', () => {
    const path = 'dev-team/review-learnings/o-r-pr9-2026-10-30-101500-a1b2c3.md'
    let ledger = observe(EMPTY_LEDGER, call(MEM('read'), { path }), notFound(path), true)
    ledger = observe(ledger, call(MEM('read'), { path: 'other.md' }), { text: '# a note' }, false)
    ledger = observe(ledger, call(MEM('read'), { path: 'locked.md' }), { isError: true, result: [{ type: 'text', text: 'Internal error: index locked' }], text: 'Internal error: index locked' }, true)
    ledger = observe(ledger, call('Bash', { command: 'openssl rand -hex 3' }), { result: { stdout: 'a1b2c3\n' } }, false)
    ledger = observe(ledger, call('Bash', { command: 'date +%H%M%S' }), { result: { stdout: '101500\n' } }, false)
    ledger = observe(ledger, call('Bash', { command: 'echo a1b2c4' }), { result: { stdout: 'a1b2c4\n' } }, false)
    expect([ledger.notFound, ledger.tokens, ledger.times]).toEqual([[path], ['a1b2c3'], ['101500']])
  })

  test('a checkout open records its path, and close forgets it', () => {
    const open = observe(EMPTY_LEDGER, call('Bash', { command: '/p/bin/holmes-checkout.sh open o/r 9 /s' }), { result: { stdout: '/s/holmes.abc123\n' } }, false)
    expect(open.checkouts).toEqual(['/s/holmes.abc123'])
    expect(observe(open, call('Bash', { command: '/p/bin/holmes-checkout.sh close /s/holmes.abc123' }), { result: { stdout: '' } }, false).checkouts).toEqual([])
  })
})

describe('verdict guard — learning notes (C2)', () => {
  const PATH = 'dev-team/review-learnings/o-r-pr9-2026-10-30-101500-a1b2c3.md'
  const NOTED: Ledger = { ...READY, notFound: [PATH], tokens: ['a1b2c3'], times: ['101500'] }
  const note = (path: string, tags: unknown = ['dev-team', 'review-learnings', 'holmes', 'correctness']): Call => ({ tool: MEM('write'), path, frontmatter: { tags }, content: 'x' })

  test('a note named from printed values, on a path read as free, with a category, passes', () => {
    expect(judgeNote(NOTED, note(PATH))).toBeUndefined()
  })

  for (const [label, ledger, call] of [
    ['a path not in the note shape', NOTED, note('dev-team/review-learnings/o-r-pr9-today.md')],
    ['a time date never printed', { ...NOTED, times: ['101501'] }, note(PATH)],
    ['a token openssl never printed', { ...NOTED, tokens: ['ffffff'] }, note(PATH)],
    ['a path no read proved free', { ...NOTED, notFound: [] }, note(PATH)],
    ['no category tag', NOTED, note(PATH, ['dev-team', 'holmes'])],
  ] as [string, Ledger, Call][]) {
    test(`${label} is refused under C2`, () => {
      expect(judgeNote(ledger, call)).toContain('C2')
    })
  }

  test('a note for an item that left In Review is refused under C8', () => {
    expect(judgeNote({ ...NOTED, status: 'Done' }, note(PATH))).toContain('C8')
  })

  test('a write outside review-learnings is not this rule', () => {
    expect(judgeNote(READY, note('progress/x.md'))).toBeUndefined()
  })
})

describe('verdict guard — the top-lessons digest (C15)', () => {
  const digest = (counts: [string, number][], approvals = 100, meta = 'Fixing the instance is not the class.') =>
    [
      '# Top Review Lessons — read before coding or triaging',
      '',
      `**Clean first-pass approvals:** ${approvals}`,
      '',
      '> **Scope:** a digest.',
      '',
      '## The meta-rule',
      '',
      meta,
      '',
      '---',
      '',
      ...counts.flatMap(([name, n], i) => [`## ${i + 1}. ${name} — ${n} ${n === 1 ? 'event' : 'events'}`, '', `- a rule for ${name}`, '']),
      '---',
      '',
      '## Maintaining this digest',
      '',
      'Rules, not history.',
      '',
    ].join('\n')
  const CURRENT = `---\nname: Dev-Team Top Review Lessons\n---\n\n${digest([['correctness', 10], ['nitpick', 4]])}`

  test('a write that adds a rule, ranked, with the protected blocks carried through, passes', () => {
    expect(judgeDigestWrite(digest([['correctness', 11], ['nitpick', 4]]).replace('- a rule for nitpick', '- a rule for nitpick\n- a new rule'), CURRENT)).toBeUndefined()
  })

  for (const [label, content] of [
    ['a write whose only change is a count', digest([['correctness', 11], ['nitpick', 4]])],
    ['a write out of rank order', digest([['nitpick', 4], ['correctness', 11]])],
    ['a write that changes the approvals count', digest([['correctness', 11], ['nitpick', 4]], 101).replace('nitpick\n', 'nitpick\n- new\n')],
    ['a write that changes the meta-rule block', digest([['correctness', 11], ['nitpick', 4]], 100, 'Changed.')],
    ['a write that drops the Maintaining section', digest([['correctness', 11], ['nitpick', 4]]).replace(/## Maintaining this digest[\s\S]*$/u, '- new\n')],
  ] as const) {
    test(`${label} is refused`, () => {
      expect(judgeDigestWrite(content, CURRENT)).toContain('C15')
    })
  }

  test('with no digest yet, a ranked write passes and an unranked one is refused', () => {
    expect(judgeDigestWrite(digest([['correctness', 1]]), undefined)).toBeUndefined()
    expect(judgeDigestWrite(digest([['correctness', 1], ['nitpick', 2]]), undefined)).toContain('C15')
  })

  test('a count-bump edit that keeps the ranking passes, and one that breaks it is refused', () => {
    expect(judgeDigestEdit('## 2. nitpick — 4 events', '## 2. nitpick — 5 events', CURRENT)).toBeUndefined()
    expect(judgeDigestEdit('## 2. nitpick — 4 events', '## 2. nitpick — 11 events', CURRENT)).toContain('C15')
  })

  test('an edit of a digest the guard could not read is refused', () => {
    expect(judgeDigestEdit('a', 'b', undefined)).toContain('C15')
  })
})

describe('verdict guard — what the guard runs', () => {
  test('checksOf reads gh pr checks --required --json: failed, cancelled, pending, passed, none required, and unreadable', () => {
    const rows = (...buckets: string[]) => JSON.stringify(buckets.map((bucket, i) => ({ name: `job${i}`, bucket })))
    expect(checksOf({ exitCode: 1, stdout: rows('pass', 'fail', 'pending'), stderr: '' })).toEqual({ checks: 'fail', names: ['job1'] })
    expect(checksOf({ exitCode: 1, stdout: rows('pass', 'cancel'), stderr: '' })).toEqual({ checks: 'cancelled', names: ['job1'] })
    expect(checksOf({ exitCode: 8, stdout: rows('pending', 'pass'), stderr: '' })).toEqual({ checks: 'pending', names: ['job0'] })
    expect(checksOf({ exitCode: 0, stdout: rows('pass', 'skipping'), stderr: '' })).toEqual({ checks: 'pass', names: [] })
    expect(checksOf({ exitCode: 1, stdout: '', stderr: "no required checks reported on the 'x' branch" })).toEqual({ checks: 'none', names: [] })
    expect(checksOf({ exitCode: 4, stdout: '', stderr: 'auth' }).checks).toBeUndefined()
  })

  test('the guard asks gh for the required checks only, so a failed optional check never reaches it', () => {
    expect(CHECKS_ARGV(9, 'o/r')).toEqual(['gh', 'pr', 'checks', '9', '-R', 'o/r', '--required', '--json', 'name,bucket'])
  })

  test('factOf reads a script: 0 is its line, 1 is none, anything else is unknown', () => {
    expect(factOf({ exitCode: 0, stdout: '9\n' })).toBe('9')
    expect(factOf({ exitCode: 1, stdout: '' })).toBeNull()
    expect(factOf({ exitCode: 2, stdout: '' })).toBeUndefined()
    expect(factOf(undefined)).toBeUndefined()
  })

  test('vaultOf resolves the vault as the dispatcher does: the variable, then core memory_path, then the default', () => {
    expect(vaultOf('/env/vault', '{"memory_path":"/core/vault"}', '/h')).toBe('/env/vault')
    expect(vaultOf(undefined, '{"memory_path":"/core/vault"}', '/h')).toBe('/core/vault')
    expect(vaultOf('', 'not json', '/h')).toBe('/h/Documents/Claude/Memory')
  })
})

describe('verdict guard — wired into tool.call', () => {
  const ITEM = JSON.stringify({ id: 7, repo: 'o/r', issue_number: 42, status: 'In Review' })
  const NOTE = 'dev-team/review-learnings/o-r-pr9-2026-10-30-101500-a1b2c3.md'
  const DIGEST = [
    '---',
    'name: Dev-Team Top Review Lessons',
    '---',
    '',
    '# Top Review Lessons — read before coding or triaging',
    '',
    '**Clean first-pass approvals:** 100',
    '',
    '## 1. correctness — 10 events',
    '',
    '- a rule',
    '',
  ].join('\n')
  type Scripts = { decision?: string; strikes?: string; buckets?: string[]; failing?: string }
  const scripts = (o: Scripts) => (argv: readonly string[]) => {
    const script = (argv[1] ?? '').split('/').pop() ?? ''
    if (script === o.failing) return { exitCode: 2, stdout: '', stderr: `gh: HTTP 502 in ${script}` }
    if (script === 'holmes-find-pr.sh') return { exitCode: 0, stdout: '9\n', stderr: '' }
    if (script === 'holmes-decision-request.sh') return { exitCode: 0, stdout: `${o.decision ?? 'review'}\n`, stderr: '' }
    if (script === 'holmes-strike-count.sh') return { exitCode: 0, stdout: `${o.strikes ?? '0'}\n`, stderr: '' }
    if (argv[0] === 'gh' && argv[2] === 'checks') {
      const buckets = o.buckets ?? ['pass']
      return { exitCode: buckets.includes('pending') ? 8 : 0, stdout: JSON.stringify(buckets.map((bucket, i) => ({ name: `job${i}`, bucket }))), stderr: '' }
    }
    return undefined
  }
  const answers = (input: Record<string, unknown>) => {
    if (input.tool === IDX('get_item')) return { result: ITEM, text: ITEM }
    if (input.tool === MEM('read') && typeof input.path === 'string' && input.path.startsWith('dev-team/review-learnings/')) return notFound(input.path)
    if (input.tool === 'Bash' && input.command === 'date +%H%M%S') return { result: { stdout: '101500\n', stderr: '', interrupted: false } }
    if (input.tool === 'Bash' && input.command === 'openssl rand -hex 3') return { result: { stdout: 'a1b2c3\n', stderr: '', interrupted: false } }
    return undefined
  }
  const holmesIndex = (o: Scripts = {}) => ({
    lane: () => 'top-level-agent' as const,
    env: { CLAUDE_CODE_AGENT: T('holmes-index'), WORKBENCH_MEMORY_PATH: '/vault' },
    roots: ['/scratch/session'],
    run: scripts(o),
    tools: answers,
  })
  const call = (tool: string, fields: Record<string, unknown> = {}) => ({ tool, tool_use_id: 'toolu_1', ...fields }) as never
  const reached = (w: ReturnType<typeof world>, tool: string) => w.calls.filter(c => c.tool === tool).length
  type Caller = { tool: { call: (e: never) => Promise<unknown> } }
  const denyOf = async ($: Caller, tool: string, fields: Record<string, unknown> = {}) => ((await $.tool.call(call(tool, fields))) as { deny?: string }).deny

  async function prepare($: Caller) {
    await $.tool.call(call(IDX('get_item'), { id: 7 }))
    await $.tool.call(call(MEM('search'), { query: 'o/r', folder: 'feedback' }))
    await $.tool.call(call(MEM('search'), { query: 'parser', folder: 'feedback' }))
  }

  test('the whole prescribed Index-mode run, with real answer shapes, has no step refused', async ($, on) => {
    const w = world(on, holmesIndex())
    w.files.set('/vault/dev-team/top-lessons.md', DIGEST)
    const steps: [string, Record<string, unknown>][] = [
      [IDX('get_item'), { id: 7 }],
      ['Agent', { subagent_type: T('holmes-lens'), prompt: 'lens 1', description: 'd' }],
      ['Agent', { subagent_type: T('holmes-lens'), prompt: 'lens 2', description: 'd' }],
      [IDX('get_item'), { id: 7 }],
      [MEM('search'), { query: 'o/r', folder: 'feedback' }],
      [MEM('search'), { query: 'parser', folder: 'feedback' }],
      [IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'approve', body: APPROVE_BODY }],
      [IDX('move'), { id: 7, agent: 'holmes', column: 'Approved' }],
      [IDX('create_issue'), { agent: 'holmes', repo: 'o/r', title: 'Umbrella', body: 'b' }],
      ['Bash', { command: 'date +%H%M%S', description: 'd' }],
      ['Bash', { command: 'openssl rand -hex 3', description: 'd' }],
      [MEM('read'), { path: NOTE }],
      [MEM('write'), { path: NOTE, frontmatter: { tags: ['dev-team', 'review-learnings', 'holmes', 'clean-approve'] }, content: 'x' }],
      [MEM('edit'), { path: 'dev-team/top-lessons.md', old_text: '**Clean first-pass approvals:** 100', new_text: '**Clean first-pass approvals:** 101' }],
    ]
    for (const [tool, fields] of steps) expect([tool, await denyOf($ as never, tool, fields)]).toEqual([tool, undefined])
    expect(w.calls.length).toBe(steps.length)
  })

  test('the whole decision-request flow, answer then move, has no step refused', async ($, on) => {
    const w = world(on, holmesIndex({ decision: 'decision-request' }))
    await prepare($ as never)
    expect(await denyOf($ as never, IDX('add_comment'), { id: 7, agent: 'holmes', pr_number: 9, body: '<!-- holmes-answer -->\nOption 2, because it is smaller.' })).toBeUndefined()
    expect(await denyOf($ as never, IDX('move'), { id: 7, agent: 'holmes', column: 'In Progress' })).toBeUndefined()
    expect([reached(w, IDX('add_comment')), reached(w, IDX('move'))]).toEqual([1, 1])
  })

  test('the whole prescribed Local-mode run has no step refused', async ($, on) => {
    const w = world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('holmes-local') }, tools: answers })
    const path = 'dev-team/review-learnings/workbench-dev-team-local-2026-10-30-101500-a1b2c3.md'
    const steps: [string, Record<string, unknown>][] = [
      [MEM('search'), { query: 'workbench-dev-team', folder: 'feedback' }],
      [MEM('search'), { query: 'parser', folder: 'feedback' }],
      ['Bash', { command: 'git status --short', description: 'd' }],
      ['Bash', { command: 'git diff HEAD', description: 'd' }],
      ['Agent', { subagent_type: T('holmes-lens'), prompt: 'lens', description: 'd' }],
      ['Bash', { command: 'date +%H%M%S', description: 'd' }],
      ['Bash', { command: 'openssl rand -hex 3', description: 'd' }],
      [MEM('read'), { path }],
      [MEM('write'), { path, frontmatter: { tags: ['dev-team', 'review-learnings', 'holmes', 'correctness'] }, content: 'x' }],
    ]
    for (const [tool, fields] of steps) expect([tool, await denyOf($ as never, tool, fields)]).toEqual([tool, undefined])
    expect(w.calls.length).toBe(steps.length)
  })

  for (const [script, decision, reason] of [
    ['holmes-find-pr.sh', 'approve', 'could not resolve the PR'],
    ['holmes-decision-request.sh', 'approve', 'could not tell whether this PR is a decision request'],
    ['holmes-strike-count.sh', 'request_changes', 'could not compute the strike count'],
  ] as const) {
    test(`${script} exiting 2 refuses the verdict, with its reason`, async ($, on) => {
      const w = world(on, holmesIndex({ failing: script }))
      await prepare($ as never)
      const deny = await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision, body: decision === 'approve' ? APPROVE_BODY : CHANGES_BODY })
      expect(deny).toContain(reason)
      expect(deny).toContain(`exit 2: gh: HTTP 502 in ${script}`)
      expect(reached(w, IDX('submit_review'))).toBe(0)
    })
  }

  test('with the vault down, two errored feedback searches still let the verdict through', async ($, on) => {
    const w = world(on, { ...holmesIndex(), tools: (input: Record<string, unknown>) => (input.tool === MEM('search') ? { isError: true, result: [{ type: 'text', text: 'down' }], text: 'down' } : answers(input)) })
    await prepare($ as never)
    expect(await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'approve', body: APPROVE_BODY })).toBeUndefined()
    expect(reached(w, IDX('submit_review'))).toBe(1)
  })

  test('without the two feedback searches, the review is refused and never reaches the engine', async ($, on) => {
    const w = world(on, holmesIndex())
    await $.tool.call(call(IDX('get_item'), { id: 7 }))
    expect(await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'approve', body: APPROVE_BODY })).toContain('C16')
    expect(reached(w, IDX('submit_review'))).toBe(0)
  })

  test('a fourth round of request-changes is refused, and the strike escalation then passes', async ($, on) => {
    const w = world(on, holmesIndex({ strikes: '3' }))
    await prepare($ as never)
    expect(await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'request_changes', body: CHANGES_BODY })).toContain('C1')
    expect(await denyOf($ as never, IDX('add_comment'), { id: 7, agent: 'holmes', pr_number: 9, body: STRIKE_BODY })).toBeUndefined()
    expect(await denyOf($ as never, IDX('move'), { id: 7, agent: 'holmes', column: 'Escalated' })).toBeUndefined()
    expect([reached(w, IDX('submit_review')), reached(w, IDX('add_comment')), reached(w, IDX('move'))]).toEqual([0, 1, 1])
  })

  for (const [label, buckets, refused] of [
    ['a failed required check', ['pass', 'fail'], 'A failed required check is a blocker'],
    ['a cancelled required check', ['cancel'], '<!-- holmes-ci-cancelled -->'],
    ['a pending required check', ['pending'], 'Do not approve yet'],
    ['no required checks', [], undefined],
  ] as const) {
    test(`an approve with ${label} ${refused === undefined ? 'passes' : 'is refused'}`, async ($, on) => {
      const w = world(on, holmesIndex({ buckets: [...buckets] }))
      await prepare($ as never)
      const deny = await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'approve', body: APPROVE_BODY })
      if (refused === undefined) expect(deny).toBeUndefined()
      else expect(deny).toContain(refused)
      expect(w.runs.find(argv => argv[0] === 'gh')).toEqual(['gh', 'pr', 'checks', '9', '-R', 'o/r', '--required', '--json', 'name,bucket'])
    })
  }

  test('a cancelled required check: the approve is refused, the escalation and the move pass, and no strike is counted', async ($, on) => {
    const w = world(on, holmesIndex({ buckets: ['pass', 'cancel'] }))
    await prepare($ as never)
    expect(await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'approve', body: APPROVE_BODY })).toContain('was cancelled (job1)')
    const body = '<!-- holmes-ci-cancelled -->\n@mikebronner The required check job1 was cancelled on PR #9. Please re-run it, then the review continues.'
    expect(await denyOf($ as never, IDX('add_comment'), { id: 7, agent: 'holmes', pr_number: 9, body })).toBeUndefined()
    expect(await denyOf($ as never, IDX('move'), { id: 7, agent: 'holmes', column: 'Escalated' })).toBeUndefined()
    expect([reached(w, IDX('submit_review')), reached(w, IDX('add_comment')), reached(w, IDX('move'))]).toEqual([0, 1, 1])
    expect(w.runs.some(argv => (argv[1] ?? '').endsWith('holmes-strike-count.sh'))).toBe(false)
  })

  test('a cancelled-check escalation with no cancelled check is refused, and the move after it too', async ($, on) => {
    const w = world(on, holmesIndex())
    await prepare($ as never)
    const body = '<!-- holmes-ci-cancelled -->\n@mikebronner The required check job0 was cancelled. Please re-run it.'
    expect(await denyOf($ as never, IDX('add_comment'), { id: 7, agent: 'holmes', pr_number: 9, body })).toContain('no required check on PR #9 is cancelled')
    expect(await denyOf($ as never, IDX('move'), { id: 7, agent: 'holmes', column: 'Escalated' })).toContain('C7')
    expect([reached(w, IDX('add_comment')), reached(w, IDX('move'))]).toEqual([0, 0])
  })

  test('a helper spawned after the last read makes the next write wait for a fresh get_item', async ($, on) => {
    const w = world(on, holmesIndex())
    await prepare($ as never)
    await $.tool.call(call('Agent', { subagent_type: T('holmes-lens'), prompt: 'lens', description: 'd' }))
    expect(await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'approve', body: APPROVE_BODY })).toContain('C8')
    await $.tool.call(call(IDX('get_item'), { id: 7 }))
    expect(await denyOf($ as never, IDX('submit_review'), { id: 7, agent: 'holmes', pr_number: 9, decision: 'approve', body: APPROVE_BODY })).toBeUndefined()
    expect(reached(w, IDX('submit_review'))).toBe(1)
  })

  test('a checkout the run left open under a scratch root is removed when the run completes', async ($, on) => {
    const w = world(on, {
      ...holmesIndex(),
      tools: (input: Record<string, unknown>) =>
        input.tool === 'Bash' ? { result: { stdout: '/scratch/session/holmes.abc123\n', stderr: '', interrupted: false } } : answers(input),
    })
    await $.tool.call(call('Bash', { command: '/plugin/bin/holmes-checkout.sh open o/r 9 /scratch/session', description: 'd' }))
    await complete($ as never)
    expect(w.runs).toContainEqual(['rm', '-rf', '--', '/scratch/session/holmes.abc123'])
  })

  test('a recorded checkout whose parent is not a scratch root is left alone', async ($, on) => {
    const w = world(on, {
      ...holmesIndex(),
      tools: (input: Record<string, unknown>) =>
        input.tool === 'Bash' ? { result: { stdout: '/scratch/session/deeper/holmes.abc123\n', stderr: '', interrupted: false } } : answers(input),
    })
    await $.tool.call(call('Bash', { command: '/plugin/bin/holmes-checkout.sh open o/r 9 /scratch/session/deeper', description: 'd' }))
    await complete($ as never)
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([])
  })

  test("Holmes Local writing the digest is refused; its own note is not this guard's", async ($, on) => {
    const w = world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('holmes-local') } })
    expect(await denyOf($ as never, MEM('edit'), { path: 'dev-team/top-lessons.md', old_text: 'a', new_text: 'b' })).toContain('C15')
    expect(await denyOf($ as never, MEM('write'), { path: 'dev-team/review-learnings/local-x.md', content: 'x' })).toBeUndefined()
    expect(reached(w, MEM('write'))).toBe(1)
  })

  test('when the mod cannot tell which agent called, the call passes and the gap is logged', async ($, on) => {
    const w = world(on, { lane: () => new Error('lane unknown') })
    expect(await denyOf($ as never, MEM('search'), { query: 'x', folder: 'feedback' })).toBeUndefined()
    expect(w.shown.some(line => line.includes('could not tell which agent made a call'))).toBe(true)
  })

  test("another agent's board write is not judged", async ($, on) => {
    const w = world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('watson-index') } })
    expect(await denyOf($ as never, IDX('move'), { id: 7, agent: 'watson', column: 'In Review' })).toBeUndefined()
    expect(reached(w, IDX('move'))).toBe(1)
  })
})

describe('verdict guard — a guard failure', () => {
  test('the refusal carries the error that caused it', () => {
    expect(verdictFailed(new Error('state store unreachable'))).toContain('(state store unreachable)')
    expect(verdictFailed('plain text')).toContain('(plain text)')
  })
})
