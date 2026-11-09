-- The tags of each sid, beside the names and gids of 0006_share_tables.sql (tables.mjs reads them).
--
-- share_table_tags holds tags[key][pos]: pos is the sid, and tags is the module's info-table tags
-- of that sid (factor_info.json for factor.name), a JSON array written with no spaces. The tags are
-- stored as the module states them, not as a colour or category derived from them, because these
-- rows are never changed: what a tag means to a reader can change, a sid's tags cannot.
--
-- The table follows the contract of 0006: a row is never updated or deleted, and a key's rows are
-- added at its end, in pos order, with no gap. A load that adds tags records itself in
-- share_table_load like any other load.
--
-- No string literal below holds a ";" or a "--": the test harness cuts this file at both
-- (worker_harness.mjs, migrationStatements), as 0002_accounts.sql states.

CREATE TABLE share_table_tags (
  key TEXT NOT NULL,
  pos INTEGER NOT NULL,
  tags TEXT NOT NULL,
  PRIMARY KEY (key, pos)
);

CREATE TRIGGER share_table_tags_no_update BEFORE UPDATE ON share_table_tags
BEGIN
  SELECT RAISE(ABORT, 'share_table_tags rows are never changed');
END;

CREATE TRIGGER share_table_tags_no_delete BEFORE DELETE ON share_table_tags
BEGIN
  SELECT RAISE(ABORT, 'share_table_tags rows are never deleted');
END;

CREATE TRIGGER share_table_tags_append_only BEFORE INSERT ON share_table_tags
WHEN NEW.pos IS NOT (SELECT COUNT(*) FROM share_table_tags WHERE key = NEW.key)
BEGIN
  SELECT RAISE(ABORT, 'share_table_tags rows are added at the end of their key, in pos order');
END;
