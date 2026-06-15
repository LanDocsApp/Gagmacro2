// POST /api/desktop/verify — called by the AutoHotkey launcher.
//
// Body: { "token": "<paste-code>" }  (also accepts a bare token string).
// Verifies the desktop token signature, resolves the Google sub's subscription
// status from KV (self-healing from Stripe on miss/stale), and returns
// { active: true|false }.

import { verifyToken } from "../../_lib/crypto.js";
import { resolveActive } from "../../_lib/subscriptions.js";
import { json } from "../../_lib/http.js";

export async function onRequestPost({ request, env }) {
  let token = "";
  try {
    const ct = request.headers.get("Content-Type") || "";
    if (ct.includes("application/json")) {
      const body = await request.json();
      token = (body && (body.token || body.code)) || "";
    } else {
      token = await request.text();
    }
  } catch {
    token = "";
  }
  token = String(token || "").trim();

  const payload = await verifyToken(env.COOKIE_SECRET, "desktop", token);
  if (!payload || payload.t !== "desktop" || !payload.sub) {
    return json({ active: false }, 401);
  }

  let active = false;
  try {
    active = await resolveActive(env, payload.sub);
  } catch {
    active = false;
  }
  return json({ active });
}
