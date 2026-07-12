---
name: release
description: >-
  Cut a new umacapture release end to end: bump the app version in pubspec.yaml,
  regenerate the version/license assets via build_runner, land the bump on the
  protected develop branch via a release/v<version> PR, tag the merge commit,
  then build and publish the Windows exe + zip to a GitHub release with
  flutter_distributor. Covers the two phases (version bump + codegen + PR merge,
  then tag + flutter_distributor deploy), the FVM/Inno Setup/GITHUB_TOKEN
  prerequisites, and the known-broken global flutter_distributor activation
  under Dart 3.12. Use when the user wants to release, ship, publish, or bump
  the app version and push a new build to GitHub releases.
---

# Release umacapture (version bump → codegen → flutter_distributor publish)

A release has two phases:

1. **Version bump + codegen + merge to develop** — edit `pubspec.yaml` `version:`,
   run `build_runner` (which regenerates `assets/version_info.json`, and
   `assets/license_info.json` when dependencies changed), then land the release
   commit on `develop` **via a pull request** (see below) to lock it in before any
   build/publish work.
2. **Tag + deploy** — tag the merged `develop` commit, then `flutter_distributor`
   builds the Windows installer (Inno Setup `exe`) and a `zip`, and publishes both
   as assets on a GitHub release of `umasagashi/umacapture`.

> **`develop` is a protected branch** (GitHub branch protection requires the two
> CI status checks — `Flutter unit/widget tests` and `Native C++ tests (doctest)`
> — to pass). A direct `git push origin develop` is **rejected by the remote**
> regardless of local permission, so the version bump must go through a PR that is
> merged once CI is green. Use a **merge commit** (`gh pr merge --merge`), not
> squash, so the tagged commit is the exact commit that was reviewed.

This skill runs the whole pipeline through the GitHub publish. Stop and ask the
user if any preflight check fails.

## Key paths

- `pubspec.yaml` — `version:` field (semver, no leading `v`), single source of truth.
- `lib/distribution_info.dart` — the custom build_runner `Builder`
  (`distributionInfoBuilder`). Despite the filename it does **not** emit a Dart
  file; it reads `pubspec.yaml` and writes the asset JSONs below.
- `build.yaml` — wires the `distribution_info` builder (`build_to: source`,
  `auto_apply: root_package`, `generate_for: pubspec.yaml`).
- `assets/version_info.json` — generated `{ "version": "<pubspec version>" }`. Committed.
- `assets/license_info.json` — generated dependency-license digest. Committed.
  The builder **rejects** GPL / EUPL / MPL strings (`flutter`, `dbus`, etc. are
  pre-excluded) and also copies `assets/license/*.txt` from `native/vendor`,
  opencv, onnxruntime, clip.
- `distribute_options.yaml` — flutter_distributor config: release `windows` with
  two jobs, `exe` and `zip`, both published to GitHub (`umasagashi/umacapture`)
  with `release-prerelease: "true"`, so the GitHub release is created as a
  **pre-release** (the arg must be the quoted string `"true"` — the publisher
  compares it to `'true'`).
- `windows/packaging/exe/` — `make_config.yaml` + `inno_template.iss` for the
  Inno Setup installer.
- Artifacts land in `dist/` (gitignored): `umacapture-v<version>-windows.exe` / `.zip`.

> The `msix` dependency in `pubspec.yaml` is vestigial (referenced only in a code
> comment). Distribution is exe + zip, not msix. Do not add an msix step.

## Preflight (run these checks first)

All commands use the FVM-pinned toolchain. The global `flutter` on PATH already
resolves to the FVM default, but verify rather than assume.

1. **Flutter SDK is the pinned version** (`.fvmrc`, currently 3.44.4) —
   `flutter_distributor` shells out to `flutter build windows`, so the PATH
   `flutter` must be the pinned one:
   ```bash
   cat .fvmrc           # the pinned version
   flutter --version    # must match it (currently Flutter 3.44.4 / Dart 3.12)
   ```
   If it does not match, prepend `.fvm/flutter_sdk/bin` to PATH for the session.

2. **Inno Setup `iscc` is available** (needed by the `exe` job):
   ```bash
   where iscc || ls "/c/Program Files (x86)/Inno Setup 6/ISCC.exe"
   ```

3. **`GITHUB_TOKEN` is set** (the GitHub publisher reads it). Confirm presence
   without printing the value:
   ```bash
   [ -n "$GITHUB_TOKEN" ] && echo "token present" || echo "MISSING"
   gh auth status        # should show logged in to umasagashi
   ```
   Never echo the token.

4. **`flutter_distributor` runs under Dart 3.12** — the globally activated
   snapshot is frequently stale and fails with
   `Can't load Kernel binary: Invalid kernel binary format version` /
   `doesn't support Dart 3.12.0`. Probe it, and only reactivate if broken:
   ```bash
   .fvm/flutter_sdk/bin/dart pub global run flutter_distributor:main --version
   # if it errors with the kernel/version message:
   .fvm/flutter_sdk/bin/dart pub global activate flutter_distributor
   ```
   Reactivation recompiles the snapshot with the FVM Dart (and pulls the latest
   flutter_distributor, e.g. 0.6.6). Do not reactivate on every run — only when
   the probe fails. The published executable is `flutter_distributor:main`.

5. **`sentry-cli` and a Sentry auth token are available** (needed by the symbol
   upload in Phase 2, step 8.5). The upload lets Sentry symbolicate native
   Windows crashes; skipping it only means that release's native crashes stay as
   raw addresses, so it is not release-blocking, but do it whenever possible.
   ```bash
   sentry-cli --version || npm install -g @sentry/cli
   [ -n "$(tr -d ' \t\r\n' < ~/.sentry_token)" ] && echo "sentry token present" || echo "MISSING"
   ```
   The read token at `~/.sentry_token` already carries `project:write`, so the
   same file the `sentry-issues` skill reads is sufficient — no separate token is
   needed. Org/project defaults come from the committed `.sentryclirc`
   (`umasagashi` / `umacapture-release`); the token is passed via the
   `SENTRY_AUTH_TOKEN` env var, never on the command line.

## Phase 1 — version bump + codegen + merge to develop

1. Pick the new version with the user (semver, e.g. `0.0.11`; no leading `v`).
   The builder validates it with `Version.parse`, so it must be valid semver.
2. Edit `pubspec.yaml` line `version: <old>` → `version: <new>`.
3. Regenerate the assets. **Delete the generated outputs first** — build_runner
   treats a pubspec `version:`-only change as a no-op and *skips* the
   `distribution_info` builder, leaving `version_info.json` stale at the old
   version. Removing the outputs forces a real rebuild. The `--force-jit` flag is
   mandatory (a transitive native build hook is incompatible with build_runner's
   default AOT):
   ```bash
   rm -f assets/version_info.json assets/license_info.json
   .fvm/flutter_sdk/bin/dart run build_runner build --force-jit
   ```
   - If it throws `Rejected key found: <license>`, a dependency introduced a
     GPL/EUPL/MPL license. Stop and resolve the dependency before continuing.
4. Review the diff and **confirm `assets/version_info.json` now shows the new
   version** (this is the step most likely to silently go wrong):
   ```bash
   cat assets/version_info.json    # must read the new <version>
   ```
   Expect `pubspec.yaml` and `assets/version_info.json` to change;
   `assets/license_info.json` and `assets/license/*.txt` change only when
   dependencies changed since the last release.

Land the release commit on `develop` **at the end of Phase 1**, before any
build/publish work. Because `develop` is protected (see the note at the top), this
goes through a short-lived `release/v<version>` PR — a direct push is rejected by
the remote.

5. Commit on a `release/v<version>` branch (title matches the project's history,
   "Bump app version"). Stage `pubspec.yaml`, `assets/version_info.json`, and any
   regenerated `assets/license_info.json` / `assets/license/*.txt`:
   ```bash
   git switch -c release/v<version>
   git add pubspec.yaml assets/version_info.json   # add license_info.json / license/*.txt if changed
   git commit -F - <<'EOF'
   Bump app version

   Co-Authored-By: Claude <noreply@anthropic.com>
   EOF
   ```
   (Replace the `Co-Authored-By` line with the standard trailer for whichever
   Claude model is running the release.)
6. Push the branch and open a PR against `develop`:
   ```bash
   git push origin release/v<version>
   gh pr create --base develop --head release/v<version> \
     --title "chore: bump app version to <version>" --body-file - <<'EOF'
   ## Summary

   Bump the app version to `<version>` for the `v<version>` release.

   ## Testing

   Ran `dart run build_runner build --force-jit`; `assets/version_info.json`
   reads `<version>`.

   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   EOF
   ```
7. Wait for the two required checks to go green, then merge with a **merge
   commit** (not squash — the tagged commit must be the reviewed one). Deleting
   the branch keeps the ref namespace clean:
   ```bash
   gh pr checks <pr-number> --watch --interval 30
   gh pr merge <pr-number> --merge --delete-branch
   ```
   Then sync local `develop` to the merge commit so the tag in Phase 2 points at
   the right place:
   ```bash
   git switch develop && git pull --ff-only origin develop
   ```

## Phase 2 — tag + publish

The Phase 1 merge commit is now on `develop`. Tag it and publish; the GitHub
release the publisher creates attaches to the pushed `v<version>` tag.

8. Create the annotated tag and push it:
   ```bash
   git tag -a "v<version>" -m "v<version>"
   git push origin "v<version>"
   ```
9. Build and publish (packages both jobs and uploads to the GitHub release):
   ```bash
   .fvm/flutter_sdk/bin/dart pub global run flutter_distributor:main \
     release --name windows
   ```
   This builds `dist/umacapture-v<version>-windows.exe` and `.zip`, then creates
   (or reuses) the `v<version>` GitHub **pre-release** and uploads both as assets.

   flutter_distributor runs `flutter build windows --release` internally, so the
   fresh, matching PDBs are now sitting in `build/windows/x64/runner/Release/`.
   Do step 9.5 **before** anything cleans `build/` — the debug-ids must match the
   exe that was just packaged, and they cannot be regenerated later.

9.5. Upload debug symbols so Sentry can symbolicate this build's native crashes.
   Two files matter: `umacapture.pdb` (covers the runner **and** the native C++
   backend, which is linked straight into the exe) and the engine's
   `flutter_windows.dll.pdb` (already in the FVM SDK cache — no download). Third-
   party DLLs (`opencv_world4130.dll`, `onnxruntime.dll`) ship without PDBs and
   stay unsymbolicated; that is expected.
   ```bash
   export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"
   ENGINE_PDB=".fvm/flutter_sdk/bin/cache/artifacts/engine/windows-x64-release/flutter_windows.dll.pdb"
   sentry-cli debug-files upload --include-sources \
     build/windows/x64/runner/Release/umacapture.pdb "$ENGINE_PDB"
   ```
   Expect `UPLOADED` lines for both debug-ids (source warnings about oversized
   Windows SDK headers are harmless). Verify the exe carries a matching debug-id
   with `sentry-cli debug-files check build/windows/x64/runner/Release/umacapture.exe`
   — if the Debug ID is absent, the `/DEBUG` link flags in
   `windows/runner/CMakeLists.txt` regressed and symbols will never match.
10. Attach `version_info.json` as a release asset. flutter_distributor only
   uploads the packaged exe/zip, so add this lightweight file separately (it lets
   a client read the published version without downloading a build). `--clobber`
   makes the step idempotent across re-runs:
   ```bash
   gh release upload "v<version>" assets/version_info.json --clobber
   ```
11. Verify the release — all three assets present and `isPrerelease` true:
    ```bash
    gh release view "v<version>" --json tagName,isPrerelease,isDraft,assets \
      --jq '{tag:.tagName,prerelease:.isPrerelease,draft:.isDraft,assets:[.assets[].name]}'
    ```

## Notes / gotchas

- **flutter_distributor uses the PATH `flutter`**, not FVM directly. The
  FVM-pinned SDK (`.fvmrc`) must be first on PATH or the build uses the wrong SDK.
- **Ordering matters.** The bump commit is merged to `develop` via PR in Phase 1
  and the `v<version>` tag is pushed in Phase 2, both before `flutter_distributor`
  publishes; otherwise the GitHub release the publisher creates can point at the
  wrong commit. Tag the merge commit on `develop`, not the pre-merge branch tip.
- **`develop` is a protected branch.** Direct `git push origin develop` is rejected
  by the remote (required checks: `Flutter unit/widget tests`,
  `Native C++ tests (doctest)`), so the bump lands via a `release/v<version>` PR
  merged with a merge commit once CI is green — no local permission overrides this.
- **Releases publish as pre-releases** by default (`release-prerelease: "true"`
  in `distribute_options.yaml`). To cut a full (non-pre-release) release instead,
  drop that arg for the run, or promote afterwards with
  `gh release edit "v<version>" --latest --prerelease=false`. Historically
  pre-releases also used a date-suffixed tag, e.g. `v0.0.10-20260507`.
- `dist/` is gitignored; build artifacts are never committed.
- Generated assets are pinned to `eol=lf` in `.gitattributes`, so codegen
  produces no EOL-only churn — do not renormalize.
- **`flutter_distributor` shells out to `flutter build windows`.** If that fails at
  INSTALL with `file cannot create directory: C:/Program Files/umacapture` (a stale
  CMakeCache from an interrupted first configure — e.g. a GitHub timeout while
  fetching sentry-native), it is not a permission problem: `rm -rf build/windows` and
  rebuild uninterrupted. See the **project-setup** skill's Notes/gotchas for the full
  mechanism.
