// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:dart_pubspec_licenses/dart_pubspec_licenses.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as path;
import 'package:version/version.dart';
import 'package:yaml/yaml.dart';

import '/web_deps_verify.dart';

Builder distributionInfoBuilder(BuilderOptions options) {
  return DistributionInfoBuilder();
}

class DistributionInfoBuilder implements Builder {
  final JsonEncoder jsonEncoder = JsonEncoder.withIndent(" " * 4);

  FutureOr<String> _buildLicenseInfo(String inputPath) async {
    // dart_pubspec_licenses 3.x: generateLicenseInfo was removed and replaced by listDependencies.
    // The Flutter 3.38 SDK layout has no root `version` file, which makes SDK package analysis fail,
    // so the Flutter SDK bundled packages are ignored (their licenses are handled by LicenseRegistry).
    final deps = await listDependencies(
      pubspecYamlPath: inputPath,
      ignore: const [
        "flutter",
        "flutter_localizations",
        "flutter_web_plugins",
        "flutter_test",
        "sky_engine",
        // dbus is MPL-2.0 (a reject target; it also matches the "General Public License" compatibility
        // wording inside the MPL text). It is a transitive dependency via file_picker's Linux implementation
        // and is not included in the Windows (msix) distribution, so it is excluded.
        // Note: if a Linux build is distributed, decide separately whether bundling MPL is acceptable.
        "dbus",
      ],
    );
    final license = jsonEncoder.convert(deps.allDependencies.map((e) => e.toJson()).toList());

    final context = license.toLowerCase();
    final rejects = ["GENERAL PUBLIC LICENSE", "EUROPEAN UNION PUBLIC LICENCE", "Mozilla Public License"];
    for (final key in rejects) {
      if (context.contains(key.toLowerCase())) {
        throw Exception("Rejected key found: $key");
      }
    }

    return license;
  }

  String _getLicenseFile(String directory) {
    final licensePattern = RegExp("LICENSE.*", caseSensitive: false);
    // Sorted, because a directory can hold more than one match -- the OpenCV Windows
    // distribution carries `LICENSE.txt` (its own Apache-2.0) next to `LICENSE_FFMPEG.txt`
    // (the plugin's LGPL, disclosed separately via [extraNativeLicenseTexts]) -- and which one
    // this returns must not depend on the order the file system happens to enumerate them in.
    return (Directory(directory)
            .listSync(recursive: false, followLinks: false)
            .map((e) => e.path)
            .where((e) => licensePattern.hasMatch(path.basename(e)))
            .toList()
          ..sort())
        .first;
  }

  /// Prebuilt native dependencies whose license texts are copied out of their own directories.
  ///
  /// `windows/opencv` and `windows/onnxruntime` are gitignored and provisioned by
  /// `tool/fetch_deps.py`; `windows/clip` is vendored in-tree.
  // TODO: This should be separated by OS.
  static const Map<String, String> nativePackageDirectories = {
    "opencv": "windows/opencv",
    "onnxruntime": "windows/onnxruntime",
    "clip": "windows/clip",
  };

  /// License texts refreshed from a provisioned dependency under a name of our own.
  ///
  /// [nativePackageDirectories] takes one `LICENSE*` per directory, and the OpenCV Windows
  /// distribution carries a second one: `LICENSE_FFMPEG.txt`, the LGPL-2.1 terms of the
  /// prebuilt FFmpeg the videoio plugin DLL is built from. That DLL is shipped
  /// (`windows/runner/CMakeLists.txt` copies it next to the executable), so its terms have to
  /// be disclosed under a package of their own rather than folded into OpenCV's Apache-2.0.
  static const Map<String, String> extraNativeLicenseTexts = {
    "assets/license/ffmpeg.txt": "windows/opencv/LICENSE_FFMPEG.txt",
  };

  /// Where the Windows build declares the DLLs it places next to `umacapture.exe`.
  ///
  /// Read with `dart:io` rather than through the asset graph: `windows/` is outside the build's
  /// source set, so it cannot be registered as a builder input and editing it does not re-run
  /// codegen. `test/licence_disclosure_windows_test.dart` re-derives the same set from the same
  /// file and turns red when the committed artifact has gone stale, which is what covers that.
  static const String windowsRunnerCMakeLists = "windows/runner/CMakeLists.txt";

  void _refreshLicenseText(String target, String source, String subject, String provisioner) {
    if (File(source).existsSync()) {
      // copySync, not copy: the async version was never awaited, so a failure to refresh
      // the text used to be swallowed and the copy raced the rest of the build.
      File(source).copySync(target);
      return;
    }
    // The provisioned Windows dependencies are absent in a checkout that only builds and
    // tests the Dart side (CI's flutter job). The disclosure is unaffected -- the entries below
    // are name -> committed text, and only *refreshing* that text needs the source directory --
    // so emit the same entry as long as the committed text is there. A missing text means
    // the disclosure really is broken, and that must not be papered over.
    if (!File(target).existsSync()) {
      throw Exception(
        "$target is missing and $source is not provisioned, so $subject's license cannot be "
        "disclosed; run '$provisioner' first",
      );
    }
  }

  FutureOr<String> _buildAdditionalLicenseInfo() async {
    const outputDir = "assets/license";
    final directories = {
      ...nativePackageDirectories,
      for (final dir in Directory("native/vendor").listSync(recursive: false, followLinks: false))
        path.basename(dir.path): dir.path,
    };

    for (final entry in directories.entries) {
      final target = "$outputDir/${entry.key}.txt";
      final directory = entry.value;
      _refreshLicenseText(
        target,
        Directory(directory).existsSync() ? _getLicenseFile(directory) : directory,
        entry.key,
        "uv run tool/fetch_deps.py",
      );
    }
    for (final entry in extraNativeLicenseTexts.entries) {
      _refreshLicenseText(
        entry.key,
        entry.value,
        path.basenameWithoutExtension(entry.key),
        "uv run tool/fetch_deps.py",
      );
    }

    final bundled = parseBundledWindowsDlls(File(windowsRunnerCMakeLists).readAsStringSync());
    final disclosures = _desktopDisclosures(directories.keys, bundled);

    // The one check that cannot be satisfied by editing this file alone: every DLL the Windows
    // build redistributes has to be claimed by some disclosure. Adding a DLL to
    // `windows/runner/CMakeLists.txt` without disclosing what is inside it fails the build here
    // instead of shipping an under-disclosed installer.
    final claimed = {for (final disclosure in disclosures) ...disclosure.shippedFiles};
    final undisclosed = bundled.thirdParty.difference(claimed);
    if (undisclosed.isNotEmpty) {
      throw Exception(
        "$windowsRunnerCMakeLists redistributes ${undisclosed.join(", ")} but nothing in "
        "DistributionInfoBuilder discloses what is inside; add the license text and an entry "
        "before shipping it",
      );
    }

    return jsonEncoder.convert({
      "disclosure_scope":
          "Every file the Windows build redistributes (parsed from $windowsRunnerCMakeLists) is "
          "claimed by an entry below. The components listed as 'statically linked into' a file "
          "are read from that file's own recorded build information; they are not derived from "
          "its code. Operating-system redistributables copied out of ${bundled.systemDirectory} "
          "are covered by their own redistribution terms and are not listed.",
      "entries": [for (final disclosure in disclosures) disclosure.toJson()],
    });
  }

  /// Every third-party component the desktop and web application bundles disclose.
  ///
  /// The platform each entry belongs to is *data* rather than a branch at the reader: the
  /// desktop and the web build do not ship the same components, and `lib/main.dart` selects on
  /// this field instead of re-deriving the split from a hand-written list of package names.
  List<_Disclosure> _desktopDisclosures(Iterable<String> textDirectories, BundledWindowsDlls bundled) {
    const bothPlatforms = ["windows", "web"];
    const windowsOnly = ["windows"];
    final openCv = bundled.matching("opencv_world");
    final ffmpeg = bundled.matching("opencv_videoio_ffmpeg");
    final onnxRuntime = bundled.matching("onnxruntime");
    return [
      // Flutter-level assets: bundled by `pubspec.yaml`, so they reach every platform.
      _Disclosure(package: "google_fonts", asset: "assets/license/google_fonts.txt", platforms: bothPlatforms),
      _Disclosure(package: "ZapSplat", asset: "assets/license/ZapSplat.txt", platforms: bothPlatforms),
      // The prebuilt native dependencies and everything vendored under `native/vendor`. Web
      // reaches the same C++ through `web/wasm/umacapture_core.wasm`, which
      // `assets/web_license_info.json` discloses with its own provenance, so these entries claim
      // the desktop build only.
      for (final name in textDirectories)
        _Disclosure(
          package: name,
          asset: "assets/license/$name.txt",
          platforms: windowsOnly,
          components: [
            switch (name) {
              "opencv" => "OpenCV 4.13.0 -- shipped as $openCv next to umacapture.exe",
              "onnxruntime" => "ONNX Runtime -- shipped as $onnxRuntime next to umacapture.exe",
              "clip" => "clip -- source form under windows/clip, compiled into umacapture.exe",
              // Deliberately no "compiled into" claim: the vendored set is not all reached by the
              // application (CLI11 is the CLI front end's, doctest is the test runner's), and
              // naming a build output each one lands in would need a per-library check this
              // builder cannot make. Where it is vendored is a fact; what links it is not.
              _ => "$name -- vendored source under ${directoryOf(name)}",
            },
          ],
          shippedFiles: switch (name) {
            "opencv" => [openCv],
            "onnxruntime" => [onnxRuntime],
            _ => const [],
          },
        ),
      // Loaded at run time by the OpenCV DLL above, and the reason the desktop build carries an
      // LGPL component at all. Disclosed separately because OpenCV's own Apache-2.0 text does
      // not reproduce these terms.
      //
      // The version and the two source pointers in `extraNotice` are facts about the provisioned
      // OpenCV distribution, so an OpenCV bump has to re-derive all three. `4.4.6` is the
      // "FFmpeg version" build-information string inside the shipped plugin DLL; the
      // `opencv_3rdparty` commit is the `FFMPEG_BINARIES_COMMIT` pinned by
      // `sources/3rdparty/ffmpeg/ffmpeg.cmake` in that distribution. They are written out rather
      // than read at build time because `--slim` provisioning (what CI uses) prunes
      // `windows/opencv/sources`, so the file naming the commit is not present in every checkout.
      _Disclosure(
        package: "ffmpeg",
        asset: "assets/license/ffmpeg.txt",
        platforms: windowsOnly,
        components: [
          "FFmpeg (OpenCV's prebuilt videoio plugin, built without GPL components) -- shipped as "
              "$ffmpeg next to umacapture.exe and loaded at run time by $openCv",
        ],
        shippedFiles: [ffmpeg],
        extraNotice:
            "This component is licensed under the GNU Lesser General Public License, version 2.1 "
            "or later. It is shipped unmodified, as a separate dynamically loaded library that "
            "umacapture does not link against, so it can be replaced with a modified version by "
            "substituting the file. It is FFmpeg 4.4.6, prebuilt by the OpenCV project and taken "
            "unchanged from the OpenCV 4.13.0 Windows distribution "
            "(https://github.com/opencv/opencv/releases/tag/4.13.0). The FFmpeg 4.4.6 sources are "
            "published at https://github.com/FFmpeg/FFmpeg/releases/tag/n4.4.6, and this exact "
            "binary together with the scripts that produced it at "
            "https://github.com/opencv/opencv_3rdparty/tree/"
            "d82ad9a54a7b42a1648a9cae8fed5c2f20ea396c/ffmpeg -- the commit that OpenCV 4.13.0's "
            "own 3rdparty/ffmpeg/ffmpeg.cmake pins (branch ffmpeg/4.x_20251226).",
      ),
      // Read out of the build-information string recorded inside the shipped OpenCV DLL, which
      // names each bundled third-party library and its version. OpenCV's Apache-2.0 text covers
      // none of them, and the desktop DLL bundles a different set from the wasm build.
      for (final (component, asset) in const [
        ("zlib 1.3.1", "assets/license/zlib.txt"),
        ("libpng 1.6.53", "assets/license/libpng.txt"),
        ("libjpeg-turbo 3.1.2-70", "assets/license/libjpeg_turbo.txt"),
      ])
        _Disclosure(
          package: path.basenameWithoutExtension(asset),
          asset: asset,
          platforms: windowsOnly,
          components: ["$component -- statically linked into $openCv"],
        ),
      _Disclosure(
        package: "opencv",
        asset: "assets/license/opencv_softfloat.txt",
        platforms: windowsOnly,
        subNoticeOf: "opencv",
        components: [
          "OpenCV core: softfloat (Berkeley SoftFloat 3c and FDLIBM derived) as shipped in "
              "OpenCV 4.13.0 -- statically linked into $openCv",
        ],
      ),
      _Disclosure(
        package: "spdlog",
        asset: "assets/license/fmt.txt",
        platforms: windowsOnly,
        subNoticeOf: "spdlog",
        components: [
          "{fmt} (bundled inside the vendored spdlog snapshot) -- compiled into umacapture.exe "
              "together with spdlog",
        ],
      ),
    ];
  }

  /// Repository-relative source directory a disclosed name was taken from.
  static String directoryOf(String name) => nativePackageDirectories[name] ?? "native/vendor/$name";

  /// Registers everything under `web/` as a build dependency, so that provisioning a file,
  /// editing one, or dropping a stray one re-runs the closed-world check below.
  ///
  /// Only the dependency edges are taken from the asset graph: [BuildStep.canRead] reports
  /// existence and [BuildStep.findAssets] reports the matched set, neither hands over any
  /// bytes. The verification itself streams the files from disk, so the 13 MB ONNX Runtime
  /// backend is never materialised in the builder.
  Future<void> _trackWebAssets(BuildStep buildStep, Iterable<String> pinned) async {
    await buildStep.findAssets(Glob("web/**")).drain<void>();
    for (final key in pinned) {
      await buildStep.canRead(AssetId(buildStep.inputId.package, "web/$key"));
    }
  }

  /// Groups [claims] by the license text they point at, one disclosure per text.
  ///
  /// Several files often share one text (the three onnxruntime-web files, the mediabunny
  /// bundle and its LICENSE), and a text with a `parent` is a sub-notice: it is disclosed
  /// under that already-listed package rather than as a dependency of its own.
  ///
  /// Pure rendering: every way a claim can be *wrong* is detected by [verifyWebLicenses],
  /// which runs first and aborts the build, so the two cannot drift apart. Claims whose
  /// asset lies outside [licenseAssetDirectory] are this repository's own code, already
  /// covered by its `LICENSE`, and are not disclosed again.
  Map<String, _WebLicenseReference> _groupWebLicenses(List<WebLicenseClaim> claims) {
    final references = <String, _WebLicenseReference>{};
    for (final claim in claims) {
      final asset = claim.licenseAsset;
      if (asset == null || !asset.startsWith(licenseAssetDirectory)) {
        continue;
      }
      final parent = claim.license["parent"] as String?;
      references
          .putIfAbsent(
            asset,
            () => _WebLicenseReference(
              package: parent ?? path.basenameWithoutExtension(asset),
              asset: asset,
              licenseId: claim.license["id"] as String,
              subNoticeOf: parent,
            ),
          )
          .add(claim);
    }
    return references;
  }

  /// Renders the provenance header shown above [reference]'s license text.
  ///
  /// Blocks are blank-line separated because [LicenseEntryWithLineBreaks] joins
  /// consecutive lines of equal indentation into a single paragraph.
  String _webLicenseNotice(_WebLicenseReference reference) {
    final blocks = <String>[
      "Included in the umacapture web build (inventory: $webDepsManifest).",
      ...reference.componentLines,
      "License: ${reference.licenseId}",
    ];
    if (reference.subNoticeOf != null) {
      blocks.add(
        "Disclosed under ${reference.subNoticeOf} because it is bundled inside it, and "
        "${reference.subNoticeOf}'s own license text does not reproduce this notice.",
      );
    }
    final sourceForm = reference.sourceForm;
    if (isMozillaPublicLicense(reference.licenseId) && sourceForm != null) {
      blocks.add(
        "Source form (MPL-2.0 section 3.2): the file(s) above are shipped unmodified and hash-pinned in "
        "$webDepsManifest. The corresponding source is ${sourceForm["url"]} (sha256 ${sourceForm["sha256"]}), "
        "also published at ${sourceForm["git_url"]}.",
      );
    }
    return blocks.join("\n\n");
  }

  /// Builds the license disclosure for everything this repository places under `web/`.
  ///
  /// The tree is treated as a closed world: every pinned file that exists must hash to its
  /// pin, every file that exists must be pinned or first-party, every referenced license text
  /// must be committed, and no file that exists may be undisclosable (a null `license.asset`)
  /// or knowingly misplaced (a `relocation_required` block). Any violation throws, so the
  /// artifact is never written from a tree that would publish something undisclosed.
  ///
  /// Those checks run over whatever is on disk, always. Only the emitted `status` depends on
  /// the gitignored `provisioned_root`: a checkout that never provisioned it is an ordinary
  /// Windows-only checkout rather than an error, and says `not_provisioned` -- but it still
  /// ships the committed part of `web/`, so skipping verification there would let exactly
  /// the files a fresh clone carries drift unnoticed.
  ///
  /// `verified` therefore requires *every* `provisioned_root` entry, not any of them: a run of
  /// `uv run tool/fetch_web_deps.py` alone leaves `wasm/ort/*` present and the `origin: in-tree`
  /// recognition core absent, and calling that tree verified is what would let
  /// `tool/build_web.sh --require-verified` ship a web bundle that cannot start. That partial
  /// state is legitimate (CI is always in it), so it gets its own status rather than an error.
  ///
  /// The manifest is read through [BuildStep.readAsString] so it is a tracked input: bumping
  /// a pin re-runs this builder. The pinned bytes themselves are hashed with `dart:io`
  /// instead, because routing a 13 MB Wasm backend through the asset graph would make every
  /// build read and digest it.
  Future<String> _buildWebLicenseInfo(BuildStep buildStep) async {
    final manifestId = AssetId(buildStep.inputId.package, webDepsManifest);
    final manifest = parseWebDepsManifest(await buildStep.readAsString(manifestId));
    final files = (manifest["files"] as Map).cast<String, dynamic>();
    await _trackWebAssets(buildStep, files.keys);
    final (present, absent) = partitionWebFiles(files);

    final problems = await verifyWebTree(manifest, licenses: true);
    if (problems.isNotEmpty) {
      throw Exception("web/ does not match $webDepsManifest:\n  ${problems.join("\n  ")}");
    }

    final references = _groupWebLicenses(webLicenseClaims(present));
    final sorted = references.values.toList()..sort((a, b) => a.asset.compareTo(b.asset));
    return jsonEncoder.convert({
      "status": webProvisioningStatus(manifest, absent),
      "status_scope":
          "Every pinned file present under web/ hashes to its pin, nothing unpinned or "
          "unlisted sits in the tree, and every license text referenced below is committed. "
          "The components listed as 'statically linked into' a file are recorded from the "
          "inputs of the build that produced it; they are not derived from the binary.",
      "manifest_version": manifest["manifest_version"],
      "generated_from": webDepsManifest,
      "absent": absent,
      "entries": [
        for (final reference in sorted)
          {
            "package": reference.package,
            "asset": reference.asset,
            "license_id": reference.licenseId,
            "sub_notice_of": reference.subNoticeOf,
            "components": reference.componentLines,
            "notice": _webLicenseNotice(reference),
          },
      ],
    });
  }

  FutureOr<String> _buildVersionInfo(String inputPath) async {
    final pubspec = loadYaml(File(inputPath).readAsStringSync());
    final String version = pubspec['version'];

    final parsed = Version.parse(version).toString();
    if (version != parsed) {
      throw FormatException("Illegal version string. pubspec=$version, parsed=$parsed");
    }

    final info = {"version": version};
    return jsonEncoder.convert(info);
  }

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    if (buildStep.inputId.pathSegments.last != "pubspec.yaml") {
      throw ArgumentError.value(buildStep.inputId.toString());
    }
    for (final output in buildStep.allowedOutputs) {
      if (output.pathSegments.last == "version_info.json") {
        buildStep.writeAsString(output, _buildVersionInfo(buildStep.inputId.path));
      } else if (output.pathSegments.last == "license_info.json") {
        buildStep.writeAsString(output, _buildLicenseInfo(buildStep.inputId.path));
      } else if (output.pathSegments.last == "additional_license_info.json") {
        buildStep.writeAsString(output, _buildAdditionalLicenseInfo());
      } else if (output.pathSegments.last == "web_license_info.json") {
        // Awaited before writing: a failed closed-world check must leave the previous
        // artifact untouched rather than replace it with a half-verified one.
        await buildStep.writeAsString(output, await _buildWebLicenseInfo(buildStep));
      } else {
        throw ArgumentError.value(output.toString());
      }
    }
  }

  @override
  Map<String, List<String>> get buildExtensions {
    return {
      "pubspec.yaml": [
        "assets/version_info.json",
        "assets/license_info.json",
        "assets/additional_license_info.json",
        "assets/web_license_info.json",
      ],
    };
  }
}

/// One disclosed license text, the platforms that carry it, and why.
class _Disclosure {
  const _Disclosure({
    required this.package,
    required this.asset,
    required this.platforms,
    this.components = const [],
    this.shippedFiles = const [],
    this.subNoticeOf,
    this.extraNotice,
  });

  /// Name the license page groups this text under.
  final String package;

  /// Repository-relative path of the committed license text.
  final String asset;

  /// Build outputs that carry this component, as `lib/main.dart` names them.
  final List<String> platforms;

  /// One line per component, naming what carries it.
  final List<String> components;

  /// Redistributed files this entry claims, matched against what the Windows build copies.
  final List<String> shippedFiles;

  /// Package this text is a sub-notice of, or `null` when it stands alone.
  final String? subNoticeOf;

  /// Terms this license imposes beyond reproducing its text.
  final String? extraNotice;

  String get _notice {
    final built = platforms.map((e) => e == "web" ? "web" : "Windows").join(" and ");
    return [
      "Included in the umacapture $built build${platforms.length > 1 ? "s" : ""}.",
      ...components,
      if (subNoticeOf != null)
        "Disclosed under $subNoticeOf because it is bundled inside it, and $subNoticeOf's own "
            "license text does not reproduce this notice.",
      ?extraNotice,
    ].join("\n\n");
  }

  Map<String, dynamic> toJson() => {
    "package": package,
    "asset": asset,
    "platforms": platforms,
    "sub_notice_of": subNoticeOf,
    "components": components,
    "shipped_files": shippedFiles,
    "notice": _notice,
  };
}

/// The DLLs a Windows build copies next to `umacapture.exe`, split by who owns them.
class BundledWindowsDlls {
  const BundledWindowsDlls({required this.thirdParty, required this.system, required this.systemDirectory});

  /// File names this repository redistributes, each of which needs a disclosure.
  final Set<String> thirdParty;

  /// File names taken from [systemDirectory], covered by their own redistribution terms.
  final Set<String> system;

  /// Directory the operating-system redistributables are copied out of.
  final String systemDirectory;

  /// The single redistributed file name containing [fragment].
  ///
  /// Throws when it is absent or ambiguous, so a renamed or dropped DLL is a build failure
  /// rather than a notice that quietly names a file the installer no longer carries.
  String matching(String fragment) => thirdParty.singleWhere(
    (e) => e.contains(fragment),
    orElse: () => throw Exception("no single redistributed DLL matches '$fragment' in $thirdParty"),
  );
}

/// Reads the DLL list out of the text of `windows/runner/CMakeLists.txt`.
///
/// The list is *counted from the build file* rather than restated by hand, because a hand-kept
/// list is exactly what goes stale when the next DLL is added. Variables are resolved from the
/// file's own `set(NAME "value")` assignments, so the disclosure follows a version bump.
///
/// Only the Release/Profile branch of each `$<CONFIG:...>` generator expression is taken: the
/// shipped installer is a `flutter build windows` (Release) output, and the Debug branch names
/// the same components under a `d`-suffixed file name.
BundledWindowsDlls parseBundledWindowsDlls(String cmakeLists) {
  final variables = <String, String>{};
  final assignment = RegExp(r'^[ \t]*set\([ \t]*([A-Za-z_][A-Za-z_0-9]*)[ \t]+"([^"]*)"[ \t]*\)', multiLine: true);
  for (final match in assignment.allMatches(cmakeLists)) {
    variables[match.group(1) ?? ""] = match.group(2) ?? "";
  }
  final reference = RegExp(r'\$\{([A-Za-z_][A-Za-z_0-9]*)\}');
  String expand(String value) {
    var result = value;
    // Bounded rather than recursive: `OpenCV_RELEASE_DLL` -> `OpenCV_DLL_PREFIX` -> `OpenCV_DIR`
    // is three levels deep, and a bound is what keeps a self-referential assignment from hanging
    // the build instead of failing the coverage check below.
    for (var i = 0; i < 8 && result.contains(r'${'); i++) {
      result = result.replaceAllMapped(reference, (m) => variables[m.group(1)] ?? (m.group(0) ?? ""));
    }
    return result;
  }

  final systemDirectory = expand(variables["SYSTEM_DLL_DIR"] ?? "");
  final thirdParty = <String>{};
  final system = <String>{};
  for (var line in cmakeLists.split("\n")) {
    line = line.split("#").first.trim();
    // `set(NAME "…dll")` defines a name; it does not copy anything. Only the items *inside* the
    // multi-line `set(DEPENDENT_DLLS …)` block and the `add_custom_command` copies do.
    if (line.startsWith("set(")) {
      continue;
    }
    for (var token in line.split(RegExp(r'\s+'))) {
      token = token.replaceAll('"', "");
      // The copy destination, not a source: it names where a file lands, not what it contains.
      // The Debug branch names the same components under a `d`-suffixed file name.
      if (token.contains(r"$<TARGET_FILE_DIR") || token.contains(r"$<$<CONFIG:Debug>:")) {
        continue;
      }
      token = token.replaceAll(r"$<${RELEASE_OR_PROFILE}:", "").replaceAll(">", "");
      // Expanded before the extension is looked at: most items reach this loop as a bare
      // `${OpenCV_RELEASE_DLL}`, which carries no file name until the variables are resolved.
      final resolved = expand(token);
      if (!resolved.endsWith(".dll")) {
        continue;
      }
      final name = resolved.split("/").last;
      (systemDirectory.isNotEmpty && resolved.startsWith(systemDirectory) ? system : thirdParty).add(name);
    }
  }
  return BundledWindowsDlls(thirdParty: thirdParty, system: system, systemDirectory: systemDirectory);
}

/// The disclosure of a single license text, and every claim that points at it.
class _WebLicenseReference {
  _WebLicenseReference({
    required this.package,
    required this.asset,
    required this.licenseId,
    required this.subNoticeOf,
  });

  /// Name the license page groups this text under.
  final String package;

  /// Repository-relative path of the committed license text.
  final String asset;

  /// SPDX-ish id as recorded in the manifest.
  final String licenseId;

  /// Package this text is a sub-notice of, or `null` when it stands alone.
  final String? subNoticeOf;

  /// Shipped files per `(component, relation)`, so files sharing a component collapse
  /// into one line instead of repeating the component name for each of them.
  final Map<(String, WebClaimRelation), List<String>> _coverage = {};

  /// The first source form seen; only MPL texts render it, and those come from one node.
  Map<String, dynamic>? sourceForm;

  void add(WebLicenseClaim claim) {
    _coverage.putIfAbsent((claim.component, claim.relation), () => []).add(claim.file);
    sourceForm ??= claim.sourceForm;
  }

  /// One line per component, naming how well the relation is evidenced.
  ///
  /// The qualifier matters: "shipped as" is backed by a SHA-256 pin over the exact bytes,
  /// while "statically linked into" is read off the build inputs. Rendering both in the same
  /// voice would overstate the second.
  List<String> get componentLines => [
    for (final entry in _coverage.entries)
      "${entry.key.$1} -- ${entry.key.$2.phrase} ${entry.value.join(", ")} (${entry.key.$2.qualifier})",
  ];
}
