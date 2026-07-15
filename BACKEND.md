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
    giveaway.js              GET  -> public giveaway state (details + live entrant count + "me")
    giveaway/enter.js        POST -> enter the signed-in account (honor gate + macro code + Pro weighting)
    giveaway/admin.js        POST -> (admin, STATS_KEY) list entries, draw/set/clear the winner
  _lib/
    creators.js        creator -> promo-code registry (mirror of macro.ahk PromoValid) + code purpose tags
    giveaways.js       giveaway registry (title/prize/kind/endsAt) + entry weights + the macro code
    money.js           shared Stripe money math: net-settled per-code earnings, MRR, churn, avg lifetime
index.html          marketing landing
signin.html         sign in with Google / get your code
creator.html        per-creator stats dashboard (opened via a private signed link)
giveaway.html       public giveaway entry page (countdown, live count, honor gate, macro code)
giveaway-admin.html owner-only draw page (STATS_KEY gate; pick + email the winner)
wrangler.toml       Pages config + SUBS KV binding
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
   - **Auto-applied discount:** `/api/checkout` will attach a Stripe promotion code
     for the user so they never paste one — from either the flash-deal variant
     (`?offer=1|2|3`) or an entered creator code (`?code=LION`). The macro sends one on
     the "Get access" link; `signin.html` persists it in the `gag_offer` / `gag_code`
     cookie across the Google-login round-trip (the OAuth callback drops query strings)
     and threads it back onto the checkout link. Offer and code are mutually exclusive
     (the flash deal is suppressed for creator-code holders); if both arrive, the flash
     wins. If Stripe rejects the discount, checkout retries at full price rather than
     failing the sale. Creator attribution is native (the promotion code lands on the
     invoice discount — see `_lib/money.js`), so it works the same as a pasted code.
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

## Giveaways

A growth loop: hand out in-game items (e.g. a Star Fruit Seed) so players sign in, subscribe
to **White Lion's YouTube**, and install/upgrade the macro for more chances to win. Built on the
existing pieces — Google login, the `STATS` D1 DB, and the `STATS_KEY` admin gate — so there are
**no new services, secrets, or bindings**.

- **The giveaways themselves are a hardcoded registry** in `_lib/giveaways.js` (`GIVEAWAYS`), the
  same pattern as the creator registry. Edit + redeploy to run one — no CRUD table. Each has a
  `title`, `prize`, `kind` (`normal` = anyone / `premium` = Pro only), and an ISO `endsAt` the
  countdown targets. `MACRO_CODE` (currently **`3QIHX`**) and `SUBSCRIBE_URL` also live here.
- **One entry per Google account** (the `giveaway_entries` PRIMARY KEY) — the strong anti-cheat.
- **Subscribe gate = honor system.** YouTube can't verify a sub, so the page makes the user click
  "Subscribe to White Lion" and tick "I subscribed" (with a warning that a fake tick forfeits the
  prize) before **Enter** unlocks. The subscribe unlocks entry but adds no tickets by itself.
- **Ticket weighting** (`WEIGHTS`): signed in = **1**; entered the macro code = **3** (+2, proves
  they have the free macro — the code is shown at the macro's bottom, under the version); Pro =
  **10**. Pro is detected automatically from the signed-in Google account (`resolveActive`) — no
  code to paste. `has_macro` is sticky, so re-entering without the code never drops the bonus.
- **Premium giveaways** use the same page but require an active Pro to enter (enforced in
  `enter.js`). Non-Pro visitors get a "Go Pro to enter" CTA.
- **"Get it" links** point at `/api/checkout`, which routes non-subscribers to Stripe Checkout and
  existing subscribers straight to their access code (`/api/success`) — so one link serves both.
- **Login round-trip:** the page sets a `gag_return` cookie (a validated same-origin path) before
  sending the user to Google; `auth/google/callback.js` honors it so they land back on the giveaway
  instead of the sign-in page. (Priority: `gag_return` > flash `gag_offer` > default landing.)
- **Live counter + countdown** come from `GET /api/giveaway` (polled every 25s) and `endsAt`.
- **Drawing a winner:** `giveaway-admin.html` (unlock with `STATS_KEY`, the same key as `/stats`)
  lists every entry with its Google email, and does a **weighted random draw** (or a manual pick).
  The winner is stored in `giveaway_winners`; the owner then emails them from their own Gmail via a
  pre-filled `mailto:` link. Winners are never exposed on the public API (only "a winner was drawn").

> One-time setup: apply **migration 0007** (`migrations/0007_add_giveaways.sql`) for the
> `giveaway_entries` + `giveaway_winners` tables. No env vars or bindings to add.

## Local dev

```
npx wrangler pages dev .
```

Provide the env vars via a `.dev.vars` file (not committed).
