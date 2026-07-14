// Best-effort event logging for the conversion funnel (see migrations/0003_add_events.sql).
//
// Writes one row into the STATS D1 `events` table. Wrapped so a missing table or a
// transient D1 error can NEVER break the calling flow (heartbeat, checkout, webhook).
// Returns true on success, false if it was skipped or swallowed an error.

const ALLOWED = new Set([
  "get_access", "checkout", "subscribe",
  // Device-linked premium unlock: fired by the macro (with device_id) when the user first
  // activates a valid access code. Unlike "subscribe" (a web-only Stripe webhook step with
  // no device_id), this can be tied back to the install, so /api/stats can measure how long
  // each install took to upgrade (first_seen -> first unlock).
  "unlock",
  "hint_shown", "hint_copied", "hint_dismiss", "hint_cta",
  "loyalty_shown", "loyalty_copied", "loyalty_dismiss", "loyalty_cta",
  // Flash-deal A/B price test popup (variant rides in meta.offer). See creators.js.
  "flash_shown", "flash_copied", "flash_dismiss", "flash_cta",
]);

export async function logEvent(env, name, opts = {}) {
  if (!env || !env.STATS || !ALLOWED.has(name)) return false;
  const ts = Number.isFinite(opts.ts) ? opts.ts : Date.now();
  const deviceId = opts.deviceId ? String(opts.deviceId).slice(0, 64) : null;
  const meta = opts.meta == null ? null : JSON.stringify(opts.meta).slice(0, 512);
  try {
    await env.STATS.prepare(
      `INSERT INTO events (ts, name, device_id, meta) VALUES (?1, ?2, ?3, ?4)`
    )
      .bind(ts, name, deviceId, meta)
      .run();
    return true;
  } catch {
    // `events` table not created yet, or a transient D1 hiccup. Never propagate.
    return false;
  }
}
