// Minimal fetch-based Stripe client. Stripe's API takes
// application/x-www-form-urlencoded bodies with bracket notation for nested
// fields, e.g. subscription_data[metadata][google_id]=123.

function toFormBody(obj, prefix) {
  const pairs = [];
  const add = (key, val) => {
    if (val === undefined || val === null) return;
    if (Array.isArray(val)) {
      val.forEach((v, i) => add(`${key}[${i}]`, v));
    } else if (typeof val === "object") {
      for (const k of Object.keys(val)) add(`${key}[${k}]`, val[k]);
    } else {
      pairs.push(encodeURIComponent(key) + "=" + encodeURIComponent(val));
    }
  };
  for (const k of Object.keys(obj)) add(prefix ? `${prefix}[${k}]` : k, obj[k]);
  return pairs.join("&");
}

// opts.version pins a Stripe-Version header for THIS call only (used by the money
// endpoint to lock the invoice->charge response shape across Stripe API versions —
// see _lib/money.js STRIPE_API_VERSION). Omitting it uses the account default.
async function stripe(env, method, path, params, opts = {}) {
  const headers = { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` };
  if (opts.version) headers["Stripe-Version"] = opts.version;
  const reqOpts = { method, headers };
  let url = "https://api.stripe.com" + path;
  if (params && method === "GET") {
    const q = toFormBody(params);
    if (q) url += (path.includes("?") ? "&" : "?") + q;
  } else if (params) {
    reqOpts.headers["Content-Type"] = "application/x-www-form-urlencoded";
    reqOpts.body = toFormBody(params);
  }
  const res = await fetch(url, reqOpts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error((data && data.error && data.error.message) || `Stripe ${res.status}`);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

export function createCheckoutSession(env, params) {
  return stripe(env, "POST", "/v1/checkout/sessions", params);
}

// Stripe-hosted billing portal: lets a customer update their payment method,
// view/download invoices, or cancel. Requires the portal to be enabled once in
// the Stripe dashboard (Settings -> Billing -> Customer portal).
export function createBillingPortalSession(env, params) {
  return stripe(env, "POST", "/v1/billing_portal/sessions", params);
}

export function getCheckoutSession(env, id) {
  // Expand subscription so we can read its status directly.
  return stripe(env, "GET", `/v1/checkout/sessions/${encodeURIComponent(id)}`, {
    "expand[0]": "subscription",
  });
}

export function getSubscription(env, id) {
  return stripe(env, "GET", `/v1/subscriptions/${encodeURIComponent(id)}`);
}

export function listSubscriptions(env, customerId) {
  return stripe(env, "GET", "/v1/subscriptions", {
    customer: customerId,
    status: "all",
    limit: 10,
  });
}

// Self-heal lookup when we only know the Google sub (e.g. KV was wiped). We set
// metadata.google_id on the subscription at checkout, so search by it.
export function searchSubscriptionsByGoogleId(env, googleId) {
  const query = `metadata['google_id']:'${googleId}'`;
  return stripe(env, "GET", `/v1/subscriptions/search?query=${encodeURIComponent(query)}`);
}

// Look up a Stripe promotion code by its customer-facing code string (e.g. "LION").
// Returns the list payload { data: [{ code, times_redeemed, active, ... }] }; data
// is empty if no such promotion code exists. Used by the creator dashboard to count
// how many people redeemed a creator's code at checkout (times_redeemed).
export function listPromotionCodes(env, code) {
  return stripe(env, "GET", "/v1/promotion_codes", { code, limit: 1 });
}

// ---- Money/payout reads (used by _lib/money.js) -------------------------
// These accept a pinned Stripe-Version (`version`) so the invoice->charge shape is
// deterministic, and take raw `params` so the caller controls pagination/expand.

export function getPrice(env, id, version) {
  return stripe(env, "GET", `/v1/prices/${encodeURIComponent(id)}`, null, { version });
}

export function listInvoicesPage(env, params, version) {
  return stripe(env, "GET", "/v1/invoices", params, { version });
}

export function listSubscriptionsPage(env, params, version) {
  return stripe(env, "GET", "/v1/subscriptions", params, { version });
}

export function listRefundsPage(env, params, version) {
  return stripe(env, "GET", "/v1/refunds", params, { version });
}

export function listPromotionCodesPage(env, params, version) {
  return stripe(env, "GET", "/v1/promotion_codes", params, { version });
}
