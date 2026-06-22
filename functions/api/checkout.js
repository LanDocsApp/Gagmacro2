// /api/checkout — create a Stripe Checkout session for the signed-in user.
// If they already have an active subscription, skip straight to their code.

import { createCheckoutSession } from "../_lib/stripe.js";
import { getCustomerId, getSubStatus, isActiveStatus } from "../_lib/kv.js";
import { baseUrl, readSession, redirect } from "../_lib/http.js";

async function handle({ request, env }) {
  const base = baseUrl(request, env);

  const session = await readSession(request, env);
  if (!session) return redirect(`${base}/api/auth/google/login`);

  // Already subscribed -> no second checkout, send them to their paste-code.
  const customerId = await getCustomerId(env, session.sub);
  if (customerId) {
    const sub = await getSubStatus(env, customerId);
    if (sub && isActiveStatus(sub.status)) return redirect(`${base}/api/success`);
  }

  const params = {
    mode: "subscription",
    line_items: [{ price: env.STRIPE_PRICE_ID, quantity: 1 }],
    allow_promotion_codes: true,
    // Skip card collection when nothing is owed (e.g. a 100%-off-forever comp
    // for a creator). Paying customers still owe $4.50, so they're unaffected.
    payment_method_collection: "if_required",
    client_reference_id: session.sub,
    metadata: { google_id: session.sub },
    subscription_data: { metadata: { google_id: session.sub } },
    success_url: `${base}/api/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${base}/signin.html?checkout=cancelled`,
  };
  // Reuse the existing Stripe customer if we know it (avoids duplicates).
  if (customerId) params.customer = customerId;
  else if (session.email) params.customer_email = session.email;

  let checkout;
  try {
    checkout = await createCheckoutSession(env, params);
  } catch (e) {
    return redirect(`${base}/signin.html?error=checkout`);
  }
  return redirect(checkout.url);
}

export const onRequestGet = handle;
export const onRequestPost = handle;
