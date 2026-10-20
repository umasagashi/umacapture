-- File sync. An account that syncs has one sync_accounts row, and one sync_objects row for every
-- object it has stored in the B2 bucket, keyed by the object's name: the SHA-256 of its bytes. The
-- bytes live in B2 under a/<account id>/<name>, so two accounts storing the same bytes hold two rows
-- and two objects, and neither can reach the other's.
--
-- A row also counts the references to its name from the account's current root, apart from whether
-- the object is stored: an image the list names before anyone put it has a row with stored_at NULL.
-- An object stored and referenced by nothing is hidden in B2 (a delete marker over its version), from
-- SYNC_ABANDONED_AFTER after it was stored when it was never referenced, and shown again when
-- something references it. B2's lifecycle deletes what stays hidden, from six days
-- after it was hidden, so a row whose hidden_since is older than that less a margin counts as not
-- stored, whatever its stored_at: nothing shows it again, and a put of its name stores it anew.
-- Such a row answers as no row does, so the rows go once nothing needs them: the hourly run deletes a
-- gone row nothing references (sync_objects_gone), and the statement that leaves the row of an image
-- never stored referenced by nothing deletes it. An account's rows follow what its root references and
-- what it hid in the last week, however often it replaces the root.
--
-- The test harness applies migrations by cutting them at every semicolon after dropping comments,
-- keeping a CREATE TRIGGER together up to its END, so no statement here may hold a semicolon or a
-- comment marker inside a string literal.

CREATE TABLE sync_accounts (
  account_id      TEXT PRIMARY KEY REFERENCES accounts(id),
  generation      INTEGER NOT NULL DEFAULT 0,      -- advanced by one with every replacement of the root
  root_name       TEXT,                            -- name of the current root, NULL before the first replacement
  image_form      TEXT NOT NULL DEFAULT 'none',    -- 'png', 'jpeg' or 'none': which images this account syncs
  stored_bytes    INTEGER NOT NULL DEFAULT 0,      -- bytes of the stored objects something references (the triggers below)
  hidden_bytes    TEXT NOT NULL DEFAULT '{}',      -- JSON, UTC day to bytes of the stored objects nothing references (the triggers below)
  record_count    INTEGER NOT NULL DEFAULT 0,      -- records the current root lists
  last_synced_day INTEGER,                         -- UTC day of the last replacement of the root, NULL before it
  daily_day       INTEGER,                         -- UTC day the daily_ counters count, NULL before the first counted request
  daily_requests  INTEGER NOT NULL DEFAULT 0,      -- sync requests counted on daily_day
  daily_rows_read INTEGER NOT NULL DEFAULT 0,      -- D1 rows they read
  daily_rows_written INTEGER NOT NULL DEFAULT 0    -- D1 rows they wrote
) WITHOUT ROWID;

CREATE TABLE sync_objects (
  account_id   TEXT NOT NULL REFERENCES accounts(id),
  name         TEXT NOT NULL,                      -- SHA-256 of the bytes, 64 lowercase hex digits
  kind         TEXT NOT NULL,                      -- 'body', 'png', 'jpeg', 'part' or 'root'
  size         INTEGER,                            -- bytes, NULL while not stored
  binding      TEXT,                               -- a body's image binding as JSON, NULL for other kinds
  slot         TEXT,                               -- a part's slot in a root, NULL for other kinds
  record_count INTEGER,                            -- records a part lists, NULL for other kinds
  refs         TEXT,                               -- JSON: what a part references, a root's slot-to-part map
  stored_at    INTEGER,                            -- seconds since the epoch of the put that stored it, NULL while not stored
  ref_count    INTEGER NOT NULL DEFAULT 0,         -- references from the current root: the root itself, its parts, their rows
  pending      TEXT,                               -- JSON, for a reduced JPEG not stored yet: PNG name to the references the root makes to it in the JPEG's place
  hidden_at    INTEGER,                            -- seconds since the epoch the request in hide_by took it to hide or show, NULL while shown
  hidden_since INTEGER,                            -- seconds since the epoch of the first hide since it was last shown, NULL while shown
  hide_by      TEXT,                               -- the request hiding or showing it, NULL once one hid it again with no marker recorded
  marker       TEXT,                               -- version id of the delete marker hiding it, NULL until that request recorded it
  PRIMARY KEY (account_id, name)
) WITHOUT ROWID;

-- The rows stored, shown and referenced by nothing: hides still to do. A put records what it stored in
-- this state and leaves it shown, for the replacement that references it. A replacement writes what
-- it stops referencing into this state in the batch that commits it and hides it before it answers,
-- so such a row stays here only when the replacement was cut off between the two. Once stored_at is
-- SYNC_ABANDONED_AFTER old, the account's next sync write and the hourly run find a row here and hide it.
CREATE INDEX sync_objects_to_hide ON sync_objects (account_id, stored_at)
  WHERE ref_count = 0 AND hidden_at IS NULL AND stored_at IS NOT NULL;

-- The rows referenced by nothing that a request began to hide or show and recorded no marker for.
-- A hide leaves this state when it records the marker, and a show when its replacement commits, so
-- a row stays here only when its request was cut off in between or B2 failed it. Once hidden_at is
-- SYNC_ABANDONED_AFTER old, the account's next sync write and the hourly run hide it again.
CREATE INDEX sync_objects_hiding ON sync_objects (account_id, name)
  WHERE ref_count = 0 AND hidden_at IS NOT NULL AND marker IS NULL AND hide_by IS NOT NULL;

-- The rows the current root references that a request left hidden, or may have. A replacement shows
-- after its commit what a hide hid after its look, and a hide gives back its marker over a name
-- referenced or taken over meanwhile, so a row stays here when one of them was cut off in between.
-- A replacement also leaves here a row it took over from a request that may still add a marker.
-- Once hidden_at is SYNC_ABANDONED_AFTER old, the account's next sync write and the hourly run delete
-- the marker the row records, or, when it records none, the markers B2 lists over the name.
CREATE INDEX sync_objects_to_show ON sync_objects (account_id, name)
  WHERE ref_count > 0 AND hidden_at IS NOT NULL;

-- The rows hidden and referenced by nothing, by the time they were first hidden: what goes past the
-- six-day boundary. Once a row is past it by a day and SYNC_ABANDONED_AFTER, and no request is hiding
-- it, the hourly run deletes it (`forgetLeftovers` in sync_refs.mjs). A row enters when a hide begins
-- and leaves when it is shown or referenced, so a sync that hides nothing writes nothing here.
CREATE INDEX sync_objects_gone ON sync_objects (hidden_since)
  WHERE ref_count = 0 AND hidden_since IS NOT NULL;

-- What a request is about to write under an account's prefix in B2: objects it puts, or the delete
-- markers it adds to hide them. The request writes its row before B2 is asked, and deletes it in the
-- statement that records what B2 then holds (the objects' sync_objects rows, or the markers on them),
-- only while the account is not being deleted. So a row stays here when its request was cut off in
-- between, failed there, or wrote to an account being deleted, and B2 may hold under its names a
-- version nothing in D1 accounts for. The account's next sync write and the hourly run take each name
-- once every row naming it is SYNC_ABANDONED_AFTER and twice RESTORE_MARGIN_SECONDS old: they delete
-- the versions of the name its requests may have written, unless the account holds the name and is
-- not being deleted, and take the name off the rows. No row references accounts, so a row outlives
-- the account it names.
CREATE TABLE sync_writes (
  account_id   TEXT NOT NULL,                      -- the account whose prefix the writes go under
  write_by     TEXT NOT NULL,                      -- the request writing them, a UUID
  names        TEXT NOT NULL,                      -- JSON array of the names it writes
  written_at   INTEGER NOT NULL,                   -- seconds since the epoch, the request's clock before it asked B2
  PRIMARY KEY (account_id, write_by)
) WITHOUT ROWID;

-- Sync's own daily counters over every account, apart from sharing's daily row. A request reads only
-- the day it began on, so the hourly run deletes the days before the one before today (`forgetDays` in
-- sync_quota.mjs).
CREATE TABLE sync_daily (
  day          INTEGER PRIMARY KEY,                -- UTC days since 1970-01-01
  requests     INTEGER NOT NULL DEFAULT 0,
  rows_read    INTEGER NOT NULL DEFAULT 0,
  rows_written INTEGER NOT NULL DEFAULT 0,      -- rows_written by account deletions included
  delete_rows  INTEGER NOT NULL DEFAULT 0       -- the rows account deletions wrote, their share of rows_written
);

-- The bytes in the sync bucket over every account, as sync_accounts counts them per account.
CREATE TABLE sync_totals (
  id           INTEGER PRIMARY KEY CHECK (id = 1),
  stored_bytes INTEGER NOT NULL DEFAULT 0,
  hidden_bytes TEXT NOT NULL DEFAULT '{}'
);
INSERT INTO sync_totals (id) VALUES (1);

-- Usage. The triggers keep stored_bytes and hidden_bytes of the account and of sync_totals equal to
-- what the account's sync_objects rows hold, whichever statement changes a row:
--   a row stored (stored_at and size set) and referenced (ref_count > 0) counts its size in stored_bytes,
--   a row stored and referenced by nothing counts its size in hidden_bytes, under the UTC day of its
--   hidden_since, or of its stored_at while it is not hidden yet,
--   any other row counts nothing.
-- So a referenced row hidden by a cut-off request (sync_objects_to_show) counts as stored, not hidden.
-- A day's bytes stop counting once B2's lifecycle may have deleted them: `usage` in sync_quota.mjs
-- reads only the days from the one the six-day boundary falls on, and adding to a day drops the days
-- eight or more before it, so the JSON holds a few days at most. Subtracting from a day already
-- dropped changes nothing.
CREATE TRIGGER sync_objects_usage_insert AFTER INSERT ON sync_objects
WHEN NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL
BEGIN
  INSERT INTO sync_accounts (account_id) SELECT NEW.account_id
    WHERE NOT EXISTS (SELECT 1 FROM sync_accounts WHERE account_id = NEW.account_id);
  UPDATE sync_accounts SET stored_bytes = stored_bytes + NEW.size
    WHERE account_id = NEW.account_id AND NEW.ref_count > 0;
  UPDATE sync_totals SET stored_bytes = stored_bytes + NEW.size WHERE id = 1 AND NEW.ref_count > 0;
  UPDATE sync_accounts SET hidden_bytes = (SELECT json_group_object(key, value) FROM json_each(json_set(hidden_bytes,
      '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"',
      coalesce(json_extract(hidden_bytes, '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"'), 0) + NEW.size))
      WHERE CAST(key AS INTEGER) >= coalesce(NEW.hidden_since, NEW.stored_at) / 86400 - 8)
    WHERE account_id = NEW.account_id AND NEW.ref_count = 0;
  UPDATE sync_totals SET hidden_bytes = (SELECT json_group_object(key, value) FROM json_each(json_set(hidden_bytes,
      '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"',
      coalesce(json_extract(hidden_bytes, '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"'), 0) + NEW.size))
      WHERE CAST(key AS INTEGER) >= coalesce(NEW.hidden_since, NEW.stored_at) / 86400 - 8)
    WHERE id = 1 AND NEW.ref_count = 0;
END;

-- An update takes the old row's share off (stored_bytes, or its day of hidden_bytes) and adds the new
-- row's: two statements per table, each skipped when it has nothing to change. A row stored neither
-- before nor after has no share either side, so it does not fire: the rows of the images a list names
-- and nobody put change their counts with every replacement.
CREATE TRIGGER sync_objects_usage_update AFTER UPDATE OF stored_at, size, ref_count, hidden_since ON sync_objects
WHEN ((OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL) OR (NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL))
  AND ((CASE WHEN OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL THEN OLD.size ELSE 0 END)
         IS NOT (CASE WHEN NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL THEN NEW.size ELSE 0 END)
    OR (OLD.ref_count > 0) IS NOT (NEW.ref_count > 0)
    OR coalesce(OLD.hidden_since, OLD.stored_at) / 86400 IS NOT coalesce(NEW.hidden_since, NEW.stored_at) / 86400)
BEGIN
  INSERT INTO sync_accounts (account_id) SELECT NEW.account_id
    WHERE NOT EXISTS (SELECT 1 FROM sync_accounts WHERE account_id = NEW.account_id);
  UPDATE sync_accounts SET
      stored_bytes = stored_bytes
        - (CASE WHEN OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL AND OLD.ref_count > 0 THEN OLD.size ELSE 0 END)
        + (CASE WHEN NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL AND NEW.ref_count > 0 THEN NEW.size ELSE 0 END),
      hidden_bytes = CASE
        WHEN OLD.stored_at IS NULL OR OLD.size IS NULL OR OLD.ref_count > 0
          OR json_type(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') IS NULL THEN hidden_bytes
        ELSE json_set(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"',
          json_extract(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') - OLD.size) END
    WHERE account_id = NEW.account_id
      AND ((CASE WHEN OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL AND OLD.ref_count > 0 THEN OLD.size ELSE 0 END)
             <> (CASE WHEN NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL AND NEW.ref_count > 0 THEN NEW.size ELSE 0 END)
        OR (OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL AND OLD.ref_count = 0));
  UPDATE sync_totals SET
      stored_bytes = stored_bytes
        - (CASE WHEN OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL AND OLD.ref_count > 0 THEN OLD.size ELSE 0 END)
        + (CASE WHEN NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL AND NEW.ref_count > 0 THEN NEW.size ELSE 0 END),
      hidden_bytes = CASE
        WHEN OLD.stored_at IS NULL OR OLD.size IS NULL OR OLD.ref_count > 0
          OR json_type(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') IS NULL THEN hidden_bytes
        ELSE json_set(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"',
          json_extract(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') - OLD.size) END
    WHERE id = 1
      AND ((CASE WHEN OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL AND OLD.ref_count > 0 THEN OLD.size ELSE 0 END)
             <> (CASE WHEN NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL AND NEW.ref_count > 0 THEN NEW.size ELSE 0 END)
        OR (OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL AND OLD.ref_count = 0));
  UPDATE sync_accounts SET hidden_bytes = (SELECT json_group_object(key, value) FROM json_each(json_set(hidden_bytes,
      '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"',
      coalesce(json_extract(hidden_bytes, '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"'), 0) + NEW.size))
      WHERE CAST(key AS INTEGER) >= coalesce(NEW.hidden_since, NEW.stored_at) / 86400 - 8)
    WHERE account_id = NEW.account_id AND NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL AND NEW.ref_count = 0;
  UPDATE sync_totals SET hidden_bytes = (SELECT json_group_object(key, value) FROM json_each(json_set(hidden_bytes,
      '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"',
      coalesce(json_extract(hidden_bytes, '$."' || (coalesce(NEW.hidden_since, NEW.stored_at) / 86400) || '"'), 0) + NEW.size))
      WHERE CAST(key AS INTEGER) >= coalesce(NEW.hidden_since, NEW.stored_at) / 86400 - 8)
    WHERE id = 1 AND NEW.stored_at IS NOT NULL AND NEW.size IS NOT NULL AND NEW.ref_count = 0;
END;

CREATE TRIGGER sync_objects_usage_delete AFTER DELETE ON sync_objects
WHEN OLD.stored_at IS NOT NULL AND OLD.size IS NOT NULL
BEGIN
  UPDATE sync_accounts SET stored_bytes = stored_bytes - OLD.size WHERE account_id = OLD.account_id AND OLD.ref_count > 0;
  UPDATE sync_totals SET stored_bytes = stored_bytes - OLD.size WHERE id = 1 AND OLD.ref_count > 0;
  UPDATE sync_accounts SET hidden_bytes = json_set(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"',
      json_extract(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') - OLD.size)
    WHERE account_id = OLD.account_id AND OLD.ref_count = 0
      AND json_type(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') IS NOT NULL;
  UPDATE sync_totals SET hidden_bytes = json_set(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"',
      json_extract(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') - OLD.size)
    WHERE id = 1 AND OLD.ref_count = 0
      AND json_type(hidden_bytes, '$."' || (coalesce(OLD.hidden_since, OLD.stored_at) / 86400) || '"') IS NOT NULL;
END;
