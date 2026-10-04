/**
 * Folder browsing for the phone, and pi's own trust store.
 *
 * The hub lets the app list directories under the PC user's real home and
 * start a project session in one. Two invariants matter more than anything
 * here:
 *
 * - A listing never escapes `realpath(home)`. Every candidate path is
 *   realpath'd and must be home itself or a descendant; symlinks are followed
 *   and rejected when their target leaves home.
 * - The trust store is read and written with pi's exact semantics so keys and
 *   values agree byte-for-byte with what pi itself writes. A malformed store
 *   is a loud error, never a silent "no decision" — pi throws on it too.
 *
 * `resolveWithinHome` and `listDirectories` reject a path that is relative,
 * nonexistent, a file, or a symlink out of home. `canonicalizePath` mirrors
 * pi's `realpathSync` with a raw-path fallback, so the keys we write match the
 * keys pi computes.
 */

import { existsSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, isAbsolute, join, sep } from 'node:path';

/** Default maximum number of entries returned by a single listing. */
export const DEFAULT_MAX_DIR_ENTRIES = 500;

/** Mode for the trust store: it lists which project folders exist and whether each is trusted. */
const TRUST_FILE_MODE = 0o600;

/** Default maximum encoded byte budget (`name` + JSON overhead) for a listing. */
export const DEFAULT_MAX_DIR_BYTES = 256 * 1024;

/** Makes each trust-store temp file name unique within this process. */
let tmpCounter = 0;

/** Raised for a path that cannot be listed: outside home, relative, missing. */
export class FolderError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FolderError';
  }
}

/** Raised when pi's trust store is malformed and must not be read or written. */
export class TrustStoreError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TrustStoreError';
  }
}

/** A directory listing with the containment root it was resolved against. */
export interface DirectoryListing {
  /** The canonical home the listing is contained by. */
  readonly root: string;
  /** The canonical directory being listed. */
  readonly path: string;
  /** Entry names (directories only), sorted case-insensitively. */
  readonly entries: string[];
  /** True when entries were cut by the count or byte cap. */
  readonly truncated: boolean;
}

/**
 * `realpathSync` with a fallback to the raw path — pi's `canonicalizePath`.
 * The fallback means a nonexistent path canonicalizes to itself rather than
 * throwing.
 */
export function canonicalizePath(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

function expandTilde(path: string, home: string): string {
  if (path === '~') return home;
  if (path.startsWith('~/')) return join(home, path.slice(2));
  return path;
}

/**
 * pi's agent directory: `$PI_CODING_AGENT_DIR` (with `~` expanded) when set,
 * else `<home>/.pi/agent`.
 */
export function getAgentDir(env: NodeJS.ProcessEnv, home: string): string {
  const envDir = env.PI_CODING_AGENT_DIR;
  if (envDir) return expandTilde(envDir, home);
  return join(home, '.pi', 'agent');
}

function isWithin(real: string, root: string): boolean {
  return real === root || real.startsWith(root + sep);
}

/**
 * Normalizes a cap: a missing or non-finite value falls back to the default,
 * otherwise the value is floored and clamped at zero. Without this a `NaN`
 * cap would disable the limit entirely (`length >= NaN` is always false) —
 * failing open where every other bad value fails closed.
 */
function normalizeCap(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback;
  return Math.max(0, Math.floor(value));
}

/**
 * Canonicalizes `path` and confirms it is a directory inside `home`. Returns
 * the canonical path, or `null` when the path is relative, empty, missing, not
 * a directory, or resolves outside home (via `..` or a symlink).
 */
export function resolveWithinHome(path: string, home: string): string | null {
  if (path === '' || !isAbsolute(path)) return null;
  let real: string;
  try {
    real = realpathSync(path);
  } catch {
    return null;
  }
  let isDir: boolean;
  try {
    isDir = statSync(real).isDirectory();
  } catch {
    return null;
  }
  if (!isDir) return null;
  if (!isWithin(real, canonicalizePath(home))) return null;
  return real;
}

/**
 * Lists the directory names directly under `target` (or `home` when `target`
 * is `undefined`). Only directories are returned: files are excluded, and a
 * symlink is included only when its realpath is a directory inside home (a
 * broken or out-of-home symlink is skipped). Both the count and encoded-byte
 * caps stop the walk; `truncated` is true only when entries were actually cut.
 *
 * Throws `FolderError` when `target` is outside home, relative, or nonexistent.
 */
export function listDirectories(
  target: string | undefined,
  home: string,
  options: { maxEntries?: number; maxBytes?: number } = {},
): DirectoryListing {
  const maxEntries = normalizeCap(options.maxEntries, DEFAULT_MAX_DIR_ENTRIES);
  const maxBytes = normalizeCap(options.maxBytes, DEFAULT_MAX_DIR_BYTES);
  const root = canonicalizePath(home);

  let resolved: string;
  if (target === undefined) {
    resolved = root;
  } else {
    const within = resolveWithinHome(target, home);
    if (within === null) throw new FolderError(`not a directory inside home: ${target}`);
    resolved = within;
  }

  let dirents: { name: string; isDirectory(): boolean; isSymbolicLink(): boolean }[];
  try {
    dirents = readdirSync(resolved, { withFileTypes: true });
  } catch (error) {
    throw new FolderError(`cannot read directory ${resolved}: ${String(error)}`);
  }

  const names: string[] = [];
  for (const dirent of dirents) {
    if (dirent.isDirectory()) {
      names.push(dirent.name);
      continue;
    }
    if (!dirent.isSymbolicLink()) continue;
    // A symlink is offered only when it resolves to a directory inside home;
    // a broken or out-of-home link is skipped.
    const linkPath = join(resolved, dirent.name);
    let linkReal: string;
    try {
      linkReal = realpathSync(linkPath);
      if (!statSync(linkReal).isDirectory()) continue;
    } catch {
      continue;
    }
    if (!isWithin(linkReal, root)) continue;
    names.push(dirent.name);
  }

  names.sort((a, b) => {
    const la = a.toLowerCase();
    const lb = b.toLowerCase();
    if (la < lb) return -1;
    if (la > lb) return 1;
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
  });

  const entries: string[] = [];
  let bytes = 0;
  let truncated = false;
  for (const name of names) {
    if (entries.length >= maxEntries) {
      truncated = true;
      break;
    }
    const cost = Buffer.byteLength(name) + 3;
    if (bytes + cost > maxBytes) {
      truncated = true;
      break;
    }
    entries.push(name);
    bytes += cost;
  }

  return { root, path: resolved, entries, truncated };
}

/**
 * pi's `TRUST_REQUIRING_PROJECT_CONFIG_RESOURCES`, checked in `<cwd>/.pi`.
 */
const TRUST_REQUIRING_PROJECT_CONFIG_RESOURCES = [
  'settings.json',
  'extensions',
  'skills',
  'prompts',
  'themes',
  'SYSTEM.md',
  'APPEND_SYSTEM.md',
];

/**
 * True when `cwd` carries a project resource pi would require trust for:
 * one of the `.pi/*` resources in `cwd` itself, or a `.agents/skills`
 * directory in `cwd` or any ancestor — excluding the user's own
 * `<home>/.agents/skills`.
 */
export function hasTrustRequiringResources(cwd: string, home: string): boolean {
  const homeDir = canonicalizePath(home);
  const userAgentsSkillsDir = join(homeDir, '.agents', 'skills');
  let currentDir = canonicalizePath(cwd);

  const configDir = join(currentDir, '.pi');
  if (TRUST_REQUIRING_PROJECT_CONFIG_RESOURCES.some((e) => existsSync(join(configDir, e)))) {
    return true;
  }

  while (true) {
    const agentsSkillsDir = join(currentDir, '.agents', 'skills');
    if (agentsSkillsDir !== userAgentsSkillsDir && existsSync(agentsSkillsDir)) return true;
    const parentDir = dirname(currentDir);
    if (parentDir === currentDir) return false;
    currentDir = parentDir;
  }
}

function stripBom(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

/**
 * Reads pi's trust store. A missing file is `{}` (not an error). A malformed
 * JSON body, a non-object root, or any value that is not `true`/`false`/`null`
 * throws `TrustStoreError` — pi's own semantics, so a store we refuse is a
 * store pi would refuse to operate on too.
 */
export function readTrustStore(trustPath: string): Record<string, boolean | null> {
  if (!existsSync(trustPath)) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(stripBom(readFileSync(trustPath, 'utf-8')));
  } catch (error) {
    throw new TrustStoreError(`Failed to read trust store ${trustPath}: ${String(error)}`);
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new TrustStoreError(`Invalid trust store ${trustPath}: expected an object`);
  }
  const data: Record<string, boolean | null> = {};
  for (const [key, value] of Object.entries(parsed)) {
    if (value !== true && value !== false && value !== null) {
      throw new TrustStoreError(
        `Invalid trust store ${trustPath}: value for ${key} must be true, false, or null`,
      );
    }
    data[key] = value;
  }
  return data;
}

/**
 * The closest `true`/`false` decision for `cwd` and its ancestors, or `null`
 * when none exists. A `null` value means "no decision" and the walk continues
 * upward — pi's `findNearestTrustEntry`.
 */
export function trustDecision(trustPath: string, cwd: string): boolean | null {
  const data = readTrustStore(trustPath);
  let currentDir = canonicalizePath(cwd);
  while (true) {
    const value = data[currentDir];
    if (value === true || value === false) return value;
    const parentDir = dirname(currentDir);
    if (parentDir === currentDir) return null;
    currentDir = parentDir;
  }
}

/**
 * Writes a decision for `cwd`, merging with the existing store. Keys are
 * sorted, parent directories are created, and the file ends with a newline —
 * pi's exact `writeTrustFile`, except for the write itself: pi truncates the
 * store in place, while this writes a sibling temp file and renames it over
 * the target, so an interrupted write can never leave the store torn. A torn
 * store is not a cosmetic problem — both pi and this hub throw on one. A
 * malformed store throws before any write, so the file is left byte-identical
 * rather than clobbered.
 */
export function saveTrustDecision(trustPath: string, cwd: string, decision: boolean | null): void {
  const existing = readTrustStore(trustPath);
  const merged: Record<string, boolean | null> = { ...existing, [canonicalizePath(cwd)]: decision };
  const sorted: Record<string, boolean | null> = {};
  for (const key of Object.keys(merged).sort()) {
    const value = merged[key];
    if (value === true || value === false || value === null) sorted[key] = value;
  }
  mkdirSync(dirname(trustPath), { recursive: true });
  // Same directory as the target: a rename is only atomic within a filesystem.
  const tmpPath = `${trustPath}.tmp-${process.pid}-${++tmpCounter}`;
  try {
    writeFileSync(tmpPath, `${JSON.stringify(sorted, null, 2)}\n`, { encoding: 'utf-8', mode: TRUST_FILE_MODE });
    renameSync(tmpPath, trustPath);
  } catch (error) {
    try {
      unlinkSync(tmpPath);
    } catch {
      // The temp file may never have been created; the original error matters.
    }
    throw error;
  }
}
