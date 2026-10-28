declare module 'node:fs' {
  export function existsSync(path: string): boolean
  export function readFileSync(path: string, encoding: 'utf8'): string
  export function writeFileSync(path: string, text: string): void
  export function statSync(path: string): { size: number }
}

declare const process: {
  env: Record<string, string | undefined>
  stdin: AsyncIterable<string | Uint8Array> & { setEncoding(encoding: 'utf8'): void }
  stdout: { write(text: string): boolean }
}
