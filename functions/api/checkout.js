// /api/checkout — create a Stripe Checkout session for the signed-in user.
// If they already have an active subscription, skip straight to their code.
//
// Flash deal (A/B price test): an `offer` variant (1/2/3) may ride in on the query
// string (?offer=2) or the `gag_offer` cookie the sign-in page sets. When present we
// AUTO-APPLY the matching Stripe promotion code (first month 75%/65%/50% off), so the user
// lands on Checkout with the discount already applied — no code to paste. See
// functions/_lib/creators.js FLASH_CODES. The cookie is what carries the variant
// across the Google-login round-trip (the OAuth callback drops the query string).
//
// Creator codes work the same way: a `code` (e.g. ?code=LION) may ride in on the query
// string or the `gag_code` cookie when the user entered a creator code in the macro. The
// code string IS its own Stripe promotion code, so we look it up and AUTO-APPLY it too —
// no code to paste. Flash offer and creator code are mutually exclusive in the macro (the
// flash deal is suppressed for creator-code holders); if both somehow arrive, the flash wins.

import { createCheckoutSession, listPromotionCodes } from "../_lib/stripe.js";
import { getCustomerId, getSubStatus, isActiveStatus } from "../_lib/kv.js";
import { baseUrl, readSession, redirect, parseCookies, cookie } from "../_lib/http.js";
import { logEvent } from "../_lib/events.js";
import { flashCodeForVariant, creatorCode } from "../_lib/creators.js";

const OFFER_COOKIE = "gag_offer";
const CODE_COOKIE = "gag_code";
const OFFER_MAX_AGE = 30 * 60; // 30 min: long enough to cover the Google-login round-trip.

// Read + validate the flash variant from the query string (wins) or the cookie.
// Returns 1/2/3, or "" if none/invalid.
function readOffer(request) {
  const q = new URL(request.url).searchParams.get("offer");
  const c = parseCookies(request)[OFFER_COOKIE];
  const raw = String(q || c || "").trim();
  return /^[123]$/.test(raw) ? raw : "";
}

// Read + validate an entered creator code from the query string (wins) or the cookie.
// Returns the UPPERCASE code (e.g. "LION") only if it's a known creator code, else "".
function readCreatorCode(request) {
  const q = new URL(request.url).searchParams.get("code");
  const c = parseCookies(request)[CODE_COOKIE];
  return creatorCode(q || c || "");
}

// Look up the active promotion code id (promo_...) for a raw promotion-code STRING, or
// null. Best-effort: any Stripe hiccup returns null so checkout falls back to full price
// rather than failing the sale.
async function promotionIdForCode(env, code) {
  if (!code) return null;
  try {
    const res = await listPromotionCodes(env, code);
    const pc = ((res && res.data) || []).find((p) => p.active) || (res && res.data && res.data[0]);
    return pc && pc.id ? pc.id : null;
  } catch {
    return null;
  }
}

// The flash variant's promotion code id, or null. Thin wrapper over promotionIdForCode.
function flashPromotionId(env, offer) {
  return promotionIdForCode(env, flashCodeForVariant(offer));
}

async function handle({ request, env }) {
  const base = baseUrl(request, env);
  const offer = readOffer(request);
  const creator = readCreatorCode(request);

  const session = await readSession(request, env);
  if (!session) {
    // Not signed in yet -> send to Google login, but first stash the offer / creator
    // code in a cookie so it survives the round-trip (the OAuth callback drops query
    // strings), and the discount still auto-applies when they come back to checkout.
    const headers = new Headers({ Location: `${base}/api/auth/google/login` });
    if (offer) headers.append("Set-Cookie", cookie(OFFER_COOKIE, offer, { maxAge: OFFER_MAX_AGE }));
    if (creator) headers.append("Set-Cookie", cookie(CODE_COOKIE, creator, { maxAge: OFFER_MAX_AGE }));
    return new Response(null, { status: 302, headers });
  }

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
    // for a creator). Paying customers still owe the price, so they're unaffected.
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

  // Auto-apply a discount so the user never has to paste a code: the flash-deal
  // variant (?offer=) OR an entered creator code (?code=). At most one applies — if
  // both arrive the flash wins. `discounts` and `allow_promotion_codes` are mutually
  // exclusive in a Checkout Session, so swap when we attach one.
  let promoId = null;
  let appliedOffer = "";
  let appliedCode = "";
  if (offer) {
    promoId = await flashPromotionId(env, offer);
    if (promoId) appliedOffer = offer;
  }
  if (!promoId && creator) {
    promoId = await promotionIdForCode(env, creator);
    if (promoId) appliedCode = creator;
  }
  if (promoId) {
    params.discounts = [{ promotion_code: promoId }];
    delete params.allow_promotion_codes;
    if (appliedOffer) {
      params.metadata.offer = appliedOffer;
      params.subscription_data.metadata.offer = appliedOffer;
    }
    if (appliedCode) {
      params.metadata.promo = appliedCode;
      params.subscription_data.metadata.promo = appliedCode;
    }
  }

  let checkout;
  try {
    checkout = await createCheckoutSession(env, params);
  } catch (e) {
    // If a flash discount was attached and Checkout rejected it for any reason (a coupon
    // restriction, an archived/expired code, etc.) retry WITHOUT the discount so the sale
    // still goes through at full price rather than dead-ending on an error page. (Percent-
    // off coupons are currency-agnostic, so the old USD-vs-EUR mismatch can't happen here.)
    if (promoId) {
      delete params.discounts;
      params.allow_promotion_codes = true;
      delete params.metadata.offer;
      delete params.subscription_data.metadata.offer;
      delete params.metadata.promo;
      delete params.subscription_data.metadata.promo;
      promoId = null;
      try {
        checkout = await createCheckoutSession(env, params);
      } catch (e2) {
        return redirect(`${base}/signin.html?error=checkout`);
      }
    } else {
      return redirect(`${base}/signin.html?error=checkout`);
    }
  }
  // Funnel: a signed-in, not-yet-subscribed user is being sent to the pay page.
  // Tag the applied flash variant / creator code so /stats can group checkout intent.
  // Best-effort and never blocks the redirect.
  await logEvent(env, "checkout", {
    meta: {
      sub: session.sub,
      offer: promoId && appliedOffer ? appliedOffer : undefined,
      promo: promoId && appliedCode ? appliedCode : undefined,
    },
  });
  // Clear the offer / creator-code cookies now that they've been consumed into the session.
  const headers = new Headers({ Location: checkout.url });
  if (offer) headers.append("Set-Cookie", cookie(OFFER_COOKIE, "", { maxAge: 0 }));
  if (creator) headers.append("Set-Cookie", cookie(CODE_COOKIE, "", { maxAge: 0 }));
  return new Response(null, { status: 302, headers });
}

export const onRequestGet = handle;
export const onRequestPost = handle;
