-- A new account syncs reduced JPEGs: sync_accounts.image_form defaults to 'jpeg' instead of 'none'.
-- The column default is where an account's first form is decided: the statements that make the row
-- name no image_form (the usage triggers of 0003_sync.sql, the charge of a request in
-- sync_quota.mjs, the first replacement of the root in sync_list.mjs), and only PUT
-- /api/sync/settings writes one. imageForm in sync.mjs answers the same form for an account that has
-- no row yet (NEW_ACCOUNT_IMAGE_FORM).
--
-- SQLite cannot change a column's default in place, so the table is made anew and every row copied
-- as it is: an account that has a row keeps the form it holds, 'none' included, whether it chose it
-- or took the old default. The two cannot be told apart, and an account that chose 'none' must not
-- start sending images.
--
-- The usage triggers of 0003_sync.sql name sync_accounts in their bodies. With legacy_alter_table
-- off, the rename below checks them against the schema while no sync_accounts exists and fails, so
-- the rename runs with it on: it renames the table alone, and the triggers, which name it by name,
-- reach the new table. D1 allows the pragma.
--
-- The columns, their order and every other default are those of 0003_sync.sql, so the Worker before
-- this one runs unchanged on the migrated database. It answers "none" for an account with no row
-- while the row it then makes holds 'jpeg' (docs/web-deploy.md, "Rolling out the reduced-image
-- default").
--
-- The test harness applies migrations by cutting them at every semicolon after dropping comments, so
-- no statement here may hold a semicolon or a comment marker inside a string literal.

PRAGMA legacy_alter_table = ON;

CREATE TABLE sync_accounts_new (
  account_id      TEXT PRIMARY KEY REFERENCES accounts(id),
  generation      INTEGER NOT NULL DEFAULT 0,      -- advanced by one with every replacement of the root
  root_name       TEXT,                            -- name of the current root, NULL before the first replacement
  image_form      TEXT NOT NULL DEFAULT 'jpeg',    -- 'png', 'jpeg' or 'none': which images this account syncs
  stored_bytes    INTEGER NOT NULL DEFAULT 0,      -- bytes of the stored objects something references (the triggers of 0003_sync.sql)
  hidden_bytes    TEXT NOT NULL DEFAULT '{}',      -- JSON, UTC day to bytes of the stored objects nothing references (the triggers of 0003_sync.sql)
  record_count    INTEGER NOT NULL DEFAULT 0,      -- records the current root lists
  last_synced_day INTEGER,                         -- UTC day of the last replacement of the root, NULL before it
  daily_day       INTEGER,                         -- UTC day the daily_ counters count, NULL before the first counted request
  daily_requests  INTEGER NOT NULL DEFAULT 0,      -- sync requests counted on daily_day
  daily_rows_read INTEGER NOT NULL DEFAULT 0,      -- D1 rows they read
  daily_rows_written INTEGER NOT NULL DEFAULT 0    -- D1 rows they wrote
) WITHOUT ROWID;

INSERT INTO sync_accounts_new (account_id, generation, root_name, image_form, stored_bytes, hidden_bytes, record_count,
    last_synced_day, daily_day, daily_requests, daily_rows_read, daily_rows_written)
  SELECT account_id, generation, root_name, image_form, stored_bytes, hidden_bytes, record_count,
    last_synced_day, daily_day, daily_requests, daily_rows_read, daily_rows_written
  FROM sync_accounts;

DROP TABLE sync_accounts;

ALTER TABLE sync_accounts_new RENAME TO sync_accounts;

PRAGMA legacy_alter_table = OFF;
