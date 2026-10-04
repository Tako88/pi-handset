/**
 * Client-side pairing copy, independent of `serve.ts` so `pair.ts` does not
 * pull in the supervisor module. The code is grouped `XXXX-XXXX` for reading,
 * and the TTL comes from the response (the client never assumes the hub's TTL).
 */
export function pairingCodeNotice(code: string, expiresInMs: number): string {
  const grouped =
    code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code;
  return `pi-droid pairing code: ${grouped} (valid for ${Math.round(expiresInMs / 60_000)} minutes)\n`;
}
