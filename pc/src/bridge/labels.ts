/** Session labels: sanitized, code-point-bounded snippets. */

/** The label's cap in Unicode code points, not UTF-16 units, so truncation
 * never leaves a lone surrogate. */
export const LABEL_MAX_CODE_POINTS = 80;

/**
 * Extracts the text of a pi message content value: a string verbatim, or the
 * joined `text` of its `{type:'text'}` parts. An image (or any other) part
 * contributes nothing; an unrecognized shape is empty text.
 */
export function messageText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => {
      if (typeof part !== 'object' || part === null) return '';
      const candidate = part as { type?: unknown; text?: unknown };
      return candidate.type === 'text' && typeof candidate.text === 'string'
        ? candidate.text
        : '';
    })
    .join(' ');
}

/**
 * The snippet cap in Unicode code points, not UTF-16 units, so a slice never
 * leaves a lone surrogate. Deliberately the wire cap, larger than the app's
 * visible cap (140); keep that ordering if either changes.
 */
export const SETTLED_TEXT_MAX_CODE_POINTS = 200;

/**
 * Bounds a turn's final assistant text to `maxCodePoints` code points for a
 * notification body. Text that fits is returned untouched; a longer string is
 * sliced and flagged `truncated`.
 */
export function settleText(
  text: string,
  maxCodePoints: number,
): { text: string; truncated: boolean } {
  const points = Array.from(text);
  if (points.length <= maxCodePoints) return { text, truncated: false };
  return { text: points.slice(0, maxCodePoints).join(''), truncated: true };
}

/**
 * Trims a raw label to a single sanitized line of at most
 * `LABEL_MAX_CODE_POINTS` code points, or `null` when there is nothing usable.
 * Control characters (including newlines) collapse to spaces, mirroring pi's
 * own session-selector sanitizer; the code-point truncation never splits a
 * surrogate pair.
 */
export function sanitizeLabel(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (cleaned.length === 0) return null;
  return Array.from(cleaned).slice(0, LABEL_MAX_CODE_POINTS).join('');
}

/** The label a single transcript entry contributes: a user message's text, or
 * `null` for any other role (and for an image-only user message). */
export function labelFromMessage(message: unknown): string | null {
  if (typeof message !== 'object' || message === null) return null;
  const candidate = message as { role?: unknown; content?: unknown };
  if (candidate.role !== 'user') return null;
  return sanitizeLabel(messageText(candidate.content));
}

/**
 * The last user prompt among transcript entries, or `null`.
 *
 * REGISTER/RECONNECT-TIME ONLY. Real pi persists a message with
 * `sessionManager.appendMessage` *after* it awaits the `message_end` extension
 * event (`agent-session.js`), so a scan of entries during a live turn is stale
 * by one prompt. The live path reads the event's own message
 * (`labelFromMessage`), never this.
 */
export function labelFromEntries(entries: readonly unknown[]): string | null {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (typeof entry !== 'object' || entry === null) continue;
    const label = labelFromMessage((entry as { message?: unknown }).message);
    if (label !== null) return label;
  }
  return null;
}
