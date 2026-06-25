// POST /api/ping — anonymous usage heartbeat from the macro.
//
// Body: { "id": "<random device id>", "v": "<app version>", "promo": "<code?>",
//         "src": "<acquisition source?>", "ev": "<funnel event?>" }
// Upserts one row per install into the STATS D1 `devices` table (no PII — just a
// random id the macro generates once and stores locally) and stitches pings into
// `sessions` rows. If the macro reports a creator promo code or an acquisition source
// ("where did you hear about us?"), each is stamped onto the install (sticky) for the
// /stats breakdown. If the macro reports a funnel event (currently just "get_access"
// when the user clicks the Get-access button), it's logged to the `events` table for
// the conversion funnel on the "New stats" tab. Powers /api/stats.
//
// Fire-and-forget from the client: always returns 200 quickly, never errors out
// loud, so a stats hiccup can never affect the macro.

import { json } from "../_lib/http.js";
import { logEvent } from "../_lib/events.js";

// Funnel events the heartbeat is allowed to report (keeps logEvent's allowlist in
// sync at the parse boundary). Today only the "Get access" click.
const PING_EVENTS = new Set(["get_access"]);

// A session is "still going" as long as pings keep arriving within this window.
// Pings fire every 60s; allowing ~2 missed beats means a flaky network or a brief
// sleep won't shatter one real session into many (which would inflate the session
// count and tank the average length). A gap longer than this starts a new session.
const SESSION_GAP_MS = 3 * 60 * 1000;

export async function onRequestPost({ request, env, waitUntil }) {
  let id = "";
  let version = "";
  let promo = "";
  let src = "";
  let ev = "";
  try {
    const body = await request.json();
    id = String((body && body.id) || "").trim().slice(0, 64);
    version = String((body && body.v) || "").trim().slice(0, 32);
    promo = String((body && body.promo) || "").trim().slice(0, 32).toUpperCase();
    if (promo && !/^[A-Z0-9 _-]{1,32}$/.test(promo)) promo = "";
    // Acquisition source: lowercase channel key (reddit / tiktok / ai / ...).
    src = String((body && body.src) || "").trim().slice(0, 24).toLowerCase();
    if (src && !/^[a-z0-9_-]{1,24}$/.test(src)) src = "";
    // Funnel event: a one-off signal the macro tags onto a heartbeat (not periodic).
    ev = String((body && body.ev) || "").trim().toLowerCase();
    if (!PING_EVENTS.has(ev)) ev = "";
  } catch {
    id = "";
  }

  // Accept only sane ids (hex/uuid-ish). Bad/empty -> quietly succeed.
  if (!id || !/^[A-Za-z0-9-]{8,64}$/.test(id)) {
    return json({ ok: true });
  }

  if (env.STATS) {
    const now = Date.now();
    try {
      // Upsert the install in a SINGLE write. promo + src are sticky (first reported
      // value wins, via COALESCE), so the macro re-sending them on every 60s heartbeat
      // no longer costs an extra UPDATE per ping -- they just ride along on this same
      // row write. This roughly halves D1 writes for attributed installs.
      //   RETURNING tells us whether the row was just created: a fresh insert has
      //   first_seen == now, a conflict-update keeps its older first_seen, so
      //   `first_seen = now` is a reliable "new install" flag.
      //   NOTE: this assumes the promo + src columns exist (they do in prod; added via
      //   the manual promo column and migrations/0002_add_src.sql). If they were ever
      //   absent the whole upsert would fail, but the outer try/catch keeps that from
      //   ever surfacing to the macro (the heartbeat always returns 200).
      const dev = await env.STATS.prepare(
        `INSERT INTO devices (id, first_seen, last_seen, version, promo, src)
         VALUES (?1, ?2, ?2, ?3, ?4, ?5)
         ON CONFLICT(id) DO UPDATE SET
           last_seen = ?2,
           version   = ?3,
           promo     = COALESCE(devices.promo, ?4),
           src       = COALESCE(devices.src, ?5)
         RETURNING (first_seen = ?2) AS is_new`
      )
        .bind(id, now, version || null, promo || null, src || null)
        .first();

      await recordSession(env, id, version, now);

      // Funnel event (e.g. "Get access" clicked). Best-effort; logEvent swallows a
      // missing `events` table so this can never break the heartbeat.
      if (ev) {
        await logEvent(env, ev, { deviceId: id, ts: now, meta: version ? { v: version } : null });
      }

      if (dev && dev.is_new) {
        // Off the response path so the Discord call never delays the macro.
        const p = notifyNewInstall(env, version, now);
        if (waitUntil) waitUntil(p);
        else await p.catch(() => {});
      }
    } catch {
      // Never let a stats write surface as an error to the macro.
    }
  }

  return json({ ok: true });
}

// Extend the device's current session, or open a new one if the last ping is
// older than the grace gap. Session length is read elsewhere as last_ping - started_at.
async function recordSession(env, id, version, now) {
  const last = await env.STATS.prepare(
    `SELECT session_id, last_ping FROM sessions
     WHERE device_id = ?1 ORDER BY last_ping DESC LIMIT 1`
  )
    .bind(id)
    .first();

  if (last && now - last.last_ping <= SESSION_GAP_MS) {
    await env.STATS.prepare(
      `UPDATE sessions SET last_ping = ?1, pings = pings + 1 WHERE session_id = ?2`
    )
      .bind(now, last.session_id)
      .run();
  } else {
    await env.STATS.prepare(
      `INSERT INTO sessions (device_id, started_at, last_ping, pings, version)
       VALUES (?1, ?2, ?2, 1, ?3)`
    )
      .bind(id, now, version || null)
      .run();
  }
}

// Post a minimal milestone to Discord when a brand-new install first pings.
// No-op if DISCORD_WEBHOOK_URL isn't configured.
async function notifyNewInstall(env, version, now) {
  const hook = env.DISCORD_WEBHOOK_URL && env.DISCORD_WEBHOOK_URL.trim();
  if (!hook) return;

  let total = 0;
  try {
    const row = await env.STATS.prepare(`SELECT COUNT(*) AS n FROM devices`).first();
    total = (row && row.n) || 0;
  } catch {
    /* count is best-effort */
  }

  const v = version ? " · v" + version : "";
  const content = `🌱 New install! Total installs: ${total.toLocaleString("en-US")}${v}`;

  try {
    await fetch(hook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content }),
    });
  } catch {
    /* Discord being down must never matter here */
  }
}
