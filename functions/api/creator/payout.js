// POST /api/creator/payout — admin payout ledger for a creator.
//
// Tracks how much you've paid each creator against the SUBSCRIBERS their code(s)
// drove (paid Stripe redemptions — the same number the dashboard shows as
// "Subscribed", not installs). ADMIN ONLY: every action requires BOTH
//   key   = your STATS_KEY (authorization — same key as /api/stats)
//   token = a creator's signed dashboard token (identifies WHICH creator)
// so a creator (who has the token but not the key) can never read or write payouts;
// this is why it's a separate endpoint from /api/creator/stats, not part of it.
//
// Body { key, token, action, ... }:
//   "list"   -> summary + history (default)
//   "add"    -> record an entry { kind:"payout"|"bonus"|"promo", subscribers, amount (dollars), note }
//               kind='payout' (default) = money disbursed; every other kind is a credit
//               owed (bonus = thank-you, promo = agreed fee for a sponsored video).
//   "delete" -> remove a payout by { id }
//
// All three return the fresh summary:
//   { creator:{ id, name, codes }, totalSubscriptions, subsAvailable,
//     paidSubscribers, pendingSubscribers, paidCents, bonusCents,
//     payouts:[{ id, subscribers, amountCents, note, kind, at }], at }
// totalSubscriptions/pendingSubscribers are null when Stripe is unreachable
// (the paid count from the ledger is always available). Payouts are per CREATOR
// (slug), aggregated across all their codes. Requires migration 0004.

import { json } from "../../_lib/http.js";
import { verifyToken } from "../../_lib/crypto.js";
import { getCreator, RETENTION_BONUS } from "../../_lib/creators.js";
import { listPromotionCodes } from "../../_lib/stripe.js";
import { PAYOUT_KIND, SQL_IS_PAYOUT, normalizeKind, listRetainedPromoSubs } from "../../_lib/money.js";

// Prefix on the `note` of an auto-created retention-bonus row. The subscription id follows,
// which both makes the row traceable and lets us dedupe (never credit the same sub twice).
const RETENTION_NOTE_PREFIX = "Retention bonus (1 week) · ";

// Auto-create retention bonuses for a creator whose subscribers earn one (see RETENTION_BONUS):
// for every attributed sub that survived its first week and hasn't been credited yet, insert a
// 'bonus' row. Idempotent (dedupes on the sub id embedded in the note) and best-effort — any
// Stripe/D1 issue just leaves the ledger as-is, so the payout view still loads. Called from
// summary() so the fresh rows are reflected the moment the owner opens the payout admin.
async function materializeRetentionBonuses(env, creator) {
  const cfg = RETENTION_BONUS[creator.id];
  if (!cfg || !env.STATS) return;
  try {
    // Union of qualifying subs across all the creator's codes. Bail unless EVERY lookup was
    // complete (available), so we never miss-and-later-double or credit off a partial list.
    const qualified = [];
    for (const code of creator.codes) {
      const { available, subs } = await listRetainedPromoSubs(env, code, cfg.days);
      if (!available) return;
      for (const s of subs) qualified.push(s);
    }
    if (!qualified.length) return;

    // Which sub ids have already been credited? Read existing retention notes once.
    const existing = new Set();
    const rows = await env.STATS.prepare(
      `SELECT note FROM payouts WHERE creator_id = ?1 AND kind = 'bonus' AND note LIKE ?2`
    )
      .bind(creator.id, RETENTION_NOTE_PREFIX + "%")
      .all();
    for (const r of (rows && rows.results) || []) {
      const id = String(r.note || "").slice(RETENTION_NOTE_PREFIX.length).trim();
      if (id) existing.add(id);
    }

    for (const s of qualified) {
      if (existing.has(s.subId)) continue;
      await env.STATS.prepare(
        `INSERT INTO payouts (creator_id, subscribers, amount_cents, note, created_at, kind)
         VALUES (?1, 0, ?2, ?3, ?4, 'bonus')`
      )
        .bind(creator.id, cfg.bonusCents, RETENTION_NOTE_PREFIX + s.subId, s.qualifiedAtMs)
        .run();
      existing.add(s.subId); // guard against a duplicate sub id inside the same batch
    }
  } catch {
    /* leave the ledger unchanged on any error */
  }
}

// Total subscribers a creator drove = sum of each code's Stripe promotion-code
// `times_redeemed`. Returns { total, available }; available=false (total=null) if
// any Stripe lookup errors, so we never show a wrong "pending" off a partial total.
async function totalSubscriptions(env, codes) {
  let total = 0;
  let available = true;
  for (const code of codes) {
    try {
      const pc = await listPromotionCodes(env, code.toUpperCase());
      const first = pc && pc.data && pc.data[0];
      total += first ? first.times_redeemed || 0 : 0;
    } catch {
      available = false;
    }
  }
  return { total: available ? total : null, available };
}

async function summary(env, creator) {
  // Bring the ledger up to date first (no-op unless this creator earns retention bonuses),
  // so the aggregate + history below already include any newly-qualified week-1 survivors.
  await materializeRetentionBonuses(env, creator);

  const { total, available } = await totalSubscriptions(env, creator.codes);

  let paidSubscribers = 0;
  let paidCents = 0;
  let bonusCents = 0;
  let payouts = [];
  try {
    // Split disbursements (kind='payout') from credits (bonus/promo): only the former
    // count as "paid". Credits are money still owed, surfaced separately.
    const agg = await env.STATS.prepare(
      `SELECT
         COALESCE(SUM(CASE WHEN ${SQL_IS_PAYOUT} THEN subscribers  ELSE 0 END), 0) AS paid_s,
         COALESCE(SUM(CASE WHEN ${SQL_IS_PAYOUT} THEN amount_cents ELSE 0 END), 0) AS paid_c,
         COALESCE(SUM(CASE WHEN ${SQL_IS_PAYOUT} THEN 0 ELSE amount_cents END), 0) AS bonus_c
       FROM payouts WHERE creator_id = ?1`
    )
      .bind(creator.id)
      .first();
    paidSubscribers = (agg && agg.paid_s) || 0;
    paidCents = (agg && agg.paid_c) || 0;
    bonusCents = (agg && agg.bonus_c) || 0;

    const rows = await env.STATS.prepare(
      `SELECT id, subscribers, amount_cents, note, created_at, kind
       FROM payouts WHERE creator_id = ?1 ORDER BY created_at DESC LIMIT 100`
    )
      .bind(creator.id)
      .all();
    payouts = ((rows && rows.results) || []).map((r) => ({
      id: r.id,
      subscribers: r.subscribers || 0,
      amountCents: r.amount_cents || 0,
      note: r.note || "",
      kind: r.kind || "payout",
      at: r.created_at,
    }));
  } catch {
    // payouts table not applied yet -> zeros + empty history
  }

  return json({
    creator: { id: creator.id, name: creator.name, codes: creator.codes },
    totalSubscriptions: total,
    subsAvailable: available,
    paidSubscribers,
    pendingSubscribers: available ? Math.max(0, total - paidSubscribers) : null,
    paidCents,
    bonusCents,
    payouts,
    at: Date.now(),
  });
}

export async function onRequestPost({ request, env }) {
  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const key = String(body.key || "").trim();
  const token = String(body.token || body.t || "").trim();
  const action = String(body.action || "list").trim();

  // Authorization: the stats key. Without it (or without one configured) we never
  // reveal or mutate payout data, even with a valid creator token.
  if (!env.STATS_KEY || key !== env.STATS_KEY) {
    return json({ error: "unauthorized" }, 401);
  }

  // Which creator: from the signed token (same token the dashboard already holds).
  const payload = await verifyToken(env.COOKIE_SECRET, "creator", token);
  if (!payload || payload.t !== "creator" || !payload.id) {
    return json({ error: "bad token" }, 400);
  }
  const creator = getCreator(payload.id);
  if (!creator) return json({ error: "unknown creator" }, 404);
  if (!env.STATS) return json({ error: "stats database not bound" }, 500);

  if (action === "add") {
    // kind: 'payout' (money disbursed, default) or a credit owed ('bonus' / 'promo').
    const kind = normalizeKind(body.kind);
    const isPayout = kind === PAYOUT_KIND;
    const subscribers = Math.max(0, Math.round(Number(body.subscribers) || 0));
    const amountCents = Math.max(0, Math.round((Number(body.amount) || 0) * 100));
    const note = String(body.note || "").slice(0, 200);
    // A credit is money-only (no subscriber count); a payout needs at least one of the two.
    if (amountCents === 0 && (!isPayout || subscribers === 0)) {
      return json({ error: "nothing to record" }, 400);
    }
    try {
      await env.STATS.prepare(
        `INSERT INTO payouts (creator_id, subscribers, amount_cents, note, created_at, kind)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`
      )
        .bind(creator.id, isPayout ? subscribers : 0, amountCents, note, Date.now(), kind)
        .run();
    } catch (e) {
      return json({ error: "could not record", detail: String((e && e.message) || e) }, 500);
    }
    return summary(env, creator);
  }

  if (action === "delete") {
    const id = Math.round(Number(body.id) || 0);
    if (!id) return json({ error: "missing id" }, 400);
    try {
      // Scope by creator_id too, so a payout can only be removed from its own creator.
      await env.STATS.prepare(
        `DELETE FROM payouts WHERE id = ?1 AND creator_id = ?2`
      )
        .bind(id, creator.id)
        .run();
    } catch (e) {
      return json({ error: "could not delete", detail: String((e && e.message) || e) }, 500);
    }
    return summary(env, creator);
  }

  // default: list
  return summary(env, creator);
}
