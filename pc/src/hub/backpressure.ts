/**
 * A per-viewer outgoing byte budget.
 *
 * The hub relays normalized events without understanding them, but it must not
 * let one slow viewer grow the hub's memory without bound. Bytes are reserved
 * when a message is handed to the socket and released when the socket reports
 * the write complete. A message that would push the outstanding total past the
 * cap is dropped **whole** — never partially sent — and the hub tells the
 * viewer to resync. The viewer answers with a `history-request`, and the hub's
 * tracked `lastSeq`/`agentState` make the resulting `snapshot` recoverable.
 *
 * Pure: no I/O, no clock. The hub owns the policy (when to announce a resync);
 * this class only keeps the arithmetic.
 */
export class ByteBudget {
  readonly cap: number;
  #queued = 0;

  constructor(cap: number) {
    this.cap = cap;
  }

  /**
   * Reserves `bytes` when the message fits; returns false when it must be
   * dropped. A rejected message is not accounted for.
   */
  admit(bytes: number): boolean {
    if (this.#queued + bytes > this.cap) return false;
    this.#queued += bytes;
    return true;
  }

  /** Releases `bytes` once the socket has written that message out. */
  drain(bytes: number): void {
    this.#queued = Math.max(0, this.#queued - bytes);
  }

  /** Bytes handed to the socket and not yet reported written. */
  get queued(): number {
    return this.#queued;
  }
}
