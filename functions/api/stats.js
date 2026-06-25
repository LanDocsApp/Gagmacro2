// GET /api/stats?key=<STATS_KEY> — usage counts for the dashboard.
//
// Returns { live, today, week, total, sessionsToday, avgSession, sessions, at, ... }:
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
// "New stats" tab additions (each computed defensively in its own try/catch so a
// missing column/table or odd data can never 500 the core dashboard):
//   funnel        = { installs, getAccess, checkout, subscribe } — the conversion
//                   funnel. installs = total; getAccess = distinct devices that
//                   clicked "Get access"; checkout = pay-page hits; subscribe = paid.
//   daily         = last 30 UTC days [{ day, installs, active }] for the trend chart
//   versions      = current install count per app version [{ version, count }]
//   retention     = { total, returning, active7, churned } (returning = used across
//                   more than one day; churned = no ping in 7+ days)
//   totalHours    = lifetime sum of all session durations, in hours
//
// Protected by the STATS_KEY env var (set in the Cloudflare dashboard). Without
// a configured key the endpoint stays locked.

import { json } from "../_lib/http.js";

// Build an array of the last `n` UTC day strings (YYYY-MM-DD), oldest first.
function lastUtcDays(now, n) {
  const days = [];
  const d = new Date(now);
  d.setUTCHours(0, 0, 0, 0);
  for (let i = n - 1; i >= 0; i--) {
    const x = new Date(d.getTime() - i * 86400000);
    days.push(x.toISOString().slice(0, 10));
  }
  return days;
}

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

    // ---- "New stats" tab data. Each block is self-contained: a failure here
    // leaves a sensible empty default and never blocks the legacy dashboard. ----

    // Conversion funnel. The `events` table may not exist yet (see migration 0003),
    // so its own try/catch returns zeros until it's created.
    let funnel = { installs: row?.total || 0, getAccess: 0, checkout: 0, subscribe: 0 };
    try {
      const f = await env.STATS.prepare(
        `SELECT
           COUNT(DISTINCT CASE WHEN name = 'get_access' THEN device_id END) AS get_access,
           SUM(CASE WHEN name = 'checkout'  THEN 1 ELSE 0 END)              AS checkout,
           SUM(CASE WHEN name = 'subscribe' THEN 1 ELSE 0 END)             AS subscribe
         FROM events`
      ).first();
      funnel.getAccess = f?.get_access || 0;
      funnel.checkout = f?.checkout || 0;
      funnel.subscribe = f?.subscribe || 0;
    } catch {
      // `events` table not created yet -> funnel shows installs only.
    }

    // 30-day daily trend: new installs (devices.first_seen) + active devices
    // (distinct device per day by session start). Merged onto a zero-filled
    // calendar so gaps render as 0 rather than disappearing.
    let daily = [];
    try {
      const cutoff30 = now - 30 * 86400000;
      const ins = await env.STATS.prepare(
        `SELECT date(first_seen / 1000, 'unixepoch') AS day, COUNT(*) AS n
         FROM devices WHERE first_seen >= ?1 GROUP BY day`
      ).bind(cutoff30).all();
      const act = await env.STATS.prepare(
        `SELECT date(started_at / 1000, 'unixepoch') AS day, COUNT(DISTINCT device_id) AS n
         FROM sessions WHERE started_at >= ?1 GROUP BY day`
      ).bind(cutoff30).all();
      const insBy = {}, actBy = {};
      for (const r of ins?.results || []) insBy[r.day] = r.n || 0;
      for (const r of act?.results || []) actBy[r.day] = r.n || 0;
      daily = lastUtcDays(now, 30).map((day) => ({
        day, installs: insBy[day] || 0, active: actBy[day] || 0,
      }));
    } catch {
      daily = [];
    }

    // Version adoption: current install count per app version.
    let versions = [];
    try {
      const vr = await env.STATS.prepare(
        `SELECT version, COUNT(*) AS n FROM devices
         WHERE version IS NOT NULL AND version <> '' GROUP BY version ORDER BY n DESC`
      ).all();
      versions = (vr?.results || []).map((r) => ({ version: String(r.version), count: r.n || 0 }));
    } catch {
      versions = [];
    }

    // Retention snapshot. returning = used across more than one day (last_seen at
    // least 24h after first_seen); active7 = pinged in the last 7d; churned =
    // installed but silent for 7+ days.
    let retention = { total: row?.total || 0, returning: 0, active7: 0, churned: 0 };
    try {
      const rt = await env.STATS.prepare(
        `SELECT
           COUNT(*)                                                          AS total,
           SUM(CASE WHEN last_seen - first_seen >= 86400000 THEN 1 ELSE 0 END) AS returning,
           SUM(CASE WHEN last_seen > ?1 THEN 1 ELSE 0 END)                    AS active7,
           SUM(CASE WHEN last_seen <= ?1 THEN 1 ELSE 0 END)                   AS churned
         FROM devices`
      ).bind(weekCutoff).first();
      retention = {
        total: rt?.total || 0,
        returning: rt?.returning || 0,
        active7: rt?.active7 || 0,
        churned: rt?.churned || 0,
      };
    } catch {
      // keep defaults
    }

    // Lifetime hours automated across every session.
    let totalHours = 0;
    try {
      const h = await env.STATS.prepare(
        `SELECT SUM(CASE WHEN last_ping > started_at THEN last_ping - started_at ELSE 0 END) AS ms
         FROM sessions`
      ).first();
      totalHours = Math.round(((h?.ms || 0) / 3600000) * 10) / 10;
    } catch {
      totalHours = 0;
    }

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
      funnel,
      daily,
      versions,
      retention,
      totalHours,
      at: now,
    });
  } catch (e) {
    return json({ error: "query failed", detail: String(e && e.message || e) }, 500);
  }
}
