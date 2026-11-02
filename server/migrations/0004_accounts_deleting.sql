-- The accounts being deleted, for the hourly run to continue their deletion (account_deletion.mjs).
-- Partial, so it holds only those accounts: finding them reads what is being deleted, not every
-- account.

CREATE INDEX accounts_deleting ON accounts (deleting_since) WHERE deleting_since IS NOT NULL;
