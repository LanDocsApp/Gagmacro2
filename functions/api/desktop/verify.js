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

  let active;
  try {
    active = await resolveActive(env, payload.sub);
  } catch {
    active = null; // KV/infra error -> status undetermined (not a confirmed cancellation)
  }

  // Undetermined (Stripe/KV unreachable): do NOT answer a definitive "not subscribed".
  // A 200 {active:false} makes the macro treat this as a cancellation and previously
  // could delete the saved code, locking out a paying user over a transient blip.
  // Return 503 so the macro classifies it as "error" and keeps trusting the saved
  // code (its offline-trust path), exactly like a real outage. A genuine, confirmed
  // "no active subscription" still returns 200 {active:false} below and revokes access.
  if (active === null || active === undefined) {
    return json({ active: false, error: "unavailable" }, 503);
  }
  return json({ active });
}
