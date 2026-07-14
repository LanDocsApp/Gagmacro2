// GET /api/giveaway?g=<id> — public state for the giveaway page (giveaway.html).
//
// Returns the giveaway details (from the _lib/giveaways.js registry), the LIVE entrant
// count + countdown target, and — only when signed in — the caller's own status: whether
// they're Pro, whether they've already entered, and how many tickets they hold. No PII of
// other entrants is ever exposed here (that's the admin page). Never 500s on a cold DB:
// each block is defensive so the page always renders.

import { readSession, json } from "../_lib/http.js";
import { resolveActive } from "../_lib/subscriptions.js";
import {
  getGiveaway,
  listGiveaways,
  MACRO_CODE,
  SUBSCRIBE_URL,
  WEIGHTS,
} from "../_lib/giveaways.js";

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const g = getGiveaway(url.searchParams.get("g") || "");
  if (!g) return json({ error: "no_giveaway" }, 404);

  // Live entrant count (people) — one row per account.
  let entrants = 0;
  let winnerDrawn = false;
  if (env.STATS) {
    try {
      const row = await env.STATS.prepare(
        `SELECT COUNT(*) AS n FROM giveaway_entries WHERE giveaway_id = ?1`
      )
        .bind(g.id)
        .first();
      entrants = (row && row.n) || 0;
    } catch {
      entrants = 0; // table not applied yet
    }
    try {
      const w = await env.STATS.prepare(
        `SELECT google_sub FROM giveaway_winners WHERE giveaway_id = ?1`
      )
        .bind(g.id)
        .first();
      winnerDrawn = !!(w && w.google_sub);
    } catch {
      winnerDrawn = false;
    }
  }

  // Caller status — only if a valid signed session is present.
  let me = { signedIn: false };
  const session = await readSession(request, env);
  if (session) {
    let isPro = false;
    try {
      isPro = (await resolveActive(env, session.sub)) === true;
    } catch {
      isPro = false;
    }

    let entry = null;
    if (env.STATS) {
      try {
        entry = await env.STATS.prepare(
          `SELECT weight, has_macro, subscribed FROM giveaway_entries
           WHERE giveaway_id = ?1 AND google_sub = ?2`
        )
          .bind(g.id, session.sub)
          .first();
      } catch {
        entry = null;
      }
    }

    let won = false;
    if (winnerDrawn && env.STATS) {
      try {
        const w = await env.STATS.prepare(
          `SELECT 1 AS hit FROM giveaway_winners WHERE giveaway_id = ?1 AND google_sub = ?2`
        )
          .bind(g.id, session.sub)
          .first();
        won = !!(w && w.hit);
      } catch {
        won = false;
      }
    }

    me = {
      signedIn: true,
      email: session.email || "",
      isPro,
      entered: !!entry,
      hasMacro: entry ? !!entry.has_macro : false,
      weight: entry ? entry.weight : 0,
      won,
    };
  }

  // Cross-link the other kind of giveaway (normal <-> premium) so a Pro can hop over.
  const others = listGiveaways()
    .filter((x) => x.id !== g.id)
    .map((x) => ({ id: x.id, title: x.title, kind: x.kind, ended: x.ended }));

  return json({
    id: g.id,
    title: g.title,
    tagline: g.tagline || "",
    prize: g.prize || "",
    kind: g.kind,
    image: g.image || "",
    endsAt: g.endsAtMs,
    ended: g.ended,
    subscribeUrl: SUBSCRIBE_URL,
    macroCodeLength: MACRO_CODE.length,
    weights: WEIGHTS,
    entrants,
    winnerDrawn,
    others,
    me,
    at: Date.now(),
  });
}
