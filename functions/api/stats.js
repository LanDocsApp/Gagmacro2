// GET /api/stats?key=<STATS_KEY> — usage counts for the dashboard.
//
// Returns { live, today, week, total, sessionsToday, avgSession, sessions, at }:
//   live          = distinct installs active in the last 2 minutes
//   today         = distinct installs active since 00:00 UTC today
//   week          = distinct installs active in the last 7 days
//   total         = all installs ever seen (every row)
//   sessionsToday = sessions started since 00:00 UTC today
//   avgSession    = mean session length in ms (last_ping - started_at), all time
//   promos        = creator promo-code breakdown [{ code, count }] (installs per code)
//   sources       = acquisition-source breakdown [{ source, count }] (installs per channel)
//   sessions      = most recent 50 sessions [{ device, started_at, last_ping,
//                   durationMs, pings, version, promo, src }]
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

    // Session aggregates. AVG over real timestamps is exact within a session;
    // we exclude single-ping sessions (duration 0) so the average reflects
    // actual use rather than launches that closed before a second beat.
    const sess = await env.STATS.prepare(
      `SELECT
         SUM(CASE WHEN started_at >= ?1 THEN 1 ELSE 0 END)            AS sessionsToday,
         AVG(CASE WHEN pings > 1 THEN last_ping - started_at END)     AS avgSession
       FROM sessions`
    )
      .bind(midnightUtc)
      .first();

    const recent = await env.STATS.prepare(
      `SELECT device_id AS device, started_at, last_ping, pings, version
       FROM sessions ORDER BY started_at DESC LIMIT 50`
    ).all();

    // Creator promo codes: installs-per-code breakdown + a device->code map to stitch
    // onto recent sessions. Own try/catch so a missing `promo` column never 500s stats.
    let promos = [];
    const promoByDevice = {};
    try {
      const pr = await env.STATS.prepare(
        `SELECT promo AS code, COUNT(*) AS n FROM devices
         WHERE promo IS NOT NULL AND promo <> '' GROUP BY promo ORDER BY n DESC`
      ).all();
      promos = (pr?.results || []).map((r) => ({ code: String(r.code), count: r.n || 0 }));

      const dp = await env.STATS.prepare(
        `SELECT id, promo FROM devices WHERE promo IS NOT NULL AND promo <> ''`
      ).all();
      for (const r of dp?.results || []) promoByDevice[String(r.id)] = String(r.promo);
    } catch {
      // `promo` column not added yet -> no breakdown, no per-session promo.
    }

    // Acquisition source: installs-per-channel breakdown + a device->source map to
    // stitch onto recent sessions. Own try/catch so a missing `src` column never 500s.
    let sources = [];
    const srcByDevice = {};
    try {
      const sr = await env.STATS.prepare(
        `SELECT src AS source, COUNT(*) AS n FROM devices
         WHERE src IS NOT NULL AND src <> '' GROUP BY src ORDER BY n DESC`
      ).all();
      sources = (sr?.results || []).map((r) => ({ source: String(r.source), count: r.n || 0 }));

      const ds = await env.STATS.prepare(
        `SELECT id, src FROM devices WHERE src IS NOT NULL AND src <> ''`
      ).all();
      for (const r of ds?.results || []) srcByDevice[String(r.id)] = String(r.src);
    } catch {
      // `src` column not added yet -> no breakdown, no per-session source.
    }

    const sessions = (recent?.results || []).map((s) => ({
      device: String(s.device || "").slice(0, 8),
      started_at: s.started_at,
      last_ping: s.last_ping,
      durationMs: (s.last_ping || 0) - (s.started_at || 0),
      pings: s.pings || 0,
      version: s.version || "",
      promo: promoByDevice[String(s.device || "")] || "",
      src: srcByDevice[String(s.device || "")] || "",
    }));

    return json({
      live: row?.live || 0,
      today: row?.today || 0,
      week: row?.week || 0,
      total: row?.total || 0,
      sessionsToday: sess?.sessionsToday || 0,
      avgSession: Math.round(sess?.avgSession || 0),
      promos,
      sources,
      sessions,
      at: now,
    });
  } catch (e) {
    return json({ error: "query failed", detail: String(e && e.message || e) }, 500);
  }
}
