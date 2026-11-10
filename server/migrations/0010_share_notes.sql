-- What a sharer writes for readers of their shares: a tagline for each share, and a public profile for
-- the account (the trainer name and the trainer id the game shows). Each is the sharer's own text,
-- written after sharing (PUT /api/shares/<id>/tagline, PUT /api/me/profile) and shown on the share's
-- page and the account's list, never on the OG card or in the import. NULL is "not written".
--
-- Every column is added, none changed, so the Worker before this one runs unchanged on the migrated
-- database: it names no new column.
--
-- The test harness applies migrations by cutting them at every semicolon after dropping comments, so
-- no statement here may hold a semicolon or a comment marker inside a string literal.

-- The share's tagline. It goes with the share's row (an unshare, a takedown of the share, the account's
-- deletion), and its UTF-8 bytes are part of the row's charge.
ALTER TABLE records ADD COLUMN tagline TEXT;

-- The account's public profile. Not charged against any budget: one pair an account, a few hundred
-- bytes at most. Both are cleared when the account's deletion begins. game_trainer_id holds the digits
-- alone, without the separators the game shows them with.
ALTER TABLE accounts ADD COLUMN trainer_name TEXT;
ALTER TABLE accounts ADD COLUMN game_trainer_id TEXT;

-- The writes of that text counted against the daily limits (ACCOUNT_TEXT_WRITES_PER_DAY and
-- TEXT_WRITES_PER_DAY in server/src/limits.mjs), taglines and profiles together: per account on
-- text_writes_day, and over every account on daily's day. Only a write that stored a value counts.
ALTER TABLE accounts ADD COLUMN text_writes_day INTEGER;
ALTER TABLE accounts ADD COLUMN text_writes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily ADD COLUMN text_writes INTEGER NOT NULL DEFAULT 0;
