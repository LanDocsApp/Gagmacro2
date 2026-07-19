// POST /api/support/admin — owner-only reply console for the in-macro support chat
// (support-admin.html). The other half of /api/support.
//
// ADMIN ONLY: gated by STATS_KEY (the same key as /api/stats and the giveaway console --
// no new secret). Body { key, action, device?, body? }:
//   "list"   -> every thread, newest first, with a preview + unread flag (the inbox)
//   "thread" -> one thread's full transcript; opening it clears MY unread flag
//   "reply"  -> append an admin message and light the user's Support tab dot
//   "close"  -> mark resolved (a new user message re-opens it automatically)
//   "reopen" -> undo close
//   "delete" -> drop a thread and its messages (spam)
//
// Threads are keyed by the macro's anonymous install id, so there is no name or email to
// show here: the device id, the macro version they wrote from, and what they typed is
// the whole record. Every action returns the state the page needs to re-render from one
// response, matching the giveaway console.

import { json } from "../../_lib/http.js";
import { validDevice, cleanBody, loadMessages, loadThread, insertMessage } from "../../_lib/support.js";

// Inbox page size. One person answering support will never scroll past this.
const LIST_LIMIT = 100;
// Characters of the newest message shown on an inbox row.
const PREVIEW = 140;

// The inbox: one row per conversation, unread first, then newest.
async function listThreads(env) {
  const rows = await env.STATS.prepare(
    `SELECT t.device_id, t.created_at, t.last_msg_at, t.last_user_at, t.last_admin_at,
            t.unread_admin, t.unread_user, t.version, t.is_pro, t.closed,
            (SELECT COUNT(*) FROM support_messages m WHERE m.device_id = t.device_id) AS n,
            (SELECT m.body FROM support_messages m WHERE m.device_id = t.device_id
              ORDER BY m.id DESC LIMIT 1) AS last_body,
            (SELECT m.sender FROM support_messages m WHERE m.device_id = t.device_id
              ORDER BY m.id DESC LIMIT 1) AS last_sender
     FROM support_threads t
     ORDER BY t.unread_admin DESC, t.last_msg_at DESC
     LIMIT ?1`
  )
    .bind(LIST_LIMIT)
    .all();
  return ((rows && rows.results) || []).map((r) => ({
    device: r.device_id,
    createdAt: r.created_at,
    lastAt: r.last_msg_at,
    lastUserAt: r.last_user_at,
    lastAdminAt: r.last_admin_at,
    unread: !!r.unread_admin,
    awaitingUser: !!r.unread_user,
    version: r.version || "",
    isPro: !!r.is_pro,
    closed: !!r.closed,
    count: r.n || 0,
    preview: String(r.last_body || "").slice(0, PREVIEW),
    lastFrom: r.last_sender === "admin" ? "admin" : "user",
  }));
}

// Full state for the page: the inbox, plus the open thread's transcript if one is selected.
async function state(env, device) {
  let threads = [];
  try {
    threads = await listThreads(env);
  } catch {
    threads = []; // table not applied yet
  }

  let messages = null;
  let thread = null;
  if (device) {
    try {
      messages = await loadMessages(env, device, 500);
      thread = await loadThread(env, device);
    } catch {
      messages = [];
      thread = null;
    }
  }

  return json({
    threads,
    unread: threads.filter((t) => t.unread).length,
    device: device || "",
    messages,
    closed: thread && thread.closed ? 1 : 0,
    at: Date.now(),
  });
}

export async function onRequestPost({ request, env }) {
  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }

  const key = String(body.key || "").trim();
  if (!env.STATS_KEY || key !== env.STATS_KEY) return json({ error: "unauthorized" }, 401);
  if (!env.STATS) return json({ error: "stats database not bound" }, 500);

  const action = String(body.action || "list").trim();
  const device = String(body.device || "").trim();
  const now = Date.now();

  if (action === "list") return state(env, device && validDevice(device) ? device : "");

  // Everything below acts on one thread.
  if (!validDevice(device)) return json({ error: "bad_device" }, 400);

  if (action === "thread") {
    // Opening a thread IS reading it.
    try {
      await env.STATS.prepare(`UPDATE support_threads SET unread_admin = 0 WHERE device_id = ?1`)
        .bind(device)
        .run();
    } catch {
      // Not fatal -- worst case the row stays bold in the inbox.
    }
    return state(env, device);
  }

  if (action === "reply") {
    const text = cleanBody(body.body);
    if (!text) return json({ error: "empty" }, 400);
    try {
      await insertMessage(env, device, "admin", text, now);
      // A reply only ever lands in a thread the user already started, so the row exists;
      // the upsert is belt-and-braces for a hand-deleted row.
      await env.STATS.prepare(
        `INSERT INTO support_threads
           (device_id, created_at, last_msg_at, last_admin_at, unread_admin, unread_user, closed)
         VALUES (?1, ?2, ?2, ?2, 0, 1, 0)
         ON CONFLICT(device_id) DO UPDATE SET
           last_msg_at   = ?2,
           last_admin_at = ?2,
           unread_admin  = 0,
           unread_user   = 1`
      )
        .bind(device, now)
        .run();
    } catch (e) {
      return json({ error: "could_not_reply", detail: String((e && e.message) || e) }, 500);
    }
    return state(env, device);
  }

  if (action === "close" || action === "reopen") {
    try {
      await env.STATS.prepare(`UPDATE support_threads SET closed = ?2 WHERE device_id = ?1`)
        .bind(device, action === "close" ? 1 : 0)
        .run();
    } catch (e) {
      return json({ error: "could_not_update", detail: String((e && e.message) || e) }, 500);
    }
    return state(env, action === "close" ? "" : device);
  }

  if (action === "delete") {
    try {
      await env.STATS.prepare(`DELETE FROM support_messages WHERE device_id = ?1`).bind(device).run();
      await env.STATS.prepare(`DELETE FROM support_threads WHERE device_id = ?1`).bind(device).run();
    } catch (e) {
      return json({ error: "could_not_delete", detail: String((e && e.message) || e) }, 500);
    }
    return state(env, "");
  }

  return json({ error: "bad_action" }, 400);
}
