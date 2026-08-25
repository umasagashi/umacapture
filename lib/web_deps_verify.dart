// ignore_for_file: depend_on_referenced_packages

/// Verification of the `web/` tree against the pins and claims in `tool/web_deps.json`.
///
/// The manifest claims that every third-party file this repository places under
/// `web/` is the *unmodified* upstream artifact it names, and the generated
/// `assets/web_license_info.json` repeats that claim to the user. Nothing here
/// trusts a human declaration: the claim only survives if the bytes on disk still
/// hash to their pin, if nothing unpinned sits in the tree that `flutter build web`
/// publishes verbatim, and if every shipped file still has a license text behind it.
///
/// This library is the single implementation of those checks, shared by the three
/// places that must agree:
///
/// * `DistributionInfoBuilder` (`lib/distribution_info.dart`), which refuses to
///   emit the disclosure artifact when a check fails,
/// * `tool/check_web_pins.dart`, which the pre-commit hook and CI run directly, and
/// * `tool/build_web.sh`, which gates `flutter build web` on it.
///
/// It intentionally depends on nothing but `dart:io`, `crypto` and `path` so the
/// command-line entry point starts quickly enough to sit in a git hook.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// Manifest pinning every file this repository places under `web/`.
const String webDepsManifest = "tool/web_deps.json";

/// Directory whose contents `flutter build web` copies verbatim into `build/web/`.
const String webDirectory = "web";

/// License disclosure generated from [webDepsManifest] by `DistributionInfoBuilder`.
const String webLicenseArtifact = "assets/web_license_info.json";

/// Directory holding the license texts the manifest's `license.asset` fields point at.
///
/// A `license.asset` outside it is the repository's own `LICENSE`, i.e. first-party
/// code that the application's own license already covers, so it is not disclosed
/// again as a third-party dependency. Only `origin: in-tree` entries may say that;
/// see [verifyWebLicenses].
const String licenseAssetDirectory = "assets/license/";

/// How a component reaches the file it is disclosed against.
///
/// The two are *not* equally well evidenced, and the disclosure says so: the bytes of a
/// shipped file are hash-pinned, while the components compiled into `umacapture_core.wasm`
/// are recorded from the inputs `native/wasm/build.sh` was given. Nothing here reads the
/// binary back, so the linked list is an assertion about the build, not a derivation from
/// the artifact.
enum WebClaimRelation {
  shipped("shipped as", "bytes hash-pinned in $webDepsManifest"),
  linked("statically linked into", "recorded from the build inputs, not derived from the binary");

  const WebClaimRelation(this.phrase, this.qualifier);

  /// Human-readable relation, e.g. `statically linked into`.
  final String phrase;

  /// How well the relation is evidenced, rendered next to the file list.
  final String qualifier;
}

/// One license claim: a component, the shipped file it lands in, and the license behind it.
class WebLicenseClaim {
  WebLicenseClaim({
    required this.component,
    required this.relation,
    required this.file,
    required this.license,
    required this.sourceForm,
  });

  /// Human-readable component name and version, e.g. `onnxruntime-web 1.27.0`.
  final String component;

  /// How the component reaches [file].
  final WebClaimRelation relation;

  /// Repository-relative path of the shipped file, e.g. `web/wasm/umacapture_core.wasm`.
  final String file;

  /// The manifest's `license` block: `id`, `asset`, and an optional sub-notice `parent`.
  final Map<String, dynamic> license;

  /// The manifest's `source_form` block, if the node carries one.
  final Map<String, dynamic>? sourceForm;

  /// Repository-relative path of the license text, or `null` when the node declares none.
  String? get licenseAsset => license["asset"] as String?;
}

/// Returns the parsed [webDepsManifest].
Map<String, dynamic> parseWebDepsManifest(String contents) => jsonDecode(contents) as Map<String, dynamic>;

/// Reads and parses [webDepsManifest] from the current working directory.
///
/// Builders read the manifest through the asset graph instead, so that bumping a
/// pin re-runs them; use [parseWebDepsManifest] there.
Map<String, dynamic> loadWebDepsManifest() => parseWebDepsManifest(File(webDepsManifest).readAsStringSync());

/// `status` of [webLicenseArtifact] when every file under the manifest's
/// `provisioned_root` is present, so the disclosure covers the whole shipped tree.
const String webStatusVerified = "verified";

/// `status` of [webLicenseArtifact] when none of them is, i.e. an ordinary
/// Windows-only checkout that never provisioned `web/wasm/`.
const String webStatusNotProvisioned = "not_provisioned";

/// `status` of [webLicenseArtifact] when only *some* of them are.
///
/// This is a real state, not a corner case: `uv run tool/fetch_web_deps.py` cannot fetch
/// the `origin: in-tree` recognition core (building it needs emsdk), so it leaves exactly
/// this shape behind -- and CI runs in it deliberately. It must not read as [webStatusVerified],
/// because `tool/build_web.sh --require-verified` would then produce a release bundle with no
/// recognition core in it.
const String webStatusPartiallyProvisioned = "partially_provisioned";

/// Returns the `status` [webLicenseArtifact] must report for a tree missing [absent].
///
/// The manifest's `provisioned_root` is the gitignored prefix a checkout has to provision.
/// [absent] is the manifest-relative key list of everything not on disk -- as produced by
/// [partitionWebFiles], or as *predicted* for a given provisioning run, which is how
/// `tool/check_web_pins.dart` derives the shape CI must produce.
String webProvisioningStatus(Map<String, dynamic> manifest, Iterable<String> absent) {
  final root = manifest["provisioned_root"] as String;
  final total = (manifest["files"] as Map).keys.where((key) => (key as String).startsWith(root)).length;
  final missing = absent.where((key) => key.startsWith(root)).length;
  if (missing == 0) {
    return webStatusVerified;
  }
  return missing == total ? webStatusNotProvisioned : webStatusPartiallyProvisioned;
}

/// Returns the SHA-256 of [file], hashed as a stream so the bytes are never held whole.
Future<String> sha256OfFile(File file) async => (await sha256.bind(file.openRead()).first).toString();

/// Splits the manifest's `files` into the entries that exist under `web/` and those that do not.
///
/// A missing entry is not an error: `web/` is exactly what `flutter build web` publishes,
/// so a file that is not there is not shipped and must not be claimed either. What is
/// there, on the other hand, is verified byte for byte.
(Map<String, Map<String, dynamic>>, List<String>) partitionWebFiles(Map<String, dynamic> files) {
  final present = <String, Map<String, dynamic>>{};
  final absent = <String>[];
  for (final entry in files.entries) {
    if (File(path.join(webDirectory, entry.key)).existsSync()) {
      present[entry.key] = (entry.value as Map).cast<String, dynamic>();
    } else {
      absent.add(entry.key);
    }
  }
  return (present, absent);
}

/// Returns one problem line per manifest entry whose on-disk bytes drifted from its pin.
Future<List<String>> verifyWebPins(Map<String, Map<String, dynamic>> present) async {
  final problems = <String>[];
  for (final entry in present.entries) {
    final file = File(path.join(webDirectory, entry.key));
    final size = file.lengthSync();
    if (size != entry.value["bytes"]) {
      problems.add("web/${entry.key}: ${entry.value["bytes"]} bytes pinned, $size on disk");
      continue;
    }
    final digest = await sha256OfFile(file);
    if (digest != entry.value["sha256"]) {
      problems.add("web/${entry.key}: sha256 ${entry.value["sha256"]} pinned, $digest on disk");
    }
  }
  return problems;
}

/// Key under an `origin: in-tree` entry's `build` block describing what the artifact was built from.
///
/// Every other check in this library compares *bytes to their pin*. None of them can see the
/// failure that matters most for a locally built artifact: the bytes still match the pin while
/// the sources they were built from have moved on, so a web build ships C++ that is older than
/// the C++ under review. That state is invisible by construction -- the artifact is gitignored,
/// so nothing in git relates it to a commit, and its own hash agrees with the manifest.
///
/// The block closes that gap by recording, next to the byte pin, a digest of the source tree the
/// artifact was produced from. [verifyInTreeSourceDigests] recomputes it from the working tree,
/// so "the pin did *not* change while its sources did" becomes a first-class failure. It needs no
/// emsdk and no artifact on disk: CI, which cannot build the module at all, still detects a pin
/// left behind by a `native/` change.
///
/// WHAT IT DOES NOT PROVE. The comparison is `recorded digest == current tree`, nothing more.
/// It cannot look inside the binary, so editing the digest by hand -- or repinning after a
/// `native/` change without rebuilding -- passes. What it removes is the *silent* case, where
/// nobody touches the manifest at all and the stale pin keeps verifying against its own bytes.
const String buildSourcesKey = "sources";

/// Returns the repository-relative paths a [buildSourcesKey] block selects, sorted.
///
/// The block names `roots` to walk, the `extensions` that reach the compiler, and the `exclude`
/// list of sources deliberately left out of the module (`native/wasm/build.sh`'s
/// `EXCLUDED_SOURCES`; `native/wasm/check_sources.py` holds the two lists together).
///
/// The selection deliberately over-approximates the module's real input set, because computing
/// the actual include closure without a compiler would be a second, unverifiable model of the
/// build: every header under the roots counts, whether or not the module includes it. A false
/// "stale" therefore costs a rebuild, while the error it exists to prevent -- a false "fresh" --
/// cannot happen. Directories are walked without following links, so only regular files count.
List<String> buildSourceFiles(Map<String, dynamic> sources) {
  final extensions = (sources["extensions"] as List).cast<String>().toSet();
  final excluded = (sources["exclude"] as List? ?? const <dynamic>[]).cast<String>().toSet();
  final selected = <String>[];
  for (final root in (sources["roots"] as List).cast<String>()) {
    for (final entity in Directory(root).listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final relative = path.split(path.relative(entity.path)).join("/");
      if (extensions.contains(path.extension(relative)) && !excluded.contains(relative)) {
        selected.add(relative);
      }
    }
  }
  return selected..sort();
}

/// Returns the SHA-256 of [bytes] with CRLF folded to LF.
///
/// `core.autocrlf=true` is in effect here, so the same commit is CRLF on this machine and LF on a
/// Linux runner. Hashing the raw bytes would make the digest describe the checkout rather than the
/// sources, and every cross-platform comparison would report a false mismatch.
String sha256OfTextBytes(List<int> bytes) {
  final normalised = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0x0D && i + 1 < bytes.length && bytes[i + 1] == 0x0A) {
      continue;
    }
    normalised.add(bytes[i]);
  }
  return sha256.convert(normalised).toString();
}

/// Returns the digest of the sources a [buildSourcesKey] block selects.
///
/// Hashes the *list* of `path sha256` lines rather than the concatenated contents, so a file that
/// is added, removed or renamed changes the digest even when no content does.
String buildSourceDigest(Map<String, dynamic> sources) {
  final lines = StringBuffer();
  for (final relative in buildSourceFiles(sources)) {
    lines.writeln("$relative ${sha256OfTextBytes(File(relative).readAsBytesSync())}");
  }
  return sha256.convert(utf8.encode(lines.toString())).toString();
}

/// Returns one problem line per `origin: in-tree` entry that no longer matches its sources.
///
/// Three failures, all of them "the pin cannot be trusted to describe current code": a missing
/// [buildSourcesKey] block (nothing to compare against, so the gate would silently be off), a
/// root that is not in this checkout (nothing to compare with), and a digest that has moved.
List<String> verifyInTreeSourceDigests(Map<String, dynamic> manifest) {
  final digests = <String, String>{};
  final problems = <String>[];
  for (final entry in (manifest["files"] as Map).cast<String, dynamic>().entries) {
    final value = (entry.value as Map).cast<String, dynamic>();
    if (value["origin"] != "in-tree") {
      continue;
    }
    final sources = (((value["build"] as Map?)?[buildSourcesKey]) as Map?)?.cast<String, dynamic>();
    if (sources == null) {
      problems.add(
        "web/${entry.key} is origin 'in-tree' but records no build.$buildSourcesKey block in "
        "$webDepsManifest; without it the pin can only be compared with the bytes on disk, never "
        "with the sources they were built from",
      );
      continue;
    }
    final roots = (sources["roots"] as List).cast<String>();
    final missing = roots.where((root) => !Directory(root).existsSync()).toList();
    if (missing.isNotEmpty) {
      problems.add(
        "web/${entry.key} records build.$buildSourcesKey over ${missing.join(", ")}, which "
        "this checkout does not have; the pin cannot be checked against its sources",
      );
      continue;
    }
    final recorded = sources["digest"] as String?;
    final selection = jsonEncode([roots, sources["extensions"], sources["exclude"]]);
    final actual = digests.putIfAbsent(selection, () => buildSourceDigest(sources));
    if (recorded != actual) {
      problems.add(
        "web/${entry.key} was built from sources digesting to $recorded, but ${roots.join(", ")} "
        "now digest to $actual; the pinned artifact is older than the code in this tree. Rebuild it "
        "(native/wasm/build.sh), copy the artifacts into web/wasm/, then repin sha256, bytes and "
        "build.$buildSourcesKey.digest ('dart run tool/check_web_pins.dart --source-digest' prints "
        "the current digest)",
      );
    }
  }
  return problems..sort();
}

/// Returns one problem line per file under `web/` that is neither pinned nor first-party.
///
/// `flutter build web` copies `web/` verbatim into `build/web/`, so an unreviewed file
/// dropped anywhere in that tree is published with no license claim behind it.
///
/// The allowlist names first-party files one by one rather than by directory prefix: a
/// prefix would allow an unbounded number of unreviewed files under it. Symbolic links
/// are always a problem, never an allowlist match -- the link name says nothing about
/// the bytes it resolves to, and a link is what a payload smuggled into the tree would
/// look like.
List<String> unlistedWebFiles(Set<String> pinned, Map<String, dynamic> allowlist) {
  final firstParty = (allowlist["files"] as List).cast<String>().toSet();
  final root = Directory(webDirectory);
  if (!root.existsSync()) {
    return const [];
  }
  final problems = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = path.split(path.relative(entity.path, from: root.path)).join("/");
    if (entity is Link) {
      problems.add(
        "web/$relative is a symbolic link; links are never covered by $webDepsManifest "
        "and 'flutter build web' would publish whatever they resolve to",
      );
      continue;
    }
    if (entity is! File || pinned.contains(relative) || firstParty.contains(relative)) {
      continue;
    }
    problems.add(
      "web/$relative is neither pinned in $webDepsManifest nor listed as first-party; "
      "'flutter build web' would publish it unreviewed",
    );
  }
  return problems..sort();
}

/// Returns the paths git tracks under `web/`, relative to `web/`, or `null` when git cannot answer.
Set<String>? gitTrackedWebFiles() {
  ProcessResult result;
  try {
    result = Process.runSync("git", ["ls-files", "--", webDirectory]);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }
  return {
    for (final line in const LineSplitter().convert(result.stdout as String))
      if (line.startsWith("$webDirectory/")) line.substring(webDirectory.length + 1),
  };
}

/// Returns one problem line per first-party allowlist entry git does not track under `web/`.
///
/// "First party" means *this repository wrote it*, and the only mechanical evidence for that
/// is that the file is committed here. Without this check the allowlist is a hole: moving a
/// gitignored third-party file's path out of `files` and into `first_party.files` drops its
/// license disclosure while the bytes keep shipping, and every other check still passes.
/// Failing closed when git cannot answer is deliberate -- an unverifiable allowlist is not a
/// trustworthy one.
List<String> untrackedFirstPartyFiles(Map<String, dynamic> allowlist) {
  final firstParty = (allowlist["files"] as List).cast<String>();
  final tracked = gitTrackedWebFiles();
  if (tracked == null) {
    return [
      "the first-party allowlist in $webDepsManifest is verified against "
          "'git ls-files $webDirectory', which could not be run here; refusing to trust the allowlist",
    ];
  }
  return [
    for (final file in firstParty)
      if (!tracked.contains(file))
        "web/$file is listed as first-party in $webDepsManifest but git does not track it; only "
            "committed files can be first-party (a third-party file moved into this list would "
            "ship with no license disclosure)",
  ]..sort();
}

/// Flattens the present manifest entries into one claim per (component, shipped file).
///
/// A top-level entry contributes the file itself; `umacapture_core.wasm` additionally
/// contributes its `linked` list, the third-party code statically linked into it.
List<WebLicenseClaim> webLicenseClaims(Map<String, Map<String, dynamic>> present) {
  final claims = <WebLicenseClaim>[];
  for (final entry in present.entries) {
    final upstream = (entry.value["upstream"] as Map?)?.cast<String, dynamic>();
    claims.add(
      WebLicenseClaim(
        component: upstream == null ? "built in this repository" : "${upstream["package"]} ${upstream["version"]}",
        relation: WebClaimRelation.shipped,
        file: "web/${entry.key}",
        license: (entry.value["license"] as Map).cast<String, dynamic>(),
        sourceForm: (entry.value["source_form"] as Map?)?.cast<String, dynamic>(),
      ),
    );
    for (final raw in (entry.value["linked"] as List? ?? const <dynamic>[])) {
      final linked = (raw as Map).cast<String, dynamic>();
      claims.add(
        WebLicenseClaim(
          component: "${linked["name"]} ${linked["version"]}",
          relation: WebClaimRelation.linked,
          file: "web/${entry.key}",
          license: (linked["license"] as Map).cast<String, dynamic>(),
          sourceForm: (linked["source_form"] as Map?)?.cast<String, dynamic>(),
        ),
      );
    }
  }
  return claims;
}

/// Returns `true` when [id] names a Mozilla Public License.
bool isMozillaPublicLicense(String id) => id.toUpperCase().contains("MPL");

/// Returns `true` when [sourceForm] discloses an immutable archive *and* an upstream tag.
bool hasCompleteSourceForm(Map<String, dynamic>? sourceForm) {
  const required = ["form", "url", "sha256", "git_url"];
  return sourceForm != null && required.every((key) => sourceForm[key] != null);
}

/// Returns one problem line per license claim that must not be published as it stands.
///
/// Covers everything the *disclosure* depends on, as opposed to the bytes: a present file
/// with nothing to disclose, a present file the manifest itself says is misplaced, a
/// third-party file waved through as covered by this repository's own license -- whether it is
/// shipped as itself or statically linked into something that is -- a referenced text that is not
/// committed, one text claimed under two ids, and an MPL text without the source form section 3.2
/// requires.
List<String> verifyWebLicenses(Map<String, dynamic> manifest) {
  final files = (manifest["files"] as Map).cast<String, dynamic>();
  final (present, _) = partitionWebFiles(files);
  final problems = <String>[];

  // `relocation_required` is how the manifest records "this file is in the wrong place": it
  // is written while the file still sits under web/ and the move is pending. Keeping it and
  // shipping anyway is the failure mode, so the block is only tolerable while the file is
  // absent -- which is exactly what this enforces.
  for (final entry in present.entries) {
    if (entry.value["relocation_required"] != null) {
      problems.add(
        "web/${entry.key} is present but marked relocation_required in $webDepsManifest "
        "(${(entry.value["relocation_required"] as Map)["reason"]}); move it out of web/ "
        "and drop the entry instead of publishing it",
      );
    }
  }

  // An upstream artifact is by definition not covered by this repository's own LICENSE, so
  // pointing its `license.asset` outside assets/license/ silently removes it from the
  // disclosure (such a path is treated as first-party and skipped) while it keeps shipping.
  //
  // This loop reads the top-level entries only, because `origin` is a top-level key: a `linked`
  // sub-entry carries none and would be waved through here. The same escape is closed for those
  // in the claim loop below, on the relation rather than on `origin`.
  for (final entry in files.entries) {
    final value = (entry.value as Map).cast<String, dynamic>();
    final asset = ((value["license"] as Map?)?.cast<String, dynamic>())?["asset"] as String?;
    if (value["origin"] == "upstream" && asset != null && !asset.startsWith(licenseAssetDirectory)) {
      problems.add(
        "web/${entry.key} is origin 'upstream' but its license.asset '$asset' is outside "
        "$licenseAssetDirectory; third-party bytes cannot be covered by this repository's own license",
      );
    }
  }

  final claimedIds = <String, String>{};
  for (final claim in webLicenseClaims(present)) {
    final asset = claim.licenseAsset;
    // A null asset is not "nothing to disclose", it is "nothing CAN be disclosed": the file
    // is published by 'flutter build web' with no license text behind it. Claims are built
    // only from files that exist, so this fires exactly when such a file is present.
    if (asset == null) {
      problems.add(
        "${claim.file} is present but ${claim.component} has no license.asset in "
        "$webDepsManifest; 'flutter build web' would publish it with nothing to disclose",
      );
      continue;
    }
    if (!asset.startsWith(licenseAssetDirectory)) {
      // Outside assets/license/ means "covered by this repository's own license", and skipping is
      // only correct when that is true. It is never true of a `linked` claim: those are the
      // third-party libraries statically linked into the wasm, and the manifest gives them no
      // `origin` key, so the top-level loop above -- which keys on `origin == "upstream"` -- cannot
      // see them at all. Copying a parent node's `"asset": "LICENSE"` into a new `linked` node
      // would otherwise pass every check while shipping undisclosed third-party code, which is the
      // one failure this whole function exists to prevent.
      if (claim.relation == WebClaimRelation.linked) {
        problems.add(
          "${claim.file} statically links ${claim.component}, but its license.asset '$asset' is "
          "outside $licenseAssetDirectory; third-party bytes cannot be covered by this "
          "repository's own license",
        );
      }
      continue;
    }
    if (!File(asset).existsSync()) {
      problems.add("$asset is referenced by $webDepsManifest but is not committed");
      continue;
    }
    final id = claim.license["id"] as String;
    final previous = claimedIds.putIfAbsent(asset, () => id);
    if (previous != id) {
      problems.add("$asset is claimed as both '$previous' and '$id'");
    }
    // MPL-2.0 is accepted for web assets only, and only against a disclosed source form
    // (section 3.2). The pub-side reject list in lib/distribution_info.dart is untouched.
    if (isMozillaPublicLicense(id) && !hasCompleteSourceForm(claim.sourceForm)) {
      problems.add("$asset is $id, which may only be disclosed with a complete source_form block");
    }
  }
  return problems..sort();
}

/// Runs the closed-world check over `web/` and returns every problem found.
///
/// An empty list means every pinned file that exists hashes to its pin, nothing else sits in
/// the tree, the first-party allowlist only names committed files, and every locally built
/// artifact is pinned against the sources this tree currently holds. Pass [licenses] to add
/// [verifyWebLicenses] on top, which is what `DistributionInfoBuilder` does before it writes
/// the disclosure.
///
/// [verifyInTreeSourceDigests] runs independently of what is on disk: the in-tree artifacts are
/// gitignored and absent in CI and in an ordinary Windows-only checkout, but their *sources* are
/// committed, so the manifest can be held to them everywhere.
///
/// [sourceDigests] defaults to `true` because every gate that decides what *ships* -- codegen,
/// `tool/build_web.sh`, CI -- must fail on a pin the sources have outgrown, and a default of
/// `false` would turn a forgotten argument into a silently disabled gate. The one caller that
/// passes `false` is `tool/check_web_pins.dart --warn-stale-source-digest`, used by
/// `tool/hooks/pre-commit`: rebuilding the module needs emsdk, so blocking there would make
/// `native/`-only work uncommittable on a machine that cannot rebuild it. That caller reports
/// the same problems as a non-blocking notice instead of dropping them.
Future<List<String>> verifyWebTree(
  Map<String, dynamic> manifest, {
  bool licenses = false,
  bool sourceDigests = true,
}) async {
  final files = (manifest["files"] as Map).cast<String, dynamic>();
  final allowlist = (manifest["first_party"] as Map).cast<String, dynamic>();
  final (present, _) = partitionWebFiles(files);
  final problems = await verifyWebPins(present);
  problems.addAll(unlistedWebFiles(files.keys.toSet(), allowlist));
  problems.addAll(untrackedFirstPartyFiles(allowlist));
  if (sourceDigests) {
    problems.addAll(verifyInTreeSourceDigests(manifest));
  }
  if (licenses) {
    problems.addAll(verifyWebLicenses(manifest));
  }
  return problems;
}
