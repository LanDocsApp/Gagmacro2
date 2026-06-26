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
//   sessions      = most recent 100 sessions [{ device, started_at, last_ping,
//                   durationMs, pings, version, promo, src }]
//
// Dashboard tab data (each computed defensively in its own try/catch so a missing
// column/table or odd data can never 500 the core endpoint):
//   funnel         = { installs, getAccess, checkout, subscribe } conversion funnel.
//   daily          = last 30 UTC days [{ day, installs, active, getAccess, checkout }]
//   versions       = current install count per app version [{ version, count }]
//   retention      = { total, oneAndDone, returning, active7, lapsed7d, lapsed30d,
//                    dist:{ d1, d1_7, d7_30, d30 } } (do users keep coming back)
//   cohorts        = up to 12 weekly install cohorts [{ week, size, active }]
//   sessionFreq    = open-count histogram [{ bucket:'1'|'2-5'|'6+', n }]
//   heatmap        = session starts [{ dow, hour, n }] (UTC, all-time)
//   sessionLengths = duration histogram [{ bucket, n }] (<1m is the breakage flag)
//   shortByVersion = per-version [{ version, total, short }] (single-ping share)
//   acqSources     = per source [{ source, installs, getAccess, returning }]
//   acqPromos      = per promo  [{ code,   installs, getAccess, returning }]
//   sessionsCount  = total rows in sessions; sessions = latest 100
//   totalHours     = lifetime sum of all session durations, in hours
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
       FROM sessions ORDER BY started_at DESC LIMIT 100`
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
    // (distinct device per day by session start) + funnel intent per day
    // (get_access / checkout events). Merged onto a zero-filled calendar in JS so
    // gaps render as 0 and we avoid a FULL OUTER JOIN.
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
      const insBy = {}, actBy = {}, gaBy = {}, coBy = {};
      for (const r of ins?.results || []) insBy[r.day] = r.n || 0;
      for (const r of act?.results || []) actBy[r.day] = r.n || 0;
      // Per-day funnel events. Own try/catch so a missing `events` table is fine.
      try {
        const ga = await env.STATS.prepare(
          `SELECT date(ts / 1000, 'unixepoch') AS day, COUNT(*) AS n
           FROM events WHERE name = 'get_access' AND ts >= ?1 GROUP BY day`
        ).bind(cutoff30).all();
        for (const r of ga?.results || []) gaBy[r.day] = r.n || 0;
        const co = await env.STATS.prepare(
          `SELECT date(ts / 1000, 'unixepoch') AS day, COUNT(*) AS n
           FROM events WHERE name = 'checkout' AND ts >= ?1 GROUP BY day`
        ).bind(cutoff30).all();
        for (const r of co?.results || []) coBy[r.day] = r.n || 0;
      } catch {
        // events table absent -> get_access/checkout stay 0 for every day.
      }
      daily = lastUtcDays(now, 30).map((day) => ({
        day,
        installs: insBy[day] || 0,
        active: actBy[day] || 0,
        getAccess: gaBy[day] || 0,
        checkout: coBy[day] || 0,
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

    // Retention: strictly about whether installs keep coming back (session length
    // is the user's schedule, not retention -> that lives on the Health tab).
    //   oneAndDone = installed >24h ago and never came back a later day
    //   returning  = used across more than one day (last_seen >= 24h after first_seen)
    //   active7    = pinged in the last 7d
    //   lapsed7d/30d = silent for 7+/30+ days
    //   dist       = time-since-last-seen histogram (<1d, 1-7d, 7-30d, 30d+)
    let retention = {
      total: row?.total || 0, oneAndDone: 0, returning: 0, active7: 0,
      lapsed7d: 0, lapsed30d: 0, dist: { d1: 0, d1_7: 0, d7_30: 0, d30: 0 },
    };
    try {
      const DAY = 86400000, WEEK = 7 * DAY, MONTH = 30 * DAY;
      const rt = await env.STATS.prepare(
        `SELECT
           COUNT(*)                                                                       AS total,
           SUM(CASE WHEN ?1 - first_seen >= ?2 AND last_seen - first_seen < ?2 THEN 1 ELSE 0 END) AS oneAndDone,
           SUM(CASE WHEN last_seen - first_seen >= ?2 THEN 1 ELSE 0 END)                   AS retained,
           SUM(CASE WHEN last_seen > ?1 - ?3 THEN 1 ELSE 0 END)                            AS active7,
           SUM(CASE WHEN ?1 - last_seen >= ?3 THEN 1 ELSE 0 END)                           AS lapsed7d,
           SUM(CASE WHEN ?1 - last_seen >= ?4 THEN 1 ELSE 0 END)                           AS lapsed30d,
           SUM(CASE WHEN ?1 - last_seen <  ?2 THEN 1 ELSE 0 END)                           AS d1,
           SUM(CASE WHEN ?1 - last_seen >= ?2 AND ?1 - last_seen < ?3 THEN 1 ELSE 0 END)   AS d1_7,
           SUM(CASE WHEN ?1 - last_seen >= ?3 AND ?1 - last_seen < ?4 THEN 1 ELSE 0 END)   AS d7_30,
           SUM(CASE WHEN ?1 - last_seen >= ?4 THEN 1 ELSE 0 END)                           AS d30
         FROM devices`
      ).bind(now, DAY, WEEK, MONTH).first();
      retention = {
        total: rt?.total || 0,
        oneAndDone: rt?.oneAndDone || 0,
        returning: rt?.retained || 0,
        active7: rt?.active7 || 0,
        lapsed7d: rt?.lapsed7d || 0,
        lapsed30d: rt?.lapsed30d || 0,
        dist: { d1: rt?.d1 || 0, d1_7: rt?.d1_7 || 0, d7_30: rt?.d7_30 || 0, d30: rt?.d30 || 0 },
      };
    } catch {
      // keep defaults
    }

    // Weekly install cohorts (last 12 weeks): cohort size + how many are still
    // active (pinged in the last 7d). Shows whether newer cohorts stick.
    let cohorts = [];
    try {
      const co = await env.STATS.prepare(
        `SELECT date(first_seen / 1000, 'unixepoch', 'weekday 0') AS week,
                COUNT(*)                                          AS size,
                SUM(CASE WHEN last_seen > ?1 - ?2 THEN 1 ELSE 0 END) AS active
         FROM devices GROUP BY week ORDER BY week DESC LIMIT 12`
      ).bind(now, 7 * 86400000).all();
      cohorts = (co?.results || []).map((r) => ({
        week: String(r.week || ""), size: r.size || 0, active: r.active || 0,
      }));
    } catch {
      cohorts = [];
    }

    // How many times each install has opened the macro (session count), bucketed.
    // Computed entirely in SQL so we never ship one row per device to the client.
    let sessionFreq = [];
    try {
      const sf = await env.STATS.prepare(
        `SELECT bucket, COUNT(*) AS n FROM (
           SELECT CASE WHEN c = 1 THEN '1' WHEN c <= 5 THEN '2-5' ELSE '6+' END AS bucket
           FROM (SELECT device_id, COUNT(*) AS c FROM sessions GROUP BY device_id)
         ) GROUP BY bucket`
      ).all();
      const m = {};
      for (const r of sf?.results || []) m[r.bucket] = r.n || 0;
      sessionFreq = [
        { bucket: "1", n: m["1"] || 0 },
        { bucket: "2-5", n: m["2-5"] || 0 },
        { bucket: "6+", n: m["6+"] || 0 },
      ];
    } catch {
      sessionFreq = [];
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

    // Health: activity heatmap (session starts by day-of-week x hour, all-time, UTC).
    let heatmap = [];
    try {
      const hm = await env.STATS.prepare(
        `SELECT CAST(strftime('%w', started_at / 1000, 'unixepoch') AS INTEGER) AS dow,
                CAST(strftime('%H', started_at / 1000, 'unixepoch') AS INTEGER) AS hour,
                COUNT(*) AS n
         FROM sessions GROUP BY dow, hour`
      ).all();
      heatmap = (hm?.results || []).map((r) => ({ dow: r.dow || 0, hour: r.hour || 0, n: r.n || 0 }));
    } catch {
      heatmap = [];
    }

    // Health: session-length distribution. Very short sessions (single ping) are
    // the red flag that the macro isn't working for that user.
    let sessionLengths = [];
    try {
      const sl = await env.STATS.prepare(
        `SELECT CASE
            WHEN pings <= 1 THEN '<1m'
            WHEN (last_ping - started_at) < 300000   THEN '1-5m'
            WHEN (last_ping - started_at) < 900000   THEN '5-15m'
            WHEN (last_ping - started_at) < 3600000  THEN '15-60m'
            WHEN (last_ping - started_at) < 10800000 THEN '1-3h'
            ELSE '3h+' END AS bucket,
          COUNT(*) AS n FROM sessions GROUP BY bucket`
      ).all();
      const m = {};
      for (const r of sl?.results || []) m[r.bucket] = r.n || 0;
      sessionLengths = ["<1m", "1-5m", "5-15m", "15-60m", "1-3h", "3h+"].map((b) => ({ bucket: b, n: m[b] || 0 }));
    } catch {
      sessionLengths = [];
    }

    // Health: short-session rate per version. A build with a high share of
    // single-ping sessions probably broke something.
    let shortByVersion = [];
    try {
      const sv = await env.STATS.prepare(
        `SELECT version, COUNT(*) AS total, SUM(CASE WHEN pings <= 1 THEN 1 ELSE 0 END) AS short
         FROM sessions WHERE version IS NOT NULL AND version <> '' GROUP BY version`
      ).all();
      shortByVersion = (sv?.results || []).map((r) => ({
        version: String(r.version), total: r.total || 0, short: r.short || 0,
      }));
    } catch {
      shortByVersion = [];
    }

    // Acquisition: per-channel install count + how many clicked Get access (intent)
    // + how many came back a later day (quality). LEFT JOIN a distinct get_access set
    // so we measure click-through without a correlated subquery.
    let acqSources = [], acqPromos = [];
    const acqCols = (col) =>
      `SELECT d.${col} AS k, COUNT(*) AS installs,
              SUM(CASE WHEN ga.device_id IS NOT NULL THEN 1 ELSE 0 END) AS getAccess,
              SUM(CASE WHEN d.last_seen - d.first_seen >= 86400000 THEN 1 ELSE 0 END) AS retained
       FROM devices d
       LEFT JOIN (SELECT DISTINCT device_id FROM events WHERE name = 'get_access') ga ON ga.device_id = d.id
       WHERE d.${col} IS NOT NULL AND d.${col} <> ''
       GROUP BY d.${col} ORDER BY installs DESC`;
    try {
      const sr = await env.STATS.prepare(acqCols("src")).all();
      acqSources = (sr?.results || []).map((r) => ({
        source: String(r.k), installs: r.installs || 0, getAccess: r.getAccess || 0, returning: r.retained || 0,
      }));
      const pr2 = await env.STATS.prepare(acqCols("promo")).all();
      acqPromos = (pr2?.results || []).map((r) => ({
        code: String(r.k), installs: r.installs || 0, getAccess: r.getAccess || 0, returning: r.retained || 0,
      }));
    } catch {
      // events table absent -> fall back to installs + returning only (no getAccess).
      const fb = (col) =>
        `SELECT ${col} AS k, COUNT(*) AS installs, 0 AS getAccess,
                SUM(CASE WHEN last_seen - first_seen >= 86400000 THEN 1 ELSE 0 END) AS retained
         FROM devices WHERE ${col} IS NOT NULL AND ${col} <> '' GROUP BY ${col} ORDER BY installs DESC`;
      try {
        const sr = await env.STATS.prepare(fb("src")).all();
        acqSources = (sr?.results || []).map((r) => ({
          source: String(r.k), installs: r.installs || 0, getAccess: 0, returning: r.retained || 0,
        }));
        const pr2 = await env.STATS.prepare(fb("promo")).all();
        acqPromos = (pr2?.results || []).map((r) => ({
          code: String(r.k), installs: r.installs || 0, getAccess: 0, returning: r.retained || 0,
        }));
      } catch {
        acqSources = []; acqPromos = [];
      }
    }

    // Total session count (context for the Sessions tab, which shows the latest 100).
    let sessionsCount = 0;
    try {
      const sc = await env.STATS.prepare(`SELECT COUNT(*) AS n FROM sessions`).first();
      sessionsCount = sc?.n || 0;
    } catch {
      sessionsCount = 0;
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
      sessionsCount,
      funnel,
      daily,
      versions,
      retention,
      cohorts,
      sessionFreq,
      heatmap,
      sessionLengths,
      shortByVersion,
      acqSources,
      acqPromos,
      totalHours,
      at: now,
    });
  } catch (e) {
    return json({ error: "query failed", detail: String(e && e.message || e) }, 500);
  }
}
