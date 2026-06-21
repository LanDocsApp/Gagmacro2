// POST /api/ping — anonymous usage heartbeat from the macro.
//
// Body: { "id": "<random device id>", "v": "<app version>" }
// Upserts one row per install into the STATS D1 table (no PII — just a random
// id the macro generates once and stores locally). Powers /api/stats.
//
// Fire-and-forget from the client: always returns 200 quickly, never errors out
// loud, so a stats hiccup can never affect the macro.

import { json } from "../_lib/http.js";

export async function onRequestPost({ request, env }) {
  let id = "";
  let version = "";
  try {
    const body = await request.json();
    id = String((body && body.id) || "").trim().slice(0, 64);
    version = String((body && body.v) || "").trim().slice(0, 32);
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
      await env.STATS.prepare(
        `INSERT INTO devices (id, first_seen, last_seen, version)
         VALUES (?1, ?2, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET last_seen = ?2, version = ?3`
      )
        .bind(id, now, version || null)
        .run();
    } catch {
      // Never let a stats write surface as an error to the macro.
    }
  }

  return json({ ok: true });
}
