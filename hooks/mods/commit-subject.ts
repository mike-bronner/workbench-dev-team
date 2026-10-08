// The commit subject check, as a pure function over workbench-core's reading of
// a Bash line. hooks/register.ts runs it after the commit guard passes a line,
// so it judges the commits the guard lets through: the main loop's and the
// pipeline's. A sub-agent's commit is already refused.
//
// It holds a `git commit -m` subject to the git-commit skill's format:
//
//   <type>: <gitmoji> <description>.
//
// A type from the skill's references/conventional-commits.md, an optional !
// for a breaking change, no scope, one space, one gitmoji from
// references/gitmoji.md, one space, and a description that ends with a period.
//
// What it judges: the first line of the first -m (or --message) value of each
// git commit in the line, read from the statements, never from the raw text. A
// commit with no -m, or with -F, --file, -C, -c, --reuse-message,
// --reedit-message, --fixup or --squash, is not judged: its message is not on
// the line. Neither is a message the line builds at run time (a `$` in it),
// except one form: `-m "$(cat <<'EOF' … EOF)"`, whose subject is the first line
// of the heredoc's body.

import type { ShellParse, Statement } from './commit-guard'

export const TYPES: readonly string[] = ['feat', 'fix', 'docs', 'style', 'refactor', 'perf', 'test', 'build', 'ci', 'chore']

// The gitmoji, as references/gitmoji.md lists them.
// tests/test-commit-subject-lists.sh holds this list to that file, and TYPES to
// references/conventional-commits.md, both ways. A subject may write each
// gitmoji with or without its trailing U+FE0F, as keyboards differ.
export const GITMOJI: readonly string[] = [
  '🎨', '⚡️', '🔥', '🐛', '🚑️', '✨', '📝', '🚀', '💄', '🎉', '✅', '🔒️', '🔐', '🔖', '🚨', '🚧', '💚', '⬇️', '⬆️', '📌',
  '👷', '📈', '♻️', '➕', '➖', '🔧', '🔨', '🌐', '✏️', '💩', '⏪️', '🔀', '📦️', '👽️', '🚚', '📄', '💥', '🍱', '♿️', '💡',
  '🍻', '💬', '🗃️', '🔊', '🔇', '👥', '🚸', '🏗️', '📱', '🤡', '🥚', '🙈', '📸', '⚗️', '🔍️', '🏷️', '🌱', '🚩', '🥅', '💫',
  '🗑️', '🛂', '🩹', '🧐', '⚰️', '🧪', '👔', '🩺', '🧱', '🧑‍💻', '💸', '🧵', '🦺', '✈️', '🦖',
]

const bare = (emoji: string): string => emoji.replace(/\uFE0F/g, '')
const KNOWN: ReadonlySet<string> = new Set(GITMOJI.map(bare))

// Options of git commit whose message is not on the line.
const NOT_ON_LINE = /^(-F|--file|-C|-c|--reuse-message|--reedit-message|--fixup|--squash)(=|$)/
// Short options of git commit that take a value, attached or as the next word.
const SHORT_VALUED = 'mFCct'
// Short options of git commit whose value is optional and only ever attached
// (`-unormal`, `-S<keyid>`): the rest of the word is the value, never another
// option and never the message.
const SHORT_ATTACHED = 'uS'

type Message = { text: string } | 'not-judged'

// The message of one git commit statement, or not-judged.
function messageOf(statement: Statement, parse: ShellParse): Message | undefined {
  const args = statement.args
  let message: string | undefined
  for (let i = statement.subcommandAt + 1; i < args.length; i++) {
    const arg = args[i] ?? ''
    if (arg === '--') break
    if (NOT_ON_LINE.test(arg)) return 'not-judged'
    let value: string | undefined
    if (arg === '--message' || arg === '--message=') value = args[++i]
    else if (arg.startsWith('--message=')) value = arg.slice('--message='.length)
    else if (/^-[^-]/.test(arg)) {
      for (let c = 1; c < arg.length; c++) {
        const flag = arg[c] ?? ''
        if (SHORT_ATTACHED.includes(flag)) break
        if (!SHORT_VALUED.includes(flag)) continue
        if (flag === 'F' || flag === 'C' || flag === 'c') return 'not-judged'
        const attached = arg.slice(c + 1)
        const taken = attached === '' ? args[++i] : attached
        if (flag === 'm') value = taken
        break
      }
    }
    if (value !== undefined && message === undefined) message = value
  }
  if (message === undefined) return undefined
  if (message === '$_') {
    const bodies = parse.statements.filter(s => s.source === 'substitution')
    const only = bodies.length === 1 ? bodies[0] : undefined
    if (only?.name === 'cat' && only.args.length === 0 && only.heredocs.length === 1) return { text: only.heredocs[0]?.body ?? '' }
    return 'not-judged'
  }
  return message.includes('$') ? 'not-judged' : { text: message }
}

// What is wrong with a subject, or undefined when it keeps the format.
export function subjectFault(subject: string): string | undefined {
  const head = /^([A-Za-z]+)(\([^)]*\))?(!)?:/.exec(subject)
  if (head === null) return 'it does not start with a type and a colon'
  if (head[2] !== undefined) return `it has a scope, ${head[2]}`
  if (!TYPES.includes(head[1] ?? '')) return `"${head[1]}" is not a type`
  const rest = subject.slice(head[0].length)
  if (!rest.startsWith(' ') || rest.startsWith('  ')) return 'the colon is not followed by exactly one space'
  const [emoji = '', ...words] = rest.slice(1).split(' ')
  if (!KNOWN.has(bare(emoji))) return `"${emoji}" is not a gitmoji from the skill's list`
  const description = words.join(' ')
  if (!/[^.\s]/.test(description) || description.startsWith(' ')) return 'the gitmoji is not followed by one space and a description'
  if (!description.endsWith('.')) return 'the description does not end with a period'
  return undefined
}

// The refusal for a line whose commit subject breaks the format, or undefined.
export function subjectVerdict(parse: ShellParse): { deny: string } | undefined {
  for (const statement of parse.statements) {
    if (statement.name !== 'git' || statement.subcommandAt < 0 || statement.args[statement.subcommandAt] !== 'commit') continue
    const message = messageOf(statement, parse)
    if (message === undefined || message === 'not-judged') continue
    const subject = message.text.split('\n').find(line => line.trim() !== '')?.replace(/\s+$/, '') ?? ''
    const fault = subjectFault(subject)
    if (fault !== undefined) return { deny: subjectDeny(subject, fault) }
  }
  return undefined
}

export function subjectDeny(subject: string, fault: string): string {
  return [
    `🛑 Blocked: a commit subject that breaks the git-commit format, because ${fault}.`,
    '',
    `Commit guard (workbench-dev-team). The subject was: ${JSON.stringify(subject)}. ` +
      'The expected shape is "<type>: <gitmoji> <Description>.", for example "feat: ✨ Add email validation endpoint.". ' +
      `The type is one of ${TYPES.join(', ')}, with ! after it for a breaking change, and never a scope. ` +
      'The gitmoji comes from the git-commit skill\'s references/gitmoji.md, and the description ends with a period. ' +
      'Fix the message with the /workbench-dev-team:git-commit skill, and commit again.',
  ].join('\n')
}
