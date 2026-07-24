// POST /api/creator/payout-view — read-only payout summary FOR A CREATOR.
//
// Auth: the creator's signed dashboard token ONLY (no STATS_KEY). This is the
// creator-facing read path, so it must never expose the disbursement ledger's write
// side or any customer PII. The admin write path (record/delete a payout) stays in
// /api/creator/payout, which requires STATS_KEY + token.
//
// Body { token }. Returns:
//   { name, codes, currency,
//     earned:  { subs, moneyCents },   // Stripe net-settled month-1 revenue + manual bonuses
//     paidOut: { subs, moneyCents },   // from the D1 payouts ledger (kind='payout' = disbursed)
//     pending: { subs, moneyCents },   // earned - paidOut (clamped >= 0)
//     bonus:   { moneyCents },         // manual credits owed (D1 payouts, any non-payout kind)
//     redemptions: [{ at, code, amountCents, status }],   // NO PII; credits appear as status='bonus'|'promo'
//     available, at }
// earned/pending read null ("—") when Stripe is unreachable; paidOut/bonus (pure D1) always show.

import { json } from "../../_lib/http.js";
import { verifyToken } from "../../_lib/crypto.js";
import { getCreator } from "../../_lib/creators.js";
import { buildCreatorEarnings, SQL_IS_PAYOUT } from "../../_lib/money.js";

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

  // D1 ledger — always available, independent of Stripe. Two classes of row:
  //   kind='payout'      -> money already paid OUT (reduces what's owed)
  //   any other kind     -> a credit OWED on top of Stripe earnings (raises earned/pending);
  //                         'bonus' = thank-you, 'promo' = agreed sponsored-video fee
  let paidSubs = 0;
  let paidCents = 0;
  let bonusCents = 0;
  let bonusRows = [];
  try {
    if (env.STATS) {
      const agg = await env.STATS.prepare(
        `SELECT
           COALESCE(SUM(CASE WHEN ${SQL_IS_PAYOUT} THEN subscribers  ELSE 0 END), 0) AS paid_s,
           COALESCE(SUM(CASE WHEN ${SQL_IS_PAYOUT} THEN amount_cents ELSE 0 END), 0) AS paid_c,
           COALESCE(SUM(CASE WHEN ${SQL_IS_PAYOUT} THEN 0 ELSE amount_cents END), 0) AS bonus_c
         FROM payouts WHERE creator_id = ?1`
      )
        .bind(creator.id)
        .first();
      paidSubs = (agg && agg.paid_s) || 0;
      paidCents = (agg && agg.paid_c) || 0;
      bonusCents = (agg && agg.bonus_c) || 0;

      // Individual credit entries -> shown as "Bonus"/"Promo" line items in the earnings
      // list, so the creator can see what each credit was for.
      const br = await env.STATS.prepare(
        `SELECT amount_cents, note, created_at, kind FROM payouts
         WHERE creator_id = ?1 AND NOT (${SQL_IS_PAYOUT}) ORDER BY created_at DESC LIMIT 100`
      )
        .bind(creator.id)
        .all();
      bonusRows = ((br && br.results) || []).map((r) => {
        const kind = r.kind === "promo" ? "promo" : "bonus";
        return {
          at: r.created_at,
          code: (r.note && String(r.note).trim()) || (kind === "promo" ? "Promo" : "Bonus"),
          amountCents: r.amount_cents || 0,
          status: kind,
        };
      });
    }
  } catch {
    /* ledger absent (or pre-migration) -> 0 paid / 0 bonus */
  }

  // Earned (Stripe). Defensive: any failure -> nulls, never a 500.
  let earn = { currency: null, earnedSubs: null, earnedMoneyCents: null, redemptions: [], available: false };
  try {
    if (env.STRIPE_SECRET_KEY) earn = await buildCreatorEarnings(env, creator);
  } catch {
    /* keep nulls */
  }

  // Total earned = Stripe net-settled earnings + manual bonuses. Bonuses don't add subs.
  const earnedCents = earn.earnedMoneyCents != null ? earn.earnedMoneyCents + bonusCents : null;
  const pendSubs = earn.earnedSubs != null ? Math.max(0, earn.earnedSubs - paidSubs) : null;
  const pendCents = earnedCents != null ? Math.max(0, earnedCents - paidCents) : null;

  // Merge bonus entries into the (PII-free) redemptions list, newest first.
  const redemptions = (earn.redemptions || []).concat(bonusRows).sort((a, b) => b.at - a.at);

  return json({
    name: creator.name,
    codes: creator.codes,
    currency: earn.currency,
    earned: { subs: earn.earnedSubs, moneyCents: earnedCents },
    paidOut: { subs: paidSubs, moneyCents: paidCents },
    pending: { subs: pendSubs, moneyCents: pendCents },
    bonus: { moneyCents: bonusCents },
    redemptions,
    available: earn.available,
    at: Date.now(),
  });
}
