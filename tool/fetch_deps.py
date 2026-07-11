# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Provision the Windows native build dependencies into ``windows/``.

The C++ backend (``native/CMakeLists.txt`` and ``windows/runner``) links against
two large prebuilt third-party packages that are gitignored and were historically
copied in by hand:

* **OpenCV 4.13.0** -> ``windows/opencv`` (the official ``opencv_world4130`` prebuilt,
  distributed as a 7-Zip self-extracting ``.exe``).
* **ONNX Runtime 1.27.0** -> ``windows/onnxruntime`` (the official ``win-x64`` zip,
  plus two ``experimental_onnxruntime_cxx_*`` headers that live only in the source
  tree, not the release zip).
* **FFmpeg n7.1.5 (BtbN LGPL, shared)** -> ``windows/ffmpeg`` (headers + import libs +
  versioned DLLs). Only the CLI target links it, for the lossless FFV1 ``.mkv`` capture
  recorder and its replay reader (``native/src/cv/ffv1_recorder.*`` / ``ffv1_reader.*``).
  A dated BtbN autobuild tag is used so the pinned asset (git-hash in its name) is
  immutable; ``lgpl`` (not ``gpl``) suffices because FFV1 and the matroska muxer are
  native LGPL components.

This script downloads each artifact from its official URL, verifies it against a
pinned SHA-256, and extracts it into the exact layout CMake expects -- the same
tree a contributor used to place manually. By default nothing is pruned, so the
result is byte-identical to a plain official extraction; the SHA-256 is checked
on the downloaded archive (before extraction), so it stays the authoritative
record of *which* build is vendored regardless of any later pruning.

``--slim`` additionally drops the parts of each prebuilt this project never links or
ships -- everything it removes is third-party debug symbols or bindings/tools/sources
we never touch, so the linked/shipped tree is unchanged. For OpenCV (~915 MB -> ~230 MB):
the source tree, the Java and Python bindings, OpenCV's own debug symbols (``.pdb`` --
never symbolicated here, Sentry covers only ``umacapture.pdb``), the bundled sample
``.exe`` tools, the cascade/license ``etc/`` tree, and the duplicate top-level FFmpeg
plugin (the copy CMake loads lives under ``x64/vc16/bin``). For ONNX Runtime
(~402 MB -> ~16 MB): its own ``.pdb`` debug symbols. CI passes ``--slim`` to keep its
cache lean (today it provisions only OpenCV); local devs omit it so a full official
tree is available for release builds. See ``OPENCV_SLIM_PRUNE_*`` / ``ONNX_SLIM_PRUNE_*``
below for the exact sets.

The third dependency, ``windows/clip``, is committed to the repository (pure MIT
source, no binaries) and is therefore not fetched here.

Run it via ``uv run`` (this repo invokes Python through ``uv``, never bare
``python``); it uses only the standard library::

    uv run tool/fetch_deps.py                 # all deps (skips ones already present)
    uv run tool/fetch_deps.py --only opencv   # just OpenCV (what CI provisions)
    uv run tool/fetch_deps.py --only opencv --slim  # + prune unused OpenCV parts (CI)
    uv run tool/fetch_deps.py --only ffmpeg --slim  # just FFmpeg, pruned (CLI FFV1 tests)
    uv run tool/fetch_deps.py --force         # re-fetch even if already present

To bump a dependency version, change its ``*_URL`` and ``*_SHA256`` constants (and
the ``ONNX_HEADERS`` entries) below and re-run; download a copy once and
``sha256sum`` it to get the new pin.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WINDOWS_DIR = REPO_ROOT / "windows"

OPENCV_URL = "https://github.com/opencv/opencv/releases/download/4.13.0/opencv-4.13.0-windows.exe"
OPENCV_SHA256 = "f0e98c302464d6860777a7015065e11b9b271b5394e6ba92663f0cf1fc303f2c"

ONNX_URL = "https://github.com/microsoft/onnxruntime/releases/download/v1.27.0/onnxruntime-win-x64-1.27.0.zip"
ONNX_SHA256 = "c5c81710938e68079ff1a192b04897faabe4b43830d48f39f27ecd4e16138bfc"

# BtbN FFmpeg-Builds n7.1.5, win64, LGPL, shared. Pinned to a dated autobuild tag so the
# asset (its name carries the git hash g7d0e842004) is immutable -- the SHA-256 below would
# otherwise drift if it pointed at the mutable ``latest`` tag. The archive's single root
# folder holds ``bin/ include/ lib/``. To bump: pick a newer autobuild tag's
# ``ffmpeg-nX.Y.Z-...-win64-lgpl-shared-X.Y.zip`` asset, download it once, sha256sum it,
# and update both constants (and the CMake DLL-version names if the major version changes).
FFMPEG_URL = (
    "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-07-10-13-44"
    "/ffmpeg-n7.1.5-1-g7d0e842004-win64-lgpl-shared-7.1.zip"
)
FFMPEG_SHA256 = "d31de3f3c69b3f70fbe8babacea0cff8de2b51e259fc0bd0b37b3a5c0d114077"

# The C++ recognizer uses ONNX Runtime's experimental C++ session wrapper, which
# ships only in the source tree (tagged v1.27.0), not in the win-x64 release zip.
# Pinned to the raw blobs at that tag; each is hash-verified like the archives.
ONNX_HEADERS = {
    "experimental_onnxruntime_cxx_api.h": (
        "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.0"
        "/include/onnxruntime/core/session/experimental_onnxruntime_cxx_api.h",
        "0e60a8a69e56982a51e548dab41d6d10c0a1cd98762648dee0d1ea90ce0a0041",
    ),
    "experimental_onnxruntime_cxx_inline.h": (
        "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.0"
        "/include/onnxruntime/core/session/experimental_onnxruntime_cxx_inline.h",
        "7f5cf1653e7379f7107ce0148d28499240ac89cf728aa6ac47ffd33a1a888600",
    ),
}


# Parts of the OpenCV prebuilt this project never links or ships, removed by
# ``--slim`` (see the module docstring). Paths are relative to ``windows/opencv``.
# A missing entry is skipped, so a layout shift in a future OpenCV bump degrades to
# "kept" rather than erroring -- ``--slim`` only ever shrinks, never breaks, a build.
OPENCV_SLIM_PRUNE_DIRS = (
    "sources",  # full source tree (the only part the old CI dropped)
    "build/java",  # JNI bindings
    "build/python",  # Python bindings
    "build/etc",  # haarcascades / lbpcascades / third-party licenses
    "build/bin",  # duplicate FFmpeg plugin; the loaded copy lives under x64/*/bin
)

# Glob patterns (relative to ``windows/opencv``) for individual files to drop. The
# ``x64/*/`` wildcard spans the runtime folder (e.g. ``vc16``) so no version is baked in.
OPENCV_SLIM_PRUNE_GLOBS = (
    "build/x64/*/bin/*.pdb",  # OpenCV's own debug symbols (never symbolicated here)
    "build/x64/*/bin/*.exe",  # bundled sample tools (opencv_version, annotation, ...)
)

# The ONNX Runtime equivalent (paths relative to ``windows/onnxruntime``): its own debug
# symbols, never symbolicated here, and ~384 MB -- dwarfing the 15 MB DLL they pair with.
ONNX_SLIM_PRUNE_GLOBS = ("lib/*.pdb",)

# FFmpeg parts the CLI never links or ships (paths relative to ``windows/ffmpeg``). We link
# only avformat/avcodec/avutil and load their transitive DLLs (swresample, swscale); avdevice
# and avfilter are unused, as are the ffmpeg/ffplay front-end exes. ``ffprobe.exe`` is kept for
# the recorder's smoke-test assertions. A missing entry is skipped (see prune_tree), so a future
# layout shift degrades to "kept" rather than erroring.
FFMPEG_SLIM_PRUNE_DIRS = ("doc",)  # HTML manuals we never read
FFMPEG_SLIM_PRUNE_GLOBS = (
    "bin/ffmpeg.exe",
    "bin/ffplay.exe",
    "bin/avdevice-*.dll",
    "bin/avfilter-*.dll",
    "lib/avdevice.lib",
    "lib/avfilter.lib",
)


def log(message: str) -> None:
    """Print a progress line."""
    print(f"[fetch_deps] {message}", flush=True)


# Per-read socket timeout (seconds). Bounds a stalled connection so a hung
# download fails fast in CI instead of blocking the job until it times out.
DOWNLOAD_TIMEOUT = 60


def download(url: str, dest: Path) -> None:
    """Stream ``url`` to ``dest``."""
    log(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT) as response, dest.open("wb") as out:
        shutil.copyfileobj(response, out)


def verify_sha256(path: Path, expected: str) -> None:
    """Raise ``SystemExit`` if ``path`` does not hash to ``expected``."""
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        raise SystemExit(f"SHA-256 mismatch for {path.name}\n  expected {expected}\n  actual   {digest}")
    log(f"verified {path.name} (sha256 ok)")


def download_verified(url: str, dest: Path, expected: str) -> None:
    """Download ``url`` to ``dest`` and check it against ``expected``."""
    download(url, dest)
    verify_sha256(dest, expected)


def _sole_child_dir(directory: Path) -> Path:
    """Return the single subdirectory of ``directory`` (the archive's root folder)."""
    children = [child for child in directory.iterdir() if child.is_dir()]
    if len(children) != 1:
        raise SystemExit(f"expected exactly one top-level dir in {directory}, found {children}")
    return children[0]


def extract_opencv(exe: Path, target: Path) -> None:
    """Self-extract the OpenCV SFX so that ``target`` (windows/opencv) holds ``build/``.

    The archive's internal root is ``opencv/`` (containing ``build/`` and
    ``sources/``), so extracting into ``target.parent`` (windows/) yields
    ``windows/opencv/build`` -- the ``OpenCV_DIR`` CMake references. Prefer a
    ``7z``/``7za`` on PATH (what CI has); otherwise fall back to the ``.exe``'s own
    7-Zip self-extractor, which needs no external tool.
    """
    out_dir = str(target.parent)
    sevenzip = shutil.which("7z") or shutil.which("7za")
    if sevenzip:
        subprocess.run([sevenzip, "x", str(exe), f"-o{out_dir}", "-y"], check=True)
    else:
        subprocess.run([str(exe), f"-o{out_dir}", "-y"], check=True)


def _tree_size(path: Path) -> int:
    """Total size in bytes of ``path`` (a file, or a directory walked recursively)."""
    if path.is_file():
        return path.stat().st_size
    return sum(child.stat().st_size for child in path.rglob("*") if child.is_file())


def prune_tree(target: Path, dirs: tuple[str, ...], globs: tuple[str, ...]) -> None:
    """Remove ``dirs`` and ``globs``-matched files under ``target`` (see the ``*_SLIM_*`` sets)."""
    removed = 0
    for relative in dirs:
        path = target / relative
        if path.exists():
            removed += _tree_size(path)
            shutil.rmtree(path)
            log(f"pruned {relative}")
    for pattern in globs:
        for path in target.glob(pattern):
            removed += path.stat().st_size
            path.unlink()
            log(f"pruned {path.relative_to(target).as_posix()}")
    log(f"slim: removed ~{removed // (1024 * 1024)} MB")


def extract_onnxruntime(zip_path: Path, target: Path) -> None:
    """Extract the ONNX Runtime zip so ``include/`` and ``lib/`` land directly in ``target``."""
    import zipfile

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(tmp_dir)
        inner = _sole_child_dir(tmp_dir)
        target.mkdir(parents=True)
        for item in inner.iterdir():
            shutil.move(str(item), str(target / item.name))


def place_onnx_headers(include_dir: Path) -> None:
    """Download the experimental C++ headers into ``include_dir`` (verified)."""
    for name, (url, sha256) in ONNX_HEADERS.items():
        download_verified(url, include_dir / name, sha256)


def _prepare_target(target: Path, force: bool) -> bool:
    """Return ``True`` if provisioning should proceed, handling skip/force."""
    if target.exists():
        if not force:
            log(f"{target.relative_to(REPO_ROOT)} already present; skipping (use --force to re-fetch)")
            return False
        log(f"removing existing {target.relative_to(REPO_ROOT)} (--force)")
        shutil.rmtree(target)
    return True


def fetch_opencv(force: bool, slim: bool) -> None:
    """Provision windows/opencv."""
    if sys.platform != "win32":
        raise SystemExit("OpenCV is a Windows self-extracting .exe; run this on Windows to provision it.")
    target = WINDOWS_DIR / "opencv"
    if not _prepare_target(target, force):
        return
    with tempfile.TemporaryDirectory() as tmp:
        exe = Path(tmp) / "opencv.exe"
        download_verified(OPENCV_URL, exe, OPENCV_SHA256)
        extract_opencv(exe, target)
    if slim:
        prune_tree(target, OPENCV_SLIM_PRUNE_DIRS, OPENCV_SLIM_PRUNE_GLOBS)
    log(f"provisioned {target.relative_to(REPO_ROOT)}")


def fetch_onnxruntime(force: bool, slim: bool) -> None:
    """Provision windows/onnxruntime (release zip + experimental headers)."""
    target = WINDOWS_DIR / "onnxruntime"
    if not _prepare_target(target, force):
        return
    with tempfile.TemporaryDirectory() as tmp:
        zip_path = Path(tmp) / "onnxruntime.zip"
        download_verified(ONNX_URL, zip_path, ONNX_SHA256)
        extract_onnxruntime(zip_path, target)
    place_onnx_headers(target / "include")
    if slim:
        prune_tree(target, (), ONNX_SLIM_PRUNE_GLOBS)
    log(f"provisioned {target.relative_to(REPO_ROOT)}")


def extract_ffmpeg(zip_path: Path, target: Path) -> None:
    """Extract the BtbN FFmpeg zip so ``include/``, ``lib/`` and ``bin/`` land directly in ``target``.

    The archive's single root folder (``ffmpeg-nX.Y.Z-...-shared/``) holds those three dirs, so this
    mirrors ``extract_onnxruntime``: extract to a temp dir, then move the sole root folder's children
    into ``windows/ffmpeg`` -- the exact ``FFMPEG_DIR`` layout ``native/CMakeLists.txt`` references.
    """
    import zipfile

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(tmp_dir)
        inner = _sole_child_dir(tmp_dir)
        target.mkdir(parents=True)
        for item in inner.iterdir():
            shutil.move(str(item), str(target / item.name))


def fetch_ffmpeg(force: bool, slim: bool) -> None:
    """Provision windows/ffmpeg (BtbN LGPL shared build)."""
    target = WINDOWS_DIR / "ffmpeg"
    if not _prepare_target(target, force):
        return
    with tempfile.TemporaryDirectory() as tmp:
        zip_path = Path(tmp) / "ffmpeg.zip"
        download_verified(FFMPEG_URL, zip_path, FFMPEG_SHA256)
        extract_ffmpeg(zip_path, target)
    if slim:
        prune_tree(target, FFMPEG_SLIM_PRUNE_DIRS, FFMPEG_SLIM_PRUNE_GLOBS)
    log(f"provisioned {target.relative_to(REPO_ROOT)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--only",
        choices=["opencv", "onnxruntime", "ffmpeg", "all"],
        default="all",
        help="provision a single dependency instead of all (default: all)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="re-fetch even if the target directory already exists",
    )
    parser.add_argument(
        "--slim",
        action="store_true",
        help="prune unused third-party parts (OpenCV ~915->230 MB, ONNX ~402->16 MB); used by CI",
    )
    args = parser.parse_args()

    if args.only in ("opencv", "all"):
        fetch_opencv(args.force, args.slim)
    if args.only in ("onnxruntime", "all"):
        fetch_onnxruntime(args.force, args.slim)
    if args.only in ("ffmpeg", "all"):
        fetch_ffmpeg(args.force, args.slim)


if __name__ == "__main__":
    main()
