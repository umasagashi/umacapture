-- Whether the account's list is public (1) or private (0). By the product decision, every account
-- starts private, including accounts that already exist when this column is added.
--
-- Only a column is added, so the previous Worker runs on the migrated database without naming it.
-- It does not enforce visibility: do not roll back to a Worker that ignores this column.
--
-- The test harness cuts migrations at semicolons after dropping comments, so no statement here may
-- hold a semicolon or a comment marker inside a string literal.
ALTER TABLE accounts ADD COLUMN list_public INTEGER NOT NULL DEFAULT 0;
