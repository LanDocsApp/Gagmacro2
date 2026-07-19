// GET /api/stats?key=<STATS_KEY> — D1-only usage data for the dashboard. NO Stripe calls
// live here (that's /api/money, lazy-loaded by the Money tab), so this stays fast and cheap.
// Returns:
//   live          = distinct installs active in the last 2 minutes
//   todayActive   = distinct installs that started a session today (UTC)
//   todayNew      = installs whose first ping was today (UTC)
//   todayReturning= todayActive - todayNew (installs active today that installed earlier)
//   week          = distinct installs active in the last 7 days
//   total         = all installs ever seen (every row)
//   sessionsToday = sessions started since 00:00 UTC today
//   avgSession    = mean session length in ms (last_ping - started_at), all time
//   totalHours    = lifetime sum of all session durations, in hours
//   funnel        = { installs, getAccess, checkout, subscribe } conversion funnel
//   upgradeTime   = install->upgrade timing { count, medianMs, avgMs, buckets } from the
//                   first_seen -> first 'unlock' event delta per device (null figures if none)
//   daily         = last 30 UTC days [{ day, installs, active, subs, getAccess, checkout }]
//   versions      = current install count per app version [{ version, count }]
//   acqSources    = per source [{ source, installs, getAccess, returning }]
//   acqPromos     = per promo  [{ code,   installs, getAccess, returning }] (incl. zero-install creator codes)
//   flash         = flash-deal A/B price test funnel per variant { shown, clicked }
//   giveaway      = giveaway-page funnel (see the block below)
//   at            = server time
//
// The three "today" figures are derived from the SAME sources as the daily series, so the
// cards and the chart can never disagree: active comes from sessions started today, new from
// devices first seen today, and returning is exactly active - new. (They used to be computed
// from devices.last_seen independently, which let returning exceed active and made new +
// returning != active.) A device's first ping opens both its `devices` row and its first
// session, so every new install is also active today -- the subtraction can't go negative.
//
// Each block is computed defensively in its own try/catch so a missing column/table
// can never 500 the endpoint. Protected by the STATS_KEY env var (fails closed when unset).

import { json } from "../_lib/http.js";
import { CREATORS } from "../_lib/creators.js";
import { MACRO_CODE } from "../_lib/giveaways.js";

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
  const d = new Date(now);
  const midnightUtc = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());

  try {
    const row = await env.STATS.prepare(
      `SELECT
         COUNT(*)                                              AS total,
         SUM(CASE WHEN last_seen > ?1 THEN 1 ELSE 0 END)       AS live,
         SUM(CASE WHEN first_seen >= ?2 THEN 1 ELSE 0 END)     AS todayNew,
         SUM(CASE WHEN last_seen > ?3 THEN 1 ELSE 0 END)       AS week
       FROM devices`
    )
      .bind(liveCutoff, midnightUtc, weekCutoff)
      .first();

    // Session aggregates: sessions started today, distinct devices active today (the same
    // definition the daily chart uses), and mean session length (excluding single-ping
    // launches so the average reflects real use).
    const sess = await env.STATS.prepare(
      `SELECT
         SUM(CASE WHEN started_at >= ?1 THEN 1 ELSE 0 END)                     AS sessionsToday,
         COUNT(DISTINCT CASE WHEN started_at >= ?1 THEN device_id END)         AS todayActive,
         AVG(CASE WHEN pings > 1 THEN last_ping - started_at END)              AS avgSession
       FROM sessions`
    )
      .bind(midnightUtc)
      .first();

    const todayNew = row?.todayNew || 0;
    const todayActive = sess?.todayActive || 0;
    // Every install's first ping also opens its first session, so new ⊆ active and this
    // is a true partition. The clamp is belt-and-braces against clock skew.
    const todayReturning = Math.max(0, todayActive - todayNew);

    // Conversion funnel (events table may not exist yet -> zeros).
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
      // events table not created yet -> funnel shows installs only.
    }

    // 30-day daily trend: new installs + active devices + new paid subscribers + funnel
    // intent per day. `subs` is what the dashboard draws as the amber bar beside the green
    // installs bar — one 'subscribe' event per completed paid checkout (Stripe webhook).
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
      const insBy = {}, actBy = {}, subBy = {}, gaBy = {}, coBy = {};
      for (const r of ins?.results || []) insBy[r.day] = r.n || 0;
      for (const r of act?.results || []) actBy[r.day] = r.n || 0;
      try {
        // One pass over the events table for all three per-day series.
        const ev = await env.STATS.prepare(
          `SELECT name, date(ts / 1000, 'unixepoch') AS day, COUNT(*) AS n
           FROM events
           WHERE name IN ('get_access','checkout','subscribe') AND ts >= ?1
           GROUP BY name, day`
        ).bind(cutoff30).all();
        for (const r of ev?.results || []) {
          if (r.name === "get_access") gaBy[r.day] = r.n || 0;
          else if (r.name === "checkout") coBy[r.day] = r.n || 0;
          else if (r.name === "subscribe") subBy[r.day] = r.n || 0;
        }
      } catch {
        // events table absent -> get_access/checkout/subs stay 0.
      }
      daily = lastUtcDays(now, 30).map((day) => ({
        day,
        installs: insBy[day] || 0,
        active: actBy[day] || 0,
        subs: subBy[day] || 0,
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

    // Acquisition: per-channel + per-promo install count + Get-access CTR + returning.
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

    // Flash-deal A/B price test: per-variant funnel denominators from the events table.
    // shown/clicked are DISTINCT installs (people), grouped by the price arm in meta.offer.
    // The conversion numerator (paid subs) + net revenue per arm come from Stripe on the
    // Money tab (per-promotion-code), matched to these variants on the dashboard.
    let flash = { "1": { shown: 0, clicked: 0 }, "2": { shown: 0, clicked: 0 }, "3": { shown: 0, clicked: 0 } };
    try {
      const fr = await env.STATS.prepare(
        `SELECT json_extract(meta, '$.offer') AS variant,
                COUNT(DISTINCT CASE WHEN name = 'flash_shown' THEN device_id END) AS shown,
                COUNT(DISTINCT CASE WHEN name = 'flash_cta'   THEN device_id END) AS clicked
         FROM events
         WHERE name IN ('flash_shown','flash_cta')
           AND json_extract(meta, '$.offer') IN ('1','2','3')
         GROUP BY variant`
      ).all();
      for (const r of fr?.results || []) {
        const v = String(r.variant);
        if (flash[v]) flash[v] = { shown: r.shown || 0, clicked: r.clicked || 0 };
      }
    } catch {
      // events table / json_extract unavailable -> zeros (Money tab still shows conversions).
    }

    // Giveaway page funnel (giveaway.html). Three sources, each independently guarded:
    //   views/downloads/proClicks -- gw_* events posted by the page (/api/ev)
    //   checkouts/subscribes      -- normal checkout/subscribe events tagged meta.src='giveaway'
    //                                by /api/checkout + the Stripe webhook (server-side, so
    //                                the money numbers can't be inflated from the browser)
    //   entries/byCode            -- the giveaway_entries table (one row per Google account)
    // `byCode` splits entrants by the macro code they pasted: the shared code, a creator code
    // like LION, or none at all. Needs migration 0009; stays empty until it's applied.
    const giveaway = {
      views: 0, downloads: 0, proClicks: 0, checkouts: 0, subscribes: 0,
      entries: 0, entriesPro: 0, entriesMacro: 0, entriesBase: 0,
      byCode: [], codeAvailable: false,
      // The shared macro code, so the dashboard can label it without hardcoding the string.
      macroCode: String(MACRO_CODE || "").toUpperCase(),
    };
    try {
      const gv = await env.STATS.prepare(
        `SELECT name, COUNT(*) AS n FROM events
         WHERE name IN ('gw_view','gw_download','gw_pro') GROUP BY name`
      ).all();
      for (const r of gv?.results || []) {
        if (r.name === "gw_view") giveaway.views = r.n || 0;
        else if (r.name === "gw_download") giveaway.downloads = r.n || 0;
        else if (r.name === "gw_pro") giveaway.proClicks = r.n || 0;
      }
    } catch {
      // events table absent -> the click funnel stays at zero.
    }
    try {
      const gp = await env.STATS.prepare(
        `SELECT name, COUNT(*) AS n FROM events
         WHERE name IN ('checkout','subscribe')
           AND json_extract(meta, '$.src') = 'giveaway'
         GROUP BY name`
      ).all();
      for (const r of gp?.results || []) {
        if (r.name === "checkout") giveaway.checkouts = r.n || 0;
        else if (r.name === "subscribe") giveaway.subscribes = r.n || 0;
      }
    } catch {
      // json_extract unavailable -> paid steps stay at zero.
    }
    try {
      const ge = await env.STATS.prepare(
        `SELECT COUNT(*) AS n,
                SUM(CASE WHEN is_pro = 1 THEN 1 ELSE 0 END) AS pro,
                SUM(CASE WHEN is_pro = 0 AND has_macro = 1 THEN 1 ELSE 0 END) AS macro
         FROM giveaway_entries`
      ).first();
      giveaway.entries = ge?.n || 0;
      giveaway.entriesPro = ge?.pro || 0;
      giveaway.entriesMacro = ge?.macro || 0;
      giveaway.entriesBase = Math.max(0, giveaway.entries - giveaway.entriesPro - giveaway.entriesMacro);
    } catch {
      // giveaway_entries absent -> no entry figures.
    }
    try {
      const gc = await env.STATS.prepare(
        `SELECT UPPER(TRIM(COALESCE(code, ''))) AS k, COUNT(*) AS n
         FROM giveaway_entries GROUP BY k ORDER BY n DESC`
      ).all();
      giveaway.codeAvailable = true;
      giveaway.byCode = (gc?.results || []).map((r) => ({
        code: String(r.k || ""),   // "" = entered without a code
        entries: r.n || 0,
      }));
    } catch {
      // Pre-0009 database (no `code` column) -> the dashboard shows the "apply 0009" note.
      giveaway.codeAvailable = false;
      giveaway.byCode = [];
    }

    // Time-to-upgrade: how long each install took from first_seen (install) to its FIRST
    // device-linked 'unlock' event (the user activating a valid code in the macro). Reported
    // as median + mean + a bucketed distribution, so a few slow deciders can't skew the
    // headline figure. The macro fires 'unlock' only at first activation (not on relaunch),
    // so pre-launch subscribers with saved codes don't pollute this — it measures genuine
    // upgrades happening after this shipped, and fills in for post-launch cohorts.
    let upgradeTime = { count: 0, medianMs: null, avgMs: null, buckets: null };
    try {
      const ur = await env.STATS.prepare(
        `SELECT (MIN(e.ts) - d.first_seen) AS delta
         FROM events e JOIN devices d ON d.id = e.device_id
         WHERE e.name = 'unlock'
         GROUP BY e.device_id
         HAVING (MIN(e.ts) - d.first_seen) > 0`
      ).all();
      const deltas = (ur?.results || []).map((r) => r.delta).filter((x) => x > 0).sort((a, b) => a - b);
      const n = deltas.length;
      if (n) {
        const mid = Math.floor(n / 2);
        const median = n % 2 ? deltas[mid] : Math.round((deltas[mid - 1] + deltas[mid]) / 2);
        const avg = Math.round(deltas.reduce((s, x) => s + x, 0) / n);
        const H = 3600000, DAY = 86400000;
        const buckets = { lt1h: 0, h1to24: 0, d1to7: 0, d7to30: 0, gt30d: 0 };
        for (const x of deltas) {
          if (x < H) buckets.lt1h++;
          else if (x < DAY) buckets.h1to24++;
          else if (x < 7 * DAY) buckets.d1to7++;
          else if (x < 30 * DAY) buckets.d7to30++;
          else buckets.gt30d++;
        }
        upgradeTime = { count: n, medianMs: median, avgMs: avg, buckets };
      }
    } catch {
      // events/devices unavailable (or no unlocks yet) -> no upgrade-time data.
    }

    // Make every registered creator code show up in Acquisition, even with zero installs.
    try {
      const present = new Set(acqPromos.map((r) => String(r.code).toUpperCase()));
      for (const c of Object.values(CREATORS)) {
        for (const code of c.codes) {
          const CODE = String(code).toUpperCase();
          if (!present.has(CODE)) {
            present.add(CODE);
            acqPromos.push({ code: CODE, installs: 0, getAccess: 0, returning: 0 });
          }
        }
      }
    } catch {
      // registry unavailable -> just show the codes that have installs
    }

    return json({
      live: row?.live || 0,
      todayActive,
      todayNew,
      todayReturning,
      week: row?.week || 0,
      total: row?.total || 0,
      sessionsToday: sess?.sessionsToday || 0,
      avgSession: Math.round(sess?.avgSession || 0),
      totalHours,
      funnel,
      daily,
      versions,
      acqSources,
      acqPromos,
      flash,
      giveaway,
      upgradeTime,
      at: now,
    });
  } catch (e) {
    return json({ error: "query failed", detail: String(e && e.message || e) }, 500);
  }
}
