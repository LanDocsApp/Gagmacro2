-- Adds a `payouts` ledger to the usage-stats DB for creator payout tracking.
--
-- One row per payout you make to a creator. Powers the admin-only "Payouts"
-- section on /creator.html (recorded/read via /api/creator/payout, gated by
-- STATS_KEY). Payouts are tracked per CREATOR (the `id` slug from _lib/creators.js),
-- aggregated across all of that creator's promo codes -- you pay on the number of
-- subscribers their code(s) drove, not per code.
--
--   subscribers  -- how many subscribers this payout covers (the unit you pay on)
--   amount_cents -- how much you paid, in cents (optional; 0 if you only track counts)
--   note         -- optional memo (PayPal/transfer id, the period it covers, etc.)
--
-- The dashboard sums these: paid subscribers = SUM(subscribers), pending = total
-- subscribers driven (Stripe redemptions) minus paid, total paid = SUM(amount_cents).
--
-- Apply ONCE to the production D1 database (gagmacro-stats). Run the statements
-- directly -- do NOT use `wrangler d1 migrations apply` here (earlier promo/src
-- columns were added manually with no tracked migration, so a full run would try to
-- re-add them and fail). Either:
--   wrangler d1 execute gagmacro-stats --remote --file migrations/0004_add_payouts.sql
-- or paste the statements below into the D1 "Console" tab in the Cloudflare dashboard.

CREATE TABLE IF NOT EXISTS payouts (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  creator_id   TEXT    NOT NULL,            -- creator slug (jose, jukem, lion)
  subscribers  INTEGER NOT NULL DEFAULT 0,  -- subscribers this payout covers
  amount_cents INTEGER NOT NULL DEFAULT 0,  -- amount paid, in cents (optional)
  note         TEXT,                        -- optional memo
  created_at   INTEGER NOT NULL             -- epoch ms
);

CREATE INDEX IF NOT EXISTS idx_payouts_creator ON payouts(creator_id, created_at);
