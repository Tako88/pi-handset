// The guard-witness subject: a process that mutates its own argv.
//
// Real `pi` is a `#!/usr/bin/env node` script that sets `process.title`,
// which rewrites the argv memory behind `/proc/<pid>/cmdline`. A spawn-time
// read captures the pre-exec/pre-title shape; a reap-time read sees the
// post-title padded shape. This fixture reproduces both the `env -> node`
// re-exec chain and the title rewrite, so a witness that uses it can see the
// fault a shell shim is blind to.
//
// It is written at runtime with mode 0o755 (like the existing shims) rather
// than checked in, so the suite owns its lifecycle.

import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** Env var carrying the path the subject writes its own pid to. */
export const TITLE_REWRITER_PID_ENV = 'PI_HANDSET_REWRITER_PID';
/** Env var carrying the path the subject writes its original argv JSON to. */
export const TITLE_REWRITER_ARGV_ENV = 'PI_HANDSET_REWRITER_ARGV';

const SCRIPT = `#!/usr/bin/env node
const fs = require('node:fs');
const pidFile = process.env.${TITLE_REWRITER_PID_ENV};
const argvFile = process.env.${TITLE_REWRITER_ARGV_ENV};
if (pidFile) fs.writeFileSync(pidFile, String(process.pid));
if (argvFile) fs.writeFileSync(argvFile, JSON.stringify(process.argv));
process.title = 'pi';
setInterval(() => {}, 1000);
`;

/**
 * Writes the title-rewriting subject into `dir` as `name` (default `pi`,
 * so a PATH-prepended dir makes it the binary the hub resolves) and returns
 * its path. The subject writes its pid and original argv to the paths named by
 * `TITLE_REWRITER_PID_ENV` / `TITLE_REWRITER_ARGV_ENV`, then rewrites its
 * title and sleeps.
 */
export function writeTitleRewriter(dir: string, name = 'pi'): string {
  const path = join(dir, name);
  writeFileSync(path, SCRIPT, { mode: 0o755 });
  return path;
}
