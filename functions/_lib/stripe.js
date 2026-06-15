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

async function stripe(env, method, path, params) {
  const opts = { method, headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` } };
  let url = "https://api.stripe.com" + path;
  if (params && method === "GET") {
    const q = toFormBody(params);
    if (q) url += (path.includes("?") ? "&" : "?") + q;
  } else if (params) {
    opts.headers["Content-Type"] = "application/x-www-form-urlencoded";
    opts.body = toFormBody(params);
  }
  const res = await fetch(url, opts);
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
