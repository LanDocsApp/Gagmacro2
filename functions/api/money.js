// GET /api/money?key=<STATS_KEY> — the Money tab's data (active subs, MRR, this-month
// money, and the per-promotion-code redemption/earnings table). Split from /api/stats
// so the fast D1-only tabs (Overview, Acquisition) never pay for the heavy Stripe scan;
// stats.html fetches this lazily, only when the Money tab is opened.
//
// Gated by STATS_KEY exactly like /api/stats (fails CLOSED when the key is unset).
// All Stripe work degrades to null fields ("—" in the UI) and returns HTTP 200 — a
// Stripe outage must never 500 or blank the whole dashboard. See _lib/money.js for the
// net-settled (balance_transaction.net) money model and the Stripe API-version pin.

import { json } from "../_lib/http.js";
import { buildMoneySnapshot } from "../_lib/money.js";

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const key = url.searchParams.get("key") || "";

  if (!env.STATS_KEY || key !== env.STATS_KEY) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!env.STRIPE_SECRET_KEY) {
    // Stripe not configured -> respond 200 with empty/null money so the tab shows "—".
    return json({ error: "stripe not configured", codes: [], codesAvailable: false, at: Date.now() });
  }

  try {
    return json(await buildMoneySnapshot(env));
  } catch {
    // Last-resort guard: never 500 the dashboard over Stripe, and don't echo raw Stripe
    // error text (price/promo ids, version mismatches) back to the key holder.
    return json({ error: "money query failed", codes: [], codesAvailable: false, at: Date.now() }, 200);
  }
}
