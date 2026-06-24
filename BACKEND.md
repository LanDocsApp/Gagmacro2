# Garden Macro — subscription backend

Cloudflare Pages + Pages Functions. No build step, no SDKs — raw `fetch` and Web
Crypto. Static pages live at the repo root; the API lives under `functions/`.

## Layout

```
functions/
  _lib/
    crypto.js          HMAC sign/verify (session + desktop token), Stripe webhook sig
    http.js            cookies, redirects, JSON/HTML, signed-session read, baseUrl
    google.js          Google OAuth (openid email profile)
    stripe.js          fetch-based Stripe client (form-encoded)
    kv.js              SUBS namespace access (user:/sub: keys)
    subscriptions.js   active-status resolution + self-heal from Stripe
  api/
    auth/google/login.js     GET  -> redirect to Google (CSRF state cookie)
    auth/google/callback.js  GET  -> exchange code, set signed session
    checkout.js              GET/POST -> Stripe Checkout (or skip if already active)
    success.js               GET  -> confirm checkout, write KV, show paste-code
    webhook.js               POST -> verify Stripe sig, sync KV
    desktop/verify.js        POST -> { token } -> { active: true|false }
    desktop/portal.js        POST -> { token } -> { url } (Stripe billing portal: manage/cancel)
index.html      marketing landing
signin.html     sign in with Google / get your code
wrangler.toml   Pages config + SUBS KV binding
```

## Config

KV binding `SUBS` is in `wrangler.toml`. These are set in the Cloudflare
dashboard (Pages → Settings → Environment variables), already configured:

- `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`, `STRIPE_WEBHOOK_SECRET`
- `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`
- `COOKIE_SECRET` (signs the session cookie + the desktop paste-code)
- optional `PUBLIC_BASE_URL` — only if served from a domain other than the
  request origin. Otherwise the origin is detected automatically.

External setup that must match:

- **Google** authorized redirect URI: `https://gardenmacro.com/api/auth/google/callback`
- **Stripe webhook** endpoint: `https://gardenmacro.com/api/webhook`, sending
  `checkout.session.completed` and `customer.subscription.created/updated/deleted`.

## Flow

1. `signin.html` → **Continue with Google** → `/api/auth/google/login`.
2. Google → `/api/auth/google/callback`: sets a signed HttpOnly session cookie,
   returns to `signin.html` (now showing "signed in").
3. **Get your access code** → `/api/checkout`: if already subscribed, jumps
   straight to the code; otherwise creates a Stripe Checkout session
   (`client_reference_id` = Google sub, `metadata.google_id` on both the session
   and the subscription).
4. After payment Stripe redirects to `/api/success?session_id=...`, which writes
   the `user:` / `sub:` KV records and shows the **paste-code**.
5. Stripe also calls `/api/webhook` to keep KV in sync on renewals/cancellations.

## KV model

- `user:{googleSub}` → `customerId`
- `sub:{customerId}` → `{ status, googleId, checkedAt }`

Active = `active`, `trialing`, or `past_due`.

## Launcher / macro integration (freemium)

The macro is **free** for everyone. The launcher (`launcher.ahk`) just
auto-updates and runs it — no subscription gate. Licensing lives in the macro:
the **last 5 seeds** are locked in the WebView UI until the user unlocks them.

The paste-code is a signed token over the user's Google sub. In the macro's
"Get access" modal the user pastes it; the macro calls:

```
POST https://gardenmacro.com/api/desktop/verify
Content-Type: application/json

{ "token": "<paste-code>" }
```

Response: `{ "active": true }` or `{ "active": false }`. On `active` the macro
saves the code to `%AppData%\GardenMacro\token.txt` and unlocks the last 5
seeds live; on the next launch it re-verifies in the background (and trusts the
saved code when offline). `/api/desktop/verify` self-heals from Stripe if KV is
cold or stale, so it stays correct even if a webhook is missed.

## Manage / cancel subscription (Account tab)

Once a user is Pro, the macro shows an **Account** tab with a **Manage
subscription** button. It POSTs the saved paste-code to `/api/desktop/portal`,
which verifies the token, resolves the Stripe customer (self-healing the link
from Stripe like `verify` does), and returns a one-time **Stripe Billing Portal**
URL. The macro opens it in the browser, where the user can update their card,
download invoices, or **cancel** — the self-serve cancel path that prevents bank
chargebacks. Cancellations flow back through `/api/webhook`, so KV (and the
macro's unlock state on next launch) stay in sync automatically.

> One-time setup: enable the portal in the Stripe dashboard at **Settings →
> Billing → Customer portal** (allow cancellation, invoice history, and
> payment-method updates), or `createBillingPortalSession` will error.

## Local dev

```
npx wrangler pages dev .
```

Provide the env vars via a `.dev.vars` file (not committed).
