// Shared helpers for the in-macro support chat (see migrations/0010_add_support.sql).
//
// Two callers, one shape: /api/support (the macro, keyed by anonymous device id) and
// /api/support/admin (me, gated by STATS_KEY). Both read the same transcript, so the
// row -> JSON mapping lives here and can only be wrong in one place.

// The macro's install id is a Windows GUID with the braces stripped, and the macro
// itself re-generates anything that fails this exact test (GetOrCreateDeviceId), so a
// value that does not match cannot have come from a real install.
export const DEVICE_RE = /^[A-Za-z0-9-]{8,64}$/;

// Longest single message we store. Generous for a bug description, small enough that
// nobody can use the chat as free blob storage.
export const MAX_BODY = 2000;

// Messages returned per transcript fetch. The macro re-renders the whole list on every
// poll (no append/dedupe logic to get wrong), so this doubles as the payload cap.
export const PAGE = 100;

export function validDevice(id) {
  return DEVICE_RE.test(String(id || "").trim());
}

// Trim + hard-cap a message body. Returns "" for anything unusable so callers can
// reject with one falsy check.
export function cleanBody(s) {
  const t = String(s == null ? "" : s).replace(/\r\n/g, "\n").trim();
  if (!t) return "";
  return t.slice(0, MAX_BODY);
}

// Newest PAGE messages for one thread, returned oldest-first (reading order).
// The caller decides what a missing table means; this just throws.
export async function loadMessages(env, deviceId, limit = PAGE) {
  const rows = await env.STATS.prepare(
    `SELECT id, sender, body, created_at FROM support_messages
     WHERE device_id = ?1 ORDER BY id DESC LIMIT ?2`
  )
    .bind(deviceId, limit)
    .all();
  const list = ((rows && rows.results) || []).map((r) => ({
    id: r.id,
    from: r.sender === "admin" ? "admin" : "user",
    body: r.body || "",
    at: r.created_at,
  }));
  list.reverse();
  return list;
}

export async function loadThread(env, deviceId) {
  return env.STATS.prepare(
    `SELECT device_id, created_at, last_msg_at, last_user_at, last_admin_at,
            unread_admin, unread_user, version, is_pro, closed
     FROM support_threads WHERE device_id = ?1`
  )
    .bind(deviceId)
    .first();
}

// Append one message. Returns its row id so the macro can advance its "last seen" cursor.
export async function insertMessage(env, deviceId, sender, body, at) {
  const res = await env.STATS.prepare(
    `INSERT INTO support_messages (device_id, sender, body, created_at) VALUES (?1, ?2, ?3, ?4)`
  )
    .bind(deviceId, sender, body, at)
    .run();
  return (res && res.meta && res.meta.last_row_id) || 0;
}

// Highest message id in a thread, 0 if the thread has none. This is the cursor the
// macro compares against its saved "last seen" id to decide whether to light the
// Support tab's unread dot, so it must stay cheap -- it runs on a background timer.
export async function lastMessageId(env, deviceId) {
  const row = await env.STATS.prepare(
    `SELECT MAX(id) AS n FROM support_messages WHERE device_id = ?1`
  )
    .bind(deviceId)
    .first();
  return (row && row.n) || 0;
}
