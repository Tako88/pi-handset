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
) as {
  pi?: { extensions?: string[] };
  bin?: Record<string, string>;
  scripts?: Record<string, string>;
};

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

// The CLI is installed as a command by linking this package, so the manifest
// decides both the name and the entry point. A typo in either makes
// `pi-handset serve` unrunnable, and a target with no shebang makes the linked
// command fail to execute — both silent until someone tries it.
test('the manifest declares a runnable pi-handset bin', () => {
  const target = manifest.bin?.['pi-handset'];
  assert.equal(
    typeof target,
    'string',
    `no pi-handset bin: ${JSON.stringify(manifest.bin)}`,
  );
  const entry = join(packageDir, target as string);
  assert.ok(existsSync(entry), `bin target does not exist: ${target}`);
  const firstLine = readFileSync(entry, 'utf8').split('\n')[0];
  assert.equal(
    firstLine,
    '#!/usr/bin/env node',
    `bin target is not a node script: ${firstLine}`,
  );
});

// `npm run serve` is the path that works without linking the package, so the
// scripts must stay pointed at the same entry point the bin uses.
test('the manifest exposes serve and pair as npm scripts', () => {
  for (const command of ['serve', 'pair']) {
    const script = manifest.scripts?.[command] ?? '';
    assert.match(
      script,
      new RegExp(`src/cli/main\\.ts ${command}$`),
      `the ${command} script does not run the CLI: ${script}`,
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
