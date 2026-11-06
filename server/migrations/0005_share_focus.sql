-- How the sharer chose to present a shared record: 'training' leads with what the training
-- achieved, 'inheritance' with the factors and lineage. NULL means the sharer chose nothing, and
-- the public record takes the focus its kind gives (public_record.mjs, defaultFocus). The value is
-- a fact of the share, not of the record, so it stays out of the payload and its charge. Rows that
-- exist before this migration keep NULL.

ALTER TABLE records ADD COLUMN focus TEXT CHECK (focus IN ('training', 'inheritance'));
