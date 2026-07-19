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
  // Flash-deal A/B price test popup (variant rides in meta.offer). See creators.js.
  "flash_shown", "flash_copied", "flash_dismiss", "flash_cta",
  // Giveaway page (giveaway.html) funnel. Web events, no device_id — the page posts them
  // to /api/ev. Powers the Giveaway tab on /stats:
  //   gw_view     -- the giveaway page was opened
  //   gw_download -- clicked "Download the macro free"
  //   gw_pro      -- clicked "Get Garden Macro Pro" (heads to /api/checkout?src=giveaway)
  // The paid steps are NOT here: they ride on the normal checkout/subscribe events tagged
  // with meta.src = "giveaway", so giveaway revenue is counted the same way as everywhere else.
  "gw_view", "gw_download", "gw_pro",
]);

// NOTE: the loyalty_* (50% off, 5h/20h runtime) and hint_* (20% off, post-session) popups
// were removed from the macro, so those events are no longer written or read anywhere.
// Historical rows may still sit in the `events` table; nothing queries them.

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
