// Tests for the clipboard capability seam.
//
// `ClipboardAlt` used to branch on `kIsWeb` inside its methods and carried two copies of the
// candidate scan: a synchronous `existsSync` loop for desktop and an asynchronous one for web. The
// difference is now expressed as the capabilities declared by `clipboard_image_writer.dart`, and
// the scan exists once. These tests run on the native half of the seam (the VM), with a filesystem
// backend whose synchronous surface throws exactly as the web one does — so a scan that reached for
// `existsSync` again would fail here rather than only in a browser.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/clipboard_capability_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/clipboard_image_writer.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/web_like_fs_backend.dart';

final _refProvider = Provider<RefBase>((ref) => ref.base);

void main() {
  late Directory tempRoot;
  late FsBackend originalBackend;
  late ProviderContainer container;
  late RefBase ref;

  late Future<void> Function() closeHive;

  setUpAll(() async {
    loadAppTranslations();
    // The paste-image mode is a persisted setting, so the native write path reads the settings box.
    closeHive = await initHiveForTest(['settings']);
  });

  tearDownAll(() => closeHive());

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_clipboard_capability_test');
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
    // No platform controller: the write itself cannot succeed here, which keeps these tests about
    // the candidate scan and the capability gate rather than about the OS clipboard.
    container = ProviderContainer.test(overrides: [platformControllerProvider.overrideWithValue(null)]);
    ref = container.read(_refProvider);
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  FilePath filePath(String name) => FilePath('${tempRoot.path}${Platform.pathSeparator}$name');

  test('the native seam needs no gesture and can write file references', () {
    expect(clipboardWriteNeedsGesture, isFalse);
    expect(clipboardSupportsFileReferences, isTrue);
  });

  test('reports the candidates as missing without touching the synchronous filesystem', () async {
    var missingCalls = 0;
    final ok = await ClipboardAlt.pasteFirstAvailableImage(ref, [
      filePath('a.png'),
      filePath('b.png'),
    ], onMissing: () => missingCalls++);

    expect(ok, isFalse);
    // The gesture gate is a browser capability, so a userInitiated: false call still runs the scan
    // here; if it did not, onMissing could never fire.
    expect(missingCalls, 1);
  });

  test('finds a later candidate through the asynchronous surface', () async {
    final second = filePath('b.png');
    File(second.path).writeAsBytesSync(const [1, 2, 3]);
    var missingCalls = 0;

    final ok = await ClipboardAlt.pasteFirstAvailableImage(ref, [
      filePath('a.png'),
      second,
    ], onMissing: () => missingCalls++);

    // The write cannot succeed without a platform controller, but the scan must have found the file
    // rather than reporting it missing.
    expect(ok, isFalse);
    expect(missingCalls, 0);
  });

  test('pasteFile stats the path asynchronously and reports a missing file', () async {
    expect(await ClipboardAlt.pasteFile(ref, filePath('gone.png')), isFalse);
  });
}
