-- Adds the entrant's Grow a Garden (Roblox) username to the giveaway tables.
--
-- Why: the winner's prize (seeds) is delivered IN-GAME, so the owner needs the
-- entrant's Roblox username, not just their Google email. giveaway.html now asks
-- for it during entry; enter.js stores it here; the admin page shows it so the
-- owner knows exactly which account to send the prize to.
--
--   giveaway_entries.username  -- the entrant's Roblox username, captured at entry
--   giveaway_winners.username  -- copied onto the winner row when drawn/selected
--
-- Apply ONCE to the production D1 database (gagmacro-stats), the same way as 0007:
-- run the two statements directly (do NOT use `wrangler d1 migrations apply`). Either:
--   wrangler d1 execute gagmacro-stats --remote --file migrations/0008_add_giveaway_username.sql
-- or paste the two statements into the D1 "Console" tab in the Cloudflare dashboard.
--
-- SQLite has no "ADD COLUMN IF NOT EXISTS", so run each line only once. If a line
-- reports "duplicate column name", that column already exists — safe to ignore.

ALTER TABLE giveaway_entries ADD COLUMN username TEXT;
ALTER TABLE giveaway_winners ADD COLUMN username TEXT;
