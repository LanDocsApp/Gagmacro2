-- Adds an `expenses` ledger to the usage-stats DB for the Finances tab P&L.
--
-- One row per cost you log (domain, Cloudflare, tools, investments, one-off spend).
-- Powers the owner-only Finances tab on /stats (recorded/read via /api/expenses, gated
-- by STATS_KEY). The dashboard computes profit = revenue (Stripe) − creator payouts
-- (Stripe) − operating expenses (this table).
--
--   amount_cents -- the cost in minor units (cents)
--   currency     -- ISO code the amount is in (optional; defaults to your account currency)
--   recurrence   -- 'once' | 'monthly' | 'yearly'. Monthly counts every month; yearly is
--                   amortized to /12 per month; once counts only in the month of incurred_at.
--   category     -- free-form bucket: infra | domain | marketing | tools | investment | other
--   incurred_at  -- epoch ms the cost was paid / started
--
-- Apply ONCE to the production D1 database (gagmacro-stats). Run the statements directly:
--   wrangler d1 execute gagmacro-stats --remote --file migrations/0006_add_expenses.sql
-- or paste them into the D1 "Console" tab in the Cloudflare dashboard.

CREATE TABLE IF NOT EXISTS expenses (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  label        TEXT    NOT NULL,             -- "Domain gardenmacro.com", "Cloudflare Workers Paid"
  category     TEXT,                          -- infra | domain | marketing | tools | investment | other
  amount_cents INTEGER NOT NULL DEFAULT 0,    -- cost in cents
  currency     TEXT,                          -- ISO code (optional)
  recurrence   TEXT    NOT NULL DEFAULT 'once', -- once | monthly | yearly
  incurred_at  INTEGER NOT NULL,              -- epoch ms (paid / start date)
  note         TEXT,
  created_at   INTEGER NOT NULL               -- epoch ms
);

CREATE INDEX IF NOT EXISTS idx_expenses_incurred ON expenses(incurred_at);
