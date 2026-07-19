// POST /api/ev — tiny public event beacon for the WEB pages (currently giveaway.html).
//
// Body: { "n": "<event name>", "g": "<giveaway id?>" }
//
// The macro reports its funnel through /api/ping (which carries a device_id). Web pages
// have no device id and no session at the point we care about (a logged-out visitor
// clicking "Download the macro free"), so they post here instead. Powers the Giveaway tab
// on /stats.
//
// Deliberately narrow, because this is an UNAUTHENTICATED write path:
//   - only the three gw_* names are accepted; anything else is dropped on the floor
//   - the only client-controlled payload is a giveaway id, length-capped and charset-checked
//   - no PII, no free-form meta, no counters the client can set
// Worst case someone can inflate three vanity counters on a private dashboard, which is
// proportionate to the value of the data. The paid steps deliberately do NOT go through
// here — checkout/subscribe are logged server-side (checkout.js / webhook.js) tagged with
// meta.src = "giveaway", so money can never be faked from the browser.
//
// Fire-and-forget from the client: always returns 200 quickly and never errors out loud,
// so a stats hiccup can never break the giveaway page.

import { json } from "../_lib/http.js";
import { logEvent } from "../_lib/events.js";

// Web funnel events this beacon is allowed to report (keeps logEvent's allowlist in
// sync at the parse boundary):
//   gw_view     -- the giveaway page was opened
//   gw_download -- clicked "Download the macro free"
//   gw_pro      -- clicked "Get Garden Macro Pro"
const WEB_EVENTS = new Set(["gw_view", "gw_download", "gw_pro"]);

export async function onRequestPost({ request, env }) {
  let name = "";
  let giveaway = "";
  try {
    const body = await request.json();
    name = String((body && body.n) || "").trim().toLowerCase();
    if (!WEB_EVENTS.has(name)) name = "";
    giveaway = String((body && body.g) || "").trim().slice(0, 32).toLowerCase();
    if (giveaway && !/^[a-z0-9_-]{1,32}$/.test(giveaway)) giveaway = "";
  } catch {
    name = "";
  }

  if (name) {
    // logEvent swallows a missing `events` table / transient D1 error on its own.
    await logEvent(env, name, { meta: giveaway ? { g: giveaway } : null });
  }

  return json({ ok: true });
}
