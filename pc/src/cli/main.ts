/**
 * The `pi-handset` CLI dispatcher. Deliberately not guarded on `process.argv[1]`
 * (that guard is what breaks under a `bin` symlink in #37) — nothing imports
 * this module, so running it is the only way it executes.
 */

import { runPair } from './pair.ts';
import { runServe } from './serve.ts';

export function usage(): string {
  return (
    'usage: pi-handset <command> [options]\n' +
    '\n' +
    'commands:\n' +
    '  serve [--port N] [--no-lan] [--take-over] [--max-sessions N]\n' +
    '  pair\n'
  );
}

async function main(argv: readonly string[]): Promise<number> {
  const [command, ...rest] = argv;
  switch (command) {
    case 'serve':
      return runServe(rest);
    case 'pair':
      return runPair(rest, {
        stdout: (text) => process.stdout.write(text),
        stderr: (text) => process.stderr.write(text),
      });
    default:
      process.stderr.write(usage());
      return 2;
  }
}

void main(process.argv.slice(2)).then((code) => {
  process.exitCode = code;
});
