# Web end-to-end check (headless Chrome)

An automated end-to-end check of the **web front end**: the release web build in `build/web`, with its
real wasm recognition core, runs in headless Chrome; a recorded clip goes in either through the
video-import button or as a fake screen share; the record the app writes to OPFS is compared with the
CLI golden. The Windows counterpart is `docs/live-capture-harness.md`.

Nothing is shown on screen: Chrome runs `--headless=new` on a throwaway profile, every interaction
is a DevTools-protocol call into the renderer, and the OS pointer, keyboard and foreground window are
never touched. Every host other than `127.0.0.1` resolves to NOTFOUND, so nothing leaves the machine.

## Files

| file | what it is |
|---|---|
| `run_scenario.py` | **Entry point.** Runs one scenario and leaves its evidence in `<out-root>/<name>/`; exit 0 only for an overall PASS. |
| `web_import_e2e.py` | The harness: serves `build/web` with `tool/serve_web_build.py`, starts headless Chrome, installs the recognition module through the app's manual-update dialog, feeds the clip, dumps OPFS and every console line, judges its own run (`e2e_checks.json`). |
| `compare_record.py` | Compares the active records with a golden using `normalize` / `_sort_key` / `_dumps` from `native/test/integration/run.py`, and checks the resize and factor-tab alignment facts in `prediction.json`. Runs without a browser. |
| `check_build_pins.py` | sha256 of every file pinned in `tool/web_deps.json` against `build/web` and `web/`. |
| `opfs_walk.js` | Injected into the page to dump OPFS. |

## Prerequisites

- A web build in `build/web` made from the current tree. `uv run tool/web_e2e/check_build_pins.py`
  checks the pinned files; it does not cover `main.dart.js`, which nothing pins.
- `sandbox/modules` (the ONNX models) and the clips under `testdata/clips/golden/`.
- Google Chrome (found on `PATH` or in the standard install locations; otherwise `--chrome PATH`
  after `--`), the Windows font `NotoSansJP-VF.ttf` (served for every Google Fonts request; `--font`),
  and `uv`.

## Running

From the repository root. Output goes to `testdata/harness/runs/web-e2e/<name>/` (`--out-root` to
change); a directory that already holds files is refused, so each run needs a new `--name`.
Import takes about 65 s, a live run about 90–100 s.

```bash
FR='{"band":{"min":540,"max":720},"captured_size":{"width":720,"height":1280},"pre_band_unit":720,"unit":720,"arm":"untouched"}'
SENT='キャプチャ中にゲーム画面の大きさが変わりました'

# 1. Video import: the record matches the golden; the resize facts and the measured factor-tab shift are recorded.
uv run tool/web_e2e/run_scenario.py --name import-1 \
  --golden native/test/integration/golden/player_standard_entry_screen_no_arrows.json --expect-frame-resize "$FR" \
  --expect-alignment '{"measured":true,"banner_left_edge":23,"nominal_left":31,"shift":-8}' \
  -- --mode import --clip testdata/clips/golden/player_standard_entry_screen_no_arrows.mp4 \
  --forbid-text "$SENT" --forbid-console 'capture size changed'

# 2. Live capture, size unchanged: the record matches the golden.
uv run tool/web_e2e/run_scenario.py --name live-1 \
  --golden native/test/integration/golden/player_standard_no_scrollbar.json --expect-frame-resize "$FR" \
  -- --mode live --clip testdata/clips/golden/player_standard_no_scrollbar.mp4 \
  --forbid-text "$SENT" --forbid-console 'capture size changed'

# 3. Live capture, shared surface shrunk to 90 % ten seconds in: refused, nothing recorded, the reason shown.
uv run tool/web_e2e/run_scenario.py --name live-resize-1 \
  -- --mode live --clip testdata/clips/golden/player_standard_entry_screen_no_arrows.mp4 \
  --resize-at 10 --resize-scale 0.9 --expect-outcome refused \
  --expect-text "$SENT" --expect-console 'failSession.*capture size changed' --quiet-seconds 7
```

`uv run tool/web_e2e/web_import_e2e.py --help` lists every harness option (`--expect-text`,
`--forbid-text`, `--expect-console`, `--forbid-console`, `--expect-outcome`, `--resize-at`, …).

### Evidence of a run

`args.json` (command lines, `HEAD`, sha256 of the build under test), `inputs.sha256` (clip, golden,
`modules.zip`), `stdout.txt`, `compare.txt`, `e2e_checks.json`, `opfs.json`, `console.log`,
`final.png`, `server.log`, `cleanup.json` and `result.json` (every verdict). `cleanup.json` is measured
by `run_scenario.py` itself after the harness ended: Chrome and the server are not alive, no
process names the profile or the ports, both ports are closed, the profile directory is gone.

### Checks a run cannot pass vacuously

- `compare_record.py` fails on an empty golden, on zero active records, on a record without a
  `prediction.json` (or the reverse), on a tab without complete resize facts, and on an unmeasured
  factor-tab alignment.
- `--expect-text` counts a sentence only when it is **visible** (its own node and every ancestor
  rendered, a non-empty box inside the viewport); `--forbid-text` needs at least one observation.
  The observation gaps are stored with the verdict (live ≈ 0.7 s, import ≈ 2.4 s), so a notice shown
  and removed within one gap would be missed.

## Choice of clips

- **Live, size unchanged: `player_standard_no_scrollbar.mp4`.** The clips are screen recordings and
  keep the mouse pointer in their pixels. The live feed replays them in real time, and which frame of
  a tab becomes the head of its record depends on whether the stationary latch or the first scroll
  offset fires first; in `player_standard_entry_screen_no_arrows.mp4` the pointer rests on a
  family-tree rank badge of the campaign tab right then, so the live record's parent rank flips between
  runs. In `player_standard_no_scrollbar.mp4` the pointer stays clear of the family-tree badges while
  that tab is shown, and the clip has the same 720×1280 geometry.
- **Import and the mid-capture resize: `player_standard_entry_screen_no_arrows.mp4`.** Import decodes
  every frame in order and matches its golden on every run; the resize scenario asserts only the
  refusal, so the pointer does not matter there.

## What it proves and what it does not

Proves, for the clips given: the web build's real wasm core in Chrome writes the CLI golden's
records by import and by a live feed; `prediction.json` carries the resize facts and the factor-tab
alignment; a change of the shared surface size mid-capture is refused, nothing is recorded, and the
reason is visible to the user, while it is visible in no unchanged run; Chrome, the server, the ports
and the profile are gone after each run.

Does not prove: Firefox (Chrome only); a real `getDisplayMedia` share (the track is a
`canvas.captureStream(30)` of the clip: no window-capture backend, unrecorded frame pacing);
hidden-tab throttling; the band's downscale arm (both clips are 720 wide); network paths (module
download and Sentry are blocked); CanvasKit and fonts as Google serves them (substituted locally).
An import stops waiting once the console has been quiet for 20 s after the first `prediction.json`,
so a record written later than that would be missed.
