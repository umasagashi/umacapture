// The success toast names what was copied.
//
//   .fvm/flutter_sdk/bin/flutter test test/clipboard_copy_subject_test.dart
//
// `ClipboardAlt` had one success sentence — 「クリップボードに画像をコピーしました。」
// — and handed it to every caller. The storage view's folder button
// (`storage_tree.dart` の `_CopyEntitySlot` → `ClipboardAlt.pasteEntity`) puts a
// *directory* on the clipboard, and reported it as an image.
//
// Two things are asserted, and they fail for different reasons on purpose:
//
//  * the **subject** each caller reports, read back off the toast stream. The
//    image callers are here as the positive control — they were correct before
//    this stage and have to stay correct, so collapsing the three sentences back
//    into one turns the file and folder cases red while leaving the image case
//    green.
//  * the **expected sentences are literals out of `ja.json`** (`appSentenceAt`),
//    never `'…success_file'.tr()`. `.tr()` renders a key it cannot resolve as the
//    key itself, so a test that built its expectation the way the code does would
//    agree with a deleted entry — and with the very interpolation the switch in
//    `ClipboardAlt._successKey` exists to rule out.
//
// WHAT THIS SUITE DOES NOT REACH. The OS clipboard: the `pasteboard` channel is
// mocked, so nothing here says a paste in Explorer yields the folder. And the
// browser: this runs on the VM with the native half of the seam compiled in, so
// `clipboard_image_writer_web.dart` is never executed.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

/// The channel `pasteboard` talks to on the native host.
const _pasteboardChannel = MethodChannel('pasteboard');

late Directory _root;

String _abs(String relative) =>
    '${_root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

void _write(String relative, int bytes) {
  final file = File(_abs(relative));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

/// Collects the toasts published while a case runs.
///
/// `Toaster.show` publishes into a module-level broadcast stream, so a container
/// that is not the one under test still sees them.
class _ToastObserver {
  _ToastObserver() {
    _container = ProviderContainer(retry: (_, _) => null);
    _container.listen(plainToastEventProvider, (_, next) => next.whenData(seen.add));
    addTearDown(_container.dispose);
  }

  late final ProviderContainer _container;
  final List<ToastData> seen = [];

  /// Lets the broadcast stream deliver what has already been published.
  Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 20));
}

ProviderContainer _container() {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      // The image write takes one of two routes and only the file-reference one
      // can succeed here — the other hands the bytes to the platform controller,
      // which no VM test has. Pinned with no entry key, so the fixture needs no
      // Hive box: the persisted setting is scenery in this suite, and the claim
      // under test is which *sentence* a successful image copy produces.
      clipboardPasteImageModeProvider.overrideWith(
        () => ExclusiveItemsNotifier<ClipboardPasteImageMode>(
          values: ClipboardPasteImageMode.values,
          defaultValue: ClipboardPasteImageMode.file,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('clipboard_copy_subject_test');
    _write('folder/record.json', 10);
    _write('image.png', 20);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _pasteboardChannel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _pasteboardChannel,
      null,
    );
    _root.deleteSync(recursive: true);
  });

  group('the three shipped sentences are three sentences', () {
    test('each names its own subject, and no two are the same', () {
      final image = appSentenceAt('toast.clipboard.success_image');
      final file = appSentenceAt('toast.clipboard.success_file');
      final directory = appSentenceAt('toast.clipboard.success_directory');

      // The defect in one line: the folder sentence must not be the image one.
      expect({image, file, directory}, hasLength(3));
      // And each has to be about the thing it is for — three distinct sentences
      // that all said 「画像」 would satisfy the check above.
      expect(image, contains('画像'));
      expect(file, contains('ファイル'));
      expect(directory, contains('フォルダ'));
      expect(directory, isNot(contains('画像')));
      expect(file, isNot(contains('画像')));
    });

    test('every subject has one, so none can fall through to a raw key', () {
      // Non-vacuity for the switch in `ClipboardAlt._successKey`: a member added
      // without an entry in `ja.json` would render its key on screen, and
      // `appSentenceAt` throws rather than returning it.
      for (final subject in ClipboardCopySubject.values) {
        expect(() => appSentenceAt('toast.clipboard.success_${subject.name}'), returnsNormally, reason: subject.name);
      }
      expect(ClipboardCopySubject.values, hasLength(3));
    });
  });

  group('what the toast says is what went on the clipboard', () {
    test('a folder is reported as a folder', () async {
      final observer = _ToastObserver();
      final ref = _container().read(refBaseProvider);

      expect(await ClipboardAlt.pasteEntity(ref, DirectoryPath(_abs('folder'))), isTrue);
      await observer.drain();

      expect(observer.seen.map((toast) => toast.description), [appSentenceAt('toast.clipboard.success_directory')]);
      // Named separately, because "it is the folder sentence" and "it is not the
      // image sentence" are the same assertion only while the two differ, and the
      // whole defect was that they did not.
      expect(observer.seen.single.description, isNot(appSentenceAt('toast.clipboard.success_image')));
    });

    test('a file is reported as a file', () async {
      final observer = _ToastObserver();
      final ref = _container().read(refBaseProvider);

      expect(await ClipboardAlt.pasteEntity(ref, FilePath(_abs('folder/record.json'))), isTrue);
      await observer.drain();

      expect(observer.seen.map((toast) => toast.description), [appSentenceAt('toast.clipboard.success_file')]);
      expect(observer.seen.single.description, isNot(appSentenceAt('toast.clipboard.success_image')));
    });

    test('an image is still reported as an image', () async {
      // The positive control. This caller was right before this stage, so it is
      // what tells a failing run apart from a broken one: a change that collapses
      // the sentences back to a single one leaves this green and the two above
      // red.
      final observer = _ToastObserver();
      final ref = _container().read(refBaseProvider);

      expect(await ClipboardAlt.pasteImage(ref, FilePath(_abs('image.png')), userInitiated: true), isTrue);
      await observer.drain();

      expect(observer.seen.map((toast) => toast.description), [appSentenceAt('toast.clipboard.success_image')]);
    });

    test('a silent copy says nothing at all', () async {
      // The addon action copies with `silent: true`; a subject that reached the
      // toaster anyway would put a sentence in front of a user who pressed
      // nothing.
      final observer = _ToastObserver();
      final ref = _container().read(refBaseProvider);

      expect(await ClipboardAlt.pasteEntity(ref, DirectoryPath(_abs('folder')), silent: true), isTrue);
      await observer.drain();

      expect(observer.seen, isEmpty);
    });
  });
}
