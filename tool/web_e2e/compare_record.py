# /// script
# requires-python = ">=3.11"
# ///
"""Judge one web_import_e2e.py run: records vs the golden, prediction.json resize facts, console errors.

The record comparison is run.py's own: it imports normalize / _sort_key / _dumps from
native/test/integration/run.py (read-only), so the volatile metadata strip and the canonical order
are exactly the golden suite's, not a copy.

Exit 0 only when every check passes. A run can never pass vacuously:
  * the golden must be a non-empty list, and the run must hold at least one active record;
  * every active record must have a prediction.json beside it (same directory), and every
    prediction.json must belong to an active record;
  * every expected tab (--expect-tabs, default skill,factor,campaign) must carry frame_resize with a
    structurally complete `base` and a non-empty `tab_frames`, and factor_tab_alignment.measured must be true.
Value expectations are passed per scenario:
  --expect-frame-resize JSON   subset that every tab's `base` and every `tab_frames` entry must match
  --expect-alignment JSON      subset that factor_tab_alignment must match
--golden can point at a modified copy for a positive control.
"""
import argparse
import difflib
import importlib.util
import json
import re
import sys
from pathlib import Path

ERROR_PATTERNS = [
    r"ignoring unreadable resize facts",
    r"failed to write the record's resize facts",
    r"(?i)\babort",
    r"(?i)stitch_failed|scrape_failed|capture_size_changed",
]

RESIZE_KEYS = ("band", "captured_size", "pre_band_unit", "unit", "arm")
ACTIVE_RECORD = re.compile(r"^(.*/chara_detail/active/[^/]+)/record\.json$")
ACTIVE_PREDICTION = re.compile(r"^(.*/chara_detail/active/[^/]+)/prediction\.json$")


def load_run_py(repo: Path):
    spec = importlib.util.spec_from_file_location("golden_run", repo / "native/test/integration/run.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def subset_diff(expected, actual, path="$"):
    """Differences where `actual` does not contain `expected` (dicts by subset, everything else by equality)."""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected an object, got {json.dumps(actual, ensure_ascii=False)[:80]}"]
        out = []
        for k, v in expected.items():
            if k not in actual:
                out.append(f"{path}.{k}: missing")
            else:
                out += subset_diff(v, actual[k], f"{path}.{k}")
        return out
    return [] if expected == actual else [f"{path}: expected {expected!r}, got {actual!r}"]


def resize_entry_problems(e, name):
    """Structural completeness of one base / tab_frames entry."""
    if not isinstance(e, dict):
        return [f"{name} is not an object"]
    out = [f"{name}.{k} missing" for k in RESIZE_KEYS if k not in e]
    band, size = e.get("band"), e.get("captured_size")
    if "band" in e and not (isinstance(band, dict) and is_int(band.get("min")) and is_int(band.get("max"))):
        out.append(f"{name}.band needs integer min and max")
    if "captured_size" in e and not (isinstance(size, dict) and is_int(size.get("width")) and is_int(size.get("height"))):
        out.append(f"{name}.captured_size needs integer width and height")
    for k in ("pre_band_unit", "unit"):
        if k in e and not (isinstance(e[k], (int, float)) and not isinstance(e[k], bool)):
            out.append(f"{name}.{k} is not a number")
    if "arm" in e and not (isinstance(e["arm"], str) and e["arm"]):
        out.append(f"{name}.arm is not a non-empty string")
    return out


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--run", required=True, help="the --out directory of web_import_e2e.py")
    ap.add_argument("--golden", required=True)
    ap.add_argument("--expect-tabs", default="skill,factor,campaign",
                    help="comma-separated tabs whose frame_resize must be present")
    ap.add_argument("--expect-frame-resize", default=None,
                    help="JSON subset every tab's base and tab_frames entry must match")
    ap.add_argument("--expect-alignment", default=None, help="JSON subset factor_tab_alignment must match")
    args = ap.parse_args()
    repo, run = Path(args.repo).resolve(), Path(args.run).resolve()
    rp = load_run_py(repo)
    opfs = json.loads((run / "opfs.json").read_text(encoding="utf-8"))
    texts = opfs["texts"]
    fails = []
    tabs = [t for t in args.expect_tabs.split(",") if t]
    want_resize = json.loads(args.expect_frame_resize) if args.expect_frame_resize else None
    want_align = json.loads(args.expect_alignment) if args.expect_alignment else None

    # 1. records vs golden, the run.py way (active records only, as collect_records does).
    golden = json.loads(Path(args.golden).read_text(encoding="utf-8"))
    if not isinstance(golden, list) or not golden:
        fails.append("golden is empty or not a list")
    record_dirs = {}
    for p, t in texts.items():
        m = ACTIVE_RECORD.match(p)
        if m:
            record_dirs[m.group(1)] = rp.normalize(json.loads(t))
    recs = list(record_dirs.values())
    print(f"RECORDS {len(recs)} GOLDEN {len(golden) if isinstance(golden, list) else '?'}")
    if not recs:
        fails.append("no active record in the run")
    actual = rp._dumps(sorted(recs, key=rp._sort_key))
    expected = rp._dumps(golden)
    same = actual == expected
    print(f"RECORDS-GOLDEN-MATCH {same}")
    if not same:
        fails.append("record mismatch")
        for line in list(difflib.unified_diff(expected.splitlines(), actual.splitlines(), "golden", "web", n=1))[:40]:
            print("  ", line)

    # 2. prediction.json: one per active record, with the resize facts.
    pred_dirs = {}
    for p, t in texts.items():
        m = ACTIVE_PREDICTION.match(p)
        if m:
            pred_dirs[m.group(1)] = (p, json.loads(t))
    print(f"PREDICTIONS {len(pred_dirs)}")
    for d in sorted(set(record_dirs) - set(pred_dirs)):
        fails.append(f"record without prediction.json: {d}")
    for d in sorted(set(pred_dirs) - set(record_dirs)):
        fails.append(f"prediction.json without record: {d}")
    for d, (p, pred) in sorted(pred_dirs.items()):
        fr, fa = pred.get("frame_resize"), pred.get("factor_tab_alignment")
        print("PREDICTION", p)
        print("  frame_resize =", json.dumps(fr, ensure_ascii=False))
        print("  factor_tab_alignment =", json.dumps(fa, ensure_ascii=False))
        if not isinstance(fr, dict):
            fails.append("frame_resize missing")
        else:
            for tab in tabs:
                entry = fr.get(tab)
                if not isinstance(entry, dict):
                    fails.append(f"frame_resize.{tab} missing")
                    continue
                fails += [f"frame_resize.{x}" for x in resize_entry_problems(entry.get("base"), f"{tab}.base")]
                frames = entry.get("tab_frames")
                if not isinstance(frames, list) or not frames:
                    fails.append(f"frame_resize.{tab}.tab_frames missing or empty")
                    continue
                if want_resize is not None:
                    fails += [f"frame_resize.{tab}.base {x}" for x in subset_diff(want_resize, entry.get("base"))]
                for i, tf in enumerate(frames):
                    name = f"{tab}.tab_frames[{i}]"
                    fails += [f"frame_resize.{x}" for x in resize_entry_problems(tf, name)]
                    if isinstance(tf, dict):
                        if not (is_int(tf.get("frames")) and tf["frames"] > 0):
                            fails.append(f"frame_resize.{name}.frames is not a positive integer")
                        if want_resize is not None:
                            fails += [f"frame_resize.{name} {x}" for x in subset_diff(want_resize, tf)]
        if not isinstance(fa, dict) or fa.get("measured") is not True:
            fails.append("factor_tab_alignment missing or not measured")
        elif want_align is not None:
            fails += [f"factor_tab_alignment {x}" for x in subset_diff(want_align, fa)]

    # 3. console: every line of every target (page and workers).
    hits = []
    for line in (run / "console.log").read_text(encoding="utf-8").splitlines():
        if any(re.search(rx, line) for rx in ERROR_PATTERNS):
            hits.append(line[:300])
    print(f"CONSOLE-ERROR-HITS {len(hits)}")
    for h in hits[:20]:
        print("  ", h)
    if hits:
        fails.append("console errors")
    print("VERDICT", "PASS" if not fails else "FAIL: " + "; ".join(fails))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
