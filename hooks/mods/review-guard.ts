// The review guard, as pure functions over workbench-core's reading of a Bash
// line ($.workbench.parseShell). hooks/register.ts calls them for Bash, Edit,
// Write and NotebookEdit, resolves the paths they return on the disk, and
// refuses the call of a Holmes reviewer that would write outside the scratch
// roots.
//
// Holmes reviews code he must not change. In Local mode the tree he reads is the
// human's live working directory, and the uncommitted change in it is the ONLY
// copy of the work, so a reviewer that writes to it destroys the thing it was
// sent to read. Prose in an agent prompt is advisory: on the mode's first real
// exercise a lens sub-agent ran `chmod` against that directory with the rule in
// its own prompt. This guard is not advisory.
//
// WHO IS HELD. A call from Holmes (`holmes`, or his mode agents `holmes-local`
// and `holmes-index`) or his helper (`holmes-lens`), with or without the
// `workbench-dev-team:` prefix, and from any sub-agent one of them spawned, at
// any depth. A top-level `--agent` run of one of them (the scheduled pipeline)
// is held on its main loop and in every sub-agent. The main loop of any other
// session, and every other agent, keeps its tools.
//
// THE SCRATCH ROOTS are the places a reviewer may write: workbench-core's
// $.workbench.scratchRoots (the session scratchpad, ~/Developer/scratchpad and
// ~/.claude/plans) and $TMPDIR, where a bare `mktemp -d` lands. A write lands
// in a root only when it is strictly beneath one, resolved both through every
// symlink and with its final name left unresolved, so no root can be removed
// and no link can lead out of one. With no root found, every write is refused.
//
// WHAT COUNTS AS A WRITE. Reads and test runs pass, and so does a write inside
// a scratch root. The line is drawn at commands whose purpose is to change a
// file's content, location, existence, or metadata:
//   1. git, inverted: GIT_READ_ONLY lists the verbs that only read, and every
//      other verb is refused. branch, tag, remote, config, stash and worktree
//      pass in their listing forms only, symbolic-ref with one argument, and
//      reflog in every form but expire, delete and drop. A git -c,
//      --config-env or --exec-path=<dir> is refused, since configuration can
//      name a program (core.pager, diff.external, an alias). The environment is
//      configuration too (GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND, GIT_CONFIG_COUNT
//      each name a program), so a reviewer's git is refused when a GIT_*
//      variable is set in front of it, and when ANY other statement on the
//      line can change the environment git inherits: an assignment of any
//      name, the export family, anything that sets a variable by name
//      (printf -v, read, mapfile, getopts, a for loop, ${x:=y}), set, source,
//      the dot command, eval, let and arithmetic. The rule is the category,
//      not a list of GIT_ spellings, because each review round found a new
//      spelling. It over-refuses a line that sets an unrelated variable before
//      git, a cost Mike's fail-closed rule accepts for reviewers. A plain
//      `FOO=1 git status`, a non-GIT_ name on git itself, still runs.
//      An option of a reading verb that names or runs a program is refused
//      (PROGRAM_OPTIONS: grep -O, ls-remote --upload-pack, archive --exec and
//      --remote, --ext-diff, and --textconv, git grep's included). `git
//      archive` and git's --output write the file they name, judged by path.
//   2. The file writers in MUTATING, judged by the paths they write:
//      cp's destination (never its sources), mv's every operand, rsync's
//      destination, the directory tar and unzip extract into, sort -o, uniq's
//      second operand, and so on. A writer fed by xargs or parallel is refused,
//      since its paths arrive at run time.
//   3. In-place editing: sed -i, perl -i and ruby -i, judged by the files they
//      edit, so an edit on a scratch copy passes. A sed script with a w or e
//      command, an awk program that prints to a file, pipes, or calls
//      system(), and find with -delete, -exec, -ok or -fprint are refused.
//   4. Formatters asked to write: --write, --fix, --in-place on any other
//      command (git, the writers, find and an in-place edit meet the rules
//      above), a formatter's short write flag, and a formatter that writes by
//      default and was not put in check mode. Refused wherever they point.
//   5. Redirects bash really performs (>, >>, >|, &>, <>, a >& to a file),
//      judged by target. A > inside quotes, an awk or sed program, a heredoc
//      body, arithmetic or [[ ]] is not a redirect, and the reader says so.
//      A quoted heredoc body is data, so a body written to a scratch file
//      passes whatever text it holds (an `-I{}`, an `=> {`).
//
// FAIL CLOSED. A line parseShell cannot read whole (any unknown), a wrapper
// it cannot place (isPlaced false), a command name built at run time, and a
// program the guard does not know with a writer's name among its words
// (`parallel chmod …`, a runner off every list) are refused: a false refusal
// costs a reviewer one step, while a bypass costs a write to the tree under
// review (vault: decisions/2026-10-05-holmes-guard-fail-closed-on-unknown-
// wrappers.md). A cd, pushd, popd or chdir, or a wrapper option that changes
// directory, makes every later relative path unresolvable.
//
// WHAT IT DOES NOT COVER. This guard catches honest mistakes, and is not a
// security boundary (Mike, 2026-10-07: these gaps are accepted rather than
// chased). It reads the words of a line, so a change it cannot see in them is
// out of scope: a value-only change such as PATH=, HOME= or XDG_CONFIG_HOME=
// before git; git -C into a repository whose own config is hostile; an
// arithmetic assignment such as $((X=1)); a bash alias defined on the same
// line; code inside an interpreter (`python -c`, `node -e`); a script file;
// a package script (`npm run format`); and a zsh builtin outside its tables
// that sets a variable by name (zformat -f or -a, zregexparse, and module
// builtins such as sysread, zstat -A and zselect -a). Nor does it catch a
// program off every list that writes on its own (`gh pr checkout`). The
// reviewer prompts' no-write rule and the human's review of the diff are the
// backstop there.

import type { EngineInterface } from 'claude-code'

type Workbench = EngineInterface['workbench']
export type ShellParse = Awaited<ReturnType<Workbench['parseShell']>>
export type Statement = ShellParse['statements'][number]

// A refused call: the short action the person reads, and the reason the model
// reads after it.
export type Finding = { action: string; reason: string }

// A path a call writes: as written, and absolute when it can be known.
export type Write = { raw: string; path: string | undefined; writer: string }

export type Verdict = { finding: Finding } | { writes: Write[] }

// The agent types the guard holds. `u` folds `ſ` into `s`, as Python's
// re.IGNORECASE did for the bash guard.
const REVIEWER = /(^|[:/])holmes(-lens|-local|-index)?$/iu

export const isReviewerType = (type: string | undefined): boolean => type !== undefined && REVIEWER.test(type.trim())

// git verbs that only read. Every other verb is refused.
const GIT_READ_ONLY: ReadonlySet<string> = new Set([
  'annotate', 'blame', 'cat-file', 'check-attr', 'check-ignore', 'count-objects', 'describe', 'diff', 'diff-index',
  'diff-tree', 'for-each-ref', 'grep', 'log', 'ls-files', 'ls-tree', 'merge-base', 'name-rev', 'rev-list',
  'rev-parse', 'shortlog', 'show', 'show-ref', 'status', 'var', 'verify-commit', 'verify-tag',
  'whatchanged', 'ls-remote', 'archive',
])
// Read-only only in some forms, judged in gitReads: symbolic-ref with one
// argument, and reflog other than expire, delete and drop.

const BRANCH_READ_FLAGS = new Set([
  '--show-current', '-a', '--all', '-r', '--remotes', '-v', '-vv', '--verbose', '-l', '--list', '--no-color',
  '--contains', '--no-contains', '--merged', '--no-merged', '--points-at',
])
const TAG_READ_FLAGS = new Set(['-l', '--list', '-n', '--no-color', '--contains', '--no-contains', '--merged', '--no-merged', '--points-at'])
const LIST_VALUE_PREFIXES = ['--format=', '--sort=', '--contains=', '--no-contains=', '--merged=', '--no-merged=', '--points-at=']
const LIST_VALUE_FLAGS = new Set(LIST_VALUE_PREFIXES.map(prefix => prefix.slice(0, -1)))
const CONFIG_READ_FLAGS = new Set(['--get', '--get-all', '--get-regexp', '--get-urlmatch', '--list', '-l', '--get-color', '--get-colorbool'])
const CONFIG_WRITE_FLAGS = new Set(['--add', '--unset', '--unset-all', '--replace-all', '--rename-section', '--remove-section', '--edit', '-e'])

// Commands whose purpose is to change a file's content, location, existence,
// or metadata, each judged by the paths writeTargets says it writes.
const MUTATING: ReadonlySet<string> = new Set([
  'chmod', 'chown', 'chgrp', 'rm', 'rmdir', 'unlink', 'mv', 'shred', 'truncate', 'touch', 'tee', 'cp', 'ln',
  'install', 'dd', 'patch', 'mkdir', 'rsync', 'tar', 'unzip', 'sort', 'uniq',
])

// Options that take the next word as their value, on both GNU and BSD.
const VALUE_OPTIONS: Readonly<Record<string, ReadonlySet<string>>> = {
  install: new Set(['-m', '-o', '-g']),
  truncate: new Set(['-s', '-r']),
  touch: new Set(['-r', '-t', '-d']),
  mkdir: new Set(['-m']),
  rsync: new Set(['-e', '-f', '-T']),
  uniq: new Set(['-f', '-s', '-w', '--skip-fields', '--skip-chars', '--check-chars']),
  chmod: new Set(['--reference']),
}

const UNZIP_READ_FLAGS = new Set('lptvcZh')

// The three in-place editors: the letters that mean in place, and the letters
// that take the rest of their word (or the next word) as a value.
const IN_PLACE_EDITORS: Readonly<Record<string, { inPlace: string; value: string }>> = {
  sed: { inPlace: 'iI', value: 'ef' },
  perl: { inPlace: 'i', value: 'eEFImMx' },
  ruby: { inPlace: 'i', value: 'eCEFIrx' },
}
// The value letters whose value is the program, so no file operand is a script.
const CODE_LETTERS: Readonly<Record<string, string>> = { sed: 'ef', perl: 'eE', ruby: 'e' }

const IN_PLACE_FLAGS = new Set(['--write', '--fix', '--in-place'])

const FORMATTER_WRITE_FLAGS: Readonly<Record<string, ReadonlySet<string>>> = {
  gofmt: new Set(['-w']), goimports: new Set(['-w']), gofumpt: new Set(['-w']), shfmt: new Set(['-w']),
  prettier: new Set(['-w']), 'clang-format': new Set(['-i']), autopep8: new Set(['-i']), yapf: new Set(['-i']),
  'swift-format': new Set(['-i']),
  rubocop: new Set(['-a', '-A', '-x', '--autocorrect', '--autocorrect-all', '--auto-correct', '--auto-correct-all', '--safe-auto-correct', '--fix-layout']),
}
const FORMATTER_CLUSTER_FLAGS: Readonly<Record<string, { write: string; value: string }>> = {
  yapf: { write: 'i', value: 'le' },
  autopep8: { write: 'i', value: 'jp' },
  prettier: { write: 'w', value: '' },
  rubocop: { write: 'aAx', value: 'corfCs' },
}
const STDIN_NAME_OPTIONS = new Set(['--stdin-filename', '--filename'])
const FORMATTERS_WRITING_BY_DEFAULT: Readonly<Record<string, ReadonlySet<string>>> = {
  black: new Set(['--check', '--diff', '-c', '--code']),
  rustfmt: new Set(['--check', '--emit=stdout', '--print-config']),
  'cargo fmt': new Set(['--check']),
  'go fmt': new Set(['-n']),
  'ruff format': new Set(['--check', '--diff']),
  isort: new Set(['--check-only', '--check', '-c', '--diff', '--show-config', '--show-files', '--stdout', '-d']),
  'terraform fmt': new Set(['-check', '-write=false']),
  'mix format': new Set(['--check-formatted', '--dry-run']),
  'dotnet format': new Set(['--verify-no-changes']),
  'deno fmt': new Set(['--check']),
  'zig fmt': new Set(['--check']),
  stylua: new Set(['--check']),
  pint: new Set(['--test']),
  'php-cs-fixer fix': new Set(['--dry-run']),
}
const RUSTFMT_CONFIG_FILE_KINDS = new Set(['default', 'minimal'])
const OFF_VALUES = new Set(['false', 'f', '0', 'no', 'off'])
const FORMATTER_INFO_FLAGS = new Set(['-h', '--help', '-V', '--version'])

// Wrappers and runners the shell reader does not place, stepped through here
// so the program behind them is judged. Each runner lists the subcommands that
// run another program. The value options take the next word.
const PASS_THROUGH: ReadonlySet<string> = new Set(['npx', 'bunx', 'pnpx', 'noglob'])
const RUNNERS: Readonly<Record<string, ReadonlySet<string>>> = {
  bundle: new Set(['exec']), uv: new Set(['run']), poetry: new Set(['run']), pipx: new Set(['run']),
  pnpm: new Set(['exec', 'dlx']), npm: new Set(['exec', 'x']), yarn: new Set(['exec', 'dlx', 'run']), composer: new Set(['exec']),
}
const YARN_OWN_WRITER_NAMES = new Set(['install', 'unlink', 'patch'])
const RUNNER_VALUE_OPTIONS: Readonly<Record<string, readonly string[]>> = {
  npx: ['-p', '--package'],
  uv: ['-w', '--with', '--with-editable', '--with-requirements', '-p', '--python', '--package', '--extra', '--group', '--env-file', '--index', '-i', '--index-url', '--directory', '--project'],
  poetry: ['-C', '--directory', '-P', '--project'],
  pipx: ['--spec', '--python', '--pip-args', '--index-url'],
  pnpm: ['-C', '--dir', '-F', '--filter', '--package'],
  npm: ['-p', '--package', '--prefix', '-w', '--workspace'],
  yarn: ['--cwd', '-p', '--package'],
  composer: ['-d', '--working-dir'],
}
const RUNNER_CHDIR_OPTIONS: Readonly<Record<string, readonly string[]>> = {
  uv: ['--directory'], poetry: ['-C', '--directory'], pnpm: ['-C', '--dir'], npm: ['-w', '--workspace', '--prefix'],
  yarn: ['--cwd'], composer: ['-d', '--working-dir'],
}
// A runner option whose value is a command line, which the guard cannot read.
const RUNNER_SCRIPT_OPTIONS: Readonly<Record<string, readonly string[]>> = { npm: ['-c', '--call'], npx: ['-c', '--call'] }

// Builtins that change the directory later statements run in.
const DIRECTORY_CHANGES = new Set(['cd', 'pushd', 'popd', 'chdir'])

// Programs that never run a command named among their words, so a writer's
// name there is data: `grep -rn chmod .`, `man rm`, `command -v tee`.
const KNOWN: ReadonlySet<string> = new Set([
  'echo', 'printf', 'cat', 'head', 'tail', 'wc', 'ls', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'jq', 'yq', 'man',
  'which', 'type', 'whereis', 'whatis', 'apropos', 'command', 'file', 'stat', 'diff', 'cmp', 'comm', 'cut', 'tr',
  'column', 'nl', 'less', 'more', 'test', '[', '[[', '((', 'printenv', 'basename', 'dirname', 'realpath', 'readlink',
  'true', 'false', ':', 'cd', 'pushd', 'popd', 'pwd', 'git', 'gh', 'date', 'sleep', 'help', 'hash', 'alias',
  'export', 'local', 'declare', 'readonly', 'unset', 'set', 'trap', 'tldr', 'mktemp',
  // A case pattern and a loop's word list are words, never commands.
  'case', 'for', 'select',
])

// Names that run or write when they stand among another program's words.
const WRITER_NAMES: ReadonlySet<string> = new Set([
  ...MUTATING, ...Object.keys(IN_PLACE_EDITORS), ...Object.keys(FORMATTER_WRITE_FLAGS), 'black', 'rustfmt', 'cargo',
  'go', 'ruff', 'isort', 'terraform', 'mix', 'dotnet', 'deno', 'zig', 'stylua', 'pint', 'php-cs-fixer', 'git', 'find',
  'awk', 'gawk', 'mawk', 'nawk', 'bash', 'sh', 'zsh', 'dash', 'ksh', 'fish', 'csh', 'tcsh', 'eval', 'exec', 'source',
  'env', 'sudo', 'doas', 'nohup', 'nice', 'ionice', 'stdbuf', 'timeout', 'gtimeout', 'xargs', 'parallel',
  'caffeinate', 'chronic', 'unbuffer', 'flock', 'setsid', 'watch', 'time', 'builtin', ...PASS_THROUGH,
  ...Object.keys(RUNNERS),
])

const AWK = new Set(['awk', 'gawk', 'mawk', 'nawk'])

// A command name the shell builds at run time: a brace, a glob, or zsh's
// `=name` path expansion.
const BUILT_NAME = /[{}*?[\]]|^=/

// A GIT_* assignment in front of git.
const isGitEnv = (word: string): boolean => /^GIT_[A-Za-z0-9_]*\+?=/.test(word)

// Commands that can change the environment later commands on the line
// inherit: they set, export, or import variables by name, or run text that
// could. printf counts only with -v.
const ENV_CHANGERS: ReadonlySet<string> = new Set([
  'export', 'declare', 'typeset', 'local', 'readonly', 'read', 'mapfile', 'readarray', 'getopts', 'for', 'select',
  'set', 'source', '.', 'eval', 'let', '((', 'unset',
  // zsh, Mike's shell: its options (allexport among them), its declarations,
  // and the builtins that set a variable by name.
  'setopt', 'unsetopt', 'emulate', 'integer', 'float', 'vared', 'zparseopts', 'getln',
])

// Builtins that set a variable by name only with one of these options:
// printf -v and print -v, zsh's strftime -s, and zstyle's lookup forms.
const SETS_BY_OPTION: Readonly<Record<string, RegExp>> = {
  printf: /^-[A-Za-z]*v/,
  print: /^-[A-Za-z]*v/,
  strftime: /^-[A-Za-z]*s/,
  zstyle: /^-/,
}

// A parameter expansion that assigns: ${x:=y} or ${x=y}.
const ASSIGNING_EXPANSION = /\$\{[^}]*?:?=/

// Whether a statement can change the environment of the others on its line.
const changesEnv = (st: Statement): boolean =>
  st.assignments.length > 0 ||
  (ENV_CHANGERS.has(st.name) && st.nameAt >= 0) ||
  (SETS_BY_OPTION[st.name] !== undefined && st.args.some(a => SETS_BY_OPTION[st.name]?.test(a) === true)) ||
  st.words.some(w => ASSIGNING_EXPANSION.test(w))

// A path holding any of these is shell the guard does not expand.
const UNRESOLVABLE = /[$`*?[\]{}()'"\\<>\uE000]/

// Redirect targets that write no file.
const DEVICE = /^\/dev\/(?:null|stdout|stderr|tty|fd\/[0-9]+)$/

const basename = (word: string): string => (word.split('/').pop() ?? word).toLowerCase()

// The absolute path a command names, or undefined when it cannot be known.
export function resolvePath(raw: string, cwd: string | undefined, home: string | undefined): string | undefined {
  let target = raw
  if (target === '~' || target.startsWith('~/')) {
    if (!home) return undefined
    target = home + target.slice(1)
  }
  if (target === '' || target.startsWith('~') || UNRESOLVABLE.test(target)) return undefined
  if (!target.startsWith('/')) {
    if (!cwd) return undefined
    target = `${cwd.replace(/\/$/, '')}/${target}`
  }
  return target
}

// Options of a reading verb that run a program, name one, or run one the
// configuration names, by verb: each refused as `git -c` is. A long option is
// matched by any cut git accepts down to the length given, so `--open-files=`
// is `--open-files-in-pager`. git log's `-O<file>` is an order file and reads.
const PROGRAM_OPTIONS: Readonly<Record<string, readonly [string, number][]>> = {
  // grep alone runs textconv only when asked.
  grep: [['-O', 2], ['--open-files-in-pager', 6], ['--ext-grep', 7], ['--textconv', 7]],
  'ls-remote': [['--upload-pack', 4], ['--exec', 5]],
  archive: [['--exec', 5], ['--remote', 8]],
  diff: [['--ext-diff', 6], ['--textconv', 7]],
  log: [['--ext-diff', 6], ['--textconv', 7]],
  show: [['--ext-diff', 6], ['--textconv', 7]],
  whatchanged: [['--ext-diff', 6], ['--textconv', 7]],
  'diff-tree': [['--ext-diff', 6], ['--textconv', 7]],
  'diff-index': [['--ext-diff', 6], ['--textconv', 7]],
  blame: [['--textconv', 7]],
  annotate: [['--textconv', 7]],
  'cat-file': [['--textconv', 7], ['--filters', 5]],
}

// The option of `rest` that runs a program, or undefined. `--` ends options.
function programOption(verb: string, rest: readonly string[]): string | undefined {
  for (const arg of rest) {
    if (arg === '--') return undefined
    const key = arg.split('=')[0] ?? arg
    for (const [option, shortest] of PROGRAM_OPTIONS[verb] ?? []) {
      // A short option counts anywhere in a single-dash cluster (`-nOcat`).
      const isShort = !option.startsWith('--') && arg.startsWith('-') && !arg.startsWith('--') && arg.includes(option.slice(1))
      if (option.startsWith('--') ? key.length >= shortest && option.startsWith(key) : isShort) return option
    }
  }
  return undefined
}

// git's own verdict on `git <verb> <rest>`: true when it only reads.
function gitReads(verb: string, rest: readonly string[]): boolean {
  if (programOption(verb, rest) !== undefined) return false
  if (GIT_READ_ONLY.has(verb)) return true
  const flags = rest.filter(a => a.startsWith('-'))
  let positionals = rest.filter(a => !a.startsWith('-'))
  // symbolic-ref reads a ref with one argument, and sets or deletes it with
  // two or with -d.
  if (verb === 'symbolic-ref') {
    return positionals.length === 1 && flags.every(f => ['-q', '--quiet', '--short', '--recurse', '--no-recurse'].includes(f))
  }
  // reflog shows by default; expire, delete and drop destroy the recovery trail.
  if (verb === 'reflog') return !['expire', 'delete', 'drop'].includes(positionals[0] ?? '')
  const isListing = flags.includes('-l') || flags.includes('--list')
  if (verb === 'branch' || verb === 'tag') {
    positionals = rest.filter((a, i) => !a.startsWith('-') && !(i > 0 && LIST_VALUE_FLAGS.has(rest[i - 1] ?? '')))
    const allowed = verb === 'branch' ? BRANCH_READ_FLAGS : TAG_READ_FLAGS
    const flagsOk = flags.every(f => allowed.has(f) || LIST_VALUE_PREFIXES.some(p => f.startsWith(p)) || (verb === 'tag' && /^-n\d+$/.test(f)))
    return flagsOk && (positionals.length === 0 || isListing)
  }
  const first = positionals[0]
  if (verb === 'remote') {
    return flags.every(f => ['-v', '--verbose', '--all', '--push', '-n'].includes(f)) && (first === undefined || first === 'get-url' || first === 'show')
  }
  if (verb === 'config') {
    if (flags.some(f => CONFIG_WRITE_FLAGS.has(f.split('=')[0] ?? f))) return false
    return flags.some(f => CONFIG_READ_FLAGS.has(f)) || first === 'get' || first === 'list'
  }
  if (verb === 'stash') return first === 'list' || first === 'show'
  if (verb === 'worktree') return first === 'list'
  return false
}

// The files git writes beside its output: `--output <f>`, `-o <f>` for archive.
function gitOutputs(verb: string, rest: readonly string[]): string[] {
  const out: string[] = []
  rest.forEach((arg, i) => {
    if (arg.startsWith('--output=')) out.push(arg.slice('--output='.length))
    else if (arg === '--output' || (verb === 'archive' && arg === '-o')) out.push(rest[i + 1] ?? '')
    else if (verb === 'archive' && /^-o./.test(arg)) out.push(arg.slice(2))
  })
  return out
}

// The operands of a writer: the words that are not options or option values.
function operandsOf(name: string, args: readonly string[]): string[] {
  const operands: string[] = []
  let isDone = false
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? ''
    if (!isDone && arg === '--') isDone = true
    else if (isDone || !arg.startsWith('-') || arg === '-') operands.push(arg)
    else if (VALUE_OPTIONS[name]?.has(arg)) i++
  }
  return operands
}

function tarTargets(args: readonly string[], cwd: string): string[] {
  const longModes: Record<string, string> = { '--extract': 'x', '--get': 'x', '--create': 'c', '--append': 'r', '--update': 'u', '--catenate': 'A', '--concatenate': 'A', '--delete': 'r' }
  const modes = new Set<string>()
  const archives: string[] = []
  const dirs: string[] = []
  let toStdout = false
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? ''
    if (arg.startsWith('--')) {
      const at = arg.indexOf('=')
      const key = at < 0 ? arg : arg.slice(0, at)
      for (const m of longModes[key] ?? '') modes.add(m)
      toStdout ||= key === '--to-stdout'
      if (key === '--file' || key === '--directory') {
        const value = at < 0 ? (args[++i] ?? '') : arg.slice(at + 1)
        ;(key === '--file' ? archives : dirs).push(value)
      }
    } else if ((arg.startsWith('-') && arg !== '-') || i === 0) {
      const letters = arg.replace(/^-+/, '')
      for (let j = 0; j < letters.length; j++) {
        const char = letters[j] ?? ''
        if (char === 'f' || char === 'C') {
          let value = arg.startsWith('-') ? letters.slice(j + 1) : ''
          if (!value) value = args[++i] ?? ''
          ;(char === 'f' ? archives : dirs).push(value)
          if (arg.startsWith('-')) break
        } else {
          if ('xcruA'.includes(char)) modes.add(char)
          toStdout ||= char === 'O'
        }
      }
    }
  }
  const targets: string[] = []
  if ([...modes].some(m => 'cruA'.includes(m))) targets.push(...archives.filter(a => a !== '-'))
  if (modes.has('x') && !toStdout) targets.push(...(dirs.length > 0 ? dirs : [cwd]))
  return targets
}

function unzipTargets(args: readonly string[], cwd: string): string[] {
  let letters = ''
  let dest: string | undefined
  const operands: string[] = []
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? ''
    if (arg.startsWith('-') && !arg.startsWith('--') && arg.length > 1) {
      for (let j = 1; j < arg.length; j++) {
        if (arg[j] === 'd') {
          dest = arg.slice(j + 1) || (args[++i] ?? '')
          break
        }
        letters += arg[j]
      }
    } else if (!arg.startsWith('-')) operands.push(arg)
  }
  if (operands.length === 0 || [...letters].some(l => UNZIP_READ_FLAGS.has(l))) return []
  return [dest ?? cwd]
}

function sortTargets(args: readonly string[]): string[] {
  const targets: string[] = []
  args.forEach((arg, i) => {
    const next = args[i + 1] ?? ''
    if (arg.startsWith('--output')) targets.push(arg.includes('=') ? arg.slice(arg.indexOf('=') + 1) : next)
    else if (/^-[A-Za-z]*o$/.test(arg)) targets.push(next)
    else if (/^-[A-Za-z]*o.+/.test(arg) && !arg.startsWith('--')) targets.push(arg.slice(arg.indexOf('o') + 1))
  })
  return targets
}

// The paths a MUTATING command writes, as written. An extra path can only
// refuse more. `cwd` is '' when it is unknown, which no path resolves under.
function writeTargets(name: string, args: readonly string[], cwd: string): string[] {
  const operands = operandsOf(name, args)
  if (name === 'dd') return args.filter(a => a.startsWith('of=')).map(a => a.slice(3))
  if (name === 'cp' || name === 'ln' || name === 'install') {
    for (let i = 0; i < args.length; i++) {
      const arg = args[i] ?? ''
      if (arg.startsWith('--target-directory=')) return [arg.slice(arg.indexOf('=') + 1)]
      if (arg === '--target-directory' || /^-[A-Za-z]*t$/.test(arg)) return [args[i + 1] ?? '']
      if (/^-[A-Za-z]*t.+/.test(arg) && !arg.startsWith('--')) return [arg.slice(arg.indexOf('t') + 1)]
    }
    if (name === 'install' && args.includes('-d')) return operands
    if (name === 'ln' && operands.length === 1) return [cwd ? `${cwd}/${basename(operands[0] ?? '')}` : '']
    // The destination is the last operand; a source is only read.
    return operands.slice(-1)
  }
  if (name === 'chmod' || name === 'chown' || name === 'chgrp') {
    return args.some(a => a.startsWith('--reference')) ? operands : operands.slice(1)
  }
  if (name === 'rsync') {
    if (args.includes('--remove-source-files')) return operands
    return operands.length > 1 ? operands.slice(-1) : []
  }
  if (name === 'tar') return tarTargets(args, cwd)
  if (name === 'unzip') return unzipTargets(args, cwd)
  if (name === 'sort') return sortTargets(args)
  if (name === 'uniq') return operands.slice(1)
  if (name === 'patch') {
    let directory = cwd
    args.forEach((arg, i) => {
      if (arg === '-d' || arg === '--directory') directory = args[i + 1] ?? ''
      else if (arg.startsWith('--directory=')) directory = arg.slice('--directory='.length)
      else if (arg.startsWith('-d') && arg.length > 2) directory = arg.slice(2)
    })
    return [...operands, directory]
  }
  return operands
}

// The files an in-place sed, perl or ruby edits, or undefined when it edits
// none in place.
function inPlaceTargets(name: string, args: readonly string[]): string[] | undefined {
  const editor = IN_PLACE_EDITORS[name]
  if (editor === undefined) return undefined
  let isInPlace = false
  let hasCode = false
  const operands: string[] = []
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? ''
    if (arg === '--') {
      operands.push(...args.slice(i + 1))
      break
    }
    if (arg.startsWith('--')) {
      if (arg.startsWith('--in-place')) isInPlace = true
      if (name === 'sed' && (arg === '--expression' || arg === '--file')) {
        hasCode = true
        i++
      } else if (name === 'sed' && (arg.startsWith('--expression=') || arg.startsWith('--file='))) hasCode = true
      continue
    }
    if (!arg.startsWith('-') || arg === '-') {
      operands.push(arg)
      continue
    }
    for (let j = 1; j < arg.length; j++) {
      const char = arg[j] ?? ''
      if (editor.inPlace.includes(char)) {
        isInPlace = true
        // BSD sed takes the backup suffix as the next word: `sed -i '' …`.
        if (name === 'sed' && j === arg.length - 1 && (args[i + 1] === '' || /^\.[A-Za-z0-9_~-]*$/.test(args[i + 1] ?? ''))) i++
        // GNU's attached suffix (`-i.bak`) is the rest of the word.
        if (name === 'sed' || name === 'perl' || name === 'ruby') {
          if (j < arg.length - 1 && !/^[A-Za-z]/.test(arg.slice(j + 1))) break
        }
        continue
      }
      if (editor.value.includes(char)) {
        if (CODE_LETTERS[name]?.includes(char)) hasCode = true
        if (j === arg.length - 1) i++
        break
      }
    }
  }
  if (!isInPlace) return undefined
  // With no -e or -f, the first operand is the program, not a file.
  return hasCode ? operands : operands.slice(1)
}

// A sed program that writes a file (w, W, s///w) or runs a command (e).
const SED_WRITES = /(?:^|[;\n{}\d$/])\s*[wW]\s*\S|(?:^|[;\n{}])\s*e(?:\s|$|;)|\/[gpiImM0-9]*e[gpiImM0-9]*\s*(?:$|[;}\n])/
// An awk program that prints to a file or a pipe, reads a command, or runs one.
const AWK_WRITES = /\bsystem\s*\(|\|\s*(?:&\s*)?getline|\bprintf?\b[^;}\n]*(?:>|\|)|"\s*\|\s*getline/

function sedPrograms(args: readonly string[]): string[] {
  const programs: string[] = []
  let hasFlag = false
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? ''
    if (arg === '-e' || arg === '--expression') {
      hasFlag = true
      programs.push(args[++i] ?? '')
    } else if (arg.startsWith('--expression=')) {
      hasFlag = true
      programs.push(arg.slice('--expression='.length))
    } else if (/^-[A-Za-z]*e./.test(arg) && !arg.startsWith('--')) {
      hasFlag = true
      programs.push(arg.slice(arg.indexOf('e') + 1))
    } else if (arg === '-f' || arg === '--file' || arg.startsWith('--file=')) {
      hasFlag = true
    }
  }
  if (!hasFlag) {
    const first = args.find(a => !a.startsWith('-'))
    if (first !== undefined) programs.push(first)
  }
  return programs
}

function formatterWrites(name: string, args: readonly string[]): string | undefined {
  if (/^python[0-9.]*$/.test(name) && args[0] === '-m' && args.length > 1) {
    name = args[1] ?? ''
    args = args.slice(2)
  }
  for (const arg of args) {
    let key = arg.split('=')[0] ?? arg
    if (key.length === 3 && key.startsWith('--')) key = key.slice(1)
    if (FORMATTER_WRITE_FLAGS[name]?.has(key)) return name
  }
  const cluster = FORMATTER_CLUSTER_FLAGS[name]
  if (cluster !== undefined) {
    for (const arg of args) {
      if (arg.startsWith('--') || !arg.startsWith('-')) continue
      for (const char of arg.slice(1)) {
        if (cluster.write.includes(char)) return name
        if (cluster.value.includes(char)) break
      }
    }
  }
  const sub = args.find(a => !a.startsWith('-') && !a.startsWith('+')) ?? ''
  const key = name in FORMATTERS_WRITING_BY_DEFAULT ? name : `${name} ${sub}`
  const checks = FORMATTERS_WRITING_BY_DEFAULT[key]
  if (checks === undefined) return undefined
  const words = new Set<string>(args)
  args.forEach((a, i) => {
    if (i + 1 < args.length) words.add(`${a}=${args[i + 1]}`)
    const at = a.indexOf('=')
    if (at >= 0 && !OFF_VALUES.has(a.slice(at + 1).toLowerCase())) words.add(a.slice(0, at))
  })
  if (key === 'rustfmt' && words.has('--print-config')) {
    const operands = args.filter(a => !a.startsWith('-'))
    const joined = args.filter(a => a.startsWith('--print-config=')).map(a => a.slice('--print-config='.length))
    const kind = joined[0] ?? operands.shift() ?? ''
    return operands.length > 0 && RUSTFMT_CONFIG_FILE_KINDS.has(kind) ? key : undefined
  }
  if ([...words].some(w => checks.has(w) || FORMATTER_INFO_FLAGS.has(w))) return undefined
  const operands = args.filter((a, i) => !a.startsWith('-') && !a.startsWith('+') && (i === 0 || !STDIN_NAME_OPTIONS.has(args[i - 1] ?? '')))
  if (key.includes(' ')) operands.splice(operands.indexOf(sub), 1)
  if (operands.length === 0 && (args.includes('-') || key === 'rustfmt')) return undefined
  return key
}

// The program behind the runners and wrappers the shell reader does not place:
// its name, its words, whether it changes directory, and a finding when its
// command cannot be read at all.
function stepThrough(name: string, args: readonly string[]): { name: string; args: readonly string[]; chdir: boolean; finding?: Finding } {
  let chdir = false
  for (let guard = 0; guard < 16; guard++) {
    const runner = RUNNERS[name]
    if (!PASS_THROUGH.has(name) && runner === undefined) break
    const values = RUNNER_VALUE_OPTIONS[name] ?? []
    const matches = (options: readonly string[], key: string) => options.some(o => key === o || (o.startsWith('--') && key.length > 3 && o.startsWith(key)))
    // Steps over the options from `i`, before and after a run subcommand.
    let i = 0
    let script: string | undefined
    const skipOptions = () => {
      while (i < args.length && (args[i] ?? '').startsWith('-')) {
        const arg = args[i] ?? ''
        const key = arg.split('=')[0] ?? arg
        if (matches(RUNNER_SCRIPT_OPTIONS[name] ?? [], key)) script = key
        if (matches(RUNNER_CHDIR_OPTIONS[name] ?? [], key)) chdir = true
        i += matches(values, key) && !arg.includes('=') ? 2 : 1
      }
    }
    skipOptions()
    if (runner !== undefined) {
      const sub = args[i]
      if (sub !== undefined && runner.has(sub)) {
        i++
        skipOptions()
      } else if (sub === undefined || !(name === 'yarn' && !YARN_OWN_WRITER_NAMES.has(sub))) {
        return { name, args, chdir }
      }
    }
    if (script !== undefined) {
      return { name, args, chdir, finding: { action: `\`${name} ${script}\``, reason: `\`${name} ${script}\` hands over a command line the guard cannot read.` } }
    }
    if (i >= args.length) return { name, args, chdir }
    name = basename(args[i] ?? '')
    args = args.slice(i + 1)
  }
  return { name, args, chdir }
}

const unreadable = (what: string): Finding => ({
  action: 'a command the guard cannot read',
  reason: `${what}, so the guard cannot tell whether it writes. Run each command plainly, with literal paths.`,
})

// Options of env and sudo that run the command in another directory.
const CHDIR_WORD = /^(?:-[A-Za-z]*[CD]|--ch)/

export type Context = {
  // The directory the line starts in; undefined when it is not known.
  cwd: string | undefined
  home: string | undefined
  // Prose in a fenced block, read one line at a time by a lint: what the
  // reader could not read is passed over, a word that is not a command name
  // (an unknown program, a name built at run time) is not judged, and neither
  // are redirects. The rules a known command meets still apply.
  isDocs?: boolean
}

// The verdict on one Bash line: a finding, or the paths it writes.
export function reviewBash(parse: ShellParse, context: Context): Verdict {
  const isDocs = context.isDocs === true
  if (!isDocs && parse.unknowns.length > 0) {
    return { finding: unreadable(`The line holds shell the reader cannot read (${parse.unknowns.join(', ')})`) }
  }
  const writes: Write[] = []
  let cwd = context.cwd
  const write = (writer: string, raw: string) => writes.push({ writer, raw, path: resolvePath(raw, cwd, context.home) })
  // Another statement on the line that can change what a git inherits.
  const envChangers = parse.statements.filter(changesEnv)
  for (const s of parse.statements) {
    if (!s.isPlaced && !isDocs) return { finding: unreadable(`A wrapper option in front of \`${s.words[s.nameAt] ?? ''}\` cannot be placed`) }
    if (!isDocs) {
      for (const r of s.redirects) {
        if (!r.isReal) continue
        const isFile = ['>', '>>', '>|', '&>', '&>>', '<>'].includes(r.op) || (r.op === '>&' && !/^(?:[0-9]+-?|-)$/.test(r.target))
        if (!isFile || DEVICE.test(r.target)) continue
        // zsh reads `>!` and `>>!` as one operator that clobbers the next
        // word, where bash reads a file named `!`: both are judged.
        if (r.target === '!') writes.push({ writer: 'a redirect', raw: r.target, path: undefined })
        else write('a redirect', r.target)
        if (r.target.startsWith('!') && r.target.length > 1) write('a redirect', r.target.slice(1))
      }
    }
    if (s.nameAt < 0) continue
    const pre = s.words.slice(0, s.nameAt)
    if ((s.wrappers.includes('env') || s.wrappers.includes('sudo')) && pre.some(w => CHDIR_WORD.test(w))) cwd = undefined
    if (!isDocs && BUILT_NAME.test(s.name) && !['[', '[['].includes(s.name)) {
      return { finding: unreadable(`The command name \`${s.words[s.nameAt] ?? ''}\` is built when the line runs`) }
    }
    const stepped = stepThrough(s.name, s.args)
    if (stepped.finding !== undefined) return { finding: stepped.finding }
    if (stepped.chdir) cwd = undefined
    const { name, args } = stepped
    const isFed = s.wrappers.includes('xargs') || s.wrappers.includes('parallel')
    if (DIRECTORY_CHANGES.has(name)) {
      cwd = undefined
      continue
    }
    if (name === 'git') {
      const at = s.subcommandAt
      const globals = at < 0 ? s.args : s.args.slice(0, at)
      if (globals.some(a => a === '-c' || /^-c./.test(a) || a.startsWith('--config-env') || a.startsWith('--exec-path='))) {
        return { finding: { action: '`git -c`', reason: 'git is run with configuration on its command line, which can name a program git runs (core.pager, diff.external, an alias). Run git without -c.' } }
      }
      // The environment is configuration too: GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND
      // and GIT_CONFIG_COUNT/KEY/VALUE each name a program git runs.
      if (s.assignments.some(isGitEnv) || s.words.some(w => ASSIGNING_EXPANSION.test(w)) || envChangers.some(st => st !== s)) {
        return {
          finding: {
            action: '`git` beside a change to its environment',
            reason:
              'git is run with a GIT_ variable in front of it, or beside a command that can change the environment it inherits (an assignment, export, read, a for loop, set, source, eval). A GIT_ variable can name a program git runs (GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND, GIT_CONFIG_COUNT). Run git on its own line, with no variable set before it.',
          },
        }
      }
      if (at >= 0) {
        const verb = (s.args[at] ?? '').toLowerCase()
        const rest = s.args.slice(at + 1)
        if (!gitReads(verb, rest)) {
          return {
            finding: {
              action: `\`git ${verb}\``,
              reason: `\`git ${verb}\` is not one of git's read-only forms, so it is refused wherever it points. \`git restore\`, \`checkout\`, \`switch\`, \`reset\`, \`clean\`, and \`stash\` all discard exactly the uncommitted change a Local-mode review is sent to read.`,
            },
          }
        }
        for (const out of gitOutputs(verb, rest)) write(`git ${verb}`, out)
      }
      continue
    }
    if (MUTATING.has(name)) {
      if (isFed) return { finding: { action: `\`${name}\``, reason: `\`${name}\` changes files, and its paths arrive from xargs or parallel at run time, where the guard cannot read them.` } }
      for (const raw of writeTargets(name, args, cwd ?? '')) write(name, raw)
      continue
    }
    if (name === 'find') {
      const writer = args.find(a => ['-delete', '-exec', '-execdir', '-ok', '-okdir', '-fprint', '-fprint0', '-fprintf', '-fls'].includes(a))
      if (writer !== undefined) return { finding: { action: `\`find ${writer}\``, reason: `\`find ${writer}\` deletes, writes, or runs a command against the files it matches.` } }
      continue
    }
    const inPlace = inPlaceTargets(name, args)
    if (inPlace !== undefined) {
      if (isFed || inPlace.length === 0) return { finding: { action: `\`${name} -i\``, reason: `\`${name} -i\` rewrites files in place, and the guard cannot tell which.` } }
      for (const raw of inPlace) write(`${name} -i`, raw)
    }
    if (name === 'sed' && sedPrograms(args).some(p => SED_WRITES.test(p))) {
      return { finding: { action: '`sed` writing or running', reason: 'the sed program writes a file (w) or runs a command (e).' } }
    }
    if (AWK.has(name) && args.some(a => AWK_WRITES.test(a))) {
      return { finding: { action: `\`${name}\` writing or running`, reason: `the ${name} program prints to a file or a pipe, or runs a command.` } }
    }
    if (inPlace === undefined && args.some(a => IN_PLACE_FLAGS.has(a.split('=')[0] ?? a))) {
      return { finding: { action: `\`${name}\` with a rewrite flag`, reason: `\`${name}\` is being run with a rewrite flag. Run formatters and linters in check mode only.` } }
    }
    const formatter = formatterWrites(name, args)
    if (formatter !== undefined) {
      return { finding: { action: `\`${formatter}\` rewriting files`, reason: `\`${formatter}\` rewrites files unless it runs in check mode. Run formatters and linters in check mode only, such as \`--check\`.` } }
    }
    if (!isDocs && !KNOWN.has(name)) {
      // Each word of an argument counts, after an `=` too: `--split-string=rm x`.
      const behind = args.flatMap(a => a.split(/[\s=]+/)).find(word => WRITER_NAMES.has(basename(word)))
      if (behind !== undefined) {
        return { finding: unreadable(`\`${name}\` is a program the guard does not know, and \`${behind}\` stands among its words, where it may run`) }
      }
    }
  }
  return { writes }
}

// The verdict on an Edit, Write or NotebookEdit of `raw`.
export function reviewEdit(tool: string, raw: string, context: Context): Verdict {
  return { writes: [{ writer: tool, raw, path: resolvePath(raw, context.cwd, context.home) }] }
}

// The refusal the model reads: the action, the reason, and the way to work.
export function refusalOf(finding: Finding, roots: readonly string[]): string {
  const where = roots.map(root => `\`${root}\``).join(', ') || 'none could be found on this host'
  return (
    `🛑 Blocked: ${finding.action}. A Holmes reviewer writes only in scratch.\n\n` +
    `Review guard (workbench-dev-team). This command is refused, because ${finding.reason}\n\n` +
    'You are running as a Holmes reviewer, and a reviewer writes nothing outside ' +
    `the scratch roots. The scratch roots here are: ${where}. The code under review ` +
    "is read, never changed: in Local mode it is the human's live working " +
    'directory, and the uncommitted change in it is the only copy of the work.\n\n' +
    'Read it instead. `git status`, `git diff HEAD`, `git ls-files --others ' +
    '--exclude-standard`, and `git show` are all allowed, and so is the test suite. ' +
    'Validate by running the existing tests in place and reading them. Write no ' +
    'probe script, copy no repository, and change no code, not even in scratch. ' +
    'Report a hole no test covers as a finding that names the missing test. ' +
    'If a failure looks pre-existing, say so in your findings — never ' +
    'isolate it by changing the tree.\n\n' +
    'There is no flag to clear and no path around this. If you believe you are not ' +
    'a reviewer, report that to the session that dispatched you and stop.'
  )
}

// The disk, as the guard reads it. stat answers where a path lands with every
// symlink resolved (realPath undefined when it leads nowhere), or undefined
// when nothing is there. names lists a directory's entries, links included.
export type Disk = {
  stat: (path: string) => Promise<{ realPath: string | undefined } | undefined>
  names: (dir: string) => Promise<string[] | undefined>
}

// Where an absolute path lands with every symlink resolved: the deepest part
// that exists, resolved, then the rest as written. Undefined when a part that
// does not exist is `.` or `..`, or exists only as a link that leads nowhere,
// since either could land anywhere.
export async function landing(path: string, disk: Disk): Promise<string | undefined> {
  const parts = path.split('/').filter(part => part !== '')
  for (let i = parts.length; i >= 0; i--) {
    const head = `/${parts.slice(0, i).join('/')}`
    const stat = await disk.stat(head)
    if (stat === undefined) continue
    if (stat.realPath === undefined) return undefined
    const rest = parts.slice(i)
    if (rest.some(part => part === '.' || part === '..')) return undefined
    if (rest.length > 0) {
      const names = await disk.names(head)
      if (names === undefined || names.includes(rest[0] ?? '')) return undefined
    }
    return [stat.realPath.replace(/\/$/, ''), ...rest].join('/')
  }
  return undefined
}

// Whether a path lands strictly beneath a scratch root, both through every
// symlink and with its final name left where it lives: `rm <dir>/link`
// removes the link where it lives, wherever it points.
export async function isInScratch(path: string, roots: readonly string[], disk: Disk): Promise<boolean> {
  const trimmed = path.replace(/\/+$/, '')
  const cut = trimmed.lastIndexOf('/')
  const name = trimmed.slice(cut + 1)
  const followed = await landing(path, disk)
  let own = followed
  if (!(name === '' || name === '.' || name === '..' || path.endsWith('/'))) {
    const parent = await landing(trimmed.slice(0, cut) || '/', disk)
    own = parent === undefined ? undefined : `${parent.replace(/\/$/, '')}/${name}`
  }
  const beneath = (p: string | undefined) => p !== undefined && roots.some(root => p.startsWith(`${root.replace(/\/$/, '')}/`))
  return beneath(followed) && beneath(own)
}

// The first write that lands outside the scratch roots, as a finding.
export async function judgeWrites(writes: readonly Write[], roots: readonly string[], disk: Disk): Promise<Finding | undefined> {
  for (const w of writes) {
    const base = `\`${w.writer}\` changes a file's content, location, existence, or metadata`
    if (roots.length === 0) return { action: `\`${w.writer}\``, reason: `${base}, and no scratch root was found to judge its paths against.` }
    if (w.path === undefined) return { action: `\`${w.writer}\``, reason: `${base}, and the path \`${w.raw || '(none)'}\` cannot be resolved.` }
    if (!(await isInScratch(w.path, roots, disk))) return { action: `\`${w.writer}\``, reason: `${base}, and \`${w.raw}\` is outside the scratch roots.` }
  }
  return undefined
}
