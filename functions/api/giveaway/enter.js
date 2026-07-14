// POST /api/giveaway/enter — enter (or update) the signed-in account's giveaway entry.
//
// Body: { g: "<giveaway id>", subscribed: true, code?: "<macro code>" }
//
// Rules:
//   - Must be signed in (Google session)         -> 1 entry per account (anti-cheat).
//   - Honor gate: `subscribed` must be true       -> the White Lion subscribe was confirmed.
//   - `code` matching the macro code adds tickets  -> proves they have the free macro (+2).
//   - Premium giveaways require an active Pro.
//   - Pro is detected from the Google account (resolveActive) — no code to paste for Pro.
//
// Re-entering is allowed and idempotent (upsert on giveaway_id+google_sub): a user can enter
// first, then come back and add the macro code to bump their tickets. `has_macro` is sticky —
// once proven, it stays — so a later re-submit without the code never DROPS their bonus.

import { readSession, json } from "../../_lib/http.js";
import { resolveActive } from "../../_lib/subscriptions.js";
import { getGiveaway, computeWeight, MACRO_CODE } from "../../_lib/giveaways.js";

export async function onRequestPost({ request, env }) {
  const session = await readSession(request, env);
  if (!session) return json({ error: "signin" }, 401);
  if (!env.STATS) return json({ error: "no_database" }, 500);

  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }

  const g = getGiveaway(String(body.g || ""));
  if (!g) return json({ error: "no_giveaway" }, 404);
  if (g.ended) return json({ error: "ended" }, 400);

  // Honor-system subscribe gate — the page won't let them click Enter without ticking it,
  // but enforce server-side too.
  if (body.subscribed !== true) return json({ error: "subscribe" }, 400);

  // Macro code (optional). Wrong-but-provided is a soft error so the page can nudge them;
  // an empty code is fine (they just enter at the base weight).
  const code = String(body.code || "").trim().toUpperCase();
  const codeMatches = code === MACRO_CODE.toUpperCase();
  if (code && !codeMatches) return json({ error: "badcode" }, 400);

  let isPro = false;
  try {
    isPro = (await resolveActive(env, session.sub)) === true;
  } catch {
    isPro = false;
  }

  // Premium giveaway: Pro members only.
  if (g.kind === "premium" && !isPro) return json({ error: "proonly" }, 403);

  // Merge with any existing entry so has_macro is sticky (never lost on re-entry).
  let prior = null;
  try {
    prior = await env.STATS.prepare(
      `SELECT has_macro FROM giveaway_entries WHERE giveaway_id = ?1 AND google_sub = ?2`
    )
      .bind(g.id, session.sub)
      .first();
  } catch {
    prior = null;
  }
  const hasMacro = codeMatches || !!(prior && prior.has_macro);
  const weight = computeWeight({ hasMacro, isPro });
  const now = Date.now();

  try {
    await env.STATS.prepare(
      `INSERT INTO giveaway_entries
         (giveaway_id, google_sub, email, name, weight, has_macro, is_pro, subscribed, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?8, ?8)
       ON CONFLICT(giveaway_id, google_sub) DO UPDATE SET
         email      = ?3,
         name       = ?4,
         weight     = ?5,
         has_macro  = ?6,
         is_pro     = ?7,
         subscribed = 1,
         updated_at = ?8`
    )
      .bind(
        g.id,
        session.sub,
        session.email || null,
        session.name || null,
        weight,
        hasMacro ? 1 : 0,
        isPro ? 1 : 0,
        now
      )
      .run();
  } catch (e) {
    return json({ error: "save", detail: String((e && e.message) || e) }, 500);
  }

  // Fresh entrant count for the live counter.
  let entrants = 0;
  try {
    const row = await env.STATS.prepare(
      `SELECT COUNT(*) AS n FROM giveaway_entries WHERE giveaway_id = ?1`
    )
      .bind(g.id)
      .first();
    entrants = (row && row.n) || 0;
  } catch {
    entrants = 0;
  }

  return json({ ok: true, entered: true, weight, hasMacro, isPro, entrants });
}
