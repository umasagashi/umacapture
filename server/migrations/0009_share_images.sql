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

-- The declaration: NULL in all four for a share without images, which it stays for the share's life.
ALTER TABLE records ADD COLUMN images TEXT;               -- JSON array of the bundle's parts, in bundle order: {kind, size, sha256, intersection?}
ALTER TABLE records ADD COLUMN images_name TEXT;          -- SHA-256 of the bundle, 64 lowercase hex digits
ALTER TABLE records ADD COLUMN images_size INTEGER;       -- bytes of the bundle, as declared
ALTER TABLE records ADD COLUMN images_stored_at INTEGER;  -- seconds since the epoch the Worker recorded the bundle as put to B2; NULL until then

-- The image budgets count declared bytes (records.images_size), once per share, from the declaration
-- until the share goes: not what B2 holds, which no D1 row can read.
ALTER TABLE totals ADD COLUMN image_bytes INTEGER NOT NULL DEFAULT 0;          -- images_size of every share that declares images
ALTER TABLE daily ADD COLUMN image_bytes INTEGER NOT NULL DEFAULT 0;           -- images_size declared on the day
ALTER TABLE accounts ADD COLUMN image_quota_bytes INTEGER NOT NULL DEFAULT 0;  -- images_size the account declared on quota_day

-- sync_writes is the write ledger of sync and of shared images both: what a request is about to write
-- under an account's prefix in B2, recorded before B2 is asked. The space says which prefix, as data
-- rather than read from the shape of a name: 'a' is sync (a/<account id>/<name>), 's' shared images
-- (s/<account id>/<name>, a name being <share id>/<bundle name>). The table keeps its name, since a
-- Worker before this migration still writes to it.
ALTER TABLE sync_writes ADD COLUMN space TEXT NOT NULL DEFAULT 'a';
