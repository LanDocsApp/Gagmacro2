// POST /api/creator/payout — admin payout ledger for a creator.
//
// Tracks how much you've paid each creator against the installs their code(s)
// drove. ADMIN ONLY: every action requires BOTH
//   key   = your STATS_KEY (authorization — same key as /api/stats)
//   token = a creator's signed dashboard token (identifies WHICH creator)
// so a creator (who has the token but not the key) can never read or write payouts;
// this is why it's a separate endpoint from /api/creator/stats, not part of it.
//
// Body { key, token, action, ... }:
//   "list"   -> summary + history (default)
//   "add"    -> record a payout { installs, amount (dollars), note }
//   "delete" -> remove a payout by { id }
//
// All three return the fresh summary:
//   { creator:{ id, name, codes }, totalInstalls, paidInstalls, pendingInstalls,
//     paidCents, payouts:[{ id, installs, amountCents, note, at }], at }
//
// Payouts are per CREATOR (slug), aggregated across all their codes — you pay on
// total installs driven, not per code. Requires migration 0004 (the payouts table).

import { json } from "../../_lib/http.js";
import { verifyToken } from "../../_lib/crypto.js";
import { getCreator } from "../../_lib/creators.js";

// COUNT installs across all of a creator's codes (same basis as /api/creator/stats).
async function totalInstalls(env, codes) {
  let total = 0;
  for (const code of codes) {
    try {
      const row = await env.STATS.prepare(
        `SELECT COUNT(*) AS n FROM devices WHERE UPPER(promo) = ?1`
      )
        .bind(code.toUpperCase())
        .first();
      total += (row && row.n) || 0;
    } catch {
      // ignore a single code's failure; the others still count
    }
  }
  return total;
}

async function summary(env, creator) {
  const total = await totalInstalls(env, creator.codes);
  let paidInstalls = 0;
  let paidCents = 0;
  let payouts = [];
  try {
    const agg = await env.STATS.prepare(
      `SELECT COALESCE(SUM(installs), 0) AS i, COALESCE(SUM(amount_cents), 0) AS c
       FROM payouts WHERE creator_id = ?1`
    )
      .bind(creator.id)
      .first();
    paidInstalls = (agg && agg.i) || 0;
    paidCents = (agg && agg.c) || 0;

    const rows = await env.STATS.prepare(
      `SELECT id, installs, amount_cents, note, created_at
       FROM payouts WHERE creator_id = ?1 ORDER BY created_at DESC LIMIT 100`
    )
      .bind(creator.id)
      .all();
    payouts = ((rows && rows.results) || []).map((r) => ({
      id: r.id,
      installs: r.installs || 0,
      amountCents: r.amount_cents || 0,
      note: r.note || "",
      at: r.created_at,
    }));
  } catch {
    // payouts table not applied yet -> zeros + empty history (still shows installs)
  }

  return json({
    creator: { id: creator.id, name: creator.name, codes: creator.codes },
    totalInstalls: total,
    paidInstalls,
    pendingInstalls: Math.max(0, total - paidInstalls),
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
    const installs = Math.max(0, Math.round(Number(body.installs) || 0));
    const amountCents = Math.max(0, Math.round((Number(body.amount) || 0) * 100));
    const note = String(body.note || "").slice(0, 200);
    if (installs === 0 && amountCents === 0) {
      return json({ error: "nothing to record" }, 400);
    }
    try {
      await env.STATS.prepare(
        `INSERT INTO payouts (creator_id, installs, amount_cents, note, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`
      )
        .bind(creator.id, installs, amountCents, note, Date.now())
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
