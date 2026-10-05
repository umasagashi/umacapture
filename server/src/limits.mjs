// Every limit the write endpoints enforce. The budget figures come from measuring the staging D1
// (bytes per row, rows written per operation) with 4,096-byte pages.

/**
 * Bytes charged per record on top of its payload, for the row, its two index entries and page slack.
 * The measured overhead (physical bytes per row minus payload) is 325.9 to 439.4 B for real records
 * and peaks at 1,248.8 B for the largest accepted form: its ~2.9 KB payload fills a page by itself.
 * The charge is that peak rounded up to a multiple of 256, so the charge covers the physical size of
 * every accepted form, not only of typical ones.
 */
export const ROW_CHARGE = 1_280;

/** Upper bound on the sum of `records.charge`: 80% of the 500 MB a D1 database may hold. */
export const STORAGE_BUDGET = 400_000_000;

/**
 * Upper bound on the charge published in one UTC day: 400,000,000 / 1,048,576 is about 381, so filling
 * the budget takes at least 381 days. At the average real payload (999.5 B) this admits about 460
 * publishes a day.
 */
export const DAILY_LIMIT = 1_048_576;

/**
 * Upper bound on the tickets issued in one UTC day. Issuing writes 4 rows per ticket plus 1 for the
 * sweep, and a publish writes 6; with the daily charge limit at most 638 publishes fit (the smallest form charges 1,643 B).
 * So the worst day writes 5,000 x 5 + 638 x 6 = 28,828 rows of the 100,000 a D1 database allows.
 */
export const TICKET_LIMIT = 5_000;

/** Publishes one ticket allows, and how long it stays valid. */
export const TICKET_USES = 10;
export const TICKET_TTL_SECONDS = 1_800;

/** Expired tickets removed per sweep, so one sweep never costs more than this many deletions. */
export const SWEEP_LIMIT = 100;

/** Request body of POST /api/records, counted as received. */
export const MAX_PUBLISH_BODY = 20 * 1024;

/** Canonical JSON of the posted form, before compression. */
export const MAX_CANONICAL = 16 * 1024;

/** Request body of the other JSON endpoints (a ticket hash and a token, or a delete key). */
export const MAX_SMALL_BODY = 4 * 1024;
