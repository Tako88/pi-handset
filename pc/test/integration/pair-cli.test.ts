// Real-socket tests for the `pi-handset pair` client. No mocks: the client talks
// to a real control server, or to a real (absence of a) hub.

import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import type { Server, Socket } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { createControlServer } from '../../src/hub/control.ts';
import type { ControlServer } from '../../src/hub/control.ts';
import { controlSocketPath, writeDiscovery } from '../../src/hub/discovery.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { runPair } from '../../src/cli/pair.ts';

const pcRoot = fileURLToPath(new URL('../..', import.meta.url));
const mainEntry = fileURLToPath(new URL('../../src/cli/main.ts', import.meta.url));

let runtimeDir: string;
const servers: ControlServer[] = [];
const rawServers: Server[] = [];
const rawSockets: Socket[] = [];

beforeEach(() => {
  runtimeDir = mkdtempSync(join(tmpdir(), 'pi-handset-pair-'));
});

afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  for (const socket of rawSockets.splice(0)) socket.destroy();
  await Promise.all(
    rawServers.splice(0).map(
      (server) => new Promise<void>((resolve) => server.close(() => resolve())),
    ),
  );
  rmSync(runtimeDir, { recursive: true, force: true });
});

function io(): { stdout: string[]; stderr: string[]; out: (s: string) => void; err: (s: string) => void } {
  const stdout: string[] = [];
  const stderr: string[] = [];
  return {
    stdout,
    stderr,
    out: (text) => stdout.push(text),
    err: (text) => stderr.push(text),
  };
}

const lanInterface = {
  eth0: [
    {
      address: '192.168.1.10',
      netmask: '255.255.255.0',
      family: 'IPv4' as const,
      mac: '00:00:00:00:00:00',
      internal: false,
      cidr: '192.168.1.10/24',
    },
  ],
};

async function startServer(
  options: Partial<Parameters<typeof createControlServer>[0]> = {},
): Promise<ControlServer> {
  const server = await createControlServer({
    runtimeDir,
    viewerPort: 8787,
    lan: true,
    mint: () => createTicketStore().issue(),
    interfaces: lanInterface,
    ...options,
  });
  servers.push(server);
  return server;
}

test('runPair prints the grouped code, the TTL and the addresses', async () => {
  await startServer({ mint: () => 'ABCD2345' });
  const stream = io();
  const code = await runPair([], { stdout: stream.out, stderr: stream.err }, { runtimeDir });
  assert.equal(code, 0);
  const out = stream.stdout.join('');
  assert.match(out, /ABCD-2345/);
  assert.match(out, /5 minutes/);
  assert.match(out, /192\.168\.1\.10:8787/);
});

test('runPair prints no addresses and a note when the hub advertised none', async () => {
  await startServer({ lan: false, mint: () => 'ABCD2345' });
  const stream = io();
  const code = await runPair([], { stdout: stream.out, stderr: stream.err }, { runtimeDir });
  assert.equal(code, 0);
  const out = stream.stdout.join('');
  assert.match(out, /no addresses/i);
  assert.doesNotMatch(out, /192\.168\.1\.10/);
});

test('runPair renders a QR whose input is exactly the pairing URI', async () => {
  await startServer({ mint: () => 'ABCD-2345' });
  const stream = io();
  let rendered = '';
  const code = await runPair([], { stdout: stream.out, stderr: stream.err }, {
    runtimeDir,
    renderQr: (uri) => {
      rendered = uri;
      return 'QR\n';
    },
  });
  assert.equal(code, 0);
  assert.equal(
    rendered,
    'pidroid://pair?v=1&code=ABCD2345&port=8787&lan=192.168.1.10',
  );
  assert.match(stream.stdout.join(''), /QR/);
});

test('runPair exits non-zero with no hub when the socket does not exist', async () => {
  const stream = io();
  const code = await runPair([], { stdout: stream.out, stderr: stream.err }, { runtimeDir });
  assert.notEqual(code, 0);
  assert.match(stream.stderr.join(''), /no hub is running/);
});

test('runPair names the pid when a live record exists but the socket is missing', async () => {
  writeDiscovery(runtimeDir, {
    agentPort: 1111,
    viewerPort: 8787,
    pid: process.pid,
    startedAt: new Date().toISOString(),
    protocolVersion: 1,
  });
  const stream = io();
  const code = await runPair([], { stdout: stream.out, stderr: stream.err }, { runtimeDir });
  assert.notEqual(code, 0);
  assert.match(stream.stderr.join(''), new RegExp(`pid ${process.pid}`));
});

test('runPair rejects an unknown flag with exit 2', async () => {
  const stream = io();
  const code = await runPair(['--wat'], { stdout: stream.out, stderr: stream.err }, { runtimeDir });
  assert.equal(code, 2);
  assert.match(stream.stderr.join(''), /--wat/);
});

test('runPair gives up when the hub accepts the connection but never answers', { timeout: 3000 }, async () => {
  mkdirSync(join(runtimeDir, 'pi-handset'), { recursive: true, mode: 0o700 });
  rawServers.push(
    createServer((socket) => {
      rawSockets.push(socket);
      // Accept and stay silent: a wedged hub must not hang `pair` forever.
    }).listen(controlSocketPath(runtimeDir)),
  );
  const stream = io();
  const started = Date.now();
  const code = await runPair([], { stdout: stream.out, stderr: stream.err }, {
    runtimeDir,
    fetchTimeoutMs: 50,
  });
  assert.equal(code, 1);
  assert.ok(Date.now() - started < 2000, 'pair must not hang on a silent hub');
  assert.match(stream.stderr.join(''), /pi-handset pair:/);
});

test('runPair reports an invalid pairing payload instead of throwing', async () => {
  mkdirSync(join(runtimeDir, 'pi-handset'), { recursive: true, mode: 0o700 });
  rawServers.push(
    createServer((socket) => {
      rawSockets.push(socket);
      // `ok:true` but `lan=8.8.8.8` does not classify as LAN, so
      // `formatPairingUri` throws on a payload the client cannot trust.
      socket.end(
        `${JSON.stringify({
          v: 1,
          type: 'pairing',
          ok: true,
          code: 'ABCD2345',
          expiresInMs: 300000,
          viewerPort: 8787,
          addresses: [{ kind: 'lan', host: '8.8.8.8' }],
        })}\n`,
      );
    }).listen(controlSocketPath(runtimeDir)),
  );
  const stream = io();
  const code = await runPair([], { stdout: stream.out, stderr: stream.err }, { runtimeDir });
  assert.equal(code, 1);
  assert.match(stream.stderr.join(''), /invalid pairing payload/);
});

test('the main dispatcher exits 2 with usage for an unknown subcommand', async () => {
  const child = spawn(process.execPath, [mainEntry, 'wat'], {
    cwd: pcRoot,
    env: { ...process.env, PI_HANDSET_RUNTIME_DIR: runtimeDir },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += String(chunk);
  });
  const code = await new Promise<number | null>((resolve) => child.on('close', resolve));
  assert.equal(code, 2);
  assert.match(stderr, /usage/i);
});
