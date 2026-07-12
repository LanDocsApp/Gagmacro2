// GET /api/portal — the website "Manage subscription" button (post-login profile).
//
// Uses the signed session cookie (not a desktop token) to resolve the user's
// Stripe customer, then redirects to a one-time Stripe Billing Portal URL where
// they can update their card, view invoices, or cancel. This is the self-serve
// cancel path: the desktop macro now points people here instead of opening the
// portal itself, so this is the single place that lets a paying user cancel —
// and giving them a real cancel button is the biggest thing that prevents bank
// chargebacks.

import { resolveActive } from "../_lib/subscriptions.js";
import { getCustomerId } from "../_lib/kv.js";
import { createBillingPortalSession } from "../_lib/stripe.js";
import { readSession, redirect, baseUrl } from "../_lib/http.js";

export async function onRequestGet({ request, env }) {
  const base = baseUrl(request, env);

  const session = await readSession(request, env);
  if (!session) return redirect(`${base}/signin.html`);

  // Make sure the Google sub is linked to a Stripe customer. resolveActive
  // self-heals the link from Stripe (by google_id metadata) if KV was wiped,
  // so this works even right after a cold start — same as the desktop endpoint.
  try {
    await resolveActive(env, session.sub);
  } catch {
    /* fall through to the KV lookup */
  }
  const customerId = await getCustomerId(env, session.sub);
  if (!customerId) return redirect(`${base}/api/success?portal=none`);

  try {
    const portal = await createBillingPortalSession(env, {
      customer: customerId,
      return_url: `${base}/api/success`,
    });
    return redirect(portal.url);
  } catch {
    // e.g. Stripe portal config not saved, or a transient error. Send them back
    // to the profile page with a message rather than a raw error.
    return redirect(`${base}/api/success?portal=error`);
  }
}
