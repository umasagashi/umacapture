/// Verifies `web/` against the pins and claims in `tool/web_deps.json`, without running codegen.
///
/// `assets/web_license_info.json` tells the user that every third-party file under
/// `web/` is the unmodified upstream artifact the manifest names. `DistributionInfoBuilder`
/// is what enforces that claim -- it refuses to emit the artifact otherwise -- but a commit
/// or a `flutter build web` that never re-runs codegen would ship the old claim over new
/// bytes. This is the cheap check that closes that gap: it runs the same verification code
/// (`lib/web_deps_verify.dart`) directly, for a fraction of a `build_runner` run.
///
///     dart run tool/check_web_pins.dart                      # pins + closed-world scan
///     dart run tool/check_web_pins.dart --licenses           # + the license-side checks
///     dart run tool/check_web_pins.dart --require-verified   # + the artifact must say 'verified'
///     dart run tool/check_web_pins.dart --ci-artifact        # + assert the CI-shaped artifact
///     dart run tool/check_web_pins.dart --source-digest      # print the in-tree source digests
///     dart run tool/check_web_pins.dart --warn-stale-source-digest   # report, don't fail, on stale
///
/// * `--licenses` adds everything the *disclosure* depends on (null `license.asset`,
///   `relocation_required`, uncommitted license text, MPL without a source form, an upstream
///   file claimed under this repository's own license). Without it the check covers the bytes
///   only, which would make the pre-commit hook weaker than the artifact it defends.
/// * `--require-verified` asserts the committed artifact exists, says `verified` (i.e. it was
///   generated in a *fully* provisioned tree) and lists exactly what is missing from `web/`
///   right now. This is what `tool/build_web.sh` gates the web build on; between them the two
///   assertions are what stop a bundle shipping without the recognition core, whether the
///   disclosure was regenerated from the partial tree or simply never regenerated at all.
/// * `--ci-artifact` requires the *generated* artifact to have the exact shape a CI
///   provisioning run must produce: every `origin: in-tree` entry -- and nothing else --
///   reported as absent, and the status that partial tree earns
///   (`partially_provisioned`, derived here rather than hard-coded). CI can restore only the
///   `origin: upstream` pins (the recognition core needs emsdk), so without that assertion its
///   regenerated artifact could silently shrink to a subset of the committed one and still
///   pass. It is meaningless in a fully provisioned local tree, where the in-tree entries are
///   present.
/// * `--source-digest` prints, for every `origin: in-tree` entry, the digest its
///   `build.sources` block records and the digest its sources have right now, and exits without
///   verifying anything else. It is the repin aid: after `native/wasm/build.sh` produces a new
///   module, the printed value is what `build.sources.digest` has to become. Every other mode
///   *checks* that pairing instead (see `verifyInTreeSourceDigests`), which is what makes a pin
///   left behind by a `native/` change visible at all.
/// * `--warn-stale-source-digest` keeps that check running but prints its findings as a notice
///   and exits 0 on them; every other check stays fatal. Only `tool/hooks/pre-commit` passes it,
///   for one reason: repinning the module requires an emsdk toolchain, so a fatal digest check
///   there makes `native/`-only work uncommittable on a machine that cannot rebuild the module.
///   Nothing that decides what *ships* passes it -- `tool/build_web.sh` and CI both run without
///   it, so the stale pin still cannot reach a bundle. Downgrading rather than skipping is
///   deliberate: the notice names the actual drift, so the developer learns it here instead of
///   from a red CI run.
///
/// Run from the repository root; every path is repository-relative.
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:umacapture/web_deps_verify.dart';

/// Exit code used for every verification failure.
const int failure = 1;

/// Flags this script accepts.
const List<String> knownFlags = [
  "--licenses",
  "--require-verified",
  "--ci-artifact",
  "--source-digest",
  "--warn-stale-source-digest",
];

/// Reports [problems] and exits, or returns when there are none.
void requireNoProblems(List<String> problems, String headline) {
  if (problems.isEmpty) {
    return;
  }
  stderr.writeln(headline);
  for (final problem in problems) {
    stderr.writeln("  $problem");
  }
  exit(failure);
}

/// Returns the generated artifact, or `null` when it is **missing**.
///
/// Missing and unreadable are deliberately different answers, and only the first one is `null`:
/// an artifact that is present but not decodable throws out of [jsonDecode] and takes the whole
/// verifier down non-zero. That is the wanted behaviour and the reason there is no `try` here —
/// the artifact is a *claim of coverage*, so the only readings that may pass are "it is not there
/// yet" (which every caller reports as a problem naming the codegen command) and "it says this".
/// Recovering from a damaged one — by treating it as absent, or by regenerating it — would let a
/// verifier that cannot read the claim it is checking report success.
Map<String, dynamic>? readArtifact() {
  final artifact = File(webLicenseArtifact);
  if (!artifact.existsSync()) {
    return null;
  }
  return jsonDecode(artifact.readAsStringSync()) as Map<String, dynamic>;
}

/// Checks that the artifact exists, claims a verified disclosure, and describes *this* tree.
///
/// Two assertions, because the artifact is **committed** while the tree it describes is partly
/// gitignored. Its `status` records whatever tree the last codegen ran in, so a clone that
/// provisioned only the upstream pins -- or nothing at all -- still reads `verified` off disk:
///
/// * `status` must be [webStatusVerified], which now means *every* `provisioned_root` entry was
///   present when it was generated ([webProvisioningStatus]). That catches a tree whose
///   disclosure was honestly regenerated from a partial provisioning run.
/// * its `absent` list must match what is actually missing right now. That catches the other
///   direction, where nothing was regenerated at all: a stale `verified` artifact next to a
///   `web/wasm/` that never received the recognition core. `tool/build_web.sh` would otherwise
///   produce a release bundle that cannot start, and the artifact would be claiming coverage of
///   files that are not there (or omitting files that are).
///
/// Together they are the inverse of [checkCiArtifact], which asserts the partial shape CI needs.
List<String> checkVerifiedArtifact(Map<String, dynamic> manifest) {
  final generated = readArtifact();
  if (generated == null) {
    return [
      "$webLicenseArtifact is missing; run 'dart run build_runner build --force-jit' "
          "(a failed run deletes it rather than writing a half-verified one)",
    ];
  }
  final problems = <String>[];
  if (generated["status"] != webStatusVerified) {
    problems.add(
      "$webLicenseArtifact says '${generated["status"]}', not '$webStatusVerified'; provision web/ "
      "(uv run tool/fetch_web_deps.py, plus native/wasm/build.sh for the recognition core) "
      "and re-run codegen",
    );
  }
  final (_, absent) = partitionWebFiles((manifest["files"] as Map).cast<String, dynamic>());
  final claimed = (generated["absent"] as List).cast<String>().toList()..sort();
  final actual = absent.toList()..sort();
  if (!const ListEquality<String>().equals(claimed, actual)) {
    problems.add(
      "$webLicenseArtifact reports absent $claimed, but $actual is what is missing from web/ "
      "right now; it does not describe this tree, so re-provision it "
      "(uv run tool/fetch_web_deps.py, plus native/wasm/build.sh) and re-run codegen",
    );
  }
  return problems;
}

/// Checks the generated artifact against the shape a CI provisioning run must produce.
List<String> checkCiArtifact(Map<String, dynamic> manifest) {
  final generated = readArtifact();
  if (generated == null) {
    return ["$webLicenseArtifact was not generated"];
  }
  final problems = <String>[];
  final files = (manifest["files"] as Map).cast<String, dynamic>();
  final expected = [
    for (final entry in files.entries)
      if ((entry.value as Map)["origin"] != "upstream") entry.key,
  ]..sort();
  // Derived, not hard-coded: CI provisions the upstream pins only, so the artifact it produces
  // reports whatever status that partial tree earns. Spelling 'verified' here instead would
  // re-introduce the very conflation this assertion exists to catch.
  final expectedStatus = webProvisioningStatus(manifest, expected);
  if (generated["status"] != expectedStatus) {
    problems.add("$webLicenseArtifact says '${generated["status"]}', not '$expectedStatus'");
  }
  final actual = (generated["absent"] as List).cast<String>().toList()..sort();
  if (!const ListEquality<String>().equals(expected, actual)) {
    problems.add(
      "$webLicenseArtifact reports absent $actual, but a CI provisioning run must "
      "leave exactly the origin:in-tree entries absent: $expected",
    );
  }
  return problems;
}

/// Prints the recorded and the current source digest of every `origin: in-tree` entry.
void printSourceDigests(Map<String, dynamic> manifest) {
  for (final entry in (manifest["files"] as Map).cast<String, dynamic>().entries) {
    final value = (entry.value as Map).cast<String, dynamic>();
    if (value["origin"] != "in-tree") {
      continue;
    }
    final sources = (((value["build"] as Map?)?[buildSourcesKey]) as Map?)?.cast<String, dynamic>();
    if (sources == null) {
      stdout.writeln("web/${entry.key}: no build.$buildSourcesKey block");
      continue;
    }
    final files = buildSourceFiles(sources);
    stdout.writeln("web/${entry.key} (${files.length} source file(s))");
    stdout.writeln("  pinned:  ${sources["digest"]}");
    stdout.writeln("  current: ${buildSourceDigest(sources)}");
  }
}

/// Reports [problems] found by [verifyInTreeSourceDigests] without failing the run.
///
/// Written to stderr, after the success summary, so it is the last thing on screen and is not
/// mistaken for part of it. It says twice over that this is only a reprieve: the run it is
/// printed from passes, the runs that gate the bundle do not.
void warnStaleSourceDigests(List<String> problems) {
  if (problems.isEmpty) {
    return;
  }
  stderr.writeln("");
  stderr.writeln("⚠ The pinned web recognition core no longer matches the sources in this tree:");
  for (final problem in problems) {
    stderr.writeln("  $problem");
  }
  stderr.writeln("");
  stderr.writeln("  NOT blocking here (--warn-stale-source-digest), because rebuilding the module");
  stderr.writeln("  needs an emsdk toolchain. CI and tool/build_web.sh run without that flag and");
  stderr.writeln("  will fail on this until the module is rebuilt and repinned.");
}

Future<void> main(List<String> arguments) async {
  final unknown = arguments.where((argument) => !knownFlags.contains(argument)).toList();
  if (unknown.isNotEmpty) {
    stderr.writeln("usage: dart run tool/check_web_pins.dart [${knownFlags.join("] [")}]");
    exit(failure);
  }
  if (!File(webDepsManifest).existsSync()) {
    stderr.writeln("$webDepsManifest not found; run this from the repository root");
    exit(failure);
  }

  final manifest = loadWebDepsManifest();
  if (arguments.contains("--source-digest")) {
    printSourceDigests(manifest);
    return;
  }
  final licenses = arguments.contains("--licenses");
  final warnStale = arguments.contains("--warn-stale-source-digest");
  requireNoProblems(
    await verifyWebTree(manifest, licenses: licenses, sourceDigests: !warnStale),
    "web/ does not match $webDepsManifest:",
  );
  if (arguments.contains("--require-verified")) {
    requireNoProblems(checkVerifiedArtifact(manifest), "$webLicenseArtifact does not cover this tree:");
  }
  if (arguments.contains("--ci-artifact")) {
    requireNoProblems(checkCiArtifact(manifest), "$webLicenseArtifact is not what this run should produce:");
  }

  final (present, absent) = partitionWebFiles((manifest["files"] as Map).cast<String, dynamic>());
  stdout.writeln(
    "web/ matches $webDepsManifest (${present.length} pinned file(s) verified, "
    "${absent.length} not provisioned${licenses ? ", licenses checked" : ""}"
    "${warnStale ? ", source digest advisory" : ""})",
  );
  if (warnStale) {
    warnStaleSourceDigests(verifyInTreeSourceDigests(manifest));
  }
}
