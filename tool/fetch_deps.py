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

This script downloads each artifact from its official URL, verifies it against a
pinned SHA-256, and extracts it into the exact layout CMake expects -- the same
tree a contributor used to place manually. Nothing is pruned, so the result is
byte-identical to a plain official extraction; the pinned hashes below double as
the authoritative record of *which* build is vendored.

The third dependency, ``windows/clip``, is committed to the repository (pure MIT
source, no binaries) and is therefore not fetched here.

Run it via ``uv run`` (this repo invokes Python through ``uv``, never bare
``python``); it uses only the standard library::

    uv run tool/fetch_deps.py                 # both deps (skips ones already present)
    uv run tool/fetch_deps.py --only opencv   # just OpenCV (what CI provisions)
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


def log(message: str) -> None:
    """Print a progress line."""
    print(f"[fetch_deps] {message}", flush=True)


def download(url: str, dest: Path) -> None:
    """Stream ``url`` to ``dest``."""
    log(f"downloading {url}")
    with urllib.request.urlopen(url) as response, dest.open("wb") as out:
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


def fetch_opencv(force: bool) -> None:
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
    log(f"provisioned {target.relative_to(REPO_ROOT)}")


def fetch_onnxruntime(force: bool) -> None:
    """Provision windows/onnxruntime (release zip + experimental headers)."""
    target = WINDOWS_DIR / "onnxruntime"
    if not _prepare_target(target, force):
        return
    with tempfile.TemporaryDirectory() as tmp:
        zip_path = Path(tmp) / "onnxruntime.zip"
        download_verified(ONNX_URL, zip_path, ONNX_SHA256)
        extract_onnxruntime(zip_path, target)
    place_onnx_headers(target / "include")
    log(f"provisioned {target.relative_to(REPO_ROOT)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--only",
        choices=["opencv", "onnxruntime", "all"],
        default="all",
        help="provision a single dependency instead of all (default: all)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="re-fetch even if the target directory already exists",
    )
    args = parser.parse_args()

    if args.only in ("opencv", "all"):
        fetch_opencv(args.force)
    if args.only in ("onnxruntime", "all"):
        fetch_onnxruntime(args.force)


if __name__ == "__main__":
    main()
