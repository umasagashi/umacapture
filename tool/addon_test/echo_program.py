# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Dummy external program for testing the addon's ExternalProgramAction runner.

The runner (lib/src/addon/execution/external_program_runner.dart) launches a
program with substituted argv, captures stdout/stderr decoded as the system
encoding (CP932 on JP Windows), and maps the exit code to success (0) / failure
(non-zero). This script makes all of that observable and lets you force the
abnormal paths. It is used both by the integration test
(integration_test/addon_external_program_test.dart) and for manual testing (see
sandbox/addon_test/README.md), so it lives under the tracked tool/ tree.

Run standalone:
    uv run tool/addon_test/echo_program.py --id 123 --name foo

Special flags (put them in the task's argumentTemplate):
    --exit N        exit with code N (non-zero -> failure path)
    --sleep N       sleep N seconds before exiting (exceed timeoutSeconds to
                    trigger the runner's timeout / kill)
    --stderr MSG    also write MSG to stderr (stderr capture check)
    --bulk N        write N characters to stdout (8192-char truncation check)
    --logfile PATH  append the invocation block to PATH instead of the default
                    echo_log.txt next to this script (used by the test to point
                    at a private temp file)

Every invocation echoes the full argv, the working directory, and a timestamp
to stdout, and appends the same block to the log file, so the result can be
verified both in the app's history dialog and from outside.
"""

import datetime
import os
import sys

DEFAULT_LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "echo_log.txt")


def _force_cp932_stdout() -> None:
    """Match the runner's system-encoding decode on Windows so Japanese token
    values round-trip instead of getting mangled."""
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="cp932", errors="replace")
            sys.stderr.reconfigure(encoding="cp932", errors="replace")
        except (AttributeError, ValueError):
            pass


def _parse_flags(argv: list[str]) -> dict:
    """Pull the known control flags out of argv. Returns the parsed options;
    the remaining (echoed) arguments stay visible in the full argv dump."""
    opts = {"exit": 0, "sleep": 0.0, "stderr": None, "bulk": 0, "logfile": DEFAULT_LOG_PATH}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--exit" and i + 1 < len(argv):
            opts["exit"] = int(argv[i + 1])
            i += 2
        elif arg == "--sleep" and i + 1 < len(argv):
            opts["sleep"] = float(argv[i + 1])
            i += 2
        elif arg == "--stderr" and i + 1 < len(argv):
            opts["stderr"] = argv[i + 1]
            i += 2
        elif arg == "--bulk" and i + 1 < len(argv):
            opts["bulk"] = int(argv[i + 1])
            i += 2
        elif arg == "--logfile" and i + 1 < len(argv):
            opts["logfile"] = argv[i + 1]
            i += 2
        else:
            i += 1
    return opts


def main() -> int:
    _force_cp932_stdout()
    argv = sys.argv[1:]
    opts = _parse_flags(argv)

    now = datetime.datetime.now().isoformat(timespec="seconds")
    lines = [
        "=" * 60,
        f"[echo_program] invoked at {now}",
        f"  cwd : {os.getcwd()}",
        f"  argc: {len(argv)}",
    ]
    for idx, arg in enumerate(argv):
        lines.append(f"  arg[{idx}]: {arg!r}")
    block = "\n".join(lines)

    print(block, flush=True)
    try:
        with open(opts["logfile"], "a", encoding="utf-8") as fp:
            fp.write(block + "\n")
    except OSError as exc:
        print(f"[echo_program] failed to write log: {exc}", file=sys.stderr, flush=True)

    if opts["stderr"] is not None:
        print(f"[echo_program] stderr: {opts['stderr']}", file=sys.stderr, flush=True)

    if opts["bulk"] > 0:
        # Emit a marker-delimited blob so the 8192-char capture limit is easy to
        # spot in the history dialog (the tail marker should be missing).
        print("BULK_START", flush=True)
        print("x" * opts["bulk"], flush=True)
        print("BULK_END", flush=True)

    if opts["sleep"] > 0:
        print(f"[echo_program] sleeping {opts['sleep']}s ...", flush=True)
        import time

        time.sleep(opts["sleep"])
        print("[echo_program] woke up", flush=True)

    return opts["exit"]


if __name__ == "__main__":
    sys.exit(main())
