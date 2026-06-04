# Native recognition backend

A map of the C++ recognition backend under `native/`, written for coding agents.
It explains **where to read** for each concern and supplements the things the
code does not make obvious on its own — the custom coordinate system and the
builder workflow.

> This doc is overview-only. For building, running, and debugging the standalone
> CLI (`umacapture_cli`), see the **`native-cli-dev`** skill
> (`.claude/skills/native-cli-dev/SKILL.md`) — that covers the MSVC toolchain,
> CMake/Ninja, subcommand mechanics, and the cdb debugger. This doc does not
> repeat any of it.

## What it does

The backend takes captured frames of the game's *character detail* screen (a
trained "hall of fame" Uma Musume) and recognizes its data. The screen has three
tabs — **Skill**, **Factor**, **Campaign** — each containing a scroll area that
does not fit one screenshot. So instead of a single capture, the backend
consumes a **recording** (live window capture or a video file), reconstructs each
tab's full scroll content into **one tall image per tab (3 images total)**, and
then runs ML recognition on those three images.

All layout coordinates live in JSON (`assets/config/chara_detail/*.json`), never
hard-coded. The JSON is authored in C++ "builders" and emitted via the CLI — see
[Builder workflow](#builder-workflow).

## Pipeline at a glance

The backend is an event-driven pipeline; each stage runs on its own
single-thread runner. Frames flow through events, not direct calls.

```
 frame source ──► FrameDistributor ──► CharaDetailSceneContext ─┐
 (capture/video)                       (detect screen+tab+type) │ on_scene_updated
                                                                ▼
                                  CharaDetailSceneScraper  (recording ─► image fragments)
                                                                │ on_completed → stitch
                                                                ▼
                                  CharaDetailSceneStitcher (fragments ─► 1 tall image / tab)
                                                                │ on_recognize_ready
                                                                ▼
                                  CharaDetailRecognizer    (3 images ─► record.json)
```

**Wiring is in `native/src/core/native_api.cpp`** (`startEventLoop`) — read this
first to see how the stages, threads, and event connections are assembled. The
public surface and notification messages are in `native/src/core/native_api.h`.

| Stage | Read | Role |
|---|---|---|
| Frame source | `native/src/core/cli.cpp`, `native/src/cv/video_loader.h` | Live window capture or video file → `Frame` |
| Distributor | `native/src/cv/frame_distributor.h` | Fan frames to scene contexts; route "no target" |
| Scene detect | `native/src/chara_detail/chara_detail_scene_context.h` | Detect the screen, active **tab**, and **record type** via a condition tree |
| Scrape | `native/src/chara_detail/chara_detail_scene_scraper.h` | Track scrolling, save scroll-area **fragments** + base + tab buttons |
| Stitch | `native/src/chara_detail/chara_detail_scene_stitcher.h` | `vconcat` fragments, rebuild a full-height canvas per tab |
| Recognize | `native/src/chara_detail/chara_detail_recognizer.h` | Run ML models over fixed rects; write the record |

Config structs for every stage (the deserialization targets of the JSON) are in
**`native/src/chara_detail/chara_detail_config.h`**. The output record schema is
in `native/src/chara_detail/chara_detail_record.h`.

### Stage notes (the non-obvious parts)

- **Scene context** (`chara_detail_scene_context.h`) evaluates a tree of
  conditions loaded from `scene_context.json`. Two sub-conditions are looked up
  by tag — `tab_page` (Skill/Factor/Campaign) and `record_type` — and their
  active index drives the rest of the pipeline. The condition/rule machinery
  itself lives under `native/src/condition/`.
- **Scraper** (`chara_detail_scene_scraper.h`) is the heart of "recording → tall
  image". Per tab it decides scrollable vs. non-scrollable by looking for a
  scrollbar, then estimates scroll offset between frames with a **two-tier
  estimator**: `ScrollBarOffsetEstimator` (coarse guess from scrollbar position)
  refined by `ImageOffsetEstimator` (AKAZE feature match + homography, accepting
  only vertical translation). Newly revealed strips are cut at color boundaries
  (`ScanParameter`) and saved as `scroll_area_NNNNN.png`. A `BaseFrameCatcher`
  grabs the static header/frame while ignoring snackbar (toast) interference.
  Output goes to `temp_dir/chara_detail/<record_id>/`.
- **Stitcher** (`chara_detail_scene_stitcher.h`) `vconcat`s the strips, then
  pastes the base image (top / vertically-stretched middle / bottom), the scroll
  area, and the tab button onto a canvas, filling the scrollbar and scroll
  residue with background color. It saves `skill.png` / `factor.png` /
  `campaign.png` to `storage_dir/chara_detail/active/<record_id>/`, **each with a
  sibling `.json` holding the `intersection` rect** so the coordinate system can
  be reconstructed at recognition time (see below).
- **Recognizer** (`chara_detail_recognizer.h`) reopens the three images with
  `Frame::open` (restoring the anchor from the saved `intersection`), then runs
  per-area recognizers (`StatusHeaderRecognizer`, `SkillTabRecognizer`,
  `FactorTabRecognizer`, `CampaignTabRecognizer`). Models are loaded from
  `modules_dir`; the model wrapper is `native/src/cv/model.h`. Output: a
  `record.json`, a `prediction.json` (every prediction's rect + confidence), and
  a cropped `trainee.jpg`.

`RecordType` (`Standard` / `InheritanceOnly` / `Friend`,
`chara_detail_record.h`) gates which tabs/fields are processed — e.g.
`InheritanceOnly` skips skills and some status fields.

## Coordinate system

This is the part that code alone makes hard to follow. **Read
`native/src/cv/scene_context.h` (`FrameAnchor`)** alongside this section;
the geometry types (`Point`, `Rect`, `Size`, `Line`, `LayoutAnchor`, `Anchor`)
are in `native/src/types/shape.h`.

### The problem it solves

The game renders at different aspect ratios: a tall phone adds **top/bottom**
padding, a wide tablet adds **left/right** padding. To make one set of
coordinates work everywhere, the system defines the **intersection** — the
region common to all environments (the largest rect of the base 9:16 aspect
ratio, `base_size = {540, 960}`, that fits the frame). Padding lies outside it.
`FrameAnchor::intersect()` computes this; the margins are the leftover bands.

### Normalized scale + anchors

Coordinates are stored as `double` on a scale where **the intersection width =
1.0** (`unit_size = intersection.width()`, scale = `1/unit_size`). A point is not
just an (x, y): it carries an **`Anchor`** that names, independently for the
horizontal and vertical axis, which edge the value is measured from. There are
six `LayoutAnchor` origins:

| Anchor | Origin (per axis) |
|---|---|
| `ScreenStart` | screen left / top edge |
| `ScreenLogicalEnd` | one past the screen's last pixel (`frame_size`) |
| `ScreenPixelEnd` | screen's last pixel (`frame_size - 1`) |
| `IntersectStart` | intersection left / top (common region edge) |
| `IntersectLogicalEnd` | one past the intersection's last pixel |
| `IntersectPixelEnd` | intersection's last pixel |

`Screen*` anchors track the real screen edge (including padding);
`Intersect*` anchors track the common region. Because the intersection is 1.0
wide, `IntersectLogicalEnd − IntersectStart = 1.0`.

### Logical end vs. pixel end

This distinction trips people up:

- **logical end** is the *open*-interval endpoint — the (virtual) pixel just past
  the last real one. A box from `IntersectStart 0.0` of width `1.0` ends exactly
  at `IntersectLogicalEnd 0.0`.
- **pixel end** is the *closed*-interval endpoint — the last real, addressable
  pixel (one less). Since `logical end` is virtual and can't be indexed, code
  uses `pixel end` (1 px smaller) when it needs an actual pixel.

In `FrameAnchor`, `*LogicalEnd` offsets use the full size and `*PixelEnd` offsets
use `size − 1` — that one-pixel difference is the whole story.

### Conversions

`FrameAnchor` turns anchored, normalized coordinates into real pixels:

- `absolute(p)` → re-express any anchor as `ScreenStart` normalized coords (adds
  the per-anchor offset).
- `expand(p)` → multiply by `unit_size` and round to integer pixels.
- `mapToFrame(p)` = `expand(absolute(p))` — the full normalized → pixel path used
  everywhere (`Frame::view`, `colorAt`, model rects, …).
- `mapFromFrame` / `scaleFromPixels` / `scaleToPixels` go the other way.

A worked example of authoring with these anchors is the builder code below.

## Builder workflow

Layout coordinates are **authored in C++**, not edited as JSON by hand. The
builders construct the config structs with readable expressions, and the CLI
serializes them to JSON (round-trip-verifying each).

- **Builders:** `native/tool/builder/` — one per stage
  (`chara_detail_scene_context_builder.h`, `..._scraper_builder.h`,
  `..._stitcher_builder.h`, `..._recognizer_builder.h`).
- **Helpers:** `native/tool/builder/builder_util.h` defines the short anchor
  aliases (`IS`/`ILE`/`IPE` for `Intersect*`, `SS`/`SLE`/`SPE` for `Screen*`),
  color helpers, and condition combinators (`allOf`, `anyOf`, `lineCheck`, …).
  Coordinates read like `Rect<double>{{0.1, 0.0556, IS}, {0.9, 0.8074, IS}}`.
- **Emit:** the CLI `build` subcommand (`native/src/core/cli.cpp`, `buildJson`)
  writes the four JSONs into the target assets dir and asserts
  `json == reconstructed_json` so serialization stays lossless:

  ```
  umacapture_cli build --assets_dir C:\Projects\umacapture\assets\config
  ```

  (run from the build dir — see the `native-cli-dev` skill).

**To change a coordinate or condition: edit the builder, rebuild the CLI, run
`build`, then commit the regenerated JSON.** Do not hand-edit
`assets/config/chara_detail/*.json`.

## Config & directories

- `assets/config/chara_detail/{scene_context,scene_scraper,scene_stitcher,recognizer}.json`
  — the generated layout/condition configs (deserialized into
  `chara_detail_config.h` structs).
- `assets/config/platform.json` — per-platform capture config (window targets,
  recording fps, crop profiles per aspect ratio). The full runtime config object
  is assembled in `createConfig` (`native/src/core/cli.cpp`) for CLI runs.
- Runtime dirs (from the config's `directory` block):
  - `temp_dir/chara_detail/<record_id>/` — scraper output (fragments, base, tab buttons).
  - `storage_dir/chara_detail/active/<record_id>/` — stitched `skill/factor/campaign.png` (+ `.json`), and the recognizer's `record.json` / `prediction.json` / `trainee.jpg`.
  - `modules_dir` — ML model files loaded by the recognizer.

## Reading order for a newcomer

1. `native/src/core/cli.cpp` — the five subcommands; how a run is driven.
2. `native/src/core/native_api.cpp` `startEventLoop` — the stage/thread wiring.
3. This doc's [coordinate system](#coordinate-system) + `native/src/cv/scene_context.h`.
4. The stage header for whatever you're touching (table above).
5. The matching builder in `native/tool/builder/` if you need to change layout.
