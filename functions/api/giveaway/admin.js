// POST /api/giveaway/admin — owner-only giveaway control room (giveaway-admin.html).
//
// ADMIN ONLY: gated by STATS_KEY (the same key as /api/stats — no new secret). Body
// { key, giveaway?, action, ... }:
//   "list"        -> { giveaways:[...counts], giveaway, entries:[...with email], winner }
//   "draw"        -> weighted-random pick among entries; stores + returns the winner
//   "setWinner"   -> manually pick a winner by { sub }
//   "clearWinner" -> remove the drawn winner (re-open the draw)
// Entries include email + name (the owner emails the winner from their own Gmail). Every
// action returns the fresh state so the page can re-render from one response.

import { json } from "../../_lib/http.js";
import { getGiveaway, listGiveaways } from "../../_lib/giveaways.js";

// Read every entry for a giveaway with the fields the owner needs to pick + contact.
async function loadEntries(env, gid) {
  const rows = await env.STATS.prepare(
    `SELECT google_sub, email, name, username, weight, has_macro, is_pro, created_at, updated_at
     FROM giveaway_entries WHERE giveaway_id = ?1 ORDER BY created_at ASC`
  )
    .bind(gid)
    .all();
  return ((rows && rows.results) || []).map((r) => ({
    sub: r.google_sub,
    email: r.email || "",
    name: r.name || "",
    username: r.username || "",
    weight: r.weight || 1,
    hasMacro: !!r.has_macro,
    isPro: !!r.is_pro,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  }));
}

async function loadWinner(env, gid) {
  try {
    const w = await env.STATS.prepare(
      `SELECT google_sub, email, name, username, weight, drawn_at FROM giveaway_winners WHERE giveaway_id = ?1`
    )
      .bind(gid)
      .first();
    if (!w || !w.google_sub) return null;
    return { sub: w.google_sub, email: w.email || "", name: w.name || "", username: w.username || "", weight: w.weight || null, drawnAt: w.drawn_at };
  } catch {
    return null;
  }
}

// Per-giveaway counts for the selector (entrants + total tickets), across the registry.
async function giveawaySummaries(env) {
  const out = [];
  for (const g of listGiveaways()) {
    let entrants = 0;
    let tickets = 0;
    try {
      const row = await env.STATS.prepare(
        `SELECT COUNT(*) AS n, COALESCE(SUM(weight), 0) AS w
         FROM giveaway_entries WHERE giveaway_id = ?1`
      )
        .bind(g.id)
        .first();
      entrants = (row && row.n) || 0;
      tickets = (row && row.w) || 0;
    } catch {
      entrants = 0;
      tickets = 0;
    }
    const winner = await loadWinner(env, g.id);
    out.push({
      id: g.id,
      title: g.title,
      endsAt: g.endsAtMs,
      ended: g.ended,
      entrants,
      tickets,
      hasWinner: !!winner,
    });
  }
  return out;
}

// Assemble the full response for a giveaway (used by every action).
async function state(env, gid) {
  const g = getGiveaway(gid);
  let entries = [];
  try {
    entries = await loadEntries(env, g.id);
  } catch {
    entries = []; // table not applied yet
  }
  const winner = await loadWinner(env, g.id);
  const totalTickets = entries.reduce((s, e) => s + (e.weight || 0), 0);
  return json({
    giveaways: await giveawaySummaries(env),
    giveaway: { id: g.id, title: g.title, endsAt: g.endsAtMs, ended: g.ended },
    entries,
    entrants: entries.length,
    totalTickets,
    winner,
    at: Date.now(),
  });
}

// Weighted random pick: each entry contributes `weight` tickets; draw one ticket uniformly.
function weightedPick(entries) {
  const total = entries.reduce((s, e) => s + (e.weight || 0), 0);
  if (total <= 0) return null;
  let r = Math.random() * total;
  for (const e of entries) {
    r -= e.weight || 0;
    if (r < 0) return e;
  }
  return entries[entries.length - 1];
}

async function saveWinner(env, gid, entry) {
  await env.STATS.prepare(
    `INSERT INTO giveaway_winners (giveaway_id, google_sub, email, name, username, weight, drawn_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
     ON CONFLICT(giveaway_id) DO UPDATE SET
       google_sub = ?2, email = ?3, name = ?4, username = ?5, weight = ?6, drawn_at = ?7`
  )
    .bind(gid, entry.sub, entry.email || null, entry.name || null, entry.username || null, entry.weight || null, Date.now())
    .run();
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

  const g = getGiveaway(String(body.giveaway || ""));
  if (!g) return json({ error: "no_giveaway" }, 404);
  const action = String(body.action || "list").trim();

  if (action === "draw") {
    let entries = [];
    try {
      entries = await loadEntries(env, g.id);
    } catch {
      entries = [];
    }
    const pick = weightedPick(entries);
    if (!pick) return json({ error: "no_entries" }, 400);
    try {
      await saveWinner(env, g.id, pick);
    } catch (e) {
      return json({ error: "could_not_save_winner", detail: String((e && e.message) || e) }, 500);
    }
    return state(env, g.id);
  }

  if (action === "setWinner") {
    const sub = String(body.sub || "").trim();
    if (!sub) return json({ error: "missing_sub" }, 400);
    let entry = null;
    try {
      const entries = await loadEntries(env, g.id);
      entry = entries.find((e) => e.sub === sub) || null;
    } catch {
      entry = null;
    }
    if (!entry) return json({ error: "not_an_entrant" }, 404);
    try {
      await saveWinner(env, g.id, entry);
    } catch (e) {
      return json({ error: "could_not_save_winner", detail: String((e && e.message) || e) }, 500);
    }
    return state(env, g.id);
  }

  if (action === "clearWinner") {
    try {
      await env.STATS.prepare(`DELETE FROM giveaway_winners WHERE giveaway_id = ?1`).bind(g.id).run();
    } catch (e) {
      return json({ error: "could_not_clear", detail: String((e && e.message) || e) }, 500);
    }
    return state(env, g.id);
  }

  // Default: list.
  return state(env, g.id);
}
