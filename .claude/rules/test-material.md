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
- `testdata/clips/grid/` — the encode / scale regression grid's material. It holds only the
  **pristine** rung (`screen-20260802-214946.mp4`); the ten re-encoded rungs are ffmpeg
  derivations of it and are deliberately not kept, so re-derive them from the grid table in
  `.claude/skills/native-change-verification/SKILL.md` §3 before running the grid. Finding one
  file here is the expected state, not missing material.
- `testdata/clips/source/` — primary recordings that nothing re-derives; the rest was cut from
  these.
- `testdata/clips/calibration/` — clips a shipped constant was calibrated against.
- `testdata/models/` — recognizer module sets kept for comparison against the current one.
- `testdata/harness/` — the live-capture harness's scratch data root (`appdrive_root/`) and its
  per-run artefacts (`runs/`), plus `firefox-live-capture/` — the web live-capture playtest
  checklist and its baseline measurements, filed here rather than under `evidence/` because it is
  a procedure to follow, not a record of a past measurement. The run artefacts are measurements;
  earlier runs are what a new run is compared against, so `runs/` is never emptied.
  **`runs/` and `appdrive_root/` are empty on this machine, and were already empty before this
  directory existed** — no earlier run artefacts were carried in, because there were none left to
  carry. So the "compare against earlier runs" step has no left-hand side yet: the next
  `app_drive_run.py` run becomes the baseline rather than being checked against one, and that is
  worth saying in its report. The rule above is a prohibition on emptying `runs/` in future, not
  a claim that it currently holds anything.
- `testdata/evidence/` — primary material that a shipped constant or a source comment cites as
  its derivation. Named by dropping any `analysis/` level: `.notes/analysis/<X>/` →
  `testdata/evidence/<X>/`, and `.notes/<X>/` → `testdata/evidence/<X>/` for the entries that
  never had one (`testdata/evidence/video-import/` came from `.notes/video-import/`). Reversing
  the mapping therefore has two candidate pre-images, not one.

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
