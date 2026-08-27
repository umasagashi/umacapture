# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy"]
# ///
"""Annotate a clip with the frames that bracket each tab's scrolling.

Synchronised playback needs one number per tab: the last frame at which the screen is *genuinely*
still -- the tap/settle animation finished, nothing scrolling yet. The player is parked there with
`pause-at` and released only once the app reports scroll-ready for that tab, which turns "did the
app get enough stable frames" from a race into a causal ordering.

Those numbers are properties of the clip, so they are computed once, offline, and stored in a
sidecar JSON next to it. The runtime harness reads the sidecar and never re-derives anything.

Part of a sidecar is hand-made: there is no flag for `scroll_end_frame`, so the documented procedure
is to edit that field by hand and set `manual_override` yourself. Nothing re-derives a hand edit, so
`--write` refuses to replace an existing sidecar whose contents differ and names the fields that
would change; `--force` is how you say the replacement is intended.

An annotation that produced warnings exits 1. docs/live-capture-harness.md makes "`warnings` must be
empty, or every entry must be one you understand" step 1 of verifying an annotation, and a warning is
the only signal that detection failed at all -- a `stop_frame` of -1 is armed verbatim and the player
clamps it to frame 0, so the run synchronises against a stop that was never found. A gate the
procedure calls mandatory cannot be expressed on stderr alone, because `--write && scenario_run.py …`
walks straight past it. `--allow-warnings` is how you say you read them and understood them.

    uv run tool/live_capture_test/annotate_stops.py --clip testdata/clips/golden/player_standard_5.mkv --write
    uv run tool/live_capture_test/annotate_stops.py --clip testdata/clips/my_clip.mkv --report  # the numbers

The full procedure, including how to verify an annotation before trusting it, is in
docs/live-capture-harness.md.

Definitions (all measured on the configured scroll area, not the whole frame -- see below):

  quiet frame   its scroll area differs from the previous frame's in <= --tol pixels. Default 0,
                i.e. byte-identical. The clip is lossless FFV1 of a real game window, so a scroll
                area that is not animating produces a byte-identical successor and "stable" needs
                no tolerance.
  stable run    >= --settle consecutive quiet frames.
  scroll onset  first frame of a run of >= --run frames whose scroll-area content shifts
                vertically by >= --min-shift px (1-D cross-correlation of row-mean profiles, the
                same estimator as `scroll_onset.py`, an earlier throwaway that no longer exists
                anywhere -- see docs/live-capture-harness.md).
  scroll group  consecutive onsets no more than --group-gap frames apart. One tab's scrolling is a
                burst of short swipes, so a group is a tab, and group k is tab k.
  stop frame    the last frame before a group's FIRST onset that ends a stable run. Normally
                onset-1; earlier only if the screen was still animating right up to the swipe.
  scroll end    the first quiet frame after a group's LAST onset, i.e. where the final swipe's
                momentum has run out. The scrolling phase of a tab is [first onset, scroll end].

Why the scroll area and not the whole frame: measured on player_standard_5.mkv, NO frame in the
clip is byte-identical to its predecessor -- something outside the scroll area (rows ~435..500 and
~1280..1292) animates continuously, forever. A whole-frame stability test therefore never fires.
Inside the scroll area the same clip is byte-identical on 183 of 375 frame pairs, and that is also
the region the app's own stationarity test watches (`scroll_area_stationary_rect` is a sub-rect of
`scroll_area_rect`).

Geometry is resolved from assets/config/chara_detail/scene_scraper.json plus the clip's own frame
size, rather than hardcoded the way that earlier `scroll_onset.py` did. Normalisation follows the
native builder:
BOTH axes normalise on the intersection WIDTH, and the intersection is assumed to be the whole
frame -- which is what the pipeline latches for this clip ("detail crop latched: (0,0)-(737,1310)").
`--scroll-area TOP:BOTTOM` overrides the resolved rows for a clip where that is not true.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

# The reader's own predicate for "can this be a frame index", imported rather than restated so a
# hand-written --stop-frames value this tool accepts cannot be one app_drive_run.py refuses.
from stops_schema import frame_index_fault, parse_frame_indices

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "assets/config/chara_detail/scene_scraper.json"
MAX_SHIFT = 60


# ------------------------------------------------------------------------------------- clip input


def probe(path: Path) -> tuple[int, int, list[float]]:
    size = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True).stdout.strip().split(",")
    stamps = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True).stdout
    return int(size[0]), int(size[1]), [float(s) for s in stamps.split() if s.strip()]


def frames(path: Path, width: int, height: int):
    """Yields every frame as BGR uint8. `-fps_mode passthrough` is mandatory: without it ffmpeg
    duplicates frames up to a constant rate and the indices stop matching the player's."""
    proc = subprocess.Popen(
        ["ffmpeg", "-v", "fatal", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "bgr24",
         "-fps_mode", "passthrough", "-"],
        stdout=subprocess.PIPE)
    stride = width * height * 3
    assert proc.stdout is not None
    try:
        while True:
            buf = proc.stdout.read(stride)
            if len(buf) < stride:
                return
            yield np.frombuffer(buf, np.uint8).reshape(height, width, 3)
    finally:
        proc.stdout.close()
        proc.wait()


def scroll_rows(width: int, height: int) -> tuple[int, int]:
    """Resolves `common.scroll_area_rect` to pixel rows, assuming a full-frame intersection."""
    rect = json.loads(CONFIG.read_text(encoding="utf-8"))["common"]["scroll_area_rect"]
    def resolve(value: float) -> int:
        # Both axes normalise on the intersection WIDTH; a negative value with an *End anchor
        # counts back from the intersection's bottom edge.
        return int(round(value * width)) if value >= 0 else height + int(round(value * width))
    return resolve(rect["top_left"]["y"]), resolve(rect["bottom_right"]["y"])


# ------------------------------------------------------------------------------------- estimators


def shift_of(previous: np.ndarray, current: np.ndarray) -> tuple[int, float, float]:
    """Best vertical shift in px taking `previous` onto `current`, its residual, and the residual
    at zero shift (how much of the change the shift explains)."""
    best, best_cost = 0, None
    for shift in range(-MAX_SHIFT, MAX_SHIFT + 1):
        if shift >= 0:
            a, b = previous[shift:], current[:len(current) - shift] if shift else current
        else:
            a, b = previous[:len(previous) + shift], current[-shift:]
        cost = float(np.mean(np.abs(a - b)))
        if best_cost is None or cost < best_cost:
            best, best_cost = shift, cost
    return best, best_cost or 0.0, float(np.mean(np.abs(previous - current)))


def scan(path: Path, width: int, height: int, top: int, bottom: int) -> dict:
    """One decode pass. Per frame: how many scroll-area pixels changed, the largest per-channel
    change inside and outside it, and the scroll area's row-mean profile."""
    area, area_max, outside, profiles = [0], [0], [0], []
    previous: np.ndarray | None = None
    for frame in frames(path, width, height):
        profiles.append(frame[top:bottom].astype(np.float32).mean(axis=(1, 2)))
        if previous is not None:
            delta = np.abs(frame.astype(np.int16) - previous.astype(np.int16)).max(axis=2)
            changed = delta > 0
            area.append(int(changed[top:bottom].sum()))
            area_max.append(int(delta[top:bottom].max()))
            outside.append(int(changed.sum()) - area[-1])
        previous = frame.copy()
    stacked = np.array(profiles)
    shifts, residual, flat = [0], [0.0], [0.0]
    for i in range(1, len(profiles)):
        s, r, f = shift_of(stacked[i - 1], stacked[i])
        shifts.append(s)
        residual.append(r)
        flat.append(f)
    return {"area": area, "area_max": area_max, "outside": outside, "shifts": shifts,
            "residual": residual, "flat": flat, "count": len(profiles)}


def scroll_onsets(shifts: list[int], min_shift: int, run: int) -> list[int]:
    moving = [abs(s) >= min_shift for s in shifts]
    onsets, i = [], 0
    while i < len(moving):
        if moving[i] and all(moving[i:i + run]):
            onsets.append(i)
            while i < len(moving) and moving[i]:
                i += 1
            while i + 1 < len(moving) and moving[i + 1]:  # tolerate a one-frame stall in a run
                i += 1
        i += 1
    return onsets


def group_onsets(onsets: list[int], gap: int) -> list[list[int]]:
    groups: list[list[int]] = []
    for onset in onsets:
        if groups and onset - groups[-1][-1] <= gap:
            groups[-1].append(onset)
        else:
            groups.append([onset])
    return groups


def scroll_end(area: list[int], last_onset: int, limit: int, tol: int) -> tuple[int, int]:
    """First frame after [last_onset] whose scroll area is quiet again, and how long it stays quiet.

    That frame is where the tab's scrolling phase is over: the final swipe's momentum has run out
    and the content has come to rest. It is the frame at which a harness that slowed the scroll down
    should go back to real time, because everything after it -- the rest of the dwell and the tap on
    the next tab -- is fixed-length animation that must not be stretched.

    ONE quiet frame, not a run of them, and the search stops at [limit] (the next tab's first
    onset). Both matter: on this clip tab 0 comes to rest at frame 127 and the tab switch repaints
    the whole scroll area at 128, so demanding even two consecutive quiet frames walks straight past
    the tab switch and answers 144 -- a frame that is in the NEXT tab. The returned run length says
    how much quiet actually followed, so a short one is visible rather than hidden.
    """
    for i in range(last_onset + 1, min(limit, len(area))):
        if area[i] <= tol:
            run = 0
            while i + run < len(area) and area[i + run] <= tol:
                run += 1
            return i, run
    return -1, 0


def stable_stop(area: list[int], onset: int, settle: int, tol: int) -> tuple[int, int]:
    """Last frame before [onset] that ends a run of >= [settle] quiet frames, and that run's
    length. Returns (-1, 0) when no such frame exists."""
    run, best, best_run = 0, -1, 0
    for i in range(1, onset):
        run = run + 1 if area[i] <= tol else 0
        if run >= settle:
            best, best_run = i, run
    return best, best_run


# ------------------------------------------------------------------------------------------- main


def diff_paths(old, new, prefix: str = "") -> list[str]:
    """Field paths at which two decoded sidecars disagree, walked structurally.

    Enumerated by walking the two documents rather than by listing the fields that matter, so a
    field added to the sidecar later is compared without anyone remembering to add it here."""
    if isinstance(old, dict) and isinstance(new, dict):
        paths: list[str] = []
        for key in sorted(set(old) | set(new)):
            paths += diff_paths(old.get(key), new.get(key), f"{prefix}.{key}" if prefix else key)
        return paths
    if isinstance(old, list) and isinstance(new, list) and len(old) == len(new):
        paths = []
        for index, (a, b) in enumerate(zip(old, new)):
            paths += diff_paths(a, b, f"{prefix}[{index}]")
        return paths
    return [] if old == new else [prefix or "<whole document>"]


def differing_fields(existing: Path, generated: dict) -> list[str]:
    """What replacing [existing] with [generated] would change. An unreadable or unparsable file
    counts as differing everywhere: that is precisely the case where overwriting it blind is worst."""
    try:
        old = json.loads(existing.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ["<the existing file could not be parsed>"]
    return diff_paths(old, generated)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--clip", required=True)
    parser.add_argument("--out", default=None, help="sidecar path (default <clip>.stops.json)")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--force", action="store_true",
                        help="let --write replace an existing sidecar whose contents differ")
    parser.add_argument("--allow-warnings", action="store_true",
                        help="exit 0 even though the annotation produced warnings (say this only "
                             "once you have read every one of them)")
    parser.add_argument("--report", action="store_true", help="dump the numbers behind the thresholds")
    parser.add_argument("--cache", default=None,
                        help="npz to save/reuse the decode pass in, so retuning does not re-decode")
    parser.add_argument("--tol", type=int, default=0,
                        help="scroll-area pixels a quiet frame may change (0 = byte-identical)")
    parser.add_argument("--settle", type=int, default=4, help="quiet frames a stable run needs")
    parser.add_argument("--min-shift", type=int, default=2)
    parser.add_argument("--run", type=int, default=3, help="frames a scroll run must sustain")
    parser.add_argument("--group-gap", type=int, default=40,
                        help="max frames between two onsets of the same tab's scrolling burst")
    parser.add_argument("--tabs", type=int, default=3,
                        help="how many scroll groups are real tabs; extra groups are ignored")
    parser.add_argument("--scroll-area", default=None, help="override the resolved rows, TOP:BOTTOM")
    parser.add_argument("--stop-frames", default=None,
                        help="comma-separated manual override, one stop frame per tab; detection "
                             "is still run and reported, but these frames are what is written")
    args = parser.parse_args()

    clip = Path(args.clip).resolve()
    width, height, stamps = probe(clip)
    top, bottom = ((int(v) for v in args.scroll_area.split(":")) if args.scroll_area
                   else scroll_rows(width, height))

    cache = Path(args.cache) if args.cache else None
    if cache is not None and cache.exists():
        data = {k: v.tolist() if v.ndim else int(v) for k, v in np.load(cache).items()}
        data["count"] = len(data["shifts"])
    else:
        data = scan(clip, width, height, top, bottom)
        if cache is not None:
            np.savez(cache, **{k: np.array(v) for k, v in data.items() if k != "count"})
    area, shifts = data["area"], data["shifts"]
    count = data["count"]
    if len(stamps) < count:
        raise RuntimeError(f"ffprobe reported {len(stamps)} timestamps for {count} decoded frames")

    onsets = scroll_onsets(shifts, args.min_shift, args.run)
    groups = group_onsets(onsets, args.group_gap)
    # A hand-written stop frame is checked here, against the clip that was just decoded, and through
    # the SAME predicate the harness applies when it arms one. Without it the writer could put a
    # value into the sidecar that the reader then refuses -- or worse, one that reaches `stamps[stop]`
    # below and comes out as a bare IndexError naming no field. What is refused is stated as the
    # class of usable values, so a new way of being wrong needs no new branch here.
    manual = parse_frame_indices(args.stop_frames) if args.stop_frames else None
    if manual is not None:
        faults = []
        if len(manual) != args.tabs:
            faults.append(f"has {len(manual)} entries but --tabs is {args.tabs} (one stop frame per tab)")
        faults += [f"entry {position} for tab {position} {fault}"
                   for position, value in enumerate(manual)
                   if (fault := frame_index_fault(value, count)) is not None]
        if faults:
            detail = "\n  ".join(faults)
            raise SystemExit(f"--stop-frames {args.stop_frames!r} cannot be written as stops of "
                             f"{clip.name}:\n  {detail}\n"
                             f"See docs/live-capture-harness.md, 'Manual fallback'.")

    stops = []
    warnings: list[str] = []
    if len(groups) < args.tabs:
        warnings.append(f"only {len(groups)} scroll groups were found but --tabs is {args.tabs}")
    if len(groups) > args.tabs:
        warnings.append(f"{len(groups)} scroll groups were found; groups {args.tabs}.. are ignored "
                        f"({groups[args.tabs:]})")
    used = groups[:args.tabs]
    for tab, group in enumerate(used):
        onset = group[0]
        detected, run = stable_stop(area, onset, args.settle, args.tol)
        stop = manual[tab] if manual is not None else detected
        # The scrolling phase ends when the LAST swipe of this tab has come to rest. Bound the
        # search by the next tab's first onset so a tab that never settles cannot borrow the next
        # tab's stillness and report an end frame that is already past the tab switch.
        last_onset = group[-1]
        limit = used[tab + 1][0] if tab + 1 < len(used) else count
        end, end_run = scroll_end(area, last_onset, limit, args.tol)
        if end < 0:
            warnings.append(f"tab {tab}: the scroll area never went quiet between the last onset "
                            f"{last_onset} and frame {limit}; no scroll_end_frame")
        elif end <= onset:
            warnings.append(f"tab {tab}: scroll_end_frame {end} is not after the first onset {onset}")
        # A stop that is not the frame immediately before the onset means the screen was still
        # animating up to the swipe -- possible, but far more often it means a parameter is wrong
        # (e.g. --settle longer than any stable run, in which case stable_stop silently returns the
        # last frame of some much earlier run). Say so instead of writing a plausible wrong number.
        if detected < 0:
            warnings.append(f"tab {tab}: no stable run of {args.settle} quiet frames before onset {onset}")
        elif onset - detected > 3:
            warnings.append(f"tab {tab}: detected stop {detected} is {onset - detected} frames before "
                            f"onset {onset} -- expected 1; check --settle/--tol")
        stops.append({
            "tab": tab,
            "label": f"tab{tab}",
            "stop_frame": stop,
            "stop_ms": round(stamps[stop] * 1000) if stop >= 0 else None,
            "scroll_onset_frame": onset,
            "scroll_onset_ms": round(stamps[onset] * 1000),
            "lead_frames": onset - stop if stop >= 0 else None,
            "lead_ms": round((stamps[onset] - stamps[stop]) * 1000) if stop >= 0 else None,
            "quiet_run_frames": run,
            "quiet_run_ms": round((stamps[detected] - stamps[detected - run]) * 1000) if detected > 0 else None,
            "detected_stop_frame": detected,
            "manual_override": manual is not None,
            "later_onsets_in_tab": group[1:],
            "scroll_last_onset_frame": last_onset,
            "scroll_last_onset_ms": round(stamps[last_onset] * 1000),
            "scroll_end_frame": end if end >= 0 else None,
            "scroll_end_ms": round(stamps[end] * 1000) if end >= 0 else None,
            "scroll_end_quiet_run_frames": end_run,
            "scroll_phase_frames": end - onset if end >= 0 else None,
            "scroll_phase_ms": round((stamps[end] - stamps[onset]) * 1000) if end >= 0 else None,
            "scroll_end_search_limit_frame": limit,
        })

    sidecar = {
        "version": 1,
        "clip": clip.name,
        "clip_sha256": hashlib.sha256(clip.read_bytes()).hexdigest(),
        "clip_bytes": clip.stat().st_size,
        "frame_count": count,
        "frame_size": [width, height],
        "scroll_area_rows": [top, bottom],
        "definition": {
            "quiet": "scroll-area pixels changed vs the previous frame <= quiet_tolerance_px",
            "scroll_end": "first quiet frame after the tab's last onset, searched only up to the "
                          "next tab's first onset",
            "quiet_tolerance_px": args.tol,
            "settle_frames": args.settle,
            "min_shift_px": args.min_shift,
            "scroll_run_frames": args.run,
            "group_gap_frames": args.group_gap,
            "tabs": args.tabs,
        },
        "scroll_groups": groups,
        "stops": stops,
        "warnings": warnings,
    }
    for warning in warnings:
        print(f"WARNING: {warning}", file=sys.stderr)

    if args.report:
        area_max, outside = data["area_max"], data["outside"]
        nonzero = sorted(v for v in area[1:] if v > 0)
        whole = [area[i] + outside[i] for i in range(count)]
        print(f"frames={count} size={width}x{height} scroll_rows={top}..{bottom} "
              f"scroll_area_px={(bottom - top) * width}")
        print(f"scroll onsets: {onsets}")
        print(f"scroll groups (gap {args.group_gap}): {groups}   -> tabs used: {groups[:args.tabs]}")
        print(f"whole-frame byte-identical successors: "
              f"{sum(1 for v in whole[1:] if v == 0)}/{count - 1}")
        print(f"scroll-area byte-identical successors: "
              f"{sum(1 for v in area[1:] if v == 0)}/{count - 1}")
        print(f"smallest non-zero scroll-area change: {nonzero[:12]}")
        print("  -> any --tol strictly below the first value above the 1-2 level noise band gives "
              "the same answer; the sensitivity table proves it")
        print("\nscrolling phase per tab (onset .. scroll end):")
        for entry in stops:
            print(f"  tab {entry['tab']}: {entry['scroll_onset_frame']} ({entry['scroll_onset_ms']} ms) "
                  f".. {entry['scroll_end_frame']} ({entry['scroll_end_ms']} ms)  "
                  f"= {entry['scroll_phase_frames']} frames / {entry['scroll_phase_ms']} ms, "
                  f"last onset {entry['scroll_last_onset_frame']}, "
                  f"quiet run after end {entry['scroll_end_quiet_run_frames']}, "
                  f"searched up to {entry['scroll_end_search_limit_frame']}")
        print("\nper-frame around each scroll end (index, ts_ms, area_changed_px, shift):")
        for entry in stops:
            end = entry["scroll_end_frame"]
            if end is None:
                continue
            print(f"  --- tab {entry['tab']}")
            for i in range(max(end - 6, 1), min(end + 4, count)):
                mark = "  <- scroll_end" if i == end else ""
                print(f"  {i:4d} {stamps[i] * 1000:8.0f} {area[i]:9d} {data['shifts'][i]:4d}{mark}")
        print("\nstop frame vs --tol and --settle (rows: tol, cols: settle):")
        header = "        " + "".join(f"s{s:<7d}" for s in (1, 2, 4, 8, 16, 24))
        for tab, group in enumerate(groups[:args.tabs]):
            print(f"  tab {tab} (onset {group[0]}):")
            print(header)
            for tol in (0, 4, 100, 600, 2000):
                cells = "".join(f"{stable_stop(area, group[0], s, tol)[0]:<8d}"
                                for s in (1, 2, 4, 8, 16, 24))
                print(f"  tol{tol:<5d}{cells}")
        print("\nper-frame around each stop (index, ts_ms, area_changed_px, area_maxdiff, "
              "outside_changed_px, shift):")
        for tab, group in enumerate(groups[:args.tabs]):
            print(f"  --- tab {tab}")
            for i in range(max(group[0] - 22, 1), min(group[0] + 3, count)):
                print(f"  {i:4d} {stamps[i] * 1000:8.0f} {area[i]:9d} {area_max[i]:4d} "
                      f"{outside[i]:9d} {shifts[i]:4d}")

    text = json.dumps(sidecar, indent=2) + "\n"
    out = Path(args.out) if args.out else clip.with_suffix(".stops.json")
    if args.write:
        # A sidecar carries hand edits that nothing re-derives (see the module docstring), and it
        # lives beside the clip under testdata/, which is test material rather than scratch. So an
        # overwrite that would change the file has to be asked for. An overwrite that would change
        # nothing loses nothing, and stays silent.
        changes = differing_fields(out, sidecar) if out.exists() else []
        if changes and not args.force:
            shown = ", ".join(changes[:10])
            more = f" (+{len(changes) - 10} more)" if len(changes) > 10 else ""
            print(f"{out} already exists and would change: {shown}{more}. Refusing to overwrite it: "
                  f"scroll_end_frame and any other hand edit cannot be re-derived. Re-run with "
                  f"--force to replace it, or with --out to write somewhere else.", file=sys.stderr)
            return 1
        out.write_text(text, encoding="utf-8")
        print(f"wrote {out}")
    else:
        print(text)

    # The sidecar is still produced -- the warnings are recorded in it and in the report, which is
    # what the human reads -- but the run does not pass. Step 1 of "Verify before trusting it" in
    # docs/live-capture-harness.md is that `warnings` must be empty or every entry must be one you
    # understand, and a warning is the only signal a detection failed outright; a check the procedure
    # calls mandatory has to be in the exit code, or a chained `--write && scenario_run.py …` runs on
    # a sidecar the documentation says must not be trusted.
    #
    # The list is counted, not classified: a warning added to this tool later gates the exit code
    # without anyone remembering to enumerate it here.
    if warnings and not args.allow_warnings:
        print(f"{len(warnings)} warning(s) above. The annotation is not trustworthy until each one "
              f"is understood (docs/live-capture-harness.md, 'Verify before trusting it', step 1). "
              f"Re-run with --allow-warnings once you have.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
