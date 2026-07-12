// GET /api/success — runs after Stripe Checkout (success_url) and also serves
// as the "your access" page for already-subscribed users.
//
// With ?session_id it confirms the checkout and writes the Google<->customer
// link + active status to KV. Either way it shows the user's paste-code: a
// signed desktop token over their Google sub that they paste into the launcher.

import { getCheckoutSession, getSubscription } from "../_lib/stripe.js";
import { linkUser, setSubStatus, getCustomerId, getSubStatus, isActiveStatus } from "../_lib/kv.js";
import { signToken } from "../_lib/crypto.js";
import { baseUrl, readSession, redirect, html, escapeHtml } from "../_lib/http.js";

export async function onRequestGet({ request, env }) {
  const base = baseUrl(request, env);

  const session = await readSession(request, env);
  if (!session) return redirect(`${base}/signin.html`);

  const url = new URL(request.url);
  const checkoutId = url.searchParams.get("session_id");
  let active = false;

  // Fresh from Checkout: confirm the session belongs to this user, persist KV.
  if (checkoutId) {
    try {
      const cs = await getCheckoutSession(env, checkoutId);
      if (cs && cs.client_reference_id === session.sub && cs.customer) {
        const customerId = typeof cs.customer === "string" ? cs.customer : cs.customer.id;
        await linkUser(env, session.sub, customerId);

        let status = cs.payment_status === "paid" ? "active" : "incomplete";
        if (cs.subscription) {
          const subId = typeof cs.subscription === "string" ? cs.subscription : cs.subscription.id;
          try {
            const s =
              typeof cs.subscription === "object" && cs.subscription.status
                ? cs.subscription
                : await getSubscription(env, subId);
            status = s.status;
          } catch {
            /* keep payment_status-derived value */
          }
        }
        await setSubStatus(env, customerId, { status, googleId: session.sub });
        active = isActiveStatus(status);
      }
    } catch {
      /* fall through to the KV lookup below */
    }
  }

  // Returning user (or checkout lookup failed): read status from KV.
  if (!active) {
    const customerId = await getCustomerId(env, session.sub);
    if (customerId) {
      const sub = await getSubStatus(env, customerId);
      active = !!(sub && isActiveStatus(sub.status));
    }
  }

  // The paste-code is tied to the Google sub; access is enforced at verify time.
  const pasteCode = await signToken(env.COOKIE_SECRET, "desktop", {
    t: "desktop",
    sub: session.sub,
    iat: Date.now(),
  });

  const portalNote = url.searchParams.get("portal");
  return html(renderPage({ base, email: session.email, active, pasteCode, portalNote }));
}

function renderPage({ base, email, active, pasteCode, portalNote }) {
  const banner = active
    ? `<div class="status ok">✓ Subscription active — you're all set.</div>`
    : `<div class="status warn">We couldn't confirm an active subscription yet.
         <a href="${base}/api/checkout">Subscribe</a> or refresh in a moment if you just paid.</div>`;

  // Message shown when the user just came back from (or failed to reach) the
  // Stripe billing portal via the "Manage subscription" button below.
  const portalBanner =
    portalNote === "error"
      ? `<div class="status warn">Couldn't open the billing page just now. Please try again in a moment.</div>`
      : portalNote === "none"
      ? `<div class="status warn">We couldn't find a subscription linked to your account yet.</div>`
      : "";

  // Subscription management ("Manage subscription") now lives on the sign-in
  // "Welcome back" page (signin.html), which is where the desktop macro sends
  // Pro users. This page just shows the access code + status.

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Your access — Garden Macro</title>
  <style>
    :root { --green:#16a34a; --green-dark:#15803d; --ink:#0f172a; --muted:#64748b; --line:#e2e8f0; --soft:#f8fafc; }
    * { box-sizing:border-box; margin:0; padding:0; }
    body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; color:var(--ink); background:var(--soft); line-height:1.6; min-height:100vh; display:grid; place-items:center; padding:24px; }
    .card { background:#fff; border:1px solid var(--line); border-radius:20px; padding:40px; max-width:520px; width:100%; box-shadow:0 16px 40px rgba(15,23,42,.06); }
    .mark { width:44px; height:44px; border-radius:12px; background:var(--green); display:grid; place-items:center; color:#fff; font-size:22px; margin-bottom:20px; }
    h1 { font-size:26px; letter-spacing:-.5px; margin-bottom:8px; }
    p.sub { color:var(--muted); margin-bottom:24px; }
    .status { font-size:14px; padding:12px 14px; border-radius:10px; margin-bottom:24px; }
    .status.ok { background:#ecfdf5; color:var(--green-dark); }
    .status.warn { background:#fef9c3; color:#854d0e; }
    .status a { color:inherit; font-weight:700; }
    label { display:block; font-size:13px; font-weight:600; color:var(--muted); margin-bottom:8px; }
    .code-row { display:flex; gap:8px; }
    .code { flex:1; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:13px; background:var(--soft); border:1px solid var(--line); border-radius:10px; padding:12px 14px; word-break:break-all; user-select:all; }
    .btn { background:var(--green); color:#fff; font-weight:600; font-size:14px; padding:0 18px; border:none; border-radius:10px; cursor:pointer; white-space:nowrap; }
    .btn:hover { background:var(--green-dark); }
    ol { margin:24px 0 0 18px; color:var(--muted); font-size:14px; }
    ol li { margin-bottom:6px; }
    .foot { margin-top:24px; font-size:12.5px; color:var(--muted); }
  </style>
</head>
<body>
  <div class="card">
    <div class="mark">🌱</div>
    <h1>You're in${email ? ", " + escapeHtml(email.split("@")[0]) : ""} 🎉</h1>
    <p class="sub">Copy your access code below and paste it into the Garden Macro launcher.</p>
    ${banner}
    ${portalBanner}
    <label for="code">Your paste-code</label>
    <div class="code-row">
      <div class="code" id="code">${escapeHtml(pasteCode)}</div>
      <button class="btn" id="copy">Copy</button>
    </div>
    <ol>
      <li>Open the Garden Macro launcher.</li>
      <li>When it asks for your access code, paste this in.</li>
      <li>That's it — it stays signed in and updates itself.</li>
    </ol>
    <p class="foot">Lost this code? Just <a href="${base}/signin.html">sign in</a> again to get it back.</p>
  </div>
  <script>
    document.getElementById("copy").addEventListener("click", async function () {
      try {
        await navigator.clipboard.writeText(document.getElementById("code").textContent);
        this.textContent = "Copied!";
        setTimeout(() => (this.textContent = "Copy"), 1500);
      } catch (e) {
        const r = document.createRange();
        r.selectNode(document.getElementById("code"));
        getSelection().removeAllRanges();
        getSelection().addRange(r);
      }
    });
  </script>
</body>
</html>`;
}
