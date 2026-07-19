-- Adds the in-macro support chat tables to the usage-stats DB (STATS / gagmacro-stats).
--
-- Powers the macro's "Support" tab (macro.ahk) + /api/support, and the owner-side
-- reply console support-admin.html + /api/support/admin. This REPLACES the old
-- "Report a bug" -> Discord webhook flow, whose whole problem was that it forced the
-- user to hand over an email or Discord name before I could reply.
--
-- The thread key is the macro's existing anonymous install id (device.txt, a GUID --
-- see GetOrCreateDeviceId). No account, no email, no login: the user opens the tab and
-- types, and I reply to a device id. That id is effectively a bearer token -- anyone
-- holding it can read that conversation -- which is why the tab tells users not to
-- paste anything sensitive. It is a random 36-char GUID, so guessing one is not a
-- practical attack, and the contents are macro support.
--
--   support_threads   -- ONE row per install that has ever opened a conversation. Carries
--                        the two unread flags that drive both inboxes: `unread_admin` (they
--                        wrote, I have not read it) sorts my console; `unread_user` (I
--                        replied, they have not seen it) lights the green dot on the macro's
--                        Support tab. `version` is the macro build they last wrote from,
--                        which is usually the first thing I would have asked for anyway.
--   support_messages  -- every message in every thread, `sender` = 'user' | 'admin'.
--                        Append-only; the macro renders the last 100 of them.
--
-- Every reader/writer wraps its query in its own try/catch, so these tables being absent
-- never 500s the macro or breaks the Support tab. Applying it is non-breaking, any time.
--
-- Apply ONCE to the production D1 database (gagmacro-stats). Run the statements directly --
-- do NOT use `wrangler d1 migrations apply` (earlier promo/src columns were added manually
-- with no tracked migration, so a full run would try to re-add them and fail). Either:
--   wrangler d1 execute gagmacro-stats --remote --file migrations/0010_add_support.sql
-- or paste the statements below into the D1 "Console" tab in the Cloudflare dashboard.

CREATE TABLE IF NOT EXISTS support_threads (
  device_id     TEXT    PRIMARY KEY,        -- the macro's anonymous install id (device.txt GUID)
  created_at    INTEGER NOT NULL,           -- epoch ms, first message ever sent
  last_msg_at   INTEGER NOT NULL,           -- epoch ms, newest message either way (inbox sort)
  last_user_at  INTEGER,                    -- epoch ms, newest message FROM the user
  last_admin_at INTEGER,                    -- epoch ms, newest reply FROM me
  unread_admin  INTEGER NOT NULL DEFAULT 0, -- they wrote and I have not opened the thread
  unread_user   INTEGER NOT NULL DEFAULT 0, -- I replied and they have not seen it (macro tab dot)
  version       TEXT,                       -- macro build they last wrote from, e.g. "2.0.0"
  is_pro        INTEGER NOT NULL DEFAULT 0, -- Pro at the time of their last message (triage only)
  closed        INTEGER NOT NULL DEFAULT 0  -- I marked it resolved; a new message re-opens it
);

-- Inbox ordering (newest conversation first).
CREATE INDEX IF NOT EXISTS idx_support_threads_last ON support_threads(last_msg_at DESC);

CREATE TABLE IF NOT EXISTS support_messages (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,  -- also the "have I seen this?" cursor
  device_id  TEXT    NOT NULL,
  sender     TEXT    NOT NULL,                   -- 'user' | 'admin'
  body       TEXT    NOT NULL,
  created_at INTEGER NOT NULL                    -- epoch ms
);

-- Every read is "this thread, in id order" (transcript) or "newest id in this thread"
-- (the macro's background unread check), so index the pair.
CREATE INDEX IF NOT EXISTS idx_support_messages_device ON support_messages(device_id, id);
