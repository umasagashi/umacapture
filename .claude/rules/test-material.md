# Test material under `.notes/` is never deleted on your own initiative

`.notes/` is gitignored, but it is **test material, not scratch**. Do not delete, move,
truncate or re-encode anything under it without an explicit instruction naming what to remove.

- `.notes/captures/` — capture recordings and replay outputs. Every golden case and every
  regression-grid run reads its input from here. They are recordings of live game sessions;
  most cannot be produced again at all.
- `.notes/accept_ladder/` — re-encoded ladders built for threshold calibration. Hours of
  encoding, derived from clips that themselves cannot be re-recorded.
- `.notes/analysis/` — measurement records that later work reads its baselines and its
  statement of correctness from.

Deleting build outputs (`native/cmake-build-*`, `build/`) is fine and needs no permission.
Deleting test material is not — including when it looks like leftovers from a finished task.
