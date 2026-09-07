// The settings-store row's context menu: the copy operation the settings group has
// always declared, which that row grants as 「値のテキストコピー」 — the store's keys
// and values as text — and not as a file reference.
//
// **Why this suite exists at all.** The settings group declares
// `StorageOperation.clipboard`, and until this menu there was no affordance
// anywhere that honoured it: the preview panel's copy button was
// `ClipboardAlt.pasteEntity` — an OS *file reference*, offered on a `FilePath` —
// and a store has no file identity to hand over (on web it has no file at all).
// So the declaration and the screen disagreed, and nothing in the suite noticed,
// because no test tied `StorageOperation.clipboard` to anything the user can
// press.
//
// **The assertions are positive on purpose.** A test that only claimed "the menu
// does not offer X" stays green when the menu never opens, which is the state
// this whole file is about; every claim below therefore names something that has
// to be *on screen*, or names the text that has to reach the clipboard. The one
// absence claim (the browser arrangement) is paired with a presence claim on the
// desktop arrangement in the test above it.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_settings_store_menu_test.dart
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/settings_boxes.dart';
import 'package:umacapture/src/core/storage/settings_value_render.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _root;
late PathInfo _info;

/// The stores this suite's reader answers with, keyed by store.
///
/// A fixture rather than a real Hive: `Hive.box(name)` throws unless a real box
/// is open, and what is under test is what the *row* does with entries.
late Map<StorageBoxKey, List<SettingsBoxEntry>> _stores;

/// Whether the substituted reader throws, which is a record-store outage seen from
/// a row.
late bool _readerThrows;

final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

/// The menu entry's label, read out of `ja.json` as a literal so a renamed or
/// missing key turns this red rather than comparing a key with itself.
String _copyLabel() => appSentenceAt('pages.storage.actions.copy_settings_values');

ProviderContainer _container({bool clipboard = true, bool capturing = false}) {
  return ProviderContainer(
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _info),
      clipboardFileReferenceSupportProvider.overrideWithValue(clipboard),
      capturingStateProvider.overrideWithValue(capturing),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
      settingsStoreReaderProvider.overrideWithValue((key) {
        if (_readerThrows) {
          throw StateError('Box has already been closed.');
        }
        return _stores[key] ?? const <SettingsBoxEntry>[];
      }),
    ],
  );
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 40; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<void> _secondaryPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  late List<MethodCall> platformCalls;

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_settings_store_menu_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _readerThrows = false;
    _stores = {
      // A bare string and a JSON one, so the copied text is only right if it went
      // through `renderSettingsValue` rather than through `toString()`.
      StorageBoxKey.trainerId: const [(key: 'id', value: '12345678')],
      StorageBoxKey.columnSpec: const [
        (key: 'preset', value: '{"name":"a","columns":[1,2]}'),
        (key: 'revision', value: 7),
      ],
    };
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    _root.deleteSync(recursive: true);
  });

  /// Expands the settings group so its store rows are on screen.
  Future<void> openTheStores(WidgetTester tester, ProviderContainer container) async {
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.settings, path: null));
    await _settle(tester);
    expect(find.byKey(storageBoxRowKey('trainer_id')), findsOneWidget);
  }

  /// The text `Clipboard.setData` was handed, or null when it was never called.
  String? copiedText(List<MethodCall> calls) {
    final write = calls.where((call) => call.method == 'Clipboard.setData');
    return write.isEmpty ? null : (write.last.arguments as Map)['text'] as String?;
  }

  testWidgets('a secondary press on a settings store row opens a menu offering its values as text', (tester) async {
    final container = _container();
    await openTheStores(tester, container);

    // Not on screen before the press, so the finder below cannot be matching the
    // row itself.
    expect(find.text(_copyLabel()), findsNothing);
    await _secondaryPress(tester, find.byKey(storageBoxRowKey('trainer_id')));

    expect(find.text(_copyLabel()), findsOneWidget);
    // The operations the settings group does not declare for a row are absent:
    // a store has no bytes to save or zip, and the delete this view offers is the
    // group's, which removes all eight stores at once.
    expect(find.text(appSentenceAt('pages.storage.actions.download_file')), findsNothing);
    expect(find.text(appSentenceAt('pages.storage.actions.zip_directory')), findsNothing);
    expect(find.text(appSentenceAt('pages.storage.actions.delete')), findsNothing);
  }, variant: _desktop);

  testWidgets('selecting it puts the store s keys and values on the clipboard as text', (tester) async {
    final container = _container();
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    await openTheStores(tester, container);

    await _secondaryPress(tester, find.byKey(storageBoxRowKey('column_spec')));
    await tester.tap(find.text(_copyLabel()));
    await _settle(tester);

    // What arrived is the *rendering*, spelled out rather than recomputed here.
    // Comparing only against `renderSettingsStoreAsText` would agree with that
    // function however it were written — measured: a probe that replaced the
    // renderer with `'${entry.value}'` left exactly that comparison green. So the
    // pretty-printed shape is claimed literally, and the raw string the
    // rendering tiers exist to replace is claimed absent.
    final copied = copiedText(platformCalls);
    expect(copied, startsWith('preset\n{\n'));
    expect(copied, contains('\n  "name": "a"'));
    expect(copied, isNot(contains('{"name":"a","columns":[1,2]}')));
    expect(copied, endsWith('\n\nrevision\n7'));
    // And it is that function's output, so the row and the store dialog cannot
    // drift into two renderings of the same store.
    expect(copied, renderSettingsStoreAsText(_stores[StorageBoxKey.columnSpec]!));
    expect(toasts.map((toast) => toast.description), [appSentenceAt('pages.storage.store.copied')]);
  }, variant: _desktop);

  testWidgets('a long press reaches the same menu, which is the only entrance a touch screen has', (tester) async {
    final container = _container();
    await openTheStores(tester, container);

    await tester.longPress(find.byKey(storageBoxRowKey('trainer_id')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text(_copyLabel()), findsOneWidget);
  }, variant: _desktop);

  testWidgets('an empty store copies nothing and says so rather than reporting a success', (tester) async {
    _stores = const {StorageBoxKey.trainerId: <SettingsBoxEntry>[]};
    final container = _container();
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    await openTheStores(tester, container);

    await _secondaryPress(tester, find.byKey(storageBoxRowKey('trainer_id')));
    await tester.tap(find.text(_copyLabel()));
    await _settle(tester);

    expect(copiedText(platformCalls), isNull);
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.description, appSentenceAt('pages.storage.store.empty'));
  }, variant: _desktop);

  testWidgets('a store that cannot be read says so instead of copying', (tester) async {
    _readerThrows = true;
    final container = _container();
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    await openTheStores(tester, container);

    await _secondaryPress(tester, find.byKey(storageBoxRowKey('trainer_id')));
    await tester.tap(find.text(_copyLabel()));
    await _settle(tester);

    expect(copiedText(platformCalls), isNull);
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.description, appSentenceAt('pages.storage.store.unreadable'));
  }, variant: _desktop);

  testWidgets('a capture in progress does not withhold this copy, because it writes no store', (tester) async {
    final container = _container(capturing: true);
    await openTheStores(tester, container);

    await _secondaryPress(tester, find.byKey(storageBoxRowKey('trainer_id')));
    await tester.tap(find.text(_copyLabel()));
    await _settle(tester);

    // The capture-activity withholding is asked here exactly as it is on an entry row, and
    // it answers "proceed": `StorageGroup.writtenByLiveCapture` is false for the
    // settings group, so a capture is not rewriting what this copy hands out.
    // Written down because the opposite is the plausible guess — every other
    // extract action on this view goes dead while a capture runs — and a suite
    // that never said which one is right would let either be introduced.
    expect(copiedText(platformCalls), renderSettingsStoreAsText(_stores[StorageBoxKey.trainerId]!));
  }, variant: _desktop);

  testWidgets('a build that cannot copy shows no entry, and so opens no menu', (tester) async {
    final container = _container(clipboard: false);
    await openTheStores(tester, container);

    await _secondaryPress(tester, find.byKey(storageBoxRowKey('trainer_id')));

    // The absence claim, and the reason it is not vacuous: the test above runs
    // the identical gesture on the identical row with the capability present and
    // finds this label. What this pins is the rule that a browser is shown no copy
    // affordance at all, text included: one predicate
    // (`clipboardFileReferenceSupportProvider`) decides the whole family, and on
    // web the entry is not stacked rather than stacked and disabled.
    expect(find.text(_copyLabel()), findsNothing);
  }, variant: _desktop);

  test('the copied text is the same rendering the store dialog shows', () {
    // Not a restatement of the function: the claim is that a value the dialog
    // pretty-prints is pretty-printed on the clipboard too, and that a key is
    // legible against a value that is itself several lines.
    final text = renderSettingsStoreAsText(const [(key: 'preset', value: '{"name":"a"}'), (key: 'revision', value: 7)]);

    expect(text, '''preset
{
  "name": "a"
}

revision
7''');
  });
}
