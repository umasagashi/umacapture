// The automatic module check decides through one pure function on both
// platforms: `evaluateModuleUpdate`. The desktop loader and the web boot differ
// only in how they apply its outcome, so a condition added to the decision
// reaches both of them or neither.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/module_update_verdict_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:version/version.dart';

final _goodArchive = ModuleArchiveRef("modules/${"a" * 64}.zip", "a" * 64, 10386424);

ModuleVersionRawData _versionInfo(
  String recognizerVersion, {
  String applicationVersion = "0.0.0",
  bool pinVersion = false,
  ModuleArchiveRef? moduleArchive,
}) {
  return ModuleVersionRawData(
    "1.0.0",
    "jp",
    recognizerVersion,
    "2021-02-24T00:00:00+0900",
    applicationVersion,
    pinVersion,
    moduleArchive,
  );
}

/// A published pointer: it names [_goodArchive] unless [moduleArchive] or [noArchive] says otherwise.
ModuleVersionRawData _latest(
  String recognizerVersion, {
  String applicationVersion = "0.0.0",
  ModuleArchiveRef? moduleArchive,
  bool noArchive = false,
}) {
  return _versionInfo(
    recognizerVersion,
    applicationVersion: applicationVersion,
    moduleArchive: noArchive ? null : (moduleArchive ?? _goodArchive),
  );
}

ModuleUpdateVerdict _evaluate({required ModuleVersionRawData? local, required ModuleVersionRawData? latest}) {
  return evaluateModuleUpdate(local: local, latest: latest, appVersion: Version(1, 2, 3));
}

void main() {
  group('evaluateModuleUpdate: pin / equal / app-version orders are unchanged', () {
    test('an installed module that matches the published one is left alone', () {
      final verdict = _evaluate(
        local: _versionInfo("2026-08-01T00:00:00+0900"),
        latest: _latest("2026-08-01T00:00:00+0900"),
      );

      expect(verdict, isA<ModuleUpToDate>());
    });

    test('a published module with a different version is fetched', () {
      final verdict = _evaluate(
        local: _versionInfo("2026-08-01T00:00:00+0900"),
        latest: _latest("2026-08-04T00:00:00+0900"),
      );

      expect(verdict, isA<ModuleUpdateAvailable>());
    });

    test('a version check that could not be completed is reported, not assumed to be up to date', () {
      // The distinction the dashboard banner depends on: "nothing to do" and
      // "could not find out" must not collapse into the same outcome.
      final verdict = _evaluate(local: _versionInfo("2026-08-01T00:00:00+0900"), latest: null);

      expect(verdict, isA<ModuleUpdateLatestUnavailable>());
    });

    test('a rollback counts as an update', () {
      final verdict = _evaluate(
        local: _versionInfo("2026-08-04T00:00:00+0900"),
        latest: _latest("2026-08-01T00:00:00+0900"),
      );

      expect(verdict, isA<ModuleUpdateAvailable>());
    });

    test('a locally pinned module is not replaced', () {
      final verdict = _evaluate(
        local: _versionInfo("2026-08-01T00:00:00+0900", pinVersion: true),
        latest: _latest("2026-08-04T00:00:00+0900"),
      );

      expect(verdict, isA<ModuleUpdatePinned>());
    });

    test('a pinned module is decided before the published version is even consulted', () {
      // `ModuleUpdateLatestUnavailable` is what raises the dashboard's
      // manual-install banner and the warning toast. A user who pinned the
      // module is not waiting for an update, so an unreachable pointer has
      // nothing to tell them.
      final verdict = _evaluate(local: _versionInfo("2026-08-01T00:00:00+0900", pinVersion: true), latest: null);

      expect(verdict, isA<ModuleUpdatePinned>());
    });

    test('a module that needs a newer app build than this one is not applied', () {
      final verdict = _evaluate(
        local: _versionInfo("2026-08-01T00:00:00+0900"),
        latest: _latest("2026-08-04T00:00:00+0900", applicationVersion: "9.9.9"),
      );

      expect(verdict, isA<ModuleUpdateRequiresNewerApp>());
    });

    test('a published module whose required app version is unreadable is not applied', () {
      // `application_version` is hand-written into version_info.json. When it is
      // not semver the requirement is unknown, and an unknown requirement has
      // not been shown to be met.
      for (final broken in ["", "2024.5", "latest", "１.２.３"]) {
        final verdict = _evaluate(
          local: _versionInfo("2026-08-01T00:00:00+0900"),
          latest: _latest("2026-08-04T00:00:00+0900", applicationVersion: broken),
        );

        expect(verdict, isA<ModuleUpdateRequiresNewerApp>(), reason: 'application_version=$broken');
      }
    });

    test('a readable requirement at or below this app build still updates', () {
      // The control for the case above: "unreadable" must not be widened into
      // "anything I did not expect", or every update would stop.
      for (final ok in ["0.0.0", "1.2.3"]) {
        final verdict = _evaluate(
          local: _versionInfo("2026-08-01T00:00:00+0900"),
          latest: _latest("2026-08-04T00:00:00+0900", applicationVersion: ok),
        );

        expect(verdict, isA<ModuleUpdateAvailable>(), reason: 'application_version=$ok');
      }
    });

    test('an install with no module yet takes the published one', () {
      final verdict = _evaluate(local: null, latest: _latest("2026-08-04T00:00:00+0900"));

      expect(verdict, isA<ModuleUpdateAvailable>());
    });
  });

  group('evaluateModuleUpdate: the archive reference', () {
    test('latest without module_archive is checkFailed', () {
      // A pointer that names no archive gives nothing a download could be checked
      // against, so it must not fall back to some other archive.
      final verdict = _evaluate(
        local: _versionInfo("2026-08-01T00:00:00+0900"),
        latest: _latest("2026-08-04T00:00:00+0900", noArchive: true),
      );

      expect(verdict, isA<ModuleUpdateLatestUnavailable>());
    });

    test('malformed sha256/size is checkFailed', () {
      final malformed = [
        ModuleArchiveRef("modules/x.zip", "A" * 64, 1), // upper case
        ModuleArchiveRef("modules/x.zip", "a" * 63, 1), // short
        ModuleArchiveRef("modules/x.zip", "g" * 64, 1), // not hex
        ModuleArchiveRef("modules/x.zip", "a" * 64, 0), // empty archive
        ModuleArchiveRef("modules/x.zip", "a" * 64, -1),
      ];
      for (final archive in malformed) {
        final verdict = _evaluate(
          local: _versionInfo("2026-08-01T00:00:00+0900"),
          latest: _latest("2026-08-04T00:00:00+0900", moduleArchive: archive),
        );

        expect(verdict, isA<ModuleUpdateLatestUnavailable>(), reason: '${archive.sha256}/${archive.size}');
      }
    });

    test('a well-formed reference is carried to the update verdict', () {
      final verdict = _evaluate(
        local: _versionInfo("2026-08-01T00:00:00+0900"),
        latest: _latest("2026-08-04T00:00:00+0900", moduleArchive: _goodArchive),
      );

      expect(verdict, isA<ModuleUpdateAvailable>());
      expect((verdict as ModuleUpdateAvailable).archive, same(_goodArchive));
    });

    test('a pinned module stays pinned even when the pointer names no archive', () {
      final verdict = _evaluate(
        local: _versionInfo("2026-08-01T00:00:00+0900", pinVersion: true),
        latest: _latest("2026-08-04T00:00:00+0900", noArchive: true),
      );

      expect(verdict, isA<ModuleUpdatePinned>());
    });
  });

  group('both automatic loaders decide through evaluateModuleUpdate', () {
    // The loaders are provider bodies that need a Ref and the network, so the VM
    // suite cannot run them. What it can check is that neither carries its own
    // copy of the decision -- two copies is how a new condition reaches one
    // platform only.
    final source = File('lib/src/core/version_check.dart').readAsStringSync();

    String body(String signature, String next) {
      final start = source.indexOf(signature);
      expect(start, greaterThan(0), reason: '$signature was renamed; update this test');
      final end = source.indexOf(next, start);
      expect(end, greaterThan(start), reason: 'the declaration after $signature moved; update this test');
      return source.substring(start, end);
    }

    for (final (signature, next) in [
      ('Future<ModuleVersion?> _refreshWebModule(', 'Future<void> _downloadAndExtractModuleToOpfs('),
      ('final moduleVersionLoader = FutureProvider', 'class AppVersionCheckResult'),
    ]) {
      test(signature, () {
        final loader = body(signature, next);

        expect(loader, contains('evaluateModuleUpdate('));
        expect(loader, isNot(contains('pinVersion')));
        expect(loader, isNot(contains('applicationVersion')));
        expect(loader, isNot(contains('recognizerVersion ==')));
      });
    }
  });
}
