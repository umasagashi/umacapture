# /// script
# requires-python = ">=3.11"
# ///
"""Run one web e2e scenario and leave the evidence of that run in <out-root>/<name>/
(default out-root: the web-e2e directory of the live-capture harness's run artefacts in the repository;
the README names the path).

    uv run tool/web_e2e/run_scenario.py --name <run> [--golden G [--expect-frame-resize J] [--expect-alignment J]] \
        -- <web_import_e2e.py arguments except --repo/--out>

Writes, next to web_import_e2e.py's own outputs (opfs.json, console.log, final.png, server.log, e2e_checks.json,
resources.json):
  args.json      the wrapper's argv, the exact child command lines, the worktree HEAD, sha256 of the build under test
  inputs.sha256  sha256 of the clip, the golden and modules.zip (the input videos / expectations of the run)
  stdout.txt     the whole standard output (and error) of web_import_e2e.py
  compare.txt    the whole output of compare_record.py (only when --golden is given)
  cleanup.json   after the run, for the profile, ports and PIDs the child recorded in resources.json: PIDs alive
                 or not, any process still mentioning the profile or the ports, ports closed or not, whether the
                 throwaway profile directory still exists -- each measured by this wrapper itself, not taken
                 from the child's own report
  result.json    every judgement and the overall verdict; the exit code is 0 only for overall PASS
Refuses to reuse a run directory that already holds files.
"""
import argparse
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
NO_WINDOW = subprocess.CREATE_NO_WINDOW


def sha256(path: Path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_tee(cmd, cwd, out_file: Path):
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
    p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         creationflags=NO_WINDOW)
    chunks = []
    with open(out_file, "wb") as f:
        for raw in iter(p.stdout.readline, b""):
            f.write(raw)
            f.flush()
            chunks.append(raw)
            sys.stdout.buffer.write(raw)
            sys.stdout.buffer.flush()
    p.wait()
    return p.returncode, b"".join(chunks).decode("utf-8", errors="replace")


def processes_mentioning(needles):
    """Live processes whose command line contains any needle (this probe itself excluded)."""
    # UTF-8 out (the console code page would corrupt non-ASCII command lines into invalid JSON). Only the
    # processes the harness starts are candidates: a shell whose own command text names the profile is not one.
    ps = ("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $me = $PID; "
          "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and "
          "@('chrome.exe','uv.exe','python.exe','pythonw.exe','crashpad_handler.exe') -contains $_.Name } | "
          "ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; name = $_.Name; cmd = $_.CommandLine } } | "
          "ConvertTo-Json -Compress")
    r = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps],
                       capture_output=True, creationflags=NO_WINDOW, timeout=120)
    txt = r.stdout.decode("utf-8", errors="replace").strip()
    rows = json.loads(txt) if txt else []
    if isinstance(rows, dict):
        rows = [rows]
    # The probe's own powershell has the needles in its command line only through $me exclusion above;
    # the needles are never in `ps`, so nothing else needs filtering.
    return [{"pid": x["pid"], "name": x["name"], "cmd": x["cmd"][:200]} for x in rows
            if any(n in x["cmd"] for n in needles)]


def pid_alive(pid):
    r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"], capture_output=True,
                       creationflags=NO_WINDOW)
    return f'"{pid}"' in r.stdout.decode("utf-8", errors="replace")


def port_open(port):
    s = socket.socket()
    s.settimeout(2)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    argv = sys.argv[1:]
    if "--" not in argv:
        sys.exit("usage: run_scenario.py [--repo R] --name N [--golden G ...] -- <web_import_e2e.py args>")
    split = argv.index("--")
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(REPO))
    ap.add_argument("--out-root", default=None,
                    help="directory that receives <name>/ (default: <repo>/testdata/harness/runs/web-e2e)")
    ap.add_argument("--name", required=True)
    ap.add_argument("--golden")
    ap.add_argument("--expect-frame-resize")
    ap.add_argument("--expect-alignment")
    args = ap.parse_args(argv[:split])
    e2e_args = argv[split + 1:]
    repo = Path(args.repo).resolve()
    out = (Path(args.out_root) if args.out_root else repo / "testdata" / "harness" / "runs" / "web-e2e") / args.name
    if out.exists() and any(out.iterdir()):
        sys.exit(f"{out} already holds files; use a new --name")
    out.mkdir(parents=True, exist_ok=True)
    if "--clip" not in e2e_args:
        sys.exit("the e2e arguments must include --clip")
    clip = (Path.cwd() / e2e_args[e2e_args.index("--clip") + 1]).resolve()

    before = processes_mentioning(["uma-e2e-chrome-"])
    e2e_cmd = ["uv", "run", "--quiet", str(HERE / "web_import_e2e.py"), "--repo", str(repo), "--out", str(out), *e2e_args]
    compare_cmd = None
    if args.golden:
        compare_cmd = ["uv", "run", "--quiet", str(HERE / "compare_record.py"), "--repo", str(repo), "--run", str(out),
                       "--golden", str((Path.cwd() / args.golden).resolve())]
        if args.expect_frame_resize:
            compare_cmd += ["--expect-frame-resize", args.expect_frame_resize]
        if args.expect_alignment:
            compare_cmd += ["--expect-alignment", args.expect_alignment]
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True,
                          creationflags=NO_WINDOW).stdout.strip()
    build = repo / "build" / "web"
    build_files = [build / "main.dart.js", build / "worker.js", *sorted((build / "wasm").glob("*"))]
    (out / "args.json").write_text(json.dumps({
        "wrapper_argv": sys.argv, "cwd": str(Path.cwd()), "started": time.strftime("%Y-%m-%d %H:%M:%S"),
        "e2e_cmd": e2e_cmd, "compare_cmd": compare_cmd, "worktree_head": head,
        "leftover_chrome_processes_before_run": before,
        "build_web_sha256": {str(p.relative_to(build)): sha256(p) for p in build_files if p.is_file()},
    }, ensure_ascii=False, indent=1), encoding="utf-8")
    hashes = [f"{sha256(clip)}  {clip}  (input clip)"]
    if args.golden:
        g = (Path.cwd() / args.golden).resolve()
        hashes.append(f"{sha256(g)}  {g}  (golden)")

    t0 = time.time()
    e2e_rc, _ = run_tee(e2e_cmd, str(repo), out / "stdout.txt")
    zip_path = out / "modules.zip"
    if zip_path.is_file():
        hashes.append(f"{sha256(zip_path)}  {zip_path}  (modules.zip fed to the module dialog)")
    (out / "inputs.sha256").write_text("\n".join(hashes) + "\n", encoding="utf-8")

    cmp_rc, cmp_out = None, None
    if compare_cmd:
        cmp_rc, cmp_out = run_tee(compare_cmd, str(repo), out / "compare.txt")
        cmp_out = cmp_out.replace("\r\n", "\n")

    # Cleanup, measured here against what the child recorded it started (resources.json, written as each
    # resource comes up, so it is there even when the child died part-way).
    rj = out / "resources.json"
    res = json.loads(rj.read_text(encoding="utf-8")) if rj.is_file() else {}
    profile = res.get("profile")
    http_port, cdp_port = res.get("http_port"), res.get("cdp_port")
    ports = [p for p in (http_port, cdp_port) if p is not None]
    pids = [p for p in (res.get("server_pid"), res.get("chrome_pid")) if p is not None]
    needles = ["uma-e2e-chrome-"] + ([f"--port {http_port} "] if http_port is not None else []) \
        + ([f"remote-debugging-port={cdp_port}"] if cdp_port is not None else [])
    try:
        left = processes_mentioning(needles)
    except Exception as e:  # a probe that cannot run must not read as "nothing left"
        left = [{"pid": None, "name": "probe-error", "cmd": f"{type(e).__name__}: {e}"[:200]}]
    cleanup = {
        "profile": profile,
        "profile_dir_exists": os.path.exists(profile) if profile else None,
        "profile_parent_exists": os.path.isdir(os.path.dirname(profile)) if profile else None,  # the check can only mean "gone" if the path is well-formed
        "pids_alive": {str(p): pid_alive(p) for p in pids},
        "ports": {str(p): "open" if port_open(p) else "closed" for p in ports},
        "processes_mentioning_profile_or_ports": left,
    }
    cleanup["ok"] = bool(profile) and len(ports) == 2 and len(pids) == 2 and cleanup["profile_dir_exists"] is False and cleanup["profile_parent_exists"] is True \
        and not any(cleanup["pids_alive"].values()) and all(v == "closed" for v in cleanup["ports"].values()) \
        and not left
    (out / "cleanup.json").write_text(json.dumps(cleanup, ensure_ascii=False, indent=1), encoding="utf-8")

    checks = {}
    cj = out / "e2e_checks.json"
    if cj.is_file():
        checks = json.loads(cj.read_text(encoding="utf-8"))
    overall = e2e_rc == 0 and cj.is_file() and (cmp_rc == 0 if compare_cmd else True) and cleanup["ok"]
    result = {
        "overall": "PASS" if overall else "FAIL",
        "e2e_exit": e2e_rc, "e2e_checks": checks.get("checks"), "observation": checks.get("observation"),
        "compare_exit": cmp_rc, "compare_verdict": (re.findall(r"^VERDICT .*$", cmp_out or "", re.M) or [None])[-1],
        "cleanup_ok": cleanup["ok"], "elapsed_s": round(time.time() - t0, 1),
    }
    (out / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    print("CLEANUP", json.dumps({k: v for k, v in cleanup.items() if k != "processes_mentioning_profile_or_ports"},
                                ensure_ascii=False), "leftover processes:", len(left))
    print("OVERALL", result["overall"], f"(e2e exit {e2e_rc}, compare exit {cmp_rc}, cleanup ok {cleanup['ok']})")
    return 0 if overall else 1


if __name__ == "__main__":
    sys.exit(main())
