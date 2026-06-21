// GET /api/stats?key=<STATS_KEY> — usage counts for the dashboard.
//
// Returns { live, today, week, total, at } where:
//   live  = distinct installs active in the last 2 minutes
//   today = distinct installs active since 00:00 UTC today
//   week  = distinct installs active in the last 7 days
//   total = all installs ever seen (every row)
//
// Protected by the STATS_KEY env var (set in the Cloudflare dashboard). Without
// a configured key the endpoint stays locked.

import { json } from "../_lib/http.js";

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const key = url.searchParams.get("key") || "";

  if (!env.STATS_KEY || key !== env.STATS_KEY) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!env.STATS) {
    return json({ error: "stats database not bound" }, 500);
  }

  const now = Date.now();
  const liveCutoff = now - 2 * 60 * 1000;
  const weekCutoff = now - 7 * 24 * 60 * 60 * 1000;
  // Start of today in UTC.
  const d = new Date(now);
  const midnightUtc = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());

  try {
    const row = await env.STATS.prepare(
      `SELECT
         COUNT(*)                                              AS total,
         SUM(CASE WHEN last_seen > ?1 THEN 1 ELSE 0 END)       AS live,
         SUM(CASE WHEN last_seen >= ?2 THEN 1 ELSE 0 END)      AS today,
         SUM(CASE WHEN last_seen > ?3 THEN 1 ELSE 0 END)       AS week
       FROM devices`
    )
      .bind(liveCutoff, midnightUtc, weekCutoff)
      .first();

    return json({
      live: row?.live || 0,
      today: row?.today || 0,
      week: row?.week || 0,
      total: row?.total || 0,
      at: now,
    });
  } catch (e) {
    return json({ error: "query failed", detail: String(e && e.message || e) }, 500);
  }
}
