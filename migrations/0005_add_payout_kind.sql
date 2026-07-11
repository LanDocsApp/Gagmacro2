-- Adds a `kind` column to the payouts ledger so it can hold two kinds of entry.
--
--   kind = 'payout' (default) -- money PAID OUT to the creator. Existing behaviour:
--                                counts toward "Paid out", reduces what they're owed.
--   kind = 'bonus'            -- a credit OWED to the creator on top of their Stripe
--                                earnings. Raises "Earned"/"Pending"; NOT counted as paid.
--
-- Backward-compatible: every existing row defaults to 'payout', and the old code
-- (which never references `kind`) keeps working, so this can be applied before the
-- new Functions code deploys.
--
-- Apply ONCE to the production D1 database (gagmacro-stats). Run the statement
-- directly -- do NOT use `wrangler d1 migrations apply` here (earlier promo/src/payout
-- columns were added manually with no tracked migration, so a full run would try to
-- re-add them and fail). Either:
--   wrangler d1 execute gagmacro-stats --remote --file migrations/0005_add_payout_kind.sql
-- or paste the statement below into the D1 "Console" tab in the Cloudflare dashboard.

ALTER TABLE payouts ADD COLUMN kind TEXT NOT NULL DEFAULT 'payout';
