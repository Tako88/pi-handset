/** Reconnect backoff: exponential with full jitter, capped. */

const BACKOFF_BASE_MS = 500;
const BACKOFF_CAP_MS = 30_000;
/**
 * The fixed wait after a `4008` (rate-limited) close: the hub deliberately
 * delays that close, so retrying sooner would only add load. Longer than the
 * first backoff step by construction.
 */
export const RATE_LIMITED_RECONNECT_MS = 30_000;

export interface BackoffOptions {
  rng?: () => number;
}

/** Exponential backoff with full jitter, capped. `attempt` is 0-based. */
export function computeBackoff(attempt: number, options: BackoffOptions = {}): number {
  const rng = options.rng ?? Math.random;
  const ceiling = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** Math.max(0, attempt));
  return Math.floor(rng() * ceiling);
}
