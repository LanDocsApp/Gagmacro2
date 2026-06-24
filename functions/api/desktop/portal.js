// POST /api/desktop/portal — called by the macro's "Manage subscription" button.
//
// Body: { "token": "<paste-code>" }  (also accepts a bare token string).
// Verifies the desktop token, resolves the user's Stripe customer (self-healing
// the Google<->customer link from Stripe if KV is cold), then mints a one-time
// Stripe Billing Portal URL where the user can update their card, view invoices,
// or cancel. Returns { url } on success.
//
// This is the self-serve cancel path: giving paying users an easy cancel button
// is the single biggest thing that prevents bank chargebacks.

import { verifyToken } from "../../_lib/crypto.js";
import { resolveActive } from "../../_lib/subscriptions.js";
import { getCustomerId } from "../../_lib/kv.js";
import { createBillingPortalSession } from "../../_lib/stripe.js";
import { json, baseUrl } from "../../_lib/http.js";

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
    return json({ error: "invalid_token" }, 401);
  }

  // Make sure the Google sub is linked to a Stripe customer. resolveActive
  // self-heals the link from Stripe (by google_id metadata) if KV was wiped,
  // so this works even right after a cold start.
  try {
    await resolveActive(env, payload.sub);
  } catch {
    /* fall through to the KV lookup */
  }
  const customerId = await getCustomerId(env, payload.sub);
  if (!customerId) {
    return json({ error: "no_customer" }, 404);
  }

  const base = baseUrl(request, env);
  try {
    const portal = await createBillingPortalSession(env, {
      customer: customerId,
      return_url: `${base}/api/success`,
    });
    return json({ url: portal.url });
  } catch {
    return json({ error: "portal_failed" }, 502);
  }
}
