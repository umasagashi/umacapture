-- A sharer no longer chooses how a shared record is presented: every shared page takes one layout,
-- and the public record's view.focus comes from the record's kind (public_record.mjs,
-- defaultFocus). Nothing reads or writes the column 0005 added, so it goes.
--
-- Apply this only to a D1 whose Worker reads no records.focus: a Worker that names the column
-- fails every query that reads or writes a shared record once it is gone (docs/web-deploy.md,
-- "Rolling out factor colours and the end of share focus").

ALTER TABLE records DROP COLUMN focus;
