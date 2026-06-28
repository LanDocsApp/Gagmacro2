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
//   "add"    -> record a payout { subscribers, amount (dollars), note }
//   "delete" -> remove a payout by { id }
//
// All three return the fresh summary:
//   { creator:{ id, name, codes }, totalSubscriptions, subsAvailable,
//     paidSubscribers, pendingSubscribers, paidCents,
//     payouts:[{ id, subscribers, amountCents, note, at }], at }
// totalSubscriptions/pendingSubscribers are null when Stripe is unreachable
// (the paid count from the ledger is always available). Payouts are per CREATOR
// (slug), aggregated across all their codes. Requires migration 0004.

import { json } from "../../_lib/http.js";
import { verifyToken } from "../../_lib/crypto.js";
import { getCreator } from "../../_lib/creators.js";
import { listPromotionCodes } from "../../_lib/stripe.js";

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
  const { total, available } = await totalSubscriptions(env, creator.codes);

  let paidSubscribers = 0;
  let paidCents = 0;
  let payouts = [];
  try {
    const agg = await env.STATS.prepare(
      `SELECT COALESCE(SUM(subscribers), 0) AS s, COALESCE(SUM(amount_cents), 0) AS c
       FROM payouts WHERE creator_id = ?1`
    )
      .bind(creator.id)
      .first();
    paidSubscribers = (agg && agg.s) || 0;
    paidCents = (agg && agg.c) || 0;

    const rows = await env.STATS.prepare(
      `SELECT id, subscribers, amount_cents, note, created_at
       FROM payouts WHERE creator_id = ?1 ORDER BY created_at DESC LIMIT 100`
    )
      .bind(creator.id)
      .all();
    payouts = ((rows && rows.results) || []).map((r) => ({
      id: r.id,
      subscribers: r.subscribers || 0,
      amountCents: r.amount_cents || 0,
      note: r.note || "",
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
    const subscribers = Math.max(0, Math.round(Number(body.subscribers) || 0));
    const amountCents = Math.max(0, Math.round((Number(body.amount) || 0) * 100));
    const note = String(body.note || "").slice(0, 200);
    if (subscribers === 0 && amountCents === 0) {
      return json({ error: "nothing to record" }, 400);
    }
    try {
      await env.STATS.prepare(
        `INSERT INTO payouts (creator_id, subscribers, amount_cents, note, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`
      )
        .bind(creator.id, subscribers, amountCents, note, Date.now())
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
