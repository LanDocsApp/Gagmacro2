// POST /api/payouts — owner-side view of the creator payout ledger, for the Finances tab.
//
// ADMIN ONLY: gated by STATS_KEY (same key as /api/stats), no creator token. That is what
// separates this from /api/creator/payout, which is scoped to ONE creator (STATS_KEY + that
// creator's token) and is used from the per-creator admin page. This endpoint spans every
// creator so the Finances tab can show, correct, or clear what actually left your pocket.
//
// Both write to the SAME `payouts` table, so an edit here shows up on the creator page and
// in the Money tab's Paid/Owed columns too.
//
// Body { key, action, ... }:
//   "list"   -> { payouts:[...], at }   (default)
//   "add"    -> record one { creatorId, amount (major units), paidAt (epoch ms), note?, kind? }
//   "update" -> amend one by { id, ... same fields }
//   "delete" -> remove one by { id }
// All actions return the fresh list.
//
// `kind` mirrors the creator page: 'payout' (money disbursed, the default, counts toward
// what you have paid) or 'bonus' (a credit owed on top of Stripe earnings, NOT money out).
// Only 'payout' rows hit the P&L, matching creatorPaidThisMonth() in _lib/money.js.

import { json } from "../_lib/http.js";
import { CREATORS } from "../_lib/creators.js";

async function listPayouts(env) {
  let payouts = [];
  try {
    const rows = await env.STATS.prepare(
      `SELECT id, creator_id, subscribers, amount_cents, note, kind, created_at
       FROM payouts ORDER BY created_at DESC LIMIT 500`
    ).all();
    payouts = ((rows && rows.results) || []).map((r) => ({
      id: r.id,
      creatorId: r.creator_id || "",
      subscribers: r.subscribers || 0,
      amountCents: r.amount_cents || 0,
      note: r.note || "",
      kind: r.kind === "bonus" ? "bonus" : "payout",
      paidAt: r.created_at,
    }));
  } catch {
    payouts = []; // ledger table not applied yet -> empty
  }
  // The creator slugs the UI offers in its picker. Sent alongside so the dashboard
  // never hardcodes the roster.
  // CREATORS is keyed BY slug (jose / jukem / lion / ...); the slug is the id.
  let creators = [];
  try {
    creators = Object.entries(CREATORS).map(([id, c]) => ({ id, name: (c && c.name) || id }));
  } catch {
    creators = [];
  }
  return json({ payouts, creators, at: Date.now() });
}

export async function onRequestPost({ request, env }) {
  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const key = String(body.key || "").trim();
  if (!env.STATS_KEY || key !== env.STATS_KEY) return json({ error: "unauthorized" }, 401);
  if (!env.STATS) return json({ error: "stats database not bound" }, 500);

  const action = String(body.action || "list").trim();

  // Shared field parsing for add/update.
  const parse = () => ({
    creatorId: String(body.creatorId || "").trim().toLowerCase().slice(0, 40),
    amountCents: Math.max(0, Math.round((Number(body.amount) || 0) * 100)),
    subscribers: Math.max(0, Math.round(Number(body.subscribers) || 0)),
    note: String(body.note || "").slice(0, 200),
    kind: String(body.kind || "payout").trim().toLowerCase() === "bonus" ? "bonus" : "payout",
    paidAt: Number.isFinite(Number(body.paidAt)) && Number(body.paidAt) > 0
      ? Math.round(Number(body.paidAt))
      : Date.now(),
  });

  if (action === "add") {
    const p = parse();
    if (!p.creatorId || p.amountCents === 0) return json({ error: "need a creator and amount" }, 400);
    try {
      await env.STATS.prepare(
        `INSERT INTO payouts (creator_id, subscribers, amount_cents, note, kind, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`
      )
        .bind(p.creatorId, p.subscribers, p.amountCents, p.note, p.kind, p.paidAt)
        .run();
    } catch (e) {
      return json({ error: "could not add", detail: String((e && e.message) || e) }, 500);
    }
    return listPayouts(env);
  }

  if (action === "update") {
    const id = Math.round(Number(body.id) || 0);
    if (!id) return json({ error: "missing id" }, 400);
    const p = parse();
    if (!p.creatorId || p.amountCents === 0) return json({ error: "need a creator and amount" }, 400);
    try {
      await env.STATS.prepare(
        `UPDATE payouts
         SET creator_id = ?2, subscribers = ?3, amount_cents = ?4, note = ?5, kind = ?6, created_at = ?7
         WHERE id = ?1`
      )
        .bind(id, p.creatorId, p.subscribers, p.amountCents, p.note, p.kind, p.paidAt)
        .run();
    } catch (e) {
      return json({ error: "could not update", detail: String((e && e.message) || e) }, 500);
    }
    return listPayouts(env);
  }

  if (action === "delete") {
    const id = Math.round(Number(body.id) || 0);
    if (!id) return json({ error: "missing id" }, 400);
    try {
      await env.STATS.prepare(`DELETE FROM payouts WHERE id = ?1`).bind(id).run();
    } catch (e) {
      return json({ error: "could not delete", detail: String((e && e.message) || e) }, 500);
    }
    return listPayouts(env);
  }

  return listPayouts(env);
}
