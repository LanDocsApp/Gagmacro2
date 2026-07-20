// POST /api/support — the macro's Support tab (macro.ahk). The user side of the chat.
//
// Body: { device, v?, pro?, action, body?, seen? }
//   "fetch" -> the transcript (last 100). `seen: 1` also clears the unread dot, so the
//              macro sends that only when the tab is actually on screen.
//   "send"  -> append a user message, then return the fresh transcript (one round trip,
//              so the macro never has to merge a local echo with the server's copy).
//   "check" -> { lastId, unread } and nothing else. This is the background poll that
//              runs while the tab is CLOSED, so it must stay tiny.
//
// Auth is the macro's anonymous install id (device.txt) and nothing else, on purpose:
// the whole point of this tab is that a user with a problem does not have to hand over
// an email or a Discord name before I can answer them. That makes the device id a
// bearer token -- see the migration for why that trade is the right one here.
//
// UNAUTHENTICATED WRITE PATH, so it is deliberately narrow:
//   - device id must match the macro's own GUID shape
//   - one message is capped at MAX_BODY; nothing else in the body is stored as-is
//   - RATE_MAX messages per device per hour, counted in the DB (no counter to forge)
//   - the only free-form field is the message itself, which is what the feature is for
//
// A missing table (migration not applied yet) answers as an empty thread rather than
// 500ing, so shipping the macro before the migration only means "no messages", never a
// broken tab.

import { json } from "../_lib/http.js";
import {
  validDevice,
  cleanBody,
  loadMessages,
  loadThread,
  insertMessage,
  lastMessageId,
} from "../_lib/support.js";

// Per-device flood limit: 20 messages per rolling hour. A real conversation never gets
// close; a script trying to fill the table stops after 20 rows an hour.
const RATE_MAX = 20;
const RATE_WINDOW_MS = 60 * 60 * 1000;

// Don't ping Discord for every message in a burst -- someone typing four lines in a row
// is one notification, not four. A new message pings if the thread has been quiet for
// this long, or if I have replied since their last one (i.e. it is a fresh turn).
const PING_QUIET_MS = 5 * 60 * 1000;

// Discord webhook for "someone wrote in" pings, so I don't have to sit on the admin page.
// Hardcoded rather than an env var: it is the same URL the old bug-report modal shipped
// INSIDE macro.ahk, so it is already in this repo's public history and treating it as a
// secret now buys nothing. The only thing knowing it allows is posting junk into that
// Discord channel; if that ever happens, make a new webhook and swap this line.
//
// This is now server-side only -- it is no longer handed to every user's machine.
const SUPPORT_WEBHOOK = "https://discord.com/api/webhooks/1526917578927112244/yMU9Ma9lp03dY5GGd320GFex_cwuabhaSuOMt2ztZOSt8bguaEGdKEi2xuic643nKYZP";

// Never allowed to fail the request: the user's message is already stored by the time
// this runs, so a broken webhook must not turn a successful send into an error.
async function pingDiscord(env, deviceId, body, version, isFirst) {
  const url = SUPPORT_WEBHOOK;
  if (!url) return;
  const base = (env.PUBLIC_BASE_URL || "https://gardenmacro.com").replace(/\/+$/, "");
  const preview = body.length > 900 ? body.slice(0, 900) + "..." : body;
  const payload = {
    embeds: [
      {
        title: isFirst ? "New support chat" : "New support message",
        description: preview,
        color: 1613013, // #18a355, the accent green
        fields: [
          { name: "Device", value: deviceId, inline: false },
          { name: "Version", value: version || "unknown", inline: true },
          { name: "Reply", value: base + "/support-admin", inline: true },
        ],
        timestamp: new Date().toISOString(),
      },
    ],
  };
  try {
    await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch {
    // Discord being down is not the user's problem: their message is already stored.
  }
}


// The macro's view of a thread. `unread` drives the green dot on the Support tab.
async function transcript(env, deviceId, thread) {
  let messages = [];
  try {
    messages = await loadMessages(env, deviceId);
  } catch {
    messages = []; // table not applied yet -> an empty conversation, not an error
  }
  return json({
    ok: true,
    messages,
    lastId: messages.length ? messages[messages.length - 1].id : 0,
    unread: thread && thread.unread_user ? 1 : 0,
    closed: thread && thread.closed ? 1 : 0,
  });
}

export async function onRequestPost(context) {
  const { request, env } = context;

  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }

  const device = String(body.device || "").trim();
  if (!validDevice(device)) return json({ ok: false, error: "bad_device" }, 400);
  if (!env.STATS) return json({ ok: false, error: "unavailable" }, 503);

  const action = String(body.action || "fetch").trim();
  const version = String(body.v || "").trim().slice(0, 32);
  const isPro = body.pro ? 1 : 0;
  const now = Date.now();

  // --- check: the background "any replies for me?" poll. Two cheap reads, no writes.
  if (action === "check") {
    let lastId = 0;
    let unread = 0;
    try {
      lastId = await lastMessageId(env, device);
      const t = await loadThread(env, device);
      unread = t && t.unread_user ? 1 : 0;
    } catch {
      lastId = 0;
      unread = 0;
    }
    return json({ ok: true, lastId, unread });
  }

  // --- send: append the user's message and hand back the updated transcript.
  if (action === "send") {
    const text = cleanBody(body.body);
    if (!text) return json({ ok: false, error: "empty" }, 400);

    let thread = null;
    try {
      thread = await loadThread(env, device);
    } catch {
      // The table is missing, which we can't fix here -- fall through to the insert so
      // the real error surfaces as could_not_send rather than a silent success.
      thread = null;
    }

    try {
      const since = now - RATE_WINDOW_MS;
      const row = await env.STATS.prepare(
        `SELECT COUNT(*) AS n FROM support_messages
         WHERE device_id = ?1 AND sender = 'user' AND created_at > ?2`
      )
        .bind(device, since)
        .first();
      if (((row && row.n) || 0) >= RATE_MAX) {
        return json({ ok: false, error: "rate_limited" }, 429);
      }
    } catch {
      // Can't count -> don't block a real user over it; the insert below is still capped.
    }

    try {
      await insertMessage(env, device, "user", text, now);
      await env.STATS.prepare(
        `INSERT INTO support_threads
           (device_id, created_at, last_msg_at, last_user_at, unread_admin, unread_user, version, is_pro, closed)
         VALUES (?1, ?2, ?2, ?2, 1, 0, ?3, ?4, 0)
         ON CONFLICT(device_id) DO UPDATE SET
           last_msg_at  = ?2,
           last_user_at = ?2,
           unread_admin = 1,
           unread_user  = 0,
           version      = ?3,
           is_pro       = ?4,
           closed       = 0`
      )
        .bind(device, now, version || null, isPro)
        .run();
    } catch (e) {
      return json({ ok: false, error: "could_not_send" }, 500);
    }

    // Notify me AFTER the write, and outside the response path: the user's message is
    // already safe, so a slow/broken webhook must not delay their confirmation.
    const quiet = !thread || !thread.last_user_at || now - thread.last_user_at > PING_QUIET_MS;
    const myTurn = thread && thread.last_admin_at && thread.last_admin_at > (thread.last_user_at || 0);
    if (quiet || myTurn) {
      const p = pingDiscord(env, device, text, version, !thread);
      if (context.waitUntil) context.waitUntil(p);
      else await p;
    }

    // unread_user was just cleared by the upsert, so re-reading the thread would only
    // tell us what we already know.
    return transcript(env, device, { unread_user: 0, closed: 0 });
  }

  // --- fetch (default): the transcript, optionally marking my replies as seen.
  let thread = null;
  try {
    thread = await loadThread(env, device);
  } catch {
    thread = null;
  }

  if (body.seen && thread && thread.unread_user) {
    try {
      await env.STATS.prepare(`UPDATE support_threads SET unread_user = 0 WHERE device_id = ?1`)
        .bind(device)
        .run();
      thread = Object.assign({}, thread, { unread_user: 0 });
    } catch {
      // Left unread -> the dot lingers until the next fetch. Harmless.
    }
  }

  return transcript(env, device, thread);
}
