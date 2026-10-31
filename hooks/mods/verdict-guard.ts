import { PLUGIN } from './spawn'

export const INDEX_MODE = `${PLUGIN}:holmes-index`
export const LOCAL_MODE = `${PLUGIN}:holmes-local`

export type Ledger = {
  seq: number
  lastAgentAt: number
  lastGetItemAt: number
  itemId?: string
  repo?: string
  issue?: number
  status?: string
  feedbackSearches: number
  expandable: string[]
  pr?: number | null
  reviewed?: 'approve' | 'request_changes'
  escalated: boolean
  answered: boolean
  moved?: string
  notFound: string[]
  tokens: string[]
  times: string[]
  checkouts: string[]
}

export const EMPTY_LEDGER: Ledger = {
  seq: 0,
  lastAgentAt: 0,
  lastGetItemAt: 0,
  feedbackSearches: 0,
  expandable: [],
  escalated: false,
  answered: false,
  notFound: [],
  tokens: [],
  times: [],
  checkouts: [],
}

export type Call = Record<string, unknown> & { tool: string }

export type Checks = 'pass' | 'none' | 'pending' | 'fail' | 'cancelled'

export type Facts = {
  pr?: number | null
  strikes?: number
  checks?: Checks
  decision?: 'decision-request' | 'review'
  memoryAvailable?: boolean
  why?: Partial<Record<'pr' | 'decision' | 'strikes' | 'checks', string>>
}

export const CATEGORIES: readonly string[] = [
  'test-honesty',
  'security-hardening',
  'fail-open',
  'correctness',
  'doc-drift',
  'ac-not-met',
  'nitpick',
  'escalation',
  'clean-approve',
]

export const DIGEST_PATH = 'dev-team/top-lessons.md'
const NOTE_DIR = 'dev-team/review-learnings/'
const NOTE_PATH = /^dev-team\/review-learnings\/[a-z0-9][a-z0-9._-]*-pr[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-([0-9]{6})-([0-9a-f]{6})\.md$/

const indexToolOf = (tool: string): string | undefined => /^mcp__(?:.*_)?the-index__([a-z_]+)$/.exec(tool)?.[1]
const memoryToolOf = (tool: string): string | undefined => /^mcp__.*memory__(read|write|edit|search)$/.exec(tool)?.[1]

const BOARD_WRITES: ReadonlySet<string> = new Set(['submit_review', 'add_comment', 'move', 'create_issue'])

export const isBoardWrite = (tool: string): boolean => BOARD_WRITES.has(indexToolOf(tool) ?? '')
export const isMemoryWrite = (tool: string): boolean => ['write', 'edit'].includes(memoryToolOf(tool) ?? '')
export const isWatched = (tool: string): boolean => indexToolOf(tool) !== undefined || memoryToolOf(tool) !== undefined || tool === 'Agent' || tool === 'Bash'

const str = (value: unknown): string | undefined => (typeof value === 'string' ? value : typeof value === 'number' ? String(value) : undefined)
const num = (value: unknown): number | undefined => {
  const n = typeof value === 'number' ? value : typeof value === 'string' && /^[0-9]+$/.test(value) ? Number(value) : NaN
  return Number.isInteger(n) ? n : undefined
}

function jsonOf(text: string | undefined): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(text ?? '')
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

export function textOf(result: unknown): string | undefined {
  const r = result as { text?: unknown; result?: unknown } | undefined
  if (typeof r?.text === 'string') return r.text
  if (typeof r?.result === 'string') return r.result
  if (Array.isArray(r?.result)) return r.result.map(part => str((part as { text?: unknown }).text) ?? '').join('')
  return undefined
}

const stdoutOf = (result: unknown): string | undefined => {
  const out = (result as { result?: { stdout?: unknown } } | undefined)?.result?.stdout
  return typeof out === 'string' ? out : textOf(result)
}

const isNotFound = (text: string, path: string): boolean =>
  text.includes(`Document not found: '${path}'`) || text.includes(`Document not found: ${path}`)

export function observe(ledger: Ledger, call: Call, result: unknown, isError: boolean): Ledger {
  const seq = ledger.seq + 1
  const next: Ledger = { ...ledger, seq }
  if (call.tool === 'Agent') return { ...next, lastAgentAt: seq }
  const index = indexToolOf(call.tool)
  const memory = memoryToolOf(call.tool)
  if (memory === 'search' && call.folder === 'feedback') return { ...next, feedbackSearches: ledger.feedbackSearches + 1 }
  if (memory === 'read') {
    const path = str(call.path)
    return path !== undefined && isNotFound(textOf(result) ?? '', path) ? { ...next, notFound: [...ledger.notFound, path] } : next
  }
  if (isError) return next
  if (index === 'get_item') {
    const id = str(call.id)
    if (id === undefined || (ledger.itemId !== undefined && id !== ledger.itemId)) return next
    const item = jsonOf(textOf(result))
    return {
      ...next,
      itemId: id,
      lastGetItemAt: seq,
      repo: str(item?.repo) ?? ledger.repo,
      issue: num(item?.issue_number) ?? ledger.issue,
      status: str(item?.status),
    }
  }
  if (index === 'find_item') {
    const found = jsonOf(textOf(result))?.item as Record<string, unknown> | undefined
    const id = str(found?.id)
    return id === undefined ? next : { ...next, expandable: [...ledger.expandable, id] }
  }
  if (index === 'submit_review') {
    const decision = call.decision === 'approve' || call.decision === 'request_changes' ? call.decision : undefined
    return { ...next, reviewed: decision }
  }
  if (index === 'add_comment') {
    const body = str(call.body) ?? ''
    if (firstLine(body) === ANSWER) return { ...next, answered: true }
    if (escalationOf(body) !== undefined) return { ...next, escalated: true }
    return next
  }
  if (index === 'move') return { ...next, moved: str(call.column) }
  if (call.tool === 'Bash') {
    const command = (str(call.command) ?? '').trim()
    const out = (stdoutOf(result) ?? '').trim()
    if (command === 'openssl rand -hex 3' && /^[0-9a-f]{6}$/.test(out)) return { ...next, tokens: [...ledger.tokens, out] }
    if (command === 'date +%H%M%S' && /^[0-9]{6}$/.test(out)) return { ...next, times: [...ledger.times, out] }
    const checkout = /holmes-checkout\.sh\s+(open|close)\b(.*)$/.exec(command)
    if (checkout?.[1] === 'open' && out.startsWith('/') && !out.includes('\n')) return { ...next, checkouts: [...ledger.checkouts, out] }
    if (checkout?.[1] === 'close') return { ...next, checkouts: ledger.checkouts.filter(path => !(checkout[2] ?? '').includes(path)) }
  }
  return next
}

const ANSWER = '<!-- holmes-answer -->'
const DISPUTE = '<!-- holmes-ac-dispute -->'
export const CANCELLED = '<!-- holmes-ci-cancelled -->'
const STRIKE_HEAD = '🛑 **Escalating to @mikebronner'

const firstLine = (body: string): string => (body.split('\n')[0] ?? '').trim()

function escalationOf(body: string): 'dispute' | 'strike' | 'cancelled' | undefined {
  if (firstLine(body) === DISPUTE) return 'dispute'
  if (firstLine(body) === CANCELLED) return 'cancelled'
  if (body.trimStart().startsWith(STRIKE_HEAD)) return 'strike'
  return undefined
}

const deny = (rule: string, why: string, todo: string): string =>
  `🛑 Blocked: ${why}\n\nVerdict guard (workbench-dev-team), ${rule}. ${todo} Never route around this guard: no gh write, no GraphQL, no curl.`

const missing = (body: string, parts: readonly string[]): string[] => parts.filter(part => !body.includes(part))

export function bodyFault(decision: 'approve' | 'request_changes', body: string): string | undefined {
  const head = decision === 'approve' ? '✅ **Approved**' : '🔄 **Changes Requested**'
  const parts =
    decision === 'approve'
      ? ['## Review Summary', '## 📋 Non-blocking follow-ups', 'Ready for @mikebronner to merge.']
      : ['## Issues Found', "## What's Good", '## 📋 Non-blocking follow-ups', 'Please address the above and re-request review.']
  const absent = [...(body.trimStart().startsWith(head) ? [] : [`the first line ${head}`]), ...missing(body, parts)]
  return absent.length === 0 ? undefined : absent.join(', ')
}

export function disputeFault(body: string): string | undefined {
  const lines = body.split('\n').map(line => line.trim())
  const header = lines.findIndex(line => /^\|\s*Option\s*\|\s*Pros\s*\|\s*Cons\s*\|\s*Grade\s*\|$/.test(line))
  const rows = header < 0 ? [] : lines.slice(header + 2).filter(line => line.startsWith('|'))
  const faults = [
    ...(header < 0 ? ['a table whose header is | Option | Pros | Cons | Grade |'] : []),
    ...(header >= 0 && !/^\|[\s|:-]+\|$/.test(lines[header + 1] ?? '') ? ['the table separator row under its header'] : []),
    ...(header >= 0 && (rows.length !== 3 || !rows.every((row, i) => new RegExp(`^\\|\\s*${i + 1}\\b`).test(row))) ? ['exactly three option rows, numbered 1 to 3'] : []),
    ...(lines.some(line => line.startsWith('**Recommendation:** option')) ? [] : ['a **Recommendation:** option <N> line after the table']),
    ...(body.includes('@mikebronner') ? [] : ['@mikebronner']),
  ]
  return faults.length === 0 ? undefined : faults.join(', ')
}

export function cancelledFault(body: string, jobs: string): string | undefined {
  const names = jobs.split(', ').filter(name => name !== '')
  const faults = [
    ...names.filter(name => !body.includes(name)).map(name => `the cancelled job ${name}`),
    ...(body.includes('@mikebronner') ? [] : ['@mikebronner']),
    ...(/re-?run/iu.test(body) ? [] : ['a request to re-run the job']),
  ]
  return faults.length === 0 ? undefined : faults.join(', ')
}

const strikeFault = (body: string): string | undefined => {
  const absent = missing(body, ['## Issues Found This Round', "## What's Good"])
  return absent.length === 0 ? undefined : absent.join(', ')
}

export function judgeBoard(ledger: Ledger, call: Call, facts: Facts): string | undefined {
  const tool = indexToolOf(call.tool) ?? ''
  if (call.agent !== 'holmes') return deny('C7', `a board write signed as ${JSON.stringify(call.agent ?? null)}.`, 'Pass agent: "holmes" on every write tool.')
  if (ledger.itemId === undefined) return deny('C8', 'a board write before any get_item of your item.', 'Re-read the item with get_item, then write.')
  if (ledger.status !== 'In Review')
    return deny(
      'C8',
      `the item is ${ledger.status === undefined ? 'in a status the guard could not read' : `in ${ledger.status}`}, not In Review.`,
      'The item is no longer yours: write nothing more, to the board or the vault, and report the stale exit: `⏭️ reviewed #<issue_number> (<repo>) PR #<pr_num> → stale (item now <status>); verdict <Approved|Changes|Escalated> not written`.',
    )
  if (ledger.lastGetItemAt < ledger.lastAgentAt)
    return deny('C8', 'a board write on an item read before your helpers ran.', 'Call get_item for your item again now, after the helpers finished, and write only if it is still In Review.')
  if (ledger.feedbackSearches < 2 && facts.memoryAvailable !== false)
    return deny('C16', `${ledger.feedbackSearches} memory search(es) with folder "feedback" before a board write.`, 'Run the two `feedback/` searches of §4a.5 first: one for the repo, one for the change. A search that errors counts, and with no memory tool the gate does not apply.')
  if (tool === 'create_issue') return undefined

  const id = str(call.id)
  const isOwn = id === ledger.itemId
  if (tool === 'add_comment' && !isOwn) {
    return id !== undefined && ledger.expandable.includes(id) ? undefined : deny('C7', `a comment on item ${id}, which is neither your item nor one find_item returned.`, 'Comment only on your item, or on an item find_item resolved for an expansion.')
  }
  if (!isOwn) return deny('C7', `a ${tool} on item ${id}, not your item ${ledger.itemId}.`, 'One review covers one item.')

  if (facts.pr === undefined) return deny('C13', `the guard could not resolve the PR linked to the issue (${facts.why?.pr ?? 'no answer'}).`, 'Report the error and stop. Do not move the item.')
  if (facts.pr === null)
    return deny('C13', `no PR is linked to #${ledger.issue}.`, `Write nothing and do not move the item. Report \`no PR for #${ledger.issue}\` and exit.`)
  const pr = num(call.pr_number)
  if ((tool === 'submit_review' || (tool === 'add_comment' && pr !== undefined)) && pr !== facts.pr)
    return deny('C13', `pr_number ${String(call.pr_number)} is not the PR linked to #${ledger.issue}, which is #${facts.pr}.`, `Use pr_number ${facts.pr}.`)

  if (tool === 'submit_review') {
    if (ledger.reviewed !== undefined) return deny('C7', 'a second submit_review in one run.', 'One review posts one verdict.')
    if (facts.decision === undefined) return deny('C14', `the guard could not tell whether this PR is a decision request (${facts.why?.decision ?? 'no answer'}).`, 'Report the error and stop.')
    if (facts.decision === 'decision-request')
      return deny('C14', 'this PR is a decision request, not finished work.', 'Answer it with an add_comment whose first line is <!-- holmes-answer -->, then move the item to In Progress. Do not review or approve.')
    const decision = call.decision
    if (decision !== 'approve' && decision !== 'request_changes') return deny('C5', `decision ${JSON.stringify(decision)}.`, 'The decision is approve or request_changes.')
    const fault = bodyFault(decision, str(call.body) ?? '')
    if (fault !== undefined) return deny('C5', `the verdict body lacks ${fault}.`, 'Write the body in the §5 shape for this verdict.')
    if (decision === 'approve') {
      const checks = checksDeny(facts)
      if (checks !== undefined) return checks
    } else {
      if (facts.strikes === undefined) return deny('C1', `the guard could not compute the strike count (${facts.why?.strikes ?? 'no answer'}).`, 'Report the error and stop.')
      if (facts.strikes >= 3)
        return deny('C1', `${facts.strikes} change-requests since Mike last weighed in, so this would be round ${facts.strikes + 1}.`, 'Do not request changes. Escalate: post the §5 strike escalation comment with add_comment, then move the item to Escalated.')
    }
    return undefined
  }

  if (tool === 'add_comment') {
    const body = str(call.body) ?? ''
    if (pr === undefined) return deny('C7', 'a comment on your issue, not its PR.', 'Pass pr_number: every comment on your own item goes on the PR conversation.')
    if (firstLine(body) === ANSWER) {
      if (facts.decision !== 'decision-request') return deny('C14', 'a holmes-answer comment on a PR that is not a decision request.', 'Review the PR instead.')
      return undefined
    }
    const kind = escalationOf(body)
    if (kind === 'dispute') {
      const fault = disputeFault(body)
      return fault === undefined ? undefined : deny('C6', `the AC-dispute escalation lacks ${fault}.`, 'Write it in the §5 ESCALATE shape: marker first, three graded options, one recommendation.')
    }
    if (kind === 'cancelled') {
      if (facts.checks !== 'cancelled')
        return deny('C12', `a cancelled-check escalation, but no required check on PR #${facts.pr} is cancelled (${facts.why?.checks || facts.checks || 'no answer'}).`, 'Escalate a cancelled check only while one is cancelled.')
      const fault = cancelledFault(body, facts.why?.checks ?? '')
      return fault === undefined ? undefined : deny('C12', `the cancelled-check escalation lacks ${fault}.`, 'Write it in the §4c shape: the marker first, each cancelled job by name, and a request that  re-run it.')
    }
    if (kind === 'strike') {
      if (facts.strikes === undefined) return deny('C1', `the guard could not compute the strike count (${facts.why?.strikes ?? 'no answer'}).`, 'Report the error and stop.')
      if (facts.strikes < 3) return deny('C1', `a strike escalation at ${facts.strikes} change-requests.`, 'Below 3, request changes instead.')
      const fault = strikeFault(body)
      return fault === undefined ? undefined : deny('C6', `the strike escalation lacks ${fault}.`, 'Write it in the §5 strike-gate shape.')
    }
    if (body.includes(DISPUTE)) return deny('C6', `${DISPUTE} is not the comment's first line.`, 'Put the marker on the first line.')
    return deny('C6', 'a PR comment that is no answer and no escalation.', 'A comment on your PR is a holmes-answer, an AC-dispute escalation, a strike escalation, or a cancelled-check escalation.')
  }

  if (tool === 'move') {
    if (ledger.moved !== undefined) return deny('C7', `a second move, after ${ledger.moved}.`, 'One review moves the item once.')
    const column = str(call.column)
    const allowed =
      (column === 'Approved' && ledger.reviewed === 'approve') ||
      (column === 'In Progress' && (ledger.reviewed === 'request_changes' || ledger.answered)) ||
      (column === 'Escalated' && ledger.escalated)
    if (!allowed)
      return deny(
        'C7',
        `a move to ${column} that no verdict of this run supports.`,
        'Approved follows an approve review, In Progress a request-changes review or a holmes-answer, and Escalated an escalation comment.',
      )
  }
  return undefined
}

const DIGEST_HEADING = /^## ([0-9]+)\. (\S+) — ([0-9]+) events?$/gmu

export const bodyOfNote = (text: string): string => text.replace(/^---\n[\s\S]*?\n---\n+/u, '')

function rankFault(body: string): string | undefined {
  const heads = [...body.matchAll(DIGEST_HEADING)].map(m => ({ k: Number(m[1]), name: m[2] ?? '', n: Number(m[3]) }))
  for (let i = 0; i < heads.length; i++) {
    const head = heads[i]
    if (head === undefined) continue
    if (head.k !== i + 1) return `heading ${head.name} is numbered ${head.k}, not ${i + 1}`
    const prev = heads[i - 1]
    if (prev !== undefined && head.n > prev.n) return `${head.name} (${head.n}) ranks below ${prev.name} (${prev.n})`
  }
  return undefined
}

const COUNT_LINE = /^\*\*Clean first-pass approvals:\*\* ?([0-9]+)$/mu
const metaOf = (body: string): string | undefined => /^> \*\*Scope:\*\*[\s\S]*?(?=\n## 1\. |\n---\n\n## Maintaining)/mu.exec(body)?.[0]
const maintainingOf = (body: string): string | undefined => /^## Maintaining this digest[\s\S]*$/mu.exec(body)?.[0]
const compactedOf = (body: string): string | undefined => /^.*\*\*Compacted out\*\*.*$/mu.exec(body)?.[0]
const countsHidden = (body: string): string =>
  body.replace(DIGEST_HEADING, '## $1. $2 — # events').replace(/^.*\*\*Compacted out\*\*.*$/mu, line => line.replace(/[0-9]+/gu, '#'))

export function judgeDigestWrite(content: string, current: string | undefined): string | undefined {
  const rank = rankFault(content)
  if (rank !== undefined) return deny('C15', `the digest would not be ranked: ${rank}.`, 'Order the categories by count, numbered from 1.')
  if (current === undefined) return undefined
  const was = bodyOfNote(current)
  const checks: [string, string | undefined, string | undefined][] = [
    ['the Clean first-pass approvals line', COUNT_LINE.exec(was)?.[0], COUNT_LINE.exec(content)?.[0]],
    ['the scope note and meta-rule block', metaOf(was), metaOf(content)],
    ['the Maintaining this digest section', maintainingOf(was), maintainingOf(content)],
    ['the Compacted out line', compactedOf(was)?.replace(/[0-9]+/gu, '#'), compactedOf(content)?.replace(/[0-9]+/gu, '#')],
  ]
  for (const [what, before, after] of checks) {
    if (before !== undefined && before !== after) return deny('C15', `the write changes ${what}.`, 'Carry it through byte for byte. Path B bumps the approvals count with an edit.')
  }
  if (countsHidden(content).trim() === countsHidden(was).trim())
    return deny('C15', 'a full write whose only change is a count.', 'A count bump is an edit of that one heading line.')
  return undefined
}

export function judgeDigestEdit(oldText: string, newText: string, current: string | undefined): string | undefined {
  if (current === undefined) return deny('C15', 'an edit of a digest the guard could not read.', 'Report the error. A missing digest is created with write.')
  const was = bodyOfNote(current)
  if (!was.includes(oldText) || oldText === '') return undefined
  const after = was.replace(oldText, newText)
  const rank = rankFault(after)
  if (rank !== undefined) return deny('C15', `the edit would break the ranking: ${rank}.`, 'When a bump changes the ranking, rewrite the digest with write, ranked again.')
  if (metaOf(was) !== metaOf(after) || maintainingOf(was) !== maintainingOf(after))
    return deny('C15', 'an edit inside the meta-rule block or the Maintaining section.', 'Those stay byte for byte.')
  return undefined
}

export const staleNote = (ledger: Ledger): string | undefined =>
  ledger.status !== undefined && ledger.status !== 'In Review'
    ? deny('C8', `a review-learnings write for an item now in ${ledger.status}.`, 'A verdict that never landed records no note and bumps no count.')
    : undefined

export function judgeNote(ledger: Ledger, call: Call): string | undefined {
  const path = str(call.path) ?? ''
  if (!path.startsWith(NOTE_DIR)) return undefined
  const stale = staleNote(ledger)
  if (stale !== undefined) return stale
  const m = NOTE_PATH.exec(path)
  if (m === null) return deny('C2', `the note path ${path} is not dev-team/review-learnings/<repo-slug>-pr<n>-<yyyy-mm-dd>-<hhmmss>-<token>.md.`, 'Name the note in that shape.')
  if (!ledger.times.includes(m[1] ?? '')) return deny('C2', `the time ${m[1]} is not one \`date +%H%M%S\` printed in this run.`, 'Run `date +%H%M%S` on a line of its own and use what it prints.')
  if (!ledger.tokens.includes(m[2] ?? '')) return deny('C2', `the token ${m[2]} is not one \`openssl rand -hex 3\` printed in this run.`, 'Run `openssl rand -hex 3` on a line of its own and use what it prints.')
  if (!ledger.notFound.includes(path)) return deny('C2', `no read of ${path} answered "Document not found" in this run.`, 'Read the path first. Only "Document not found" proves it free.')
  const tags = (call.frontmatter as { tags?: unknown } | undefined)?.tags
  const categories = Array.isArray(tags) ? tags.filter((tag): tag is string => CATEGORIES.includes(String(tag))) : []
  if (categories.length === 0) return deny('C2', 'the note carries no category tag.', `Tag it with one of: ${CATEGORIES.join(', ')}.`)
  return undefined
}

export const isDigest = (call: Call): boolean => str(call.path) === DIGEST_PATH

export function checksOf(run: { exitCode: number; stdout: string; stderr: string }): { checks?: Checks; names: string[] } {
  if (/no (?:required )?checks reported/iu.test(`${run.stdout}\n${run.stderr}`)) return { checks: 'none', names: [] }
  let rows: unknown
  try {
    rows = JSON.parse(run.stdout)
  } catch {
    return { names: [] }
  }
  if (!Array.isArray(rows)) return { names: [] }
  const all = rows.map(row => ({ name: String((row as { name?: unknown }).name ?? '?'), bucket: String((row as { bucket?: unknown }).bucket ?? '') }))
  if (all.length === 0) return { checks: 'none', names: [] }
  for (const [bucket, checks] of [['fail', 'fail'], ['cancel', 'cancelled'], ['pending', 'pending']] as const) {
    const names = all.filter(row => row.bucket === bucket).map(row => row.name)
    if (names.length > 0) return { checks, names }
  }
  return all.every(row => row.bucket === 'pass' || row.bucket === 'skipping') ? { checks: 'pass', names: [] } : { names: [] }
}

export const CHECKS_ARGV = (pr: number, repo: string): string[] => ['gh', 'pr', 'checks', String(pr), '-R', repo, '--required', '--json', 'name,bucket']

export function checksDeny(facts: Facts): string | undefined {
  const names = facts.why?.checks ?? ''
  switch (facts.checks) {
    case 'pass':
    case 'none':
      return undefined
    case 'fail':
      return deny('C12', `a required check on PR #${facts.pr} failed (${names}).`, 'A failed required check is a blocker: request changes and name the failing job.')
    case 'cancelled':
      return deny('C12', `a required check on PR #${facts.pr} was cancelled (${names}).`, `Neither approve nor request changes, and count no strike. Escalate: post an add_comment whose first line is ${CANCELLED}, that names each cancelled job and asks @mikebronner to re-run it, then move the item to Escalated.`)
    case 'pending':
      return deny('C12', `a required check on PR #${facts.pr} is still pending (${names}).`, 'Do not approve yet: leave the item In Review for the next tick, and write nothing.')
    default:
      return deny('C12', `the guard could not read the required checks (${names || 'no answer'}).`, 'Leave the item In Review and report the error.')
  }
}

export const whyOf = (run: { exitCode: number; stdout: string; stderr: string } | undefined): string =>
  run === undefined ? 'the script did not run' : `exit ${run.exitCode}${run.stderr.trim() === '' ? '' : `: ${run.stderr.trim().split('\n')[0]}`}`

export function factOf(run: { exitCode: number; stdout: string } | undefined): string | null | undefined {
  if (run === undefined) return undefined
  if (run.exitCode === 1) return null
  return run.exitCode === 0 ? run.stdout.trim() : undefined
}

export const vaultOf = (env: string | undefined, coreConfig: string | undefined, home: string): string => {
  if (env !== undefined && env !== '') return env
  const path = jsonOf(coreConfig)?.memory_path
  return typeof path === 'string' && path !== '' ? path : `${home}/Documents/Claude/Memory`
}

export const CORE_CONFIG = '.claude/plugins/data/workbench-core-claude-workbench/config.json'

export const LOCAL_DIGEST_DENY = deny('C15', 'a Local-mode write to dev-team/top-lessons.md.', 'A local review writes its own note and never touches the digest.')

export const verdictFailed = (error: unknown): string =>
  `🛑 Blocked: a Holmes call the verdict guard could not judge.\n\nVerdict guard (workbench-dev-team). The guard failed while reading this call (${error instanceof Error ? error.message : String(error)}), so it is refused rather than let an unchecked verdict through. Report this to the human as a guard defect, with that error. Do not try another route.`
