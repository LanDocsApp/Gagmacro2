// POST /api/expenses — owner expense ledger for the Finances tab P&L.
//
// ADMIN ONLY: gated by STATS_KEY (same key as /api/stats). These are your own costs, so
// no creator token — just the stats key. Body { key, action, ... }:
//   "list"   -> { expenses:[...], at }   (default)
//   "add"    -> record an expense { label, amount (major units), category, recurrence,
//               incurredAt (epoch ms), currency?, note? }
//   "delete" -> remove one by { id }
// All actions return the fresh list. Requires migration 0006 (the expenses table).

import { json } from "../_lib/http.js";

const RECURRENCE = new Set(["once", "monthly", "yearly"]);

async function listExpenses(env) {
  let expenses = [];
  try {
    const rows = await env.STATS.prepare(
      `SELECT id, label, category, amount_cents, currency, recurrence, incurred_at, note
       FROM expenses ORDER BY incurred_at DESC LIMIT 500`
    ).all();
    expenses = ((rows && rows.results) || []).map((r) => ({
      id: r.id,
      label: r.label || "",
      category: r.category || "other",
      amountCents: r.amount_cents || 0,
      currency: r.currency || null,
      recurrence: r.recurrence || "once",
      incurredAt: r.incurred_at,
      note: r.note || "",
    }));
  } catch {
    expenses = []; // table not applied yet -> empty ledger
  }
  return json({ expenses, at: Date.now() });
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

  if (action === "add") {
    const label = String(body.label || "").trim().slice(0, 120);
    const category = String(body.category || "other").trim().slice(0, 32) || "other";
    const amountCents = Math.max(0, Math.round((Number(body.amount) || 0) * 100));
    const recurrence = RECURRENCE.has(body.recurrence) ? body.recurrence : "once";
    const incurredAt = Number.isFinite(Number(body.incurredAt)) && Number(body.incurredAt) > 0
      ? Math.round(Number(body.incurredAt))
      : Date.now();
    const currency = String(body.currency || "").trim().slice(0, 8) || null;
    const note = String(body.note || "").slice(0, 200);
    if (!label || amountCents === 0) return json({ error: "need a label and amount" }, 400);
    try {
      await env.STATS.prepare(
        `INSERT INTO expenses (label, category, amount_cents, currency, recurrence, incurred_at, note, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`
      )
        .bind(label, category, amountCents, currency, recurrence, incurredAt, note, Date.now())
        .run();
    } catch (e) {
      return json({ error: "could not add", detail: String((e && e.message) || e) }, 500);
    }
    return listExpenses(env);
  }

  if (action === "update") {
    const id = Math.round(Number(body.id) || 0);
    if (!id) return json({ error: "missing id" }, 400);
    const label = String(body.label || "").trim().slice(0, 120);
    const category = String(body.category || "other").trim().slice(0, 32) || "other";
    const amountCents = Math.max(0, Math.round((Number(body.amount) || 0) * 100));
    const recurrence = RECURRENCE.has(body.recurrence) ? body.recurrence : "once";
    const incurredAt = Number.isFinite(Number(body.incurredAt)) && Number(body.incurredAt) > 0
      ? Math.round(Number(body.incurredAt))
      : Date.now();
    const currency = String(body.currency || "").trim().slice(0, 8) || null;
    const note = String(body.note || "").slice(0, 200);
    if (!label || amountCents === 0) return json({ error: "need a label and amount" }, 400);
    try {
      await env.STATS.prepare(
        `UPDATE expenses
         SET label = ?2, category = ?3, amount_cents = ?4, currency = ?5, recurrence = ?6, incurred_at = ?7, note = ?8
         WHERE id = ?1`
      )
        .bind(id, label, category, amountCents, currency, recurrence, incurredAt, note)
        .run();
    } catch (e) {
      return json({ error: "could not update", detail: String((e && e.message) || e) }, 500);
    }
    return listExpenses(env);
  }

  if (action === "delete") {
    const id = Math.round(Number(body.id) || 0);
    if (!id) return json({ error: "missing id" }, 400);
    try {
      await env.STATS.prepare(`DELETE FROM expenses WHERE id = ?1`).bind(id).run();
    } catch (e) {
      return json({ error: "could not delete", detail: String((e && e.message) || e) }, 500);
    }
    return listExpenses(env);
  }

  return listExpenses(env);
}
