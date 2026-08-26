# /// script
# requires-python = ">=3.11"
# ///
"""What a stops-sidecar frame number is, shared by the sidecar's WRITER and its READER.

`annotate_stops.py` writes sidecars and `app_drive_run.py` arms the frames they contain, so the two
have to agree on which values mean something. They cannot import each other: their PEP 723
dependency sets are disjoint (numpy vs websockets) and `app_drive_run` reads Windows-only
environment variables at import time. So the predicate lives here, in a module with no dependencies
at all, and both import it -- a writer that can emit a value its reader refuses is exactly the
defect this exists to prevent.

Nothing here touches the filesystem, a clip, the player or the app; `test_stops_validation.py`
covers it directly.
"""

from __future__ import annotations


def frame_index_fault(value: object, frame_count: int) -> str | None:
    """Why `value` cannot be a frame index of a clip with `frame_count` frames, or None if it can.

    A frame index the player can be armed on is an int in [0, frame_count). This is stated as a
    predicate over that class rather than as a list of known-bad values, so a new way of being
    wrong is refused without anyone remembering to extend an enumeration.
    """
    if isinstance(value, bool) or not isinstance(value, int):
        return f"is {value!r}, which is not a frame index (an int is required)"
    if not 0 <= value < frame_count:
        return f"is {value}, outside the clip's frame indices 0..{frame_count - 1}"
    return None


def parse_frame_indices(spec: str) -> list[object]:
    """Split a comma-separated `--stop-frames` spec into one candidate frame index per entry.

    A token that is not an integer is kept as the string the operator typed, so
    `frame_index_fault` can name it in the same sentence as every other unusable value. Calling
    `int()` on it here would raise a bare ValueError instead, which is the failure mode -- an
    unnamed traceback in place of a refusal -- that having one predicate is meant to remove.
    """
    values: list[object] = []
    for token in spec.split(","):
        token = token.strip()
        try:
            values.append(int(token))
        except ValueError:
            values.append(token)
    return values
