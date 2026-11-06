-- The name tables the Worker resolves recognizer class numbers (sids) through (tables.mjs). They
-- live here so publishing a recognizer module set brings them up to date without deploying the
-- Worker: the publishing step appends the rows its archive adds, and only then records the load.
--
-- share_table_name holds names[key][pos] and share_table_gid holds gids[key][pos]: pos is the sid.
-- A sid's meaning never changes once a module set ships it, so both tables only grow: a row is
-- never updated or deleted, and a key's rows are added at its end, in pos order, with no gap. The
-- triggers below refuse anything else, so neither the publishing step nor a mistyped query can
-- shrink a table or move a name to another sid.
--
-- share_table_load records each load that added at least one row, written after its rows.
-- generation is one past the previous greatest. The tables' version is the recognizer_version of
-- the row with the greatest generation. The Worker reads the generation before the rows, so the
-- rows it reads are never older than the generation it notes.
--
-- No string literal below holds a ";" or a "--": the test harness cuts this file at both
-- (worker_harness.mjs, migrationStatements), as 0002_accounts.sql states.

CREATE TABLE share_table_name (
  key TEXT NOT NULL,
  pos INTEGER NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (key, pos)
);

CREATE TABLE share_table_gid (
  key TEXT NOT NULL,
  pos INTEGER NOT NULL,
  gid INTEGER NOT NULL,
  PRIMARY KEY (key, pos)
);

CREATE TABLE share_table_load (
  generation INTEGER PRIMARY KEY,
  archive_sha256 TEXT NOT NULL,
  recognizer_version TEXT NOT NULL,
  rows_added INTEGER NOT NULL,
  loaded_at INTEGER NOT NULL
);

CREATE TRIGGER share_table_name_no_update BEFORE UPDATE ON share_table_name
BEGIN
  SELECT RAISE(ABORT, 'share_table_name rows are never changed');
END;

CREATE TRIGGER share_table_name_no_delete BEFORE DELETE ON share_table_name
BEGIN
  SELECT RAISE(ABORT, 'share_table_name rows are never deleted');
END;

CREATE TRIGGER share_table_name_append_only BEFORE INSERT ON share_table_name
WHEN NEW.pos IS NOT (SELECT COUNT(*) FROM share_table_name WHERE key = NEW.key)
BEGIN
  SELECT RAISE(ABORT, 'share_table_name rows are added at the end of their key, in pos order');
END;

CREATE TRIGGER share_table_gid_no_update BEFORE UPDATE ON share_table_gid
BEGIN
  SELECT RAISE(ABORT, 'share_table_gid rows are never changed');
END;

CREATE TRIGGER share_table_gid_no_delete BEFORE DELETE ON share_table_gid
BEGIN
  SELECT RAISE(ABORT, 'share_table_gid rows are never deleted');
END;

CREATE TRIGGER share_table_gid_append_only BEFORE INSERT ON share_table_gid
WHEN NEW.pos IS NOT (SELECT COUNT(*) FROM share_table_gid WHERE key = NEW.key)
BEGIN
  SELECT RAISE(ABORT, 'share_table_gid rows are added at the end of their key, in pos order');
END;
