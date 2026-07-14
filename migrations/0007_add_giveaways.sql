-- Adds the giveaway tables to the usage-stats DB (STATS / gagmacro-stats).
--
-- Powers the giveaway platform: giveaway.html (public entry page) + /api/giveaway*.
-- The giveaways THEMSELVES (title, prize, kind, end date) are a hardcoded registry in
-- functions/_lib/giveaways.js — same pattern as the creator registry — so there is no
-- giveaway-CRUD table. These tables only store what must live at runtime: who entered,
-- and who was drawn as the winner.
--
--   giveaway_entries  -- ONE row per Google account per giveaway (PRIMARY KEY enforces the
--                        "1 entry per account" anti-cheat). `weight` is the number of raffle
--                        tickets that account holds: 1 (signed in), 3 (has the free macro,
--                        proven by entering the code shown at the macro's bottom), or 10 (Pro).
--                        email/name come from the Google login so the owner can email the winner.
--   giveaway_winners  -- ONE row per giveaway: the drawn/selected winner. Written by the admin
--                        page (weighted random draw or manual pick); read to announce results.
--
-- Every reader/writer wraps its query in its own try/catch, so these tables being absent
-- never 500s the public page or the entry flow. Applying it is non-breaking, any time.
--
-- Apply ONCE to the production D1 database (gagmacro-stats). Run the statements directly --
-- do NOT use `wrangler d1 migrations apply` (earlier promo/src columns were added manually
-- with no tracked migration, so a full run would try to re-add them and fail). Either:
--   wrangler d1 execute gagmacro-stats --remote --file migrations/0007_add_giveaways.sql
-- or paste the statements below into the D1 "Console" tab in the Cloudflare dashboard.

CREATE TABLE IF NOT EXISTS giveaway_entries (
  giveaway_id TEXT    NOT NULL,       -- registry id, e.g. 'starfruit'
  google_sub  TEXT    NOT NULL,       -- Google account id (1 entry per account)
  email       TEXT,                   -- from Google login, for emailing the winner
  name        TEXT,                   -- from Google login (display only)
  weight      INTEGER NOT NULL DEFAULT 1,  -- raffle tickets: 1 / 3 / 10
  has_macro   INTEGER NOT NULL DEFAULT 0,  -- entered the macro code (has the free macro)
  is_pro      INTEGER NOT NULL DEFAULT 0,  -- active Pro at time of entry
  subscribed  INTEGER NOT NULL DEFAULT 0,  -- confirmed the White Lion subscribe honor gate
  created_at  INTEGER NOT NULL,       -- epoch ms, first entered
  updated_at  INTEGER NOT NULL,       -- epoch ms, last updated (e.g. added the code later)
  PRIMARY KEY (giveaway_id, google_sub)
);

CREATE INDEX IF NOT EXISTS idx_gentries_gid ON giveaway_entries(giveaway_id);

CREATE TABLE IF NOT EXISTS giveaway_winners (
  giveaway_id TEXT    PRIMARY KEY,    -- one winner per giveaway
  google_sub  TEXT    NOT NULL,
  email       TEXT,
  name        TEXT,
  weight      INTEGER,                -- the winner's ticket count (context for the owner)
  drawn_at    INTEGER NOT NULL        -- epoch ms
);
