// The commit guard, as pure functions over workbench-core's reading of a Bash
// line ($.workbench.parseShell). hooks/register.ts calls them on every Bash
// call, in every lane. It refuses what the permissions.ask rules cannot cover,
// and is silent on everything else.
//
// The approval is a "Commit it" pick in `AskUserQuestion`, once the human says
// their review is done. Claude Code's own prompt is the mechanical backstop.
// /workbench-dev-team:setup installs the ask rules git commit *, git push *,
// git * commit *, git * push *, git * commit, git * push, gh * pr merge *,
// gh * pr merge, and gh api *pulls/*/merge*, beside workbench-core's own
// gh pr merge:*. This guard does not ask and does not approve. It catches honest
// mistakes. It is not a security boundary: a script file, an interpreter, or a
// shell alias gets past it, and past the ask rules too. Review is the real gate.
//
// ACCEPTED LIMITS (Mike, 2026-10-07: the guards stay mistake-catchers, and
// these gaps are accepted rather than chased). The guard reads the words of a
// line, so a change it cannot see in them is out of scope: a value-only change
// such as PATH=, HOME= or XDG_CONFIG_HOME= before git; git -C into a
// repository whose own config is hostile; an arithmetic assignment such as
// $((X=1)); a bash alias defined on the same line; a git alias in a config
// file; a script file or a file passed to make; a command that code builds at
// run time, such as python joining "git" and "push"; and a GraphQL mutation
// held in a variable or a file (`-f query="$Q"`, `--input file`).
//
// It refuses, in this order:
//   1. A push that forces or deletes, in every lane: --force, --force-with-lease,
//      --mirror, --delete, --prune (and their prefixes), -f or -d in a short
//      cluster, a refspec that starts with + or :, or a -c that makes a remote
//      mirror or names its push refspec.
//   2. A pull request merge from a sub-agent, from a top-level `--agent` run
//      such as the pipeline, or from any turn nobody attends: gh pr merge in any
//      spelling, or gh api on pulls/<n>/merge. Holmes and Watson never merge.
//   3. A commit or push from a sub-agent. A sub-agent hands its work back
//      uncommitted. The scheduled pipeline commits from its top-level
//      `claude -p --agent` loop, which is not a sub-agent.
//   4. A commit, push, or merge the ask rules cannot see, in every lane: behind
//      a wrapper the harness does not strip before it matches (env, sudo,
//      xargs, caffeinate, ...), a NAME=value assignment, a `bash -c` or `eval`
//      script, a substitution, or a heredoc fed to a shell;
//      a git or gh named by a path or in another case; an escaped word; a
//      subcommand a `-c alias.<name>` supplies; or a subcommand, or a global
//      option word before it, built at run time from a substitution or a
//      variable (`git "$(echo commit)"`, `git $x`, `gh pr $(echo merge)`). The
//      guard cannot tell which subcommand that is, so it counts as any of
//      them. An option's value (`-C "$D"`, `--git-dir=$D`, `-R"$R"`) decides
//      no subcommand. A gh api endpoint built at run time counts as a merge
//      when the method is PUT or built, or a built word stands where a flag
//      could (the REST merge takes a PUT), and a gh api line whose fields
//      name the GraphQL mergePullRequest or enablePullRequestAutoMerge
//      mutation counts as a merge whatever its endpoint and method.
//   5. In a sub-agent, or in a run nobody attends (an attended top-level
//      `--agent` run is neither): a line whose command name the
//      reader cannot place (a wrapper option it cannot read) or that is built
//      at run time from a substitution or a variable (`"$CMD" x`,
//      `g$(echo it) push`), whatever the line names. Mike accepted the cost on
//      2026-10-07: a rare `$CMD …` line refused there. A plain `"$NAME/…"`
//      before a literal path names its program, so it is not refused. Since
//      workbench-core 4e83554, core's guards refuse each of these lines first,
//      in every lane. This rule stays as dev-team's own check in the lanes no
//      human watches. It also refuses a substitution in front of a literal
//      path (`$(…)x/y`), which core's reader at 4e83554 misses. That check
//      stays until core's reader marks an unquoted substitution.
//
// THE FOURTH RULE IS KEPT. workbench-core's commit approval gate reads past
// every hidden form above, but only for a commit or push in the main loop of an
// attended session. It stands aside for a sub-agent, a top-level `--agent` run,
// a session nobody sits at, and a turn a schedule opened, and it never looks at
// a merge. In those places a hidden form draws no prompt from the ask rules and
// no question from core, so this rule is the only thing that stops it.
//
// LANES. The lane is $.workbench.callerLane's: `main`, `sub-agent`, or
// `top-level-agent` (a `claude -p --agent` run, the pipeline among them). A
// lane the noun cannot give is read as a sub-agent, the side that refuses. The
// merge rule also reads $.workbench.isUnattended, and an unknown answer there is
// read as unattended.
//
// READING. Each rule reads the statements parseShell returns, never the text of
// the line, so `git commit -m "load env"`, `grep "git push" notes.md`, and a
// heredoc data file that quotes `git push origin` are not refused. Text is
// read in three places only, each where a command may be hidden from the
// statements:
//   - A line parseShell could not read whole (any unknown), or with a wrapper
//     it could not place, that names commit, push, or merge anywhere: rule 4
//     in every lane, and rule 1 when the text reads as a forced push.
//   - Code a program runs from its own words or heredoc: the arguments of
//     anything that is not a plain reader (python -c, awk system(), sed's e
//     command, a runner the shell reader does not list, `rg --pre`), a git -c
//     value, `git grep -O`, and a `-c alias.<name>=!…` shell alias. A mention of
//     git commit, push, or gh pr merge there counts as that command behind a
//     wrapper: rules 1 to 4.
//   - Text a plain reader handles (echo, cat, a heredoc data file) on a line
//     that also runs a program that could read it back, such as
//     `echo git push > x.sh; bash x.sh`: rules 1 to 3, not rule 4.
// In the second and third, a whole line of a comment (# or //) is skipped, so
// a script whose comment says "git commit or push" is not refused. The first
// reads the raw line, comments included.

import type { EngineInterface } from 'claude-code'

type Workbench = EngineInterface['workbench']
export type ShellParse = Awaited<ReturnType<Workbench['parseShell']>>
export type Statement = ShellParse['statements'][number]
export type CallerLane = Awaited<ReturnType<Workbench['callerLane']>>

// Who runs the line. lane is undefined when callerLane could not answer.
export type Caller = { lane: CallerLane | undefined; isUnattended: boolean }

type Op = 'commit' | 'push' | 'merge'

// The guard's verdict: the refusal the model reads, or undefined to pass.
export type Refusal = { deny: string }

// What a line runs, as the rules weigh it.
type Found = {
  // Commits, pushes and merges the rules 1 to 3 weigh.
  ops: Set<Op>
  // A push that forces or deletes.
  isForce: boolean
  // An op the ask rules cannot see (rule 4).
  isHidden: boolean
}

// The text match of the bash guard before this one (tests/oracle/), kept for
// the text the statements cannot show. A character that cannot be part of a
// word, then git and commit or push, or gh and pr merge or the API merge
// endpoint, within one command.
const W = '[^A-Za-z0-9_.-]'
const SEG = '[^;&|\\n]'
const GIT_OP = `git${W}(?:${SEG}*[^A-Za-z0-9_-])?(commit|push)(?:$|[^A-Za-z0-9_-])`
const MERGE_OP = `gh${W}(?:${SEG}*[^A-Za-z0-9_-])?(?:pr\\s+merge|api${W}${SEG}*pulls/[^\\s/]+/merge)(?:$|[^A-Za-z0-9_/-])`
const MENTION = new RegExp(`(?:^|${W})(?:${GIT_OP}|${MERGE_OP})`, 'im')
const FORCE_TEXT = new RegExp(
  `(?:^|${W})git${W}(?:${SEG}*[^A-Za-z0-9_-])?push${SEG}*\\s(?:--(?:forc|m|de|pru)|-[A-Za-z0-9]*[fd]|[+:]\\S)`,
  'im',
)
// Any of the three words, for a line the reader could not read whole.
const LOOSE = /commit|push|merge/i

// Programs that never run code from their own words: what they are handed is
// data. Text in their words is read only beside a program that could run it.
const READERS: ReadonlySet<string> = new Set([
  'echo', 'printf', 'cat', 'head', 'tail', 'wc', 'ls', 'grep', 'egrep', 'fgrep', 'rg', 'jq', 'cd', 'pwd', 'true',
  'false', 'test', '[', '[[', '((', ':', 'printenv', 'basename', 'dirname', 'realpath', 'readlink', 'stat', 'file',
  'which', 'type', 'command', 'diff', 'cmp', 'comm', 'cut', 'tr', 'sort', 'uniq', 'column', 'nl', 'tee', 'mkdir',
  'touch', 'rm', 'rmdir', 'mv', 'cp', 'ln', 'chmod', 'date', 'sleep', 'export', 'local', 'declare', 'readonly',
  'unset', 'set',
])

// The wrappers Claude Code strips before it matches an ask rule, so a commit
// behind one still prompts.
const ASK_STRIPPED: ReadonlySet<string> = new Set(['timeout', 'time', 'nice', 'nohup', 'stdbuf', 'command', 'builtin', 'noglob'])

// A command name the shell builds at run time: a brace (`{git,}`), a glob, or
// zsh's `=name` path expansion. Which program runs is not written.
const BUILT_NAME = /[{}*?[\]]|^=/

// Whole-line comments, dropped before text is matched.
const withoutComments = (text: string): string =>
  text
    .split('\n')
    .filter(line => !/^\s*(?:#|\/\/)/.test(line))
    .join('\n')

const opsIn = (text: string): Op[] => {
  const ops: Op[] = []
  const match = new RegExp(MENTION.source, 'gim')
  for (const m of text.matchAll(match)) {
    // GIT_OP captures commit or push. MERGE_OP captures nothing.
    ops.push(m[1] === undefined ? 'merge' : (m[1].toLowerCase() as Op))
  }
  return ops
}

// A git option word that sets configuration: `-c key=value` or `-ckey=value`.
function configOf(args: readonly string[], end: number): { key: string; value: string }[] {
  const config: { key: string; value: string }[] = []
  for (let i = 0; i < end; i++) {
    const arg = args[i] ?? ''
    const pair = arg === '-c' ? args[++i] : arg.startsWith('-c') ? arg.slice(2) : undefined
    if (pair === undefined) continue
    const at = pair.indexOf('=')
    config.push({ key: (at < 0 ? pair : pair.slice(0, at)).toLowerCase(), value: at < 0 ? '' : pair.slice(at + 1) })
  }
  return config
}

// A word the shell builds when the line runs: the reader's `$_` stands where a
// substitution stood, and a `$` left in a word is an expansion.
const isBuilt = (word: string): boolean => word.includes('$')

// git's and gh's global options whose value is the next word. A value built at
// run time cannot change which subcommand runs; the option word itself can.
const GLOBAL_VALUES: ReadonlySet<string> = new Set([
  '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--super-prefix', '--config-env', '--exec-path', '-R', '--repo',
])

// A global option word that carries its own value, `--git-dir=$D`, `-C$D` or
// `-R"$R"`: the value decides no subcommand.
const carriesValue = (arg: string): boolean =>
  [...GLOBAL_VALUES].some(o => (o.startsWith('--') ? arg.startsWith(`${o}=`) : arg.startsWith(o) && arg.length > o.length))

// Whether a word that decides which subcommand runs is built at run time: an
// option word before the subcommand (never a value of one, separate, after
// `=` or attached), or the subcommand itself.
function decidesBuilt(s: Statement): boolean {
  const at = s.subcommandAt
  const end = at < 0 ? s.args.length : Math.min(s.args.length, at + 1)
  for (let i = 0; i < end; i++) {
    const arg = s.args[i] ?? ''
    if (i < at && GLOBAL_VALUES.has(arg)) {
      i++
      continue
    }
    if (i < at && carriesValue(arg)) continue
    if (isBuilt(arg)) return true
  }
  return false
}

// gh api's options that take the next word as their value, so the endpoint is
// the first word that is neither an option nor such a value.
const GH_API_VALUES: ReadonlySet<string> = new Set([
  '-f', '--raw-field', '-F', '--field', '-H', '--header', '-X', '--method', '--input', '-q', '--jq', '-t', '--template',
  '--cache', '-p', '--preview', '--hostname',
])

// A gh api call's words as gh reads them (pflag, which takes no cut of a long
// flag): every method value, and the words in endpoint position. A method is
// `-X PUT`, `-XPUT`, `-X=PUT`, `--method PUT` or `--method=PUT`, and a short
// cluster that ends in X (`-iX PUT`) takes the next word, as pflag gives it.
// Every value is kept, since a later one wins and the guard reads them all.
// gh api takes one endpoint, so a second word in that position is a flag the
// shell built (`gh api $M repos/$X` with M=-XPUT).
function apiWordsOf(rest: readonly string[]): { methods: string[]; positionals: string[] } {
  const methods: string[] = []
  const positionals: string[] = []
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i] ?? ''
    if (arg === '--') {
      positionals.push(...rest.slice(i + 1))
      break
    }
    const cluster = /^-[A-Za-z]*X(.*)$/.exec(arg)
    if (arg === '--method') methods.push(rest[++i] ?? '')
    else if (arg.startsWith('--method=')) methods.push(arg.slice('--method='.length))
    else if (cluster && !arg.startsWith('--')) methods.push(cluster[1] === '' ? (rest[++i] ?? '') : (cluster[1] ?? '').replace(/^=/, ''))
    else if (GH_API_VALUES.has(arg)) i++
    else if (!arg.startsWith('-')) positionals.push(arg)
  }
  return { methods, positionals }
}

// Whether a gh api call could merge a pull request through an endpoint built
// at run time. The REST merge endpoint takes a PUT. gh sends GET, or POST with
// fields, unless the method says otherwise. So with a PUT, a method built at
// run time, or a built word where a flag could stand, any built endpoint
// counts as a merge, since the guard cannot know where it points (fail
// closed). A GraphQL merge goes over POST and is read from the fields
// (MERGE_MUTATION), and a literal pulls/<n>/merge endpoint is matched as
// written, whatever the method.
function builtMerge(rest: readonly string[]): boolean {
  const { methods, positionals } = apiWordsOf(rest)
  if (!positionals.some(isBuilt)) return false
  const isBuiltFlag = positionals.length > 1
  return isBuiltFlag || methods.some(m => isBuilt(m) || m.toUpperCase() === 'PUT')
}

// The GraphQL mutations that merge a pull request, or set it to merge.
const MERGE_MUTATION = /mergePullRequest|enablePullRequestAutoMerge/i

// Whether a push's own words force or delete.
const isForceArg = (arg: string): boolean => /^--(?:forc|m|de|pru)/i.test(arg) || /^-[A-Za-z0-9]*[fd]/.test(arg) || /^[+:]\S/.test(arg)

// What one git or gh statement runs, read from its words.
type Read = { ops: Op[]; isForce: boolean; isHidden: boolean; code: string[]; isUnread: boolean }

function readGit(s: Statement): Read {
  const read: Read = { ops: [], isForce: false, isHidden: false, code: [], isUnread: false }
  const args = s.args
  if (s.name === 'git-commit' || s.name === 'git-push') {
    read.ops.push(s.name === 'git-commit' ? 'commit' : 'push')
    read.isForce = s.name === 'git-push' && args.some(isForceArg)
    return read
  }
  const at = s.subcommandAt
  const config = configOf(args, at < 0 ? args.length : at)
  read.code.push(...config.map(c => c.value))
  // A subcommand built at run time, or configuration whose key is, could be
  // commit or push: read as unread, every op and hidden.
  if (decidesBuilt(s) || config.some(c => isBuilt(c.key))) read.isUnread = true
  if (config.some(c => /^remote\..*\.(?:mirror|push)$/.test(c.key))) read.isForce = true
  if (args.some(arg => arg.startsWith('--config-env'))) read.isUnread = true
  if (at < 0) {
    // Words xargs or parallel add could be the subcommand.
    if (s.wrappers.includes('xargs')) read.isUnread = true
    return read
  }
  let sub = (args[at] ?? '').toLowerCase()
  let rest = args.slice(at + 1)
  const alias = config.find(c => c.key === `alias.${sub}`)
  if (alias !== undefined) {
    read.isHidden = true
    if (isBuilt(alias.value)) read.isUnread = true
    if (alias.value.trimStart().startsWith('!')) {
      // A shell alias: its text is a script the reader was never handed.
      read.code.push(alias.value)
      return read
    }
    const words = alias.value.trim().split(/\s+/)
    sub = (words[0] ?? '').toLowerCase()
    rest = [...words.slice(1), ...rest]
  }
  // git grep -O runs its value as a program on the matched files.
  if (sub === 'grep' && rest.some(arg => arg.startsWith('-O') || arg.startsWith('--open-files'))) {
    read.code.push(...rest.map(arg => arg.replace(/^(?:-O|--open-files[a-z-]*=?)/, ' ')))
  }
  if (sub === 'commit' || sub === 'push') read.ops.push(sub)
  if (sub === 'push' && rest.some(isForceArg)) read.isForce = true
  return read
}

function readGh(s: Statement): Read {
  const read: Read = { ops: [], isForce: false, isHidden: false, code: [], isUnread: false }
  const at = s.subcommandAt
  if (decidesBuilt(s)) read.isUnread = true
  if (at < 0) return read
  const sub = (s.args[at] ?? '').toLowerCase()
  const rest = s.args.slice(at + 1)
  // `gh pr $(echo merge)`: the word after pr is the pr subcommand.
  if (sub === 'pr' && isBuilt(rest[0] ?? '')) read.isUnread = true
  if (sub === 'pr' && rest.some(arg => arg.toLowerCase() === 'merge')) read.ops.push('merge')
  const isLiteralMerge = sub === 'api' && rest.some(arg => /pulls\/[^\s/]+\/merge(?![A-Za-z0-9_/-])/i.test(arg))
  // A GraphQL merge, named in a field or a heredoc fed to --input, over any
  // endpoint and method. The ask rules match no such line.
  if (sub === 'api' && [...rest, ...s.heredocs.map(h => h.body)].some(word => MERGE_MUTATION.test(word))) {
    read.ops.push('merge')
    read.isHidden = true
  }
  if (isLiteralMerge) read.ops.push('merge')
  // A built endpoint the ask rule's pulls/*/merge pattern cannot see.
  if (sub === 'api' && !isLiteralMerge && builtMerge(rest)) {
    read.ops.push('merge')
    read.isHidden = true
  }
  return read
}

// Whether the ask rules would see this git or gh statement as written: a plain
// name in command position, with nothing in front of it but a wrapper the
// harness strips.
function isPlain(s: Statement): boolean {
  const named = s.words[s.nameAt] ?? ''
  const escapedAt = new Set(s.escaped)
  const lastRead = s.nameAt + 1 + Math.max(s.subcommandAt, 0)
  for (let i = s.nameAt; i <= lastRead; i++) if (escapedAt.has(i)) return false
  return s.assignments.length === 0 && s.wrappers.every(w => ASK_STRIPPED.has(w)) && s.source === 'line' && s.depth === 0 && named === s.name
}

// Everything the guard can say about a line: the ops it runs and how they are
// written, from the statements and from the text they cannot show.
export function findOps(parse: ShellParse, line: string): Found {
  const found: Found = { ops: new Set(), isForce: false, isHidden: false }
  const add = (ops: Iterable<Op>, isHidden: boolean) => {
    for (const op of ops) {
      found.ops.add(op)
      if (isHidden) found.isHidden = true
    }
  }
  const all: Op[] = ['commit', 'push', 'merge']

  // A line the reader could not read whole may hide any of them.
  const isUnread = parse.unknowns.length > 0 || parse.statements.some(s => !s.isPlaced)
  if (isUnread && LOOSE.test(line)) {
    add(all.filter(op => new RegExp(op, 'i').test(line)), true)
    if (FORCE_TEXT.test(line.replace(/\\\n/g, '').replace(/["'\\]/g, ''))) found.isForce = true
  }

  // Text a reader handles, and whether anything on the line could run it.
  const readerText: string[] = []
  let hasRunner = false
  for (const s of parse.statements) {
    const heredocs = s.heredocs.filter(h => !h.feedsShell).map(h => h.body)
    const code = (texts: readonly string[]) => {
      const text = withoutComments(texts.join('\n'))
      add(opsIn(text), true)
      if (FORCE_TEXT.test(text)) found.isForce = true
    }
    if (s.nameAt < 0) {
      readerText.push(...s.assignments, ...heredocs)
      continue
    }
    if (s.name === 'git' || s.name === 'git-commit' || s.name === 'git-push' || s.name === 'gh') {
      const read = s.name === 'gh' ? readGh(s) : readGit(s)
      add(read.ops, read.isHidden || !isPlain(s))
      if (read.isForce) found.isForce = true
      if (read.isUnread) add(all, true)
      if (read.code.length > 0) {
        hasRunner = true
        code(read.code)
      }
      readerText.push(...s.assignments, ...heredocs)
      continue
    }
    if (BUILT_NAME.test(s.name) || s.escaped.includes(s.nameAt)) {
      // The program is not written, so it may be git or gh itself.
      hasRunner = true
      code([s.words.slice(s.nameAt).join(' '), ...heredocs])
      if (LOOSE.test(s.words.join(' '))) add(all.filter(op => new RegExp(op, 'i').test(s.words.join(' '))), true)
      continue
    }
    const isReader = READERS.has(s.name) && !(s.name === 'rg' && s.args.some(arg => arg.startsWith('--pre')))
    if (isReader) {
      readerText.push(...s.args, ...s.assignments, ...heredocs)
    } else {
      hasRunner = true
      code([...s.args, ...heredocs])
      readerText.push(...s.assignments)
    }
  }
  if (hasRunner) {
    const text = withoutComments(readerText.join('\n'))
    add(opsIn(text), false)
    if (FORCE_TEXT.test(text)) found.isForce = true
  }
  return found
}

const READS =
  'A command that only reads or quotes these words, such as git log --grep, a grep for them, or a heredoc of notes, is not refused here. If one was, report it as a guard defect, and use the Read tool for the file meanwhile.'

const refusal = (line: string, why: string): Refusal => ({ deny: `🛑 Blocked: ${line}\n\nCommit guard (workbench-dev-team). ${why}` })

export const FORCE_REFUSAL = refusal(
  'a push that forces or deletes.',
  'Pushes that force or delete remote refs are refused outright, and no approval changes that. Push without the force or delete, or ask the human to do it.',
)

export const MERGE_REFUSAL = refusal(
  'a sub-agent or the pipeline does not merge a pull request.',
  `Merging is the human's own step, after review. Report that the pull request is ready to merge, and stop. Do not look for another route to a merge. ${READS}`,
)

export const SUBAGENT_REFUSAL = refusal(
  'a sub-agent does not commit or push.',
  `Leave the working tree uncommitted. Report the diff and a proposed commit message to the session that dispatched you. Do not ask to commit. Do not look for another route to a commit or push. ${READS}`,
)

export const PLAIN_REFUSAL = refusal(
  'run the commit, push, or merge as a plain line, so you are asked.',
  'The permission rules that prompt the human match a plain git or gh line, and they miss one behind a wrapper such as env or sudo, a leading NAME=value, bash -c, eval, a substitution, a path, an escape, or an alias, and one inside a program or a line the guard cannot read. Run it as git commit …, git push …, or gh pr merge …, with git -C <dir> for a directory and git -c <key>=<value> for configuration. Drop a variable prefix such as HUSKY=0.',
)

export const BUILT_REFUSAL = refusal(
  'a command name the guard cannot read, from a sub-agent or an unattended run.',
  'The command this line runs is named by a variable or a substitution, or sits behind a wrapper option the guard cannot place, so the guard cannot tell whether it commits, pushes, or merges. Name the program in plain words, such as python3 script.py rather than "$PY" script.py. Do not look for another spelling.',
)

export const FAILED_REFUSAL = refusal(
  'a call the commit guard could not judge.',
  'The guard failed while reading this command, so it refuses it rather than let a commit, push, or merge through unread. Report this to the human as a guard defect. Do not try another spelling.',
)

// Whether any statement's command name is unplaced or built at run time, as
// parseShell reads it. Since workbench-core 4e83554 its `expansion` unknown
// covers a `$` or a backtick anywhere in a command word, except a plain
// `"$NAME/…"` or `"${NAME}/…"` in double quotes before a literal path, whose
// last path part names the program.
//
// The reader writes a substitution into the word as `$_` with no mark for an
// unquoted one, so `$(echo a b)x/y` reads as the plain prefix `$_x/` and gets
// no unknown, though the shell splits the output and runs its first word. A
// name word holding `$_` is refused here too. A quoted "$(…)x/…" looks the
// same once the words are stripped, so it is refused as well. This check
// stays until core's reader marks an unquoted substitution.
const hasBuiltName = (parse: ShellParse): boolean =>
  parse.unknowns.includes('expansion') ||
  parse.unknowns.includes('wrapper') ||
  parse.statements.some(s => !s.isPlaced || (s.nameAt >= 0 && (s.words[s.nameAt] ?? '').includes('$_')))

// The verdict on one Bash line, in the order of the header's rules.
export function commitVerdict(parse: ShellParse, line: string, caller: Caller): Refusal | undefined {
  const found = findOps(parse, line)
  // A sub-agent (or a lane callerLane cannot give), or a run nobody attends.
  const isUnwatched = caller.lane === 'sub-agent' || caller.lane === undefined || caller.isUnattended
  if (found.isForce) return FORCE_REFUSAL
  if (found.ops.has('merge') && (caller.lane !== 'main' || caller.isUnattended)) return MERGE_REFUSAL
  const writes = found.ops.has('commit') || found.ops.has('push')
  if (writes && caller.lane !== 'main' && caller.lane !== 'top-level-agent') return SUBAGENT_REFUSAL
  if (found.ops.size > 0 && found.isHidden) return PLAIN_REFUSAL
  if (isUnwatched && hasBuiltName(parse)) return BUILT_REFUSAL
  return undefined
}
