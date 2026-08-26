import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
