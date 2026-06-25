-- Adds a generic `events` table to the usage-stats DB for the conversion funnel.
--
-- One row per tracked event. Powers the "New stats" tab on /stats:
--   get_access  -- the macro's "Get access" button (opens the sign-in page).
--                  device_id is the anonymous install id, so we can count distinct
--                  people who clicked. Reported on the heartbeat endpoint (/api/ping
--                  with an "ev" field).
--   checkout    -- a signed-in user was sent to the Stripe Checkout page
--                  (/api/checkout). Web step, no device_id.
--   subscribe   -- a checkout completed and was paid (Stripe webhook
--                  checkout.session.completed). Web step, no device_id.
--
-- Every writer wraps its insert in its own try/catch, so this table being absent
-- never breaks core stats, the heartbeat, checkout, or the webhook. Applying it is
-- therefore non-breaking and can be done any time.
--
-- Apply ONCE to the production D1 database (gagmacro-stats). Run the statements
-- directly -- do NOT use `wrangler d1 migrations apply` here (the earlier promo/src
-- columns were added manually with no tracked migration, so a full run would try to
-- re-add them and fail). Either:
--   wrangler d1 execute gagmacro-stats --remote --file migrations/0003_add_events.sql
-- or paste the statements below into the D1 "Console" tab in the Cloudflare dashboard.

CREATE TABLE IF NOT EXISTS events (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  ts        INTEGER NOT NULL,      -- epoch ms
  name      TEXT    NOT NULL,      -- get_access | checkout | subscribe
  device_id TEXT,                  -- anon install id when known (get_access only)
  meta      TEXT                   -- optional JSON blob (e.g. version)
);

CREATE INDEX IF NOT EXISTS idx_events_name_ts ON events(name, ts);
CREATE INDEX IF NOT EXISTS idx_events_ts      ON events(ts);
