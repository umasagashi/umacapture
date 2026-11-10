-- Images of a shared record. A sharer who chooses to share a record's images declares them with the
-- share (POST /api/shares): one bundle, the record's reduced JPEGs joined in a fixed order, named by
-- the SHA-256 of its bytes. The share's row holds the declaration, so the images are born and go with
-- the share: no row of images can outlive its share. The bundle itself is put afterwards
-- (PUT /api/shares/<id>/images) to B2 under s/<account id>/<share id>/<bundle name>.
--
-- Every column is added, none changed, so the Worker before this one runs unchanged on the migrated
-- database: it names no new column, and its writes to sync_writes get the default space 'a'.
--
-- The test harness applies migrations by cutting them at every semicolon after dropping comments, so
-- no statement here may hold a semicolon or a comment marker inside a string literal.

-- The declaration: NULL in all four for a share without images, which it stays for the share's life,
-- and for a share whose images an operator took down (share_takedowns below).
ALTER TABLE records ADD COLUMN images TEXT;               -- JSON array of the bundle's parts, in bundle order: {kind, size, sha256, intersection?}
ALTER TABLE records ADD COLUMN images_name TEXT;          -- SHA-256 of the bundle, 64 lowercase hex digits
ALTER TABLE records ADD COLUMN images_size INTEGER;       -- bytes of the bundle, as declared
ALTER TABLE records ADD COLUMN images_stored_at INTEGER;  -- seconds since the epoch the Worker recorded the bundle as put to B2; NULL until then

-- The image budgets count declared bytes (records.images_size), once per share, from the declaration
-- until the share goes: not what B2 holds, which no D1 row can read.
ALTER TABLE totals ADD COLUMN image_bytes INTEGER NOT NULL DEFAULT 0;          -- images_size of every share that declares images
ALTER TABLE daily ADD COLUMN image_bytes INTEGER NOT NULL DEFAULT 0;           -- images_size declared on the day
-- Reports of shares (POST /api/reports) accepted on the day: the count only. A report's content goes to
-- Sentry and is not kept in D1.
ALTER TABLE daily ADD COLUMN reports INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN image_quota_bytes INTEGER NOT NULL DEFAULT 0;  -- images_size the account declared on quota_day

-- sync_writes is the write ledger of sync and of shared images both: what a request is about to write
-- under an account's prefix in B2, recorded before B2 is asked. The space says which prefix, as data
-- rather than read from the shape of a name: 'a' is sync (a/<account id>/<name>), 's' shared images
-- (s/<account id>/<name>, a name being <share id>/<bundle name>). The table keeps its name, since a
-- Worker before this migration still writes to it.
ALTER TABLE sync_writes ADD COLUMN space TEXT NOT NULL DEFAULT 'a';

-- An operator's order to take a share down, one row an order, written by hand with wrangler d1 execute.
-- The hourly run carries it out with the code a sharer's own withdrawal runs: scope 'share' unshares the
-- share as DELETE /api/shares/<id> does, scope 'images' withdraws only its images, so the share stays and
-- tells no images, as one shared without them. done_at is set once carried out, or once found to have
-- nothing left to take down. A row stays as the record of what was taken down and when.
CREATE TABLE share_takedowns (
  share_id TEXT NOT NULL,                                        -- records.id of the share
  scope TEXT NOT NULL CHECK (scope IN ('images', 'share')),      -- what goes: its images, or the whole share
  ordered_at INTEGER NOT NULL,                                   -- seconds since the epoch, the operator's unixepoch()
  done_at INTEGER,                                               -- seconds since the epoch the hourly run carried it out; NULL until then
  PRIMARY KEY (share_id, scope)
);
CREATE INDEX share_takedowns_pending ON share_takedowns (ordered_at) WHERE done_at IS NULL;
