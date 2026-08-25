// The export-completed toast must not offer "open the containing folder" where
// there is no OS file manager. `PathEntity.launch()` was made a no-op there, so
// without this gate the toast stays tappable and does nothing at all -- the same
// defect the other five reveal sites were fixed for.
//
// Scope note: the VM reports `kIsWeb == false`, so the `isWeb()` term of
// `CurrentPlatform.canRevealInFileManager()` cannot be exercised here. These
// tests drive the other term (`isDesktop()`), which reaches the same false
// branch of the same gate -- see test/reveal_in_file_manager_test.dart.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/export_toast_reveal_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/core/notification_controller.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  FilePath exportedPath() => FilePath(File('exported.csv').absolute.path);

  test('offers the reveal callback where there is a file manager', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(revealExportedFileCallback(ExportResult.fileWritten(exportedPath())), isNotNull);
  });

  test('withholds the reveal callback where there is none', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(revealExportedFileCallback(ExportResult.fileWritten(exportedPath())), isNull);
  });

  test('withholds the reveal callback for a download, which has no path', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(revealExportedFileCallback(const ExportResult.downloadRequested('exported.csv')), isNull);
  });
}
