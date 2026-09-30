/**
 * The persisted pairing token.
 *
 * One 256-bit token is minted on first use and never regenerated: restarting
 * the supervisor must not de-pair the phone. It lives at
 * `<configDir>/pi-droid/token` where `<configDir>` is an absolute
 * `$XDG_CONFIG_HOME` falling back to `~/.config`.
 *
 * The config dir is a parameter, not a global, so tests exercise the real
 * filesystem in a temp dir and never touch the user's. `resolveConfigDir`
 * computes the default for production callers (M4's CLI).
 *
 * The token file's mode is set when it is created (temp file + rename), never
 * by a later `chmod`, so there is no window in which the token is
 * world-readable. A pre-existing file with a wider mode is repaired and the
 * same token is kept. An existing file whose content is not 64 lower-case hex
 * characters is *regenerated* — returning it verbatim would let an empty
 * candidate authenticate.
 *
 * `<configDir>/pi-droid` is ours, so it is repaired to `0700` when wider, and a
 * symlink at that path is refused (a leaf-only check would write the token
 * outside the directory whose mode this module relies on). `<configDir>` itself
 * belongs to the user and is never modified; if it is group- or world-writable
 * the return carries `insecureParent` so M4's CLI can warn.
 *
 * Accepted residuals, reviewed and deliberately not engineered around:
 * - The `lstat`-then-use TOCTOU window is bounded by repairing
 *   `<configDir>/pi-droid` to `0700`; no other local user can write into it.
 * - A concurrent first-create can race and mint two tokens. That window is
 *   closed at the hub level: M4's lock (an exclusive create held for the whole
 *   process lifetime) serializes startup before any token is read, so only one
 *   process reaches this module first. There is deliberately no lock here.
 * - A crash can leave `token.tmp.*` files behind. They are `0600` and
 *   superseded by the renamed token; no reaper deletes them.
 * - Hardlinks to the token are not detectable via `lstat` and are severed by
 *   the next atomic rename.
 * - Startup-fatal problems (unwritable dir, symlinked path) throw rather than
 *   returning an `{ok, code}` result. The CLI catches and prints; this is a
 *   deliberate divergence from `pairing.ts`/`protocol.ts`, which are called
 *   per-message rather than once at startup.
 */

import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import type { Stats } from 'node:fs';

/** 32 bytes = 256 bits, hex-encoded to 64 characters. */
const TOKEN_BYTES = 32;

const TOKEN_FILE_MODE = 0o600;
const CONFIG_DIR_MODE = 0o700;

/** A valid token is exactly 64 lower-case hex characters. */
const TOKEN_PATTERN = /^[0-9a-f]{64}$/;

/** What a load produced, and what M4 needs to warn about. */
interface TokenState {
  token: string;
  /** True when the token was minted fresh or invalid content was replaced. */
  regenerated: boolean;
  /** True when `<configDir>` is group- or world-writable (never modified). */
  insecureParent: boolean;
}

/** The default base config dir: an absolute `$XDG_CONFIG_HOME`, or `<home>/.config`. */
export function resolveConfigDir(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir(),
): string {
  const xdg = env.XDG_CONFIG_HOME;
  return typeof xdg === 'string' && xdg.length > 0 && isAbsolute(xdg)
    ? xdg
    : join(home, '.config');
}

/** The token file path under a config dir; exported so callers share one construction. */
export function tokenPath(configDir: string): string {
  return join(configDir, 'pi-droid', 'token');
}

function lstatOrNull(path: string): Stats | null {
  try {
    return lstatSync(path);
  } catch (error) {
    // Only ENOENT means "no file yet". EACCES/EIO/... must surface, not turn
    // an unreadable token into a silent re-mint.
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

/** Ensures `<configDir>/pi-droid` exists as a real directory at mode 0700. */
function ensureConfigDir(configDir: string): void {
  const dir = join(configDir, 'pi-droid');
  const existing = lstatOrNull(dir);

  if (existing === null) {
    mkdirSync(dir, { recursive: true, mode: CONFIG_DIR_MODE });
    return;
  }
  if (existing.isSymbolicLink()) {
    throw new Error(`refusing to use a symlinked config directory: ${dir}`);
  }
  if (!existing.isDirectory()) {
    throw new Error(`config path is not a directory: ${dir}`);
  }
  // `mkdirSync(..., {recursive})` is a no-op on an existing dir, so repair the
  // mode ourselves. Group/other bits let any local user replace the token file.
  if ((existing.mode & 0o077) !== 0) {
    chmodSync(dir, CONFIG_DIR_MODE);
  }
}

function isInsecureParent(configDir: string): boolean {
  const stats = lstatOrNull(configDir);
  return stats !== null && (stats.mode & 0o022) !== 0;
}

function mintToken(): string {
  return randomBytes(TOKEN_BYTES).toString('hex');
}

/**
 * Writes the token to a fresh temp file created at mode 0600, then renames it
 * over the target. Setting the mode at creation (rather than chmod-ing an
 * existing file) is what keeps the window between write and rename closed.
 */
function writeTokenAtomically(path: string, token: string): void {
  const temp = join(dirname(path), `token.tmp.${randomBytes(6).toString('hex')}`);
  writeFileSync(temp, token, { mode: TOKEN_FILE_MODE });
  renameSync(temp, path);
}

/**
 * Returns the persisted token, minting one on first use.
 *
 * A pre-existing file with a wider mode is repaired to 0600 and the same token
 * is kept. A pre-existing file with invalid content is replaced, and the
 * result's `regenerated` flag lets M4 warn that a phone was de-paired.
 */
export function loadOrCreateToken(configDir: string): TokenState {
  ensureConfigDir(configDir);
  const path = tokenPath(configDir);
  const insecureParent = isInsecureParent(configDir);
  const existing = lstatOrNull(path);

  if (existing?.isSymbolicLink()) {
    throw new Error(`refusing to use a symlinked token file: ${path}`);
  }

  if (existing !== null) {
    const token = readFileSync(path, 'utf8').trim();
    if (TOKEN_PATTERN.test(token)) {
      if ((existing.mode & 0o777) !== TOKEN_FILE_MODE) {
        writeTokenAtomically(path, token);
      }
      return { token, regenerated: false, insecureParent };
    }
  }

  const token = mintToken();
  writeTokenAtomically(path, token);
  return { token, regenerated: true, insecureParent };
}

/**
 * Mints a fresh token and writes it atomically at 0600, returning it. M4's
 * `rotate` uses this; doing it here keeps minting logic in one place.
 */
export function rotateToken(configDir: string): string {
  ensureConfigDir(configDir);
  const token = mintToken();
  writeTokenAtomically(tokenPath(configDir), token);
  return token;
}

/**
 * Constant-time token comparison.
 *
 * A non-string candidate is rejected outright — M5 passes unvalidated JSON in,
 * and a throw here would be a hub crash rather than a rejected connection.
 *
 * Both sides are hashed to a fixed 32-byte SHA-256 digest before
 * `timingSafeEqual`, which throws on unequal-length buffers. That digest is
 * exactly what equalizes them: the candidate is attacker-supplied and can be
 * any length, so no normalization can bound it. This is the deliberate
 * difference from `pairing.ts`, where `normalizeTicket` guarantees both sides
 * are 8 in-alphabet characters and the comparison is already equal-length.
 */
export function compareToken(candidate: unknown, expected: string): boolean {
  if (typeof candidate !== 'string') {
    return false;
  }
  const candidateDigest = createHash('sha256').update(candidate, 'utf8').digest();
  const expectedDigest = createHash('sha256').update(expected, 'utf8').digest();
  return timingSafeEqual(candidateDigest, expectedDigest);
}
