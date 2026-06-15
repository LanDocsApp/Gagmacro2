// POST /api/webhook — Stripe webhook. Verifies the signature with Web Crypto
// over the raw body, then keeps KV in sync with subscription state.

import { verifyStripeWebhook } from "../_lib/crypto.js";
import { getSubscription } from "../_lib/stripe.js";
import { linkUser, setSubStatus, getSubStatus } from "../_lib/kv.js";

export async function onRequestPost({ request, env }) {
  const sig = request.headers.get("stripe-signature") || "";
  const rawBody = await request.text(); // raw, unparsed — required for the HMAC

  const ok = await verifyStripeWebhook(rawBody, sig, env.STRIPE_WEBHOOK_SECRET);
  if (!ok) return new Response("invalid signature", { status: 400 });

  let event;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return new Response("invalid payload", { status: 400 });
  }

  const obj = (event.data && event.data.object) || {};

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const googleId = obj.client_reference_id || (obj.metadata && obj.metadata.google_id);
        const customerId = obj.customer;
        if (googleId && customerId) {
          await linkUser(env, googleId, customerId);
          let status = obj.payment_status === "paid" ? "active" : "incomplete";
          if (obj.subscription) {
            try {
              const s = await getSubscription(env, obj.subscription);
              status = s.status;
            } catch {
              /* keep payment_status-derived value */
            }
          }
          await setSubStatus(env, customerId, { status, googleId });
        }
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const customerId = obj.customer;
        if (customerId) {
          let googleId = obj.metadata && obj.metadata.google_id;
          if (!googleId) {
            const existing = await getSubStatus(env, customerId);
            googleId = existing && existing.googleId;
          }
          if (googleId) await linkUser(env, googleId, customerId);
          const status =
            event.type === "customer.subscription.deleted" ? "canceled" : obj.status;
          await setSubStatus(env, customerId, { status, googleId });
        }
        break;
      }

      default:
        break; // ignore everything else
    }
  } catch (e) {
    // Transient failure (e.g. KV/Stripe) — 500 so Stripe retries.
    return new Response("handler error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
}
