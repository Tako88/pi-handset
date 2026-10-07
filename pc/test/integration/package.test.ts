import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

// `pc/` is installed with `pi install <checkout>/pc`, so these two files decide
// what pi loads. Both are easy to break silently: a renamed manifest entry loads
// nothing, and a lost ignore pattern loads the bridge's test file as a live
// extension.

const packageDir = fileURLToPath(new URL('../..', import.meta.url));

const manifest = JSON.parse(
  readFileSync(join(packageDir, 'package.json'), 'utf8'),
) as { pi?: { extensions?: string[] } };

test('the pi manifest names the bridge, and the bridge exists', () => {
  const entries = manifest.pi?.extensions ?? [];
  assert.ok(
    entries.includes('./extensions/pi-handset-bridge.ts'),
    `the manifest does not name the bridge: ${JSON.stringify(entries)}`,
  );
  for (const entry of entries) {
    assert.ok(
      existsSync(join(packageDir, entry)),
      `manifest entry does not exist: ${entry}`,
    );
  }
});

// pi loads every .ts/.js under a package's extensions/ directory, so the ignore
// file is what keeps the bridge's own test from becoming a live extension.
test('the extensions .ignore hides the bridge test from pi', () => {
  const patterns = readFileSync(join(packageDir, 'extensions/.ignore'), 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '' && !line.startsWith('#'));
  assert.ok(
    patterns.includes('*.test.ts'),
    `no *.test.ts pattern in extensions/.ignore: ${JSON.stringify(patterns)}`,
  );
  assert.ok(
    existsSync(join(packageDir, 'extensions/pi-handset-bridge.test.ts')),
    'the ignore pattern guards nothing: no bridge test file exists',
  );
});
