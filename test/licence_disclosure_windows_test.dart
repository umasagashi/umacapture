import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:umacapture/distribution_info.dart';
import 'package:umacapture/main.dart';

/// Asserts that the Windows installer's third-party components all reach the licence page.
///
/// The set of components is **counted from `windows/runner/CMakeLists.txt`**, never restated
/// here: a hand-written list of "the five DLLs we ship" is exactly what stops noticing the
/// sixth. `DistributionInfoBuilder` refuses to emit the artifact when a redistributed DLL is
/// unclaimed, so a regeneration would fail loudly -- these tests are what catches the other
/// half, where `CMakeLists.txt` grew a DLL and codegen was never re-run, leaving a committed
/// artifact that no longer describes the build.
void main() {
  // Read in setUpAll, never at the top of main(): every input here is a file, and a file read that
  // runs while the suite is being *loaded* turns a missing input into a load failure -- no test name,
  // no reason string, and none of the assertions below ever run. From setUpAll the same breakage is
  // one named red entry carrying the path it could not open. The paths are relative, so the suite
  // requires `flutter test` to run with the package root as the working directory, as it does.
  late BundledWindowsDlls bundled;
  late List<Map<String, dynamic>> nativeEntries;
  late List<Map<String, dynamic>> webEntries;

  setUpAll(() {
    final cmakeLists = File(DistributionInfoBuilder.windowsRunnerCMakeLists).readAsStringSync();
    bundled = parseBundledWindowsDlls(cmakeLists);

    final nativeIndex =
        jsonDecode(File("assets/additional_license_info.json").readAsStringSync()) as Map<String, dynamic>;
    nativeEntries = (nativeIndex["entries"] as List).cast<Map<String, dynamic>>();
    final webIndex = jsonDecode(File("assets/web_license_info.json").readAsStringSync()) as Map<String, dynamic>;
    webEntries = (webIndex["entries"] as List).cast<Map<String, dynamic>>();
  });

  group("the DLL scan itself", () {
    // Positive control. Every assertion below is of the form "everything found is disclosed",
    // which a scan that finds nothing passes trivially. These name what the scan has to see,
    // by substring rather than by full file name, so an OpenCV version bump does not have to
    // edit a test to stay honest.
    test("finds the redistributed DLLs, by the component each one carries", () {
      expect(bundled.thirdParty.where((e) => e.contains("opencv_world")), hasLength(1));
      expect(bundled.thirdParty.where((e) => e.contains("opencv_videoio_ffmpeg")), hasLength(1));
      expect(bundled.thirdParty.where((e) => e.contains("onnxruntime")), hasLength(1));
      expect(bundled.thirdParty, hasLength(greaterThanOrEqualTo(3)));
    });

    test("separates the operating-system redistributables from ours", () {
      // The System32 copies are excluded from the disclosure by *where they come from*, not by
      // name. If that classification silently collapsed, every DLL would land in one bucket --
      // either demanding notices for msvcp140.dll or waving ours through.
      expect(bundled.systemDirectory, isNotEmpty);
      expect(bundled.system, isNotEmpty);
      expect(bundled.system.intersection(bundled.thirdParty), isEmpty);
      expect(bundled.system.any((e) => e.contains("msvcp140")), isTrue);
    });
  });

  group("the committed disclosure", () {
    test("claims every DLL the Windows build redistributes", () {
      final claimed = {for (final entry in nativeEntries) ...(entry["shipped_files"] as List).cast<String>()};
      expect(
        bundled.thirdParty.difference(claimed),
        isEmpty,
        reason:
            "windows/runner/CMakeLists.txt redistributes a DLL that assets/additional_license_info.json "
            "does not disclose; re-run 'dart run build_runner build --force-jit' after adding an entry",
      );
    });

    test("claims no file the Windows build does not redistribute", () {
      for (final entry in nativeEntries) {
        for (final file in (entry["shipped_files"] as List).cast<String>()) {
          expect(bundled.thirdParty, contains(file), reason: "${entry["package"]} claims a file nothing copies");
        }
      }
    });

    test("names, in every 'statically linked into' line, a file that is actually shipped", () {
      final lines = [for (final entry in nativeEntries) ...(entry["components"] as List).cast<String>()];
      final linked = lines.where((e) => e.contains("statically linked into"));
      expect(linked, isNotEmpty); // positive control for the filter below
      for (final line in linked) {
        expect(
          bundled.thirdParty.any(line.contains),
          isTrue,
          reason: "'$line' names a container the Windows build does not ship",
        );
      }
    });

    test("points every entry at a committed licence text", () {
      for (final entry in [...nativeEntries, ...webEntries]) {
        expect(File(entry["asset"] as String).existsSync(), isTrue, reason: "${entry["asset"]} is not committed");
      }
    });

    test("reproduces the LGPL terms of the FFmpeg plugin it ships", () {
      // The one component whose licence obliges more than a mention. Keyed on the DLL rather
      // than on a package name, so renaming the entry cannot quietly drop it.
      final plugin = bundled.matching("opencv_videoio_ffmpeg");
      final entries = nativeEntries.where((e) => (e["shipped_files"] as List).contains(plugin));
      expect(entries, hasLength(1), reason: "$plugin is shipped but nothing discloses it");
      final text = File(entries.single["asset"] as String).readAsStringSync();
      expect(text, contains("GNU LESSER GENERAL PUBLIC LICENSE"));
      expect(entries.single["notice"], contains("Lesser General Public License"));
    });
  });

  group("the disclaimers about the DLL's recorded build information", () {
    // Several lines make a checkable factual claim about a file this repository redistributes:
    // that the DLL's own recorded build information does not name the component. Read that
    // information back out of the binary instead of taking the claim's word for it -- flatbuffers
    // carried this wording while `Flatbuffers: builtin/3rdparty (25.9.23)` sat in the block.
    //
    // Which entries make the claim is decided by the phrase in the committed artifact, never by a
    // list of package names here: the next component to be moved off the claim must not need this
    // test edited to stay honest.
    const claim = "recorded build information does not name it";

    late File dll;
    late String? buildInformation;

    setUpAll(() {
      dll = File(openCvReleaseDllPath(File(DistributionInfoBuilder.windowsRunnerCMakeLists).readAsStringSync()));
      buildInformation = dll.existsSync() ? openCvBuildInformation(dll.readAsBytesSync()) : null;
    });

    test("reads the build information out of the shipped DLL", () {
      // Positive control for the two assertions below, both of which a scan that finds nothing
      // would pass trivially. The DLL is gitignored and provisioned by tool/fetch_deps.py, so on
      // a machine that has not provisioned it this skips rather than failing.
      if (!dll.existsSync()) {
        markTestSkipped("${dll.path} is not provisioned on this machine");
        return;
      }
      expect(buildInformation, isNotNull, reason: "${dll.path} carries no OpenCV build information block");
      expect(buildInformation, contains("Other third-party libraries:"));
    });

    test("names no component whose line says it is not named there", () {
      final information = buildInformation;
      if (information == null) {
        markTestSkipped("${dll.path} is not provisioned on this machine");
        return;
      }
      final disclaiming = <String>[];
      final rest = <String>[];
      for (final entry in nativeEntries) {
        final package = entry["package"] as String;
        final lines = (entry["components"] as List).cast<String>();
        (lines.any((line) => line.contains(claim)) ? disclaiming : rest).add(package);
      }
      expect(disclaiming, isNotEmpty, reason: "nothing makes the claim this test checks");
      // Positive control for the matcher: it has to be able to find a name that is in there.
      expect(rest.where((package) => namedInBuildInformation(information, package)), isNotEmpty);
      for (final package in disclaiming) {
        expect(
          namedInBuildInformation(information, package),
          isFalse,
          reason:
              "$package says ${dll.path}'s build information does not name it, but that "
              "information names it; rewrite the line in lib/distribution_info.dart to say what "
              "is recorded, then re-run 'dart run build_runner build --force-jit'",
        );
      }
    });
  });

  group("platform selection", () {
    List<Map<String, dynamic>> select(String platform) =>
        platformDisclosures(nativeEntries: nativeEntries, webEntries: webEntries, platform: platform);

    test("gives the desktop build everything the Windows installer carries", () {
      final assets = {for (final entry in select("windows")) entry["asset"] as String};
      for (final entry in nativeEntries) {
        if ((entry["platforms"] as List).contains("windows")) {
          expect(assets, contains(entry["asset"]));
        }
      }
      expect(assets, contains(nativeEntries.firstWhere((e) => e["package"] == "ffmpeg")["asset"]));
    });

    test("keeps the web-only components off the desktop licence page", () {
      // Negative control for the over-disclosure this branch already fixed: the web index
      // describes files under web/ and components linked into the Wasm core, none of which a
      // Windows installer contains. Derived from the indexes, not from a list of package names.
      final nativeAssets = {for (final entry in nativeEntries) entry["asset"] as String};
      final webOnly = {
        for (final entry in webEntries)
          if (!nativeAssets.contains(entry["asset"])) entry["asset"] as String,
      };
      expect(webOnly, isNotEmpty); // positive control: there is something to keep out
      final desktop = select("windows");
      expect({for (final entry in desktop) entry["asset"] as String}.intersection(webOnly), isEmpty);
      expect(desktop.every((e) => !(e["notice"] as String).contains("umacapture_core.wasm")), isTrue);
    });

    test("keeps the desktop-only components off the web licence page", () {
      final web = select("web");
      expect(web.length, greaterThan(webEntries.length)); // the cross-platform asset notices
      for (final entry in web) {
        final files = (entry["shipped_files"] as List?)?.cast<String>() ?? const <String>[];
        expect(files.where(bundled.thirdParty.contains), isEmpty, reason: "${entry["package"]} is desktop-only");
      }
      for (final entry in webEntries) {
        expect(web, contains(entry));
      }
    });
  });
}

/// The OpenCV release DLL, resolved out of `windows/runner/CMakeLists.txt`.
///
/// Spelling the path here would make a version, architecture or toolset bump turn this guard into
/// a silent skip -- the file would simply no longer be there. Those three live in that CMakeLists
/// as variables, so the path is rebuilt from them; if the variable disappears the caller fails
/// rather than skipping.
String openCvReleaseDllPath(String cmakeLists) {
  final variables = <String, String>{
    "CMAKE_CURRENT_LIST_DIR": path.dirname(DistributionInfoBuilder.windowsRunnerCMakeLists),
  };
  for (final match in RegExp(r'^\s*set\(\s*(\w+)\s+"([^"]*)"\s*\)', multiLine: true).allMatches(cmakeLists)) {
    variables[match.group(1)!] = match.group(2)!;
  }
  final template = variables["OpenCV_RELEASE_DLL"];
  expect(template, isNotNull, reason: "windows/runner/CMakeLists.txt no longer sets OpenCV_RELEASE_DLL");
  var resolved = template!;
  final reference = RegExp(r'\$\{(\w+)\}');
  // Bounded rather than "until nothing changes": a CMakeLists that referred a variable to itself
  // would otherwise hang the suite instead of failing it.
  for (var round = 0; round < 8 && reference.hasMatch(resolved); round++) {
    resolved = resolved.replaceAllMapped(reference, (m) => variables[m.group(1)!] ?? m.group(0)!);
  }
  expect(resolved, isNot(contains(r'${')), reason: "unresolved CMake variable in $resolved");
  return path.normalize(resolved);
}

/// The `General configuration for OpenCV` block OpenCV compiles into its own binary, or null when
/// the bytes carry none. It is a NUL-terminated C string, so the terminator bounds it.
String? openCvBuildInformation(Uint8List bytes) {
  final marker = latin1.encode("General configuration for OpenCV");
  final start = _indexOfBytes(bytes, marker);
  if (start < 0) {
    return null;
  }
  var end = start;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return latin1.decode(bytes.sublist(start, end));
}

/// Whether [information] names [component] as a word.
///
/// Word-bounded on purpose: `ade` occurs inside the block's own `Shaders:` line, and a substring
/// test would report every disclaimer about it as a violation.
bool namedInBuildInformation(String information, String component) =>
    RegExp("(?<![A-Za-z0-9])${RegExp.escape(component)}(?![A-Za-z0-9])", caseSensitive: false).hasMatch(information);

int _indexOfBytes(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        continue outer;
      }
    }
    return i;
  }
  return -1;
}
