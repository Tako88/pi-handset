// Real-socket tests for the hub control server. No mocks: a real Unix socket
// is bound, a real client connects, and the ready signal is awaited (never a
// sleep).

import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import { mkdtempSync, statSync, lstatSync, symlinkSync, unlinkSync } from 'node:fs';
import { createServer, connect } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { rmSync } from 'node:fs';

import { controlSocketPath, ensureDiscoveryDir } from '../../src/hub/discovery.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { createControlServer } from '../../src/hub/control.ts';
import type { ControlServer } from '../../src/hub/control.ts';

let runtimeDir: string;
const servers: ControlServer[] = [];

beforeEach(() => {
  runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-control-'));
});

afterEach(async () => {
  for (const server of servers.splice(0)) {
    await server.close();
  }
  rmSync(runtimeDir, { recursive: true, force: true });
});

function socketPath(): string {
  return controlSocketPath(runtimeDir);
}

/** A control server over the real ticket store, with a mix of interfaces. */
function start(overrides: Partial<Parameters<typeof createControlServer>[0]> = {}) {
  const tickets = createTicketStore();
  const promise = createControlServer({
    runtimeDir,
    viewerPort: 8787,
    lan: true,
    mint: () => tickets.issue(),
    interfaces: {
      eth0: [
        {
          address: '192.168.1.10',
          netmask: '255.255.255.0',
          family: 'IPv4',
          mac: '00:00:00:00:00:00',
          internal: false,
          cidr: '192.168.1.10/24',
        },
      ],
      tailscale0: [
        {
          address: '100.64.1.2',
          netmask: '255.255.255.0',
          family: 'IPv4',
          mac: '00:00:00:00:00:00',
          internal: false,
          cidr: '100.64.1.2/24',
        },
      ],
    },
    ...overrides,
  });
  return { promise, tickets };
}

async function remember(promise: Promise<ControlServer>): Promise<ControlServer> {
  const server = await promise;
  servers.push(server);
  return server;
}

/** Sends one raw payload and resolves with everything received before close. */
function exchange(payload: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath());
    let data = '';
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(payload));
    socket.on('data', (chunk) => {
      data += chunk.toString('utf8');
    });
    socket.on('error', reject);
    socket.on('close', () => resolve(data));
  });
}

function pairRequest(extra: Record<string, unknown> = {}): string {
  return `${JSON.stringify({ v: 1, type: 'pair', ...extra })}\n`;
}

test('a pair request answers ok with a canonical code, the port and addresses', async () => {
  await remember(start().promise);
  const raw = await exchange(pairRequest());
  const response = JSON.parse(raw) as Record<string, unknown>;
  assert.equal(response.ok, true);
  assert.match(String(response.code), /^[0-9A-Z]{8}$/);
  assert.equal(response.expiresInMs, 300000);
  assert.equal(response.viewerPort, 8787);
  assert.deepEqual(response.addresses, [
    { kind: 'lan', host: '192.168.1.10' },
    { kind: 'ts', host: '100.64.1.2' },
  ]);
});

test('the control socket is 0600 and lives under the runtime pi-droid dir', async () => {
  await remember(start().promise);
  assert.equal(socketPath(), join(runtimeDir, 'pi-droid', 'control.sock'));
  assert.equal(statSync(socketPath()).mode & 0o777, 0o600);
});

test('two requests mint two different codes', async () => {
  await remember(start().promise);
  const first = JSON.parse(await exchange(pairRequest())) as Record<string, unknown>;
  const second = JSON.parse(await exchange(pairRequest())) as Record<string, unknown>;
  assert.notEqual(first.code, second.code);
});

test('the advertised code is redeemable by the ticket store the server was given', async () => {
  const { promise, tickets } = start();
  await remember(promise);
  const response = JSON.parse(await exchange(pairRequest())) as Record<string, unknown>;
  assert.deepEqual(tickets.redeem(String(response.code)), { ok: true });
});

test('a malformed request is answered ok:false and the server keeps serving', async () => {
  await remember(start().promise);
  const bad = JSON.parse(await exchange('not json\n')) as Record<string, unknown>;
  assert.equal(bad.ok, false);
  assert.equal(bad.error, 'malformed request');
  const good = JSON.parse(await exchange(pairRequest())) as Record<string, unknown>;
  assert.equal(good.ok, true, 'the server must survive a malformed request');
});

test('an unsupported control version is answered ok:false', async () => {
  await remember(start().promise);
  const response = JSON.parse(
    await exchange(`${JSON.stringify({ v: 2, type: 'pair' })}\n`),
  ) as Record<string, unknown>;
  assert.deepEqual(response, {
    v: 1,
    type: 'pairing',
    ok: false,
    error: 'unsupported control protocol version',
  });
});

test('an unknown request type is answered ok:false', async () => {
  await remember(start().promise);
  const response = JSON.parse(
    await exchange(`${JSON.stringify({ v: 1, type: 'dance' })}\n`),
  ) as Record<string, unknown>;
  assert.equal(response.ok, false);
  assert.equal(response.error, 'unknown request type');
});

test('with lan:false the response advertises no port and no addresses', async () => {
  await remember(start({ lan: false }).promise);
  const response = JSON.parse(await exchange(pairRequest())) as Record<string, unknown>;
  assert.equal(response.ok, true);
  assert.equal(response.viewerPort, null);
  assert.deepEqual(response.addresses, []);
});

test('when mint returns null the request is refused and no code is issued', async () => {
  await remember(start({ mint: () => null }).promise);
  const response = JSON.parse(await exchange(pairRequest())) as Record<string, unknown>;
  assert.equal(response.ok, false);
  assert.equal(response.error, 'cannot mint');
});

test('when mint throws the request is refused, not an uncaught rejection', async () => {
  await remember(
    start({
      mint: () => {
        throw new Error('randomness exhausted');
      },
    }).promise,
  );
  const response = JSON.parse(await exchange(pairRequest())) as Record<string, unknown>;
  assert.equal(response.ok, false);
  assert.equal(response.error, 'cannot mint');
});

test('a request line over the byte cap is refused and the connection closed', async () => {
  await remember(start().promise);
  const raw = await exchange(`${'a'.repeat(5000)}\n`);
  const response = JSON.parse(raw) as Record<string, unknown>;
  assert.equal(response.ok, false);
  assert.equal(response.error, 'request too large');
});

test('after close the socket file is gone and a reconnect fails', async () => {
  const server = await start().promise;
  await server.close();
  assert.equal(existsSyncSafe(socketPath()), false);
  // Either the path is gone (ENOENT) or a leftover listener refuses; both fail.
  await assert.rejects(exchange(pairRequest()), /ECONNREFUSED|ENOENT/);
});

test('close does not unlink a socket file it does not own', async () => {
  const server = await start().promise;
  // An external server rebinds the same path (a fresh inode); the original's
  // close must leave the new owner's file alone.
  unlinkSync(socketPath());
  const external = createServer();
  await new Promise<void>((resolve) => external.listen(socketPath(), () => resolve()));
  const externalIno = lstatSync(socketPath()).ino;

  await server.close();
  assert.equal(lstatSync(socketPath()).ino, externalIno, 'the new owner keeps its file');
  await new Promise<void>((resolve) => external.close(() => resolve()));
});

test('close refuses to unlink a symlinked socket path', async () => {
  const server = await start().promise;
  unlinkSync(socketPath());
  const target = join(runtimeDir, 'elsewhere');
  symlinkSync(target, socketPath());
  await server.close();
  assert.equal(lstatSync(socketPath()).isSymbolicLink(), true, 'the symlink is left alone');
});

test('close is fine when someone else already removed the socket file', async () => {
  const server = await start().promise;
  unlinkSync(socketPath());
  await server.close();
});

test('a client that sends nothing is closed by the request timeout', async () => {
  await remember(start({ requestTimeoutMs: 20 }).promise);
  await new Promise<void>((resolve, reject) => {
    const socket = connect(socketPath());
    socket.on('connect', () => {
      // Send nothing.
    });
    socket.on('close', () => resolve());
    socket.on('error', reject);
    setTimeout(() => reject(new Error('the idle client was not closed')), 2000).unref();
  });
});

function existsSyncSafe(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

// Keep the import used so the intent (a `0700` parent is ensured) is explicit.
void ensureDiscoveryDir;
