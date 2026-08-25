#!/usr/bin/env bash
# One end-to-end fidelity run: start the mimic player, capture it through the real Windows capture
# path, then assert the capture is a faithful sampling of the source recording.
#
#   bash tool/live_capture_test/fidelity_run.sh <tag> [source.mkv]
#
# This is the regression check for the PLAYER itself (bit-identical presentation, no reordering);
# re-run it after any change to native/tool/mimic_player/. It says nothing about recognition --
# that is scenario_run.py.
#
# Run artefacts go outside the repository, to .notes/analysis/mimic-player/: result_<tag>.json,
# out_<tag>.mkv (the capture, ~80 MB) and the two logs.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUNS="$ROOT/.notes/analysis/mimic-player"
TAG="${1:-run}"
SOURCE="${2:-$ROOT/.notes/captures/testrun2_2m19-2m33.mkv}"
OUT="$RUNS/out_$TAG.mkv"

mkdir -p "$RUNS"
rm -f "$OUT"

# Both binaries are launched through a .cmd via `cmd /c`: MSYS2 would otherwise mangle the absolute
# Windows paths, and the CLI resolves its config files relative to the build directory the wrappers
# cd into.
MIMIC_LOG="$RUNS/mimic_$TAG.log"
MSYS2_ARG_CONV_EXCL='*' cmd /c "$(cygpath -w "$HERE/run_mimic.cmd")" \
    --record "$(cygpath -w "$SOURCE")" --x 60 --y 40 --duration 24 \
    > "$MIMIC_LOG" 2>&1 &
MIMIC_SHELL=$!

# Wait for the player's own readiness line instead of a fixed sleep: it prints
# `mimic: hwnd=... client=WxH ...` only once the window exists at the recording's size and the first
# frame is on screen, and it opens the clip and builds the whole seek index BEFORE showing the
# window, so how long that takes is a property of the clip, not a constant. Starting the capture
# early finds no UnityWndClass/umamusume window and the run dies much later, inside compare_frames.py
# on an empty capture.
#
# The timeout is a failure path, not the expected wait: the readiness line lands in a second or two
# for the default 14 s clip, and 120 s is set far above that so a long clip's index build is never
# mistaken for a hang.
READY_TIMEOUT_TICKS=600   # 600 * 0.2 s = 120 s
ticks=0
until grep -q '^mimic: hwnd=' "$MIMIC_LOG" 2>/dev/null; do
    if ! kill -0 "$MIMIC_SHELL" 2>/dev/null; then
        echo "mimic player exited before reporting readiness; see $MIMIC_LOG" >&2
        tail -5 "$MIMIC_LOG" >&2
        exit 1
    fi
    if [ "$ticks" -ge "$READY_TIMEOUT_TICKS" ]; then
        # Deliberately not killed here: the player runs under a `cmd /c` wrapper, so killing this
        # job would reap the wrapper without reliably reaching the .exe, and claiming otherwise
        # would be worse than saying so. Close its window by hand.
        echo "mimic player did not report readiness within $((READY_TIMEOUT_TICKS / 5))s;" \
             "see $MIMIC_LOG (it may still be running)" >&2
        tail -5 "$MIMIC_LOG" >&2
        exit 1
    fi
    sleep 0.2
    ticks=$((ticks + 1))
done

MSYS2_ARG_CONV_EXCL='*' cmd /c "$(cygpath -w "$HERE/run_capture.cmd")" \
    --record "$(cygpath -w "$OUT")" --duration 9 \
    > "$RUNS/capture_$TAG.log" 2>&1
wait $MIMIC_SHELL

echo "--- mimic tail ---"
tail -2 "$MIMIC_LOG"
echo "--- compare ---"
uv run "$HERE/compare_frames.py" --source "$SOURCE" --captured "$OUT" --json "$RUNS/result_$TAG.json"
