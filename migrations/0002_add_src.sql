-- Adds the acquisition-source column to the usage-stats `devices` table.
--
-- The macro asks "Where did you hear about the macro?" on first launch and reports
-- the chosen channel (reddit / tiktok / youtube / google / ai / discord / friend /
-- other) on the usage heartbeat. /api/ping stamps it onto the install (sticky) and
-- /api/stats groups by it for the dashboard breakdown.
--
-- Both endpoints tolerate the column being absent (each src read/write is wrapped in
-- its own try/catch), so applying this is non-breaking and can be done any time.
--
-- Apply ONCE to the production D1 database (gagmacro-stats). Run the single statement
-- directly -- do NOT use `wrangler d1 migrations apply` here, because the earlier
-- `promo` column was added manually (no migration was ever tracked), so a full
-- migrations run would try to re-add it and fail. Either:
--   wrangler d1 execute gagmacro-stats --remote --command "ALTER TABLE devices ADD COLUMN src TEXT;"
-- or paste the statement below into the D1 "Console" tab in the Cloudflare dashboard.

ALTER TABLE devices ADD COLUMN src TEXT;
