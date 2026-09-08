// Stage 5a: taking something out of the storage view through the clipboard.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_clipboard_action_test.dart
//
// Two properties, and neither is visible in a rendered frame on its own.
//
// **A directory is copyable at all.** The native clipboard format is a
// list of paths, so a directory and a file are the same operation — but the seam
// used to take a `FilePath` and to stat it as one, so a directory could not even
// be named. The tests below mock the `pasteboard` channel and assert *which path
// string* reached it, because an implementation that silently copied the parent,
// or that reported the directory missing, renders identically (a toast) and
// would pass any assertion about the button.
//
// **The browser says so instead of failing.** `clipboardSupportsFileReferences`
// is a compile-time `const`, so a widget reading it directly folds the browser
// arrangement out of a VM build entirely: the branch would be unreachable, not
// merely untested, and an implementation that offered the same button on web
// would keep this whole file green. Everything here goes through
// `clipboardFileReferenceSupportProvider`, which is overridable, and the browser
// cases assert both halves — the copy control is gone *and* nothing stands in
// its place, because "the copy failed" invites a retry that can never succeed.
//
// **Where a file's copy action lives.** On the row's context menu, and only
// there. It stood on the preview dialog as well until that surface was cut back
// to previewing alone, so the file cases here open a menu; the preview appears in
// this file for the opposite claim — that it offers nothing to press.
//
// WHAT THIS SUITE DOES NOT REACH. The OS clipboard itself: the channel is
// mocked, so nothing here says that Explorer resolves what was put on it (that
// is a manual check on a real Windows machine, and it needs a real paste). Nor does it reach the browser: it runs on
// the VM with the native half of the seam compiled in, so it exercises the web
// *arrangement of the widgets*, never `clipboard_image_writer_web.dart`.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/clipboard_image_writer.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/byte_size_format.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_file_preview.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/storage_row_menu.dart';

/// The channel `pasteboard` talks to on the native host.
const _pasteboardChannel = MethodChannel('pasteboard');

late Directory _root;
late PathInfo _info;

/// Every `writeFiles` payload the platform side was handed, in order.
late List<List<String>> _written;

void _write(String relative, int bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

String _abs(String relative) =>
    '${_root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

ProviderContainer _container({bool? fileReferences}) {
  return ProviderContainer(
    // The app's own policy (`lib/main.dart`), for the reason
    // `storage_file_preview_view_test.dart` states.
    retry: (_, _) => null,
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _info),
      if (fileReferences != null) clipboardFileReferenceSupportProvider.overrideWith((ref) => fileReferences),
    ],
  );
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
}

Future<void> _pumpPreview(WidgetTester tester, ProviderContainer container, FilePath file) {
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(
    tester,
    container,
    MaterialApp(
      theme: ThemeData(extensions: <ThemeExtension<dynamic>>[CodeHighlightColors.light()]),
      home: Scaffold(
        body: Center(child: StorageFilePreviewDialog(file: file)),
      ),
    ),
  );
}

/// Pumps until nothing in the tree is pending, stepping outside the fake clock so
/// the `dart:io` listings can actually complete. Bounded, and fails naming the
/// condition — see `support/settling.dart` for why this is not `pumpAndSettle`.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 60; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    // Both signals, because stage 7 turned the totals' spinners into the word
    // 「計算中…」: a settle that watched only the indicator would return while the
    // group totals were still being walked, and every byte-count assertion after
    // it would read that word instead of a size.
    final pending =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        find.text(appSentenceAt('pages.storage.status.calculating')).evaluate().isNotEmpty;
    if (!pending) {
      return;
    }
  }
  fail('the storage surface still had a pending row after 60 rounds');
}

/// Waits for a clipboard write that was started by a tap.
///
/// The write awaits `exists()`, a real `dart:io` stat, so it makes no progress
/// under the fake clock a `testWidgets` body runs on. Polled rather than given a
/// fixed number of rounds, for the reason `support/settling.dart` states, and
/// bounded so a write that never happens is named as that instead of surfacing
/// as an empty list three lines later.
Future<void> _awaitWrite(WidgetTester tester) async {
  for (var round = 0; round < 200; round++) {
    if (_written.isNotEmpty) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  fail('the tap started no clipboard write');
}

/// Presses [target] with the secondary button and lets the menu route settle.
///
/// The row's context menu is where a file's copy action lives, since the preview
/// was cut back to a preview and carries no actions of its own, so
/// the two file cases here have to open it rather than a preview.
Future<void> _secondaryPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Expands the active-records group and `rec1`, leaving `record.json` on screen
/// as a file row.
Future<void> _openToTheFile(WidgetTester tester, ProviderContainer container) async {
  await _pumpTree(tester, container);
  await _settle(tester);
  final expansion = container.read(storageTreeExpansionProvider.notifier);
  expansion.toggle((group: StorageGroupId.activeRecords, path: null));
  await _settle(tester);
  expansion.toggle((
    group: StorageGroupId.activeRecords,
    path: _abs('documents/umacapture/storage/chara_detail/active/rec1'),
  ));
  await _settle(tester);
  expect(find.text('record.json'), findsOneWidget, reason: 'the file row has to be on screen to be pressed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_clipboard_action_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _write('documents/umacapture/storage/chara_detail/active/rec1/record.json', 100);
    _write('documents/umacapture/storage/chara_detail/active/rec1/skill.png', 200);
    _written = <List<String>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pasteboardChannel, (
      call,
    ) async {
      if (call.method == 'writeFiles') {
        _written.add(List<String>.from(call.arguments as List<Object?>));
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _pasteboardChannel,
      null,
    );
    _root.deleteSync(recursive: true);
  });

  group('a directory goes on the clipboard exactly as a file does', () {
    test('a directory is handed to the OS under its own path', () async {
      final directory = DirectoryPath(_abs('documents/umacapture/storage/chara_detail/active/rec1'));

      expect(await copyFileReferenceToClipboard(directory), ClipboardWriteOutcome.success);
      // The path itself, not the parent and not a member: pasting the wrong one
      // of the three yields something plausible in Explorer, which is precisely
      // why the assertion is on the payload rather than on the outcome.
      expect(_written, [
        [directory.path],
      ]);
    });

    test('a file is handed to the OS under its own path', () async {
      final file = FilePath(_abs('documents/umacapture/storage/chara_detail/active/rec1/record.json'));

      expect(await copyFileReferenceToClipboard(file), ClipboardWriteOutcome.success);
      expect(_written, [
        [file.path],
      ]);
    });

    test('a directory that is not there is missing, and nothing is put on the clipboard', () async {
      final directory = DirectoryPath(_abs('documents/umacapture/storage/chara_detail/active/gone'));

      // Not `failed`: there was no write to fail. The two are rendered as
      // different sentences (`ClipboardAlt._report`).
      expect(await copyFileReferenceToClipboard(directory), ClipboardWriteOutcome.missing);
      expect(_written, isEmpty);
    });

    test('ClipboardAlt reports the directory copy as a success', () async {
      final container = _container();
      addTearDown(container.dispose);
      final directory = DirectoryPath(_abs('documents/umacapture/storage/chara_detail/active/rec1'));

      expect(await ClipboardAlt.pasteEntity(container.read(refBaseProvider), directory, silent: true), isTrue);
      expect(_written, [
        [directory.path],
      ]);
    });
  });

  group('the copy action is reachable from the view', () {
    // The copy used to be a button standing on the directory row; it is now an
    // entry of that row's menu, so the press is two steps and the claim is the
    // same one: what reaches the clipboard is *that* directory.
    testWidgets("a directory row's menu copies that directory", (tester) async {
      final container = _container(fileReferences: true);
      await _pumpTree(tester, container);
      await _settle(tester);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
      await _settle(tester);

      final directory = DirectoryPath(_abs('documents/umacapture/storage/chara_detail/active/rec1'));
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(directory));
      await tester.tap(find.text(storageActionLabel('copy_directory')));
      await _awaitWrite(tester);

      expect(_written, [
        [directory.path],
      ]);
    });

    // What this used to claim — "the file row carries no copy *button*" — is now
    // true of every row and of every action: the three buttons are gone and one
    // ⋮ stands where they did. So the claim it can still make is the one that
    // distinguishes the row from the preview beside it: the row has exactly one
    // trailing control, and the file's actions are behind it (the case below) and
    // not on the preview (`the preview surface itself offers no action at all`).
    testWidgets('a file row carries one trailing control, and it is the menu', (tester) async {
      final container = _container(fileReferences: true);
      await _pumpTree(tester, container);
      await _settle(tester);
      final expansion = container.read(storageTreeExpansionProvider.notifier);
      expansion.toggle((group: StorageGroupId.activeRecords, path: null));
      await _settle(tester);
      expansion.toggle((
        group: StorageGroupId.activeRecords,
        path: _abs('documents/umacapture/storage/chara_detail/active/rec1'),
      ));
      await _settle(tester);

      expect(find.text('record.json'), findsOneWidget, reason: 'the file row has to be on screen to be judged');
      final file = FilePath(_abs('documents/umacapture/storage/chara_detail/active/rec1/record.json'));
      expect(find.byKey(storageRowMenuEntityKey(file)), findsOneWidget);
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(file)), isTrue);
    });

    testWidgets("a file row's menu copies that file", (tester) async {
      // Where the preview's action bar used to be asserted. The two actions a
      // file has were taken off that surface (it previews and nothing else), so
      // the row's context menu is now their only host and is where this claim
      // has to be made.
      final container = _container(fileReferences: true);
      await _openToTheFile(tester, container);

      final file = FilePath(_abs('documents/umacapture/storage/chara_detail/active/rec1/record.json'));
      await _secondaryPress(tester, find.text('record.json'));
      await tester.tap(find.text(appSentenceAt('pages.storage.actions.copy_file')));
      await _awaitWrite(tester);

      expect(_written, [
        [file.path],
      ]);
    });

    testWidgets('the preview surface itself offers no action at all', (tester) async {
      // **The double-existence detector.** Copy and save were on this bar *and*
      // on the row menu at once; they were taken off here. Putting either back
      // fails this test, whichever spelling it comes back in — a button, a text
      // button, an icon button, or a sentence beside the size.
      //
      // Counted, not enumerated, for the reason the browser case below is: a list
      // of forbidden keys could only name the ones already thought of.
      final container = _container(fileReferences: true);
      final file = FilePath(_abs('documents/umacapture/storage/chara_detail/active/rec1/record.json'));
      await _pumpPreview(tester, container, file);
      await _settle(tester);

      final footer = find.byKey(storageFilePreviewFooterKey);
      expect(footer, findsOneWidget, reason: 'every assertion below is only meaningful inside the footer');
      // The one text allowed: the size. 100 is what `setUp` writes this fixture
      // at. Any label restored beside it raises this list.
      expect(find.descendant(of: footer, matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data), [
        formatByteSize(100),
      ]);
      // And the half a text count does not give: the only thing in the dialog
      // that can be pressed is `CardDialog`'s own close button, which is the
      // surface's chrome and not an action on the file. Counted over the whole
      // dialog rather than over the footer, because "put the buttons back" need
      // not put them back in the same row — either action returning in any
      // spelling raises this count to two.
      //
      // `bySubtype` and not `byType`. `ButtonStyleButton` is abstract and
      // `find.byType` compares `runtimeType` exactly ("this does not do subclass
      // tests", `finders.dart`), so a `byType` form could never match a
      // `TextButton` and would pass whatever the dialog held.
      expect(find.bySubtype<ButtonStyleButton>(), findsOneWidget);
      expect(
        find.byTooltip(appSentenceAt('pages.storage.preview.close_tooltip')),
        findsOneWidget,
        reason: 'the one pressable widget has to be the close button for the count above to mean anything',
      );
    });
  });

  group('in a browser the copy action is simply absent', () {
    testWidgets("a file row's menu holds neither a copy entry nor a sentence standing in for one", (tester) async {
      final container = _container(fileReferences: false);
      await _openToTheFile(tester, container);

      await _secondaryPress(tester, find.text('record.json'));

      // The menu did open — the save entry proves it — so the copy entry being
      // absent is a fact about the capability and not about a menu that never
      // appeared. Save *is* offered on web, because a browser can take delivery
      // of a file even though it cannot hold a reference to one.
      expect(find.text(appSentenceAt('pages.storage.actions.download_file')), findsOneWidget);
      expect(find.text(appSentenceAt('pages.storage.actions.copy_file')), findsNothing);
      // Nothing stands in its place either: the wording review took the
      // explanatory sentence out — "何も表示しない方が分かりやすい" — so the requirement
      // is "nothing at all is here", which the copy label's absence alone does
      // not give.
      expect(find.text(appSentenceAt('pages.storage.actions.copy_directory')), findsNothing);
    });

    // The same claim the case above makes for a file, for a directory: with no
    // file clipboard the copy is *absent*, not present and dead, and nothing
    // stands in its place. Asserted on the menu now that the row's copy button is
    // gone — and the row's menu is proven to have opened by an entry that does
    // not depend on the clipboard, so an absent copy here is an absent entry and
    // not a menu that failed to open.
    testWidgets('no directory row offers a copy entry', (tester) async {
      final container = _container(fileReferences: false);
      await _pumpTree(tester, container);
      await _settle(tester);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
      await _settle(tester);

      expect(find.text('rec1'), findsOneWidget, reason: 'the directory row has to be on screen to be judged');
      final directory = DirectoryPath(_abs('documents/umacapture/storage/chara_detail/active/rec1'));
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(directory));

      expect(find.text(storageActionLabel('delete')), findsOneWidget, reason: 'the menu did open');
      expect(find.text(storageActionLabel('copy_directory')), findsNothing);
      expect(_written, isEmpty);
    });

    test('the seam itself answers "unavailable", which is not a failure', () {
      // The distinction the wording rests on, asserted where it is decided. On the
      // VM this is the native constant; the browser half is a separate `const` in
      // `clipboard_image_writer_web.dart` and is unreachable from here.
      expect(ClipboardWriteOutcome.unavailable, isNot(ClipboardWriteOutcome.failed));
      expect(clipboardSupportsFileReferences, isTrue, reason: 'this suite runs on the native half of the seam');
    });
  });
}
