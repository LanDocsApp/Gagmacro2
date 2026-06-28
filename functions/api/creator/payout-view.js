// POST /api/creator/payout-view — read-only payout summary FOR A CREATOR.
//
// Auth: the creator's signed dashboard token ONLY (no STATS_KEY). This is the
// creator-facing read path, so it must never expose the disbursement ledger's write
// side or any customer PII. The admin write path (record/delete a payout) stays in
// /api/creator/payout, which requires STATS_KEY + token.
//
// Body { token }. Returns:
//   { name, codes, currency,
//     earned:  { subs, moneyCents },   // from Stripe: redemptions + net-settled month-1 revenue
//     paidOut: { subs, moneyCents },   // from the D1 payouts ledger (what you've disbursed)
//     pending: { subs, moneyCents },   // earned - paidOut (clamped >= 0)
//     redemptions: [{ at, code, amountCents, status }],   // NO PII (no email/name/ids)
//     available, at }
// earned/pending read null ("—") when Stripe is unreachable; paidOut (pure D1) always shows.

import { json } from "../../_lib/http.js";
import { verifyToken } from "../../_lib/crypto.js";
import { getCreator } from "../../_lib/creators.js";
import { buildCreatorEarnings } from "../../_lib/money.js";

export async function onRequestPost({ request, env }) {
  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const token = String(body.token || body.t || "").trim();

  const payload = await verifyToken(env.COOKIE_SECRET, "creator", token);
  if (!payload || payload.t !== "creator" || !payload.id) {
    return json({ error: "bad token" }, 401);
  }
  const creator = getCreator(payload.id);
  if (!creator) return json({ error: "unknown creator" }, 404);

  // Paid-out from the D1 ledger — always available, independent of Stripe.
  let paidSubs = 0;
  let paidCents = 0;
  try {
    if (env.STATS) {
      const agg = await env.STATS.prepare(
        `SELECT COALESCE(SUM(subscribers),0) AS s, COALESCE(SUM(amount_cents),0) AS c
         FROM payouts WHERE creator_id = ?1`
      )
        .bind(creator.id)
        .first();
      paidSubs = (agg && agg.s) || 0;
      paidCents = (agg && agg.c) || 0;
    }
  } catch {
    /* ledger absent -> 0 paid out */
  }

  // Earned (Stripe). Defensive: any failure -> nulls, never a 500.
  let earn = { currency: null, earnedSubs: null, earnedMoneyCents: null, redemptions: [], available: false };
  try {
    if (env.STRIPE_SECRET_KEY) earn = await buildCreatorEarnings(env, creator);
  } catch {
    /* keep nulls */
  }

  const pendSubs = earn.earnedSubs != null ? Math.max(0, earn.earnedSubs - paidSubs) : null;
  const pendCents = earn.earnedMoneyCents != null ? Math.max(0, earn.earnedMoneyCents - paidCents) : null;

  return json({
    name: creator.name,
    codes: creator.codes,
    currency: earn.currency,
    earned: { subs: earn.earnedSubs, moneyCents: earn.earnedMoneyCents },
    paidOut: { subs: paidSubs, moneyCents: paidCents },
    pending: { subs: pendSubs, moneyCents: pendCents },
    redemptions: earn.redemptions,
    available: earn.available,
    at: Date.now(),
  });
}
