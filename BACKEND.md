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
    creator/stats.js         POST -> { token } -> one creator's { installs, subscriptions } per code
    creator/link.js          GET  -> (admin, STATS_KEY) mint a creator's private dashboard link
    creator/payout.js        POST -> (admin, STATS_KEY + token) DISBURSEMENT ledger (list/add/delete)
    creator/payout-view.js   POST -> { token } -> creator's read-only earned/pending/paid + redemptions
    money.js                 GET  -> (admin, STATS_KEY) Money-tab data: active subs, MRR, this-month
                                     money, per-code net-settled earnings (heavy Stripe scan, lazy-loaded)
  _lib/
    creators.js        creator -> promo-code registry (mirror of macro.ahk PromoValid) + code purpose tags
    money.js           shared Stripe money math: net-settled per-code earnings, MRR, churn, avg lifetime
index.html      marketing landing
signin.html     sign in with Google / get your code
creator.html    per-creator stats dashboard (opened via a private signed link)
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
- optional `DISCORD_WEBHOOK_URL` — Discord channel webhook that gets a "new
  subscriber" ping on each paid checkout. Falls back to a hardcoded URL in
  `_lib/discord.js`; set this env var to rotate the webhook without a redeploy.

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

## Creator dashboard

Each creator (a hardcoded set in `_lib/creators.js`, kept in sync with the macro's
`PromoValid`) can see how their promo code is performing without seeing anyone
else's data. A creator may own more than one code (e.g. jukemplayz = ROOKIE +
JUKEM); their dashboard aggregates across all of them with a per-code breakdown.

- **Login = a private signed link.** The link's URL fragment is an HMAC token over
  `{ t:"creator", id:"<slug>" }` (signed with `COOKIE_SECRET`, same scheme as the
  desktop paste-code). `creator.html` reads it, remembers it in `localStorage`, and
  POSTs it to `/api/creator/stats`. No passwords, no per-creator secrets stored.
- **Installs** = `COUNT(*)` of `devices` rows whose `promo` is one of the creator's
  codes (D1 `STATS`).
- **Subscriptions** = each code's Stripe **promotion code** `times_redeemed` (the
  codes double as Stripe promo codes at checkout). Shows `—` if Stripe is
  unreachable, and flags a code as unlinked if no Stripe promotion code matches it.

To onboard a creator, hit (with your `STATS_KEY`):

```
GET /api/creator/link?key=<STATS_KEY>            -> links for every creator
GET /api/creator/link?key=<STATS_KEY>&id=jukem   -> one creator's link
```

and send the returned `url` to the creator. No new env vars or bindings are needed
(reuses `COOKIE_SECRET`, `STRIPE_SECRET_KEY`, `STATS_KEY`, and the `STATS` D1 DB).

### Payout tracking

A creator earns the **actual net-settled first-month revenue** from each subscriber
their code brought in — the real money that landed in Stripe (after fees, FX-converted
into the settlement currency, refunds excluded), read from each discounted invoice's
`balance_transaction.net`. There is no configurable rate; the amount is the true
per-customer Stripe figure. Because every coupon is duration `once`, each redemption's
discounted invoice IS its first-month invoice, so net-settled-of-that-invoice == earned.

Two endpoints, two audiences:

- **`/api/creator/payout-view`** (token-only, read-only) — what the **creator** sees on
  `creator.html`: **Earned / Pending / Paid out** in both money and subs, plus a
  redemptions list (date · code · amount · status) with **no customer PII**. `earned`
  comes from the Stripe scan; `paidOut` from the disbursement ledger; `pending =
  earned − paidOut`. Earned reads `—` if Stripe is unreachable; paid-out always shows.
- **`/api/creator/payout`** (admin: `STATS_KEY` + `token`) — the **disbursement ledger**.
  The `payouts` D1 table now records only what you've actually *paid* (amount, subs
  covered, note, date). The **Record a payout** form on `creator.html` appears once you
  unlock with your `STATS_KEY` (the **Admin** button; key reused from `/stats`).

The admin **Money tab** (`/api/money`, `STATS_KEY`, lazy-loaded) shows the same earnings
across every code: a per-promotion-code table tagged by purpose (creator / conversion
`superseed` / loyalty `promacro`) with uses, net-settled revenue, paid-to-creator, and
net — plus active subscribers, MRR, new/churned this month, avg subscription length → LTV,
and this-month gross/net/fees/refunds. All Stripe figures degrade to `—` (HTTP 200, never
500) when Stripe is down; Overview and Acquisition stay D1-only and never call Stripe.

> **Stripe API version:** `_lib/money.js` pins a pre-"Basil" `Stripe-Version` on every
> money call (`STRIPE_API_VERSION`) so `invoice.charge` (and its expandable
> `balance_transaction`) is always present. Stripe's 2025-03-31 "Basil" release moved the
> charge under `invoice.payments[]`; the code reads both, but the pin is the safety net —
> without it, a Basil-default account would read every `net` as 0 and pay creators $0.

> One-time setup: apply **migration 0004** (`migrations/0004_add_payouts.sql`) for the
> `payouts` ledger. The model needs no other migration; earned/owed comes from Stripe.

The **Acquisition** tab on `/stats` lists every creator code (from `_lib/creators.js`),
including codes with zero installs, so new creators show up before they've driven any.
`/stats` is now **3 tabs** (Overview · Acquisition · Money), down from six.

## Local dev

```
npx wrangler pages dev .
```

Provide the env vars via a `.dev.vars` file (not committed).
