-- The UTC epoch day of the account's last login (the claim of a full session), counted as created_day
-- counts days. An account is deleted once INACTIVE_ACCOUNT_DAYS pass with no login.
--
-- Every account that exists when this runs takes the day it runs: no earlier login was recorded, and
-- this day is never earlier than the real last login, so no account becomes due for deletion earlier
-- than it really is. NULL (an account a Worker that does not write the column created) counts from its
-- created_day instead.
--
-- Only a column is added, so the previous Worker runs on the migrated database without naming it.
-- It does not record logins: do not roll back to it while inactive accounts are being deleted.
--
-- The test harness cuts migrations at semicolons after dropping comments, so no statement here may
-- hold a semicolon or a comment marker inside a string literal.
ALTER TABLE accounts ADD COLUMN last_login_day INTEGER NULL;
UPDATE accounts SET last_login_day = CAST(strftime('%s', 'now') AS INTEGER) / 86400;
CREATE INDEX accounts_inactive ON accounts (last_login_day) WHERE deleting_since IS NULL;
