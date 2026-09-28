# Test material under `testdata/` is never deleted on your own initiative

`testdata/` is gitignored, but it is **test material, not scratch**. Do not delete, move,
truncate, rename or re-encode anything under it without an explicit instruction naming what to
remove. Unlike `.notes/`, its contents are addressed **by name** from committed files —
`native/test/integration/cases.json`, the harness scenarios under
`tool/live_capture_test/scenarios/`, and the default `--data-dir` of
`native/test/integration/run.py` — so a rename here breaks a committed reference.

- `testdata/clips/golden/` — the golden and dual-decode input clips, plus the live-capture
  harness's `*.stops.json` sidecars. Every golden case and every harness scenario reads its
  input from here. They are recordings of live game sessions; most cannot be produced again.
- `testdata/clips/ladder/` — the `…_540w` / `…_404w` re-encoded ladder built for threshold
  calibration. Hours of encoding, derived from clips that themselves cannot be re-recorded.
- `testdata/clips/grid/` — the encode / scale regression grid's material. It holds the
  **pristine** rung (`screen-20260802-214946.mp4`) and the ten re-encoded rungs named in the grid
  table in `.claude/skills/native-change-verification/SKILL.md` §3. The ten are ffmpeg derivations
  of the pristine rung, so a missing one is re-derived from that table before running the grid;
  the pristine rung is the one that cannot be replaced.
- `testdata/clips/source/` — primary recordings that nothing re-derives; the rest was cut from
  these.
- `testdata/clips/calibration/` — clips a shipped constant was calibrated against. **It is empty
  today, and that is the expected state, not missing material.** Its one clip,
  `friend_standard_many_rental.mp4`, was moved into `testdata/clips/golden/` on the user's
  instruction and registered in `native/test/integration/cases.json`, so the two constants derived
  from it — the scroll-guess veto half-width and `friend_common.viewport`, both in
  `native/tool/builder/chara_detail_scene_scraper_builder.h` — rest on material the golden suite
  re-runs. A clip being a derivation source and a golden input is not a conflict: the second only
  adds the requirement that its records stay reproducible. Keep this entry: the next clip a
  constant is calibrated on lands here, and a clip only graduates to `golden/` once a case asserts
  something about it.
- `testdata/models/` — recognizer module sets kept for comparison against the current one.
- `testdata/harness/` — the live-capture harness's scratch data root (`appdrive_root/`) and its
  per-run artefacts (`runs/`), plus `firefox-live-capture/` — the web live-capture playtest
  checklist and its baseline measurements, filed here rather than under `evidence/` because it is
  a procedure to follow, not a record of a past measurement. The run artefacts are measurements;
  earlier runs are what a new run is compared against, so `runs/` is never emptied.
  `runs/` holds earlier run artefacts on this machine, so a new `app_drive_run.py` run is checked
  against them rather than becoming the baseline.
- `testdata/evidence/` — primary material a shipped constant was derived from. A code comment
  does not cite it; it states what was derived inline (`.claude/CLAUDE.md`, `## Comments`).
  Named by dropping any `analysis/` level: `.notes/analysis/<X>/` → `testdata/evidence/<X>/`, and
  `.notes/<X>/` → `testdata/evidence/<X>/` for the entries that never had one
  (`testdata/evidence/video-import/` came from `.notes/video-import/`). Reversing the mapping
  therefore has two candidate pre-images, not one.

## `.notes/` is scratch, and must stay that way

`.notes/` is the place for **temporary working notes**: analysis write-ups, one-off probe output,
diagnostic images (`.notes/analysis/<topic>/`, per `.claude/CLAUDE.md`). It is throwaway by
design and may be swept.

**Do not put anything a test or shipped code depends on into `.notes/`.** The moment something
there becomes a dependency — a clip a case names, a log a constant was derived from, a fixture a
script reads — it belongs in `testdata/` (or in the repository, if it is small and stable).
This split exists because the two were mixed for a long time and a sweep of the scratch
directory would have taken the golden suite's inputs with it.

Deleting build outputs (`native/cmake-build-*`, `build/`) is fine and needs no permission.
Deleting test material is not — including when it looks like leftovers from a finished task.
