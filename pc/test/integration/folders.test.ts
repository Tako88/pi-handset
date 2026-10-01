// The PC folder module: path containment, directory listing caps, pi's
// trust-requiring-resource predicate, and pi's trust-store semantics.
//
// Every test crosses a real filesystem boundary — a real temp home, real
// symlinks, a real trust file. Nothing is mocked: the containment and
// truncation behaviours are exactly what mocks cannot show.

import assert from 'node:assert/strict';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, test } from 'node:test';

import {
  DEFAULT_MAX_DIR_BYTES,
  DEFAULT_MAX_DIR_ENTRIES,
  FolderError,
  TrustStoreError,
  canonicalizePath,
  getAgentDir,
  hasTrustRequiringResources,
  listDirectories,
  readTrustStore,
  resolveWithinHome,
  saveTrustDecision,
  trustDecision,
} from '../../src/hub/folders.ts';

const scratchDirs: string[] = [];

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'pi-droid-folders-test-'));
  scratchDirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
  scratchDirs.length = 0;
});

test('canonicalizePath realpaths an existing path and falls back to the raw path', () => {
  const home = scratch();
  const sub = join(home, 'sub');
  mkdirSync(sub);

  assert.equal(canonicalizePath(sub), realpathSync(sub));

  const missing = join(home, 'does-not-exist');
  assert.equal(canonicalizePath(missing), missing);
});

test('getAgentDir honors PI_CODING_AGENT_DIR (with ~ expansion) and falls back to home', () => {
  const home = scratch();

  assert.equal(getAgentDir({}, home), join(home, '.pi', 'agent'));
  assert.equal(
    getAgentDir({ PI_CODING_AGENT_DIR: join(home, 'agentdir') }, home),
    join(home, 'agentdir'),
  );
  assert.equal(
    getAgentDir({ PI_CODING_AGENT_DIR: '~/custom-agent' }, home),
    join(home, 'custom-agent'),
  );
});

test('resolveWithinHome accepts an in-home dir (trailing slash too) and rejects escapes', () => {
  const home = scratch();
  const inside = join(home, 'project');
  mkdirSync(inside);
  const file = join(home, 'notes.txt');
  writeFileSync(file, 'x');
  const outside = scratch();
  const outsideLink = join(home, 'link-out');
  symlinkSync(outside, outsideLink);

  assert.equal(resolveWithinHome(inside, home), canonicalizePath(inside));
  assert.equal(resolveWithinHome(inside + '/', home), canonicalizePath(inside));
  assert.equal(resolveWithinHome(home, home), canonicalizePath(home));

  assert.equal(resolveWithinHome('project', home), null, 'relative path');
  assert.equal(resolveWithinHome(join(home, '..'), home), null, "'..' escape");
  assert.equal(resolveWithinHome('', home), null, 'empty string');
  assert.equal(resolveWithinHome(join(home, 'missing'), home), null, 'nonexistent');
  assert.equal(resolveWithinHome(file, home), null, 'a file');
  assert.equal(
    resolveWithinHome(outsideLink, home),
    null,
    'a symlink whose target is outside home',
  );
});

test('resolveWithinHome rejects a sibling whose path shares the whole home prefix', () => {
  const base = scratch();
  const home = join(base, 'home');
  mkdirSync(home);
  const sibling = `${home}-sibling`;
  mkdirSync(sibling);

  assert.equal(
    resolveWithinHome(sibling, home),
    null,
    'a shared string prefix is not containment',
  );
  assert.throws(() => listDirectories(sibling, home), FolderError);
});

test('listDirectories lists the root: dotdirs in, files and outside symlinks out', () => {
  const home = scratch();
  mkdirSync(join(home, 'Beta'));
  mkdirSync(join(home, 'alpha'));
  mkdirSync(join(home, '.hidden'));
  mkdirSync(join(home, 'real'));
  symlinkSync(join(home, 'real'), join(home, 'zlink'));
  writeFileSync(join(home, 'afile.txt'), 'x');
  symlinkSync(scratch(), join(home, 'outlink'));
  symlinkSync(join(home, 'nowhere'), join(home, 'broken'));

  const listing = listDirectories(undefined, home);

  assert.equal(listing.root, canonicalizePath(home));
  assert.equal(listing.path, canonicalizePath(home));
  assert.deepEqual(
    listing.entries,
    ['.hidden', 'alpha', 'Beta', 'real', 'zlink'],
    'case-insensitive sort; dotdirs and in-home symlinks included; files, outside and broken symlinks excluded',
  );
  assert.equal(listing.truncated, false);
});

test('listDirectories lists a subdirectory and reports root and path', () => {
  const home = scratch();
  const sub = join(home, 'project');
  mkdirSync(join(sub, 'a'), { recursive: true });

  const listing = listDirectories(sub, home);

  assert.equal(listing.root, canonicalizePath(home));
  assert.equal(listing.path, canonicalizePath(sub));
  assert.deepEqual(listing.entries, ['a']);
});

test('listDirectories truncates at maxEntries and only marks a real cut', () => {
  const home = scratch();
  for (let i = 0; i < 5; i += 1) mkdirSync(join(home, `d${i}`));

  const capped = listDirectories(undefined, home, { maxEntries: 3 });
  assert.equal(capped.entries.length, 3);
  assert.deepEqual(capped.entries, ['d0', 'd1', 'd2']);
  assert.equal(capped.truncated, true);

  const exact = listDirectories(undefined, home, { maxEntries: 5 });
  assert.equal(exact.entries.length, 5);
  assert.equal(exact.truncated, false, 'an exact fit is not a truncation');
});

test('listDirectories truncates at maxBytes and marks truncated', () => {
  const home = scratch();
  const long = 'x'.repeat(100);
  mkdirSync(join(home, long));
  mkdirSync(join(home, 'second-long-name'));

  const capped = listDirectories(undefined, home, { maxBytes: 110 });
  assert.equal(capped.entries.length, 1, 'only the first name fits the byte cap');
  assert.equal(capped.truncated, true);

  const none = listDirectories(undefined, home, { maxBytes: 10 });
  assert.equal(none.entries.length, 0);
  assert.equal(none.truncated, true);
});

test('listDirectories treats a non-finite cap as the default, not as no cap', () => {
  const home = scratch();
  for (let i = 0; i <= DEFAULT_MAX_DIR_ENTRIES; i += 1) mkdirSync(join(home, `d${i}`));

  const nan = listDirectories(undefined, home, { maxEntries: Number.NaN });
  assert.equal(nan.entries.length, DEFAULT_MAX_DIR_ENTRIES, 'NaN falls back to the default cap');
  assert.equal(nan.truncated, true);
});

test('listDirectories throws FolderError for outside, relative and nonexistent targets', () => {
  const home = scratch();
  const outside = scratch();

  assert.throws(() => listDirectories(outside, home), FolderError);
  assert.throws(() => listDirectories('relative/path', home), FolderError);
  assert.throws(() => listDirectories(join(home, 'missing'), home), FolderError);
});

test('the default listing caps exist', () => {
  assert.equal(DEFAULT_MAX_DIR_ENTRIES, 500);
  assert.equal(DEFAULT_MAX_DIR_BYTES, 256 * 1024);
});

test('hasTrustRequiringResources mirrors pi: .pi/* in cwd, .agents/skills in cwd and ancestors', () => {
  const home = scratch();

  const withSettings = join(home, 'with-settings');
  mkdirSync(join(withSettings, '.pi'), { recursive: true });
  writeFileSync(join(withSettings, '.pi', 'settings.json'), '{}');
  assert.equal(hasTrustRequiringResources(withSettings, home), true);

  const plain = join(home, 'plain');
  mkdirSync(plain);
  assert.equal(hasTrustRequiringResources(plain, home), false);

  const parent = join(home, 'parent');
  const child = join(parent, 'child');
  mkdirSync(join(parent, '.agents', 'skills'), { recursive: true });
  mkdirSync(child, { recursive: true });
  assert.equal(hasTrustRequiringResources(child, home), true, 'ancestor .agents/skills');

  const homeWithSkills = scratch();
  mkdirSync(join(homeWithSkills, '.agents', 'skills'), { recursive: true });
  const under = join(homeWithSkills, 'under');
  mkdirSync(under);
  assert.equal(
    hasTrustRequiringResources(under, homeWithSkills),
    false,
    "the user's own <home>/.agents/skills is excluded",
  );
});

test('trustDecision reads exact and nearest-ancestor decisions, skipping null', () => {
  const home = scratch();
  const project = join(home, 'project');
  const sub = join(project, 'sub');
  mkdirSync(sub, { recursive: true });
  const trustPath = join(home, 'trust.json');

  saveTrustDecision(trustPath, project, true);
  assert.equal(trustDecision(trustPath, project), true);
  assert.equal(trustDecision(trustPath, sub), true, 'ancestor decision applies');

  saveTrustDecision(trustPath, home, false);
  assert.equal(trustDecision(trustPath, sub), true, 'nearest ancestor wins');

  saveTrustDecision(trustPath, sub, null);
  assert.equal(
    trustDecision(trustPath, sub),
    true,
    'a null value is skipped and the walk continues',
  );

  assert.equal(trustDecision(trustPath, scratch()), null, 'no entry → null');
});

test('trustDecision returns {} semantics for a missing store and throws TrustStoreError on bad stores', () => {
  const home = scratch();
  const missing = join(home, 'missing.json');
  assert.equal(trustDecision(missing, home), null);
  assert.deepEqual(readTrustStore(missing), {});

  const malformed = join(home, 'malformed.json');
  writeFileSync(malformed, '{ not json');
  assert.throws(() => trustDecision(malformed, home), TrustStoreError);
  assert.throws(() => readTrustStore(malformed), TrustStoreError);

  const nonObject = join(home, 'non-object.json');
  writeFileSync(nonObject, '[]');
  assert.throws(() => trustDecision(nonObject, home), TrustStoreError);

  const badValue = join(home, 'bad-value.json');
  writeFileSync(badValue, JSON.stringify({ '/somewhere': 'yes' }));
  assert.throws(() => trustDecision(badValue, home), TrustStoreError);
});

test('saveTrustDecision creates parents, merges, sorts and ends with a newline', () => {
  const home = scratch();
  const trustPath = join(home, 'nested', 'dir', 'trust.json');
  const project = join(home, 'project');
  mkdirSync(project);

  saveTrustDecision(trustPath, project, true);
  assert.ok(existsSync(trustPath), 'missing parent directories are created');

  const raw = readFileSync(trustPath, 'utf8');
  assert.ok(raw.endsWith('\n'), 'the store ends with a newline');
  assert.deepEqual(JSON.parse(raw), { [canonicalizePath(project)]: true });

  saveTrustDecision(trustPath, join(home, 'other'), false);
  const parsed = JSON.parse(readFileSync(trustPath, 'utf8')) as Record<string, unknown>;
  assert.deepEqual(
    Object.keys(parsed),
    [...Object.keys(parsed)].sort(),
    'keys are written sorted',
  );
  assert.equal(parsed[canonicalizePath(project)], true, 'existing keys are preserved');
  assert.equal(parsed[canonicalizePath(join(home, 'other'))], false);
});

test('saveTrustDecision refuses a malformed store and leaves it byte-identical', () => {
  const home = scratch();
  const trustPath = join(home, 'trust.json');
  writeFileSync(trustPath, '{ oops');
  const before = readFileSync(trustPath);

  assert.throws(() => saveTrustDecision(trustPath, home, true), TrustStoreError);
  assert.deepEqual(readFileSync(trustPath), before, 'the store must be untouched');
});
