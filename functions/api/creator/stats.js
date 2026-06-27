// POST /api/creator/stats — per-creator dashboard data for /creator.html.
//
// Body: { "token": "<signed creator token>" } (a bare token string is also OK).
// The token is an HMAC-signed payload { t:"creator", id:"<slug>" } minted by
// /api/creator/link (admin) and embedded in the private link we send each creator.
// It authorizes exactly ONE creator and exposes only that creator's aggregate
// numbers -- never anyone else's, and no PII (installs is a COUNT; subscriptions is
// a Stripe redemption count).
//
// Returns:
//   { name, totals:{ installs, subscriptions },
//     codes:[{ code, installs, subscriptions, linked }],
//     subsAvailable, at }
// subscriptions is null (and the UI shows "—") when Stripe can't be reached;
// linked=false means no Stripe promotion code matches that code (so it reads 0).

import { json } from "../../_lib/http.js";
import { verifyToken } from "../../_lib/crypto.js";
import { getCreator } from "../../_lib/creators.js";
import { listPromotionCodes } from "../../_lib/stripe.js";

export async function onRequestPost({ request, env }) {
  let token = "";
  try {
    const ct = request.headers.get("Content-Type") || "";
    if (ct.includes("application/json")) {
      const body = await request.json();
      token = (body && (body.token || body.t)) || "";
    } else {
      token = await request.text();
    }
  } catch {
    token = "";
  }
  token = String(token || "").trim();

  const payload = await verifyToken(env.COOKIE_SECRET, "creator", token);
  if (!payload || payload.t !== "creator" || !payload.id) {
    return json({ error: "unauthorized" }, 401);
  }

  const creator = getCreator(payload.id);
  if (!creator) return json({ error: "unknown creator" }, 404);
  if (!env.STATS) return json({ error: "stats database not bound" }, 500);

  const now = Date.now();
  const perCode = [];
  let totalInstalls = 0;
  let totalSubs = 0;
  let subsAvailable = true; // flips false if any Stripe lookup errors out

  for (const code of creator.codes) {
    const CODE = code.toUpperCase();

    // Installs: anonymous installs that reported this creator code on the heartbeat.
    let installs = 0;
    try {
      const row = await env.STATS.prepare(
        `SELECT COUNT(*) AS n FROM devices WHERE UPPER(promo) = ?1`
      )
        .bind(CODE)
        .first();
      installs = (row && row.n) || 0;
    } catch {
      installs = 0;
    }

    // Paid subscriptions: redemptions of this code as a Stripe promotion code.
    //   linked=false  -> no such Stripe promotion code (reads 0, flagged in UI)
    //   subscriptions=null -> Stripe unreachable (UI shows "—", not a wrong 0)
    let subscriptions = null;
    let linked = false;
    try {
      const pc = await listPromotionCodes(env, CODE);
      const first = pc && pc.data && pc.data[0];
      linked = !!first;
      subscriptions = first ? first.times_redeemed || 0 : 0;
    } catch {
      subscriptions = null;
      linked = null;
      subsAvailable = false;
    }

    perCode.push({ code: CODE, installs, subscriptions, linked });
    totalInstalls += installs;
    if (subscriptions !== null) totalSubs += subscriptions;
  }

  return json({
    name: creator.name,
    totals: {
      installs: totalInstalls,
      subscriptions: subsAvailable ? totalSubs : null,
    },
    codes: perCode,
    subsAvailable,
    at: now,
  });
}
