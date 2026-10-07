import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Deliberately `.ts`, and deliberately written before `./auth.ts` exists:
// the red run must fail with an unresolved import, not a loader error.
import {
  compareToken,
  loadOrCreateToken,
  resolveConfigDir,
  rotateToken,
  tokenPath,
} from './auth.ts';

// Tests never touch the real `~/.config`; they pass a throwaway temp dir as
// `configDir`.
let configDir: string;

beforeEach(() => {
  configDir = mkdtempSync(join(tmpdir(), 'pi-handset-auth-'));
});

afterEach(() => {
  rmSync(configDir, { recursive: true, force: true });
});

/** Seeds `<configDir>/pi-handset/token` with the given contents and mode. */
function seedToken(contents: string, mode = 0o600): void {
  mkdirSync(join(configDir, 'pi-handset'), { recursive: true, mode: 0o700 });
  writeFileSync(tokenPath(configDir), contents, { mode });
}

test('tokenPath points at <configDir>/pi-handset/token', () => {
  assert.equal(tokenPath(configDir), join(configDir, 'pi-handset', 'token'));
});

test('loadOrCreateToken writes a 256-bit token as 64 hex characters', () => {
  const { token, regenerated } = loadOrCreateToken(configDir);
  assert.match(token, /^[0-9a-f]{64}$/);
  assert.equal(regenerated, true);
  assert.equal(statSync(tokenPath(configDir)).isFile(), true);
});

test('the created token file is mode 0600', () => {
  loadOrCreateToken(configDir);
  assert.equal(statSync(tokenPath(configDir)).mode & 0o777, 0o600);
});

test('the pi-handset directory is created mode 0700', () => {
  loadOrCreateToken(configDir);
  assert.equal(statSync(join(configDir, 'pi-handset')).mode & 0o777, 0o700);
});

test('a second call returns the same persisted token and reports no regeneration', () => {
  const first = loadOrCreateToken(configDir);
  const second = loadOrCreateToken(configDir);
  assert.equal(second.token, first.token);
  assert.equal(second.regenerated, false);
  assert.equal(second.insecureParent, false);
});

test('a pre-existing valid token file is kept and not regenerated', () => {
  const original = 'a'.repeat(64);
  seedToken(original);

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.equal(token, original);
  assert.equal(regenerated, false);
});

test('a pre-existing 0644 file is rewritten to 0600 and the same token survives', () => {
  const original = 'a'.repeat(64);
  seedToken(original);
  chmodSync(tokenPath(configDir), 0o644);
  assert.equal(statSync(tokenPath(configDir)).mode & 0o777, 0o644);

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.equal(token, original, 'repair must not replace the token');
  assert.equal(regenerated, false);
  assert.equal(statSync(tokenPath(configDir)).mode & 0o777, 0o600);
});

test('a pre-existing 0777 file is rewritten to 0600 and the same token survives', () => {
  const original = 'b'.repeat(64);
  seedToken(original);
  chmodSync(tokenPath(configDir), 0o777);
  assert.equal(statSync(tokenPath(configDir)).mode & 0o777, 0o777);

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.equal(token, original, 'repair must not replace the token');
  assert.equal(regenerated, false);
  assert.equal(statSync(tokenPath(configDir)).mode & 0o777, 0o600);
});

test('an empty token file is regenerated instead of returned', () => {
  seedToken('');

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.match(token, /^[0-9a-f]{64}$/);
  assert.equal(regenerated, true);
});

test('a whitespace-only token file is regenerated', () => {
  seedToken('   \n\t');

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.match(token, /^[0-9a-f]{64}$/);
  assert.equal(regenerated, true);
});

test('a short token file is regenerated', () => {
  seedToken('deadbeef');

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.match(token, /^[0-9a-f]{64}$/);
  assert.equal(regenerated, true);
});

test('a 64-character non-hex token file is regenerated', () => {
  const bogus = 'z'.repeat(64);
  seedToken(bogus);

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.match(token, /^[0-9a-f]{64}$/);
  assert.notEqual(token, bogus);
  assert.equal(regenerated, true);
});

test('an upper-case hex token file is regenerated', () => {
  const bogus = 'A'.repeat(64);
  seedToken(bogus);

  const { token, regenerated } = loadOrCreateToken(configDir);

  assert.match(token, /^[0-9a-f]{64}$/);
  assert.notEqual(token, bogus);
  assert.equal(regenerated, true);
});

test('a symlinked token file is refused', () => {
  const dir = join(configDir, 'pi-handset');
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const target = join(configDir, 'somewhere-else');
  writeFileSync(target, 'a'.repeat(64), { mode: 0o600 });
  symlinkSync(target, tokenPath(configDir));

  assert.throws(() => loadOrCreateToken(configDir), /symlink/i);
});

test('a symlinked pi-handset directory is refused', () => {
  const real = join(configDir, 'real-dir');
  mkdirSync(real, { recursive: true, mode: 0o700 });
  symlinkSync(real, join(configDir, 'pi-handset'));

  assert.throws(() => loadOrCreateToken(configDir), /symlink/i);
});

test('a pre-existing 0755 pi-handset directory is repaired to 0700', () => {
  const dir = join(configDir, 'pi-handset');
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o755);
  assert.equal(statSync(dir).mode & 0o777, 0o755);

  loadOrCreateToken(configDir);

  assert.equal(statSync(dir).mode & 0o777, 0o700);
});

test('a group- or world-writable config dir is flagged but left untouched', () => {
  chmodSync(configDir, 0o777);

  const { insecureParent } = loadOrCreateToken(configDir);

  assert.equal(insecureParent, true);
  assert.equal(statSync(configDir).mode & 0o777, 0o777);
});

test('a private config dir is not flagged as insecure', () => {
  const { insecureParent } = loadOrCreateToken(configDir);
  assert.equal(insecureParent, false);
});

test('rotateToken mints a fresh token that differs from the current one', () => {
  const before = loadOrCreateToken(configDir).token;

  const rotated = rotateToken(configDir);

  assert.match(rotated, /^[0-9a-f]{64}$/);
  assert.notEqual(rotated, before);
  assert.equal(loadOrCreateToken(configDir).token, rotated);
});

test('rotateToken leaves the token file mode 0600', () => {
  loadOrCreateToken(configDir);

  rotateToken(configDir);

  assert.equal(statSync(tokenPath(configDir)).mode & 0o777, 0o600);
});

test('compareToken accepts the expected token', () => {
  const { token } = loadOrCreateToken(configDir);
  assert.equal(compareToken(token, token), true);
});

test('compareToken rejects a wrong token of the same length', () => {
  const { token } = loadOrCreateToken(configDir);
  const wrong = (token[0] === '0' ? '1' : '0') + token.slice(1);
  assert.equal(compareToken(wrong, token), false);
});

test('compareToken rejects a wrong token of a different length without throwing', () => {
  const { token } = loadOrCreateToken(configDir);
  assert.equal(compareToken('', token), false);
  assert.equal(compareToken(token + 'extra', token), false);
});

test('compareToken returns false, not a throw, for a non-string candidate', () => {
  const { token } = loadOrCreateToken(configDir);
  for (const candidate of [null, 42, {}, []]) {
    assert.equal(compareToken(candidate, token), false);
  }
});

test('resolveConfigDir uses an absolute XDG_CONFIG_HOME when set', () => {
  assert.equal(
    resolveConfigDir({ XDG_CONFIG_HOME: '/custom/config' }, '/home/someone'),
    '/custom/config',
  );
});

test('resolveConfigDir falls back to <home>/.config when XDG_CONFIG_HOME is unset', () => {
  assert.equal(resolveConfigDir({}, '/home/someone'), join('/home/someone', '.config'));
});

test('resolveConfigDir falls back when XDG_CONFIG_HOME is empty', () => {
  assert.equal(
    resolveConfigDir({ XDG_CONFIG_HOME: '' }, '/home/someone'),
    join('/home/someone', '.config'),
  );
});

test('resolveConfigDir falls back when XDG_CONFIG_HOME is relative', () => {
  assert.equal(
    resolveConfigDir({ XDG_CONFIG_HOME: 'relative/config' }, '/home/someone'),
    join('/home/someone', '.config'),
  );
});
