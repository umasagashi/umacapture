// The storage view re-reads storage every time it is entered.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_view_reload_test.dart
//
// WHAT WAS WRONG. `storage_tree.dart`'s five providers are plain (non-`autoDispose`)
// futures, and the only thing in the repository that invalidated them was
// `refreshStorageTabAfterDelete`, reached from the delete confirmation and from
// nowhere else. So a capture, a video import or an archive would write into
// `active/` while the user was elsewhere, and coming back showed the tree and the
// totals from before — until the app was restarted. The user reported exactly that
// ("新しくキャプチャしてレコードが増えても表示が追加されない") and ruled that the view
// should re-read on entry rather than grow a refresh button or be notified by each
// of the three writers.
//
// WHAT THIS FILE OWNS, AND WHAT IT NO LONGER OWNS. This was
// `storage_tab_entry_reload_test.dart`, and the mechanism it described had two
// halves in two files: `route.dart` declared the storage tab `maintainState: false`
// so that leaving it unmounted the page, and `StoragePage.initState` did the
// re-read. There is no tab and no page now — the view is a dialog — so the route
// half is gone (`app_route_test.dart` asserts the flag is nobody's any more) and
// the entry half belongs to the dialog (`storage_dialog_entry_test.dart` opens it
// twice). What survives both is the widget in the middle: **one mount of
// `FreshStorageTree` is one visit**, whoever mounts it. That is what is asserted
// here, by mounting and unmounting it directly — which is what an entry causes
// rather than the entry itself, so this stays true of a second entry nobody has
// written yet.
//
// WHAT SEPARATES THIS FROM "REFRESH ON EVERY BUILD". An implementation that
// invalidated from `build` would satisfy "the new file appears after coming back"
// just as well, while re-walking the whole data directory on every scroll and
// every expansion. So the middle of the widget test is a *negative*: a group is
// opened — a real user gesture that rebuilds the tree — after a file has been
// written behind the view's back, and the figure must not move. Only leaving and
// returning may change it.
//
// WHAT SEPARATES THIS FROM "INVALIDATE THE PROVIDERS AND KEEP THE CACHE". The
// group total is read through `DirectoryTotalsCache`, so a reload that dropped the
// providers alone would recompute from the warm cache and redraw `4 B`. The byte
// figures below are exact for that reason.
//
// WHAT THIS SUITE DOES NOT REACH. It is VM/`dart:io` only, so it says nothing
// about OPFS listing costs on web — the platform the responsiveness ruling on
// re-scanning explicitly could not measure, because the machine it was checked on
// held too few records to load it. And it says nothing about how long a re-read
// takes on a large store.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/byte_size_format.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/storage_view_sources.dart';

late Directory _root;
late PathInfo _info;

/// Stands in for the view being on screen.
///
/// What an entry does to this widget is mount it and what a departure does is
/// unmount it; every entry the app offers is some way of causing that, so the
/// toggle is the mechanism under test rather than a stand-in for one of them.
final _visible = ValueNotifier<bool>(true);

Widget _app() {
  return MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: _visible,
        builder: (context, visible, _) => visible ? const FreshStorageTree() : const SizedBox.shrink(),
      ),
    ),
  );
}

void _write(String relative, int bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

ProviderContainer _container() {
  return ProviderContainer(overrides: [pathLayoutLoader.overrideWith((ref) async => _info)]);
}

/// Pumps the view at a viewport tall enough to hold the twelve group rows and the
/// opened group's children, for the reason `storage_tree_test.dart` states: the
/// default 800x600 surface pushes the lower groups outside the `ListView`'s cache
/// extent, and "not built" then reports itself as "not found".
Future<void> _pumpView(WidgetTester tester, ProviderContainer container) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, _app());
}

/// Leaves and comes back, without disposing the container the whole tree shares —
/// the providers under test are the ones that must survive the trip.
Future<void> _leaveAndReturn(WidgetTester tester) async {
  _visible.value = false;
  await tester.pump();
  _visible.value = true;
  // Three frames, because the re-read is applied one microtask after the frame
  // that mounts the widget (`FreshStorageTree.initState` says why it cannot be
  // applied inline) and the tree is only built once it has been: mount, apply,
  // build.
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// Pumps until nothing in the tree is pending. Copied in spirit from
/// `storage_tree_test.dart`: `dart:io` futures need `runAsync`, and the pending
/// rows schedule a frame per tick so `pumpAndSettle` would never return.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 60; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    final pending =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        find.text(appSentenceAt('pages.storage.status.calculating')).evaluate().isNotEmpty;
    if (!pending) {
      return;
    }
  }
  fail('the storage tree still had a pending row after 60 rounds');
}

String _cellText(Key key) {
  final text = find.descendant(of: find.byKey(key), matching: find.byType(Text), matchRoot: true);
  return (text.evaluate().single.widget as Text).data ?? '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_view_reload');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _visible.value = true;
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('a refresh is not a value', () {
    // Riverpod 3 hands a recomputing provider back as `AsyncData` carrying the
    // *previous* value with `isLoading` set, so dropping the providers is only
    // half of re-reading: without `unwrapPrevious()` every size cell and every
    // row goes on showing the last visit's answer for the whole length of the new
    // walk. The behaviour is asserted below; this asserts the shape, because the
    // behavioural test can only reach the surfaces it draws, and a seventh watch
    // added to a surface it does not reach would be silent.
    //
    // The list of providers is read out of `storageTabContentProviders` rather
    // than written here, so it is the code that is counted and not a copy of it,
    // and the watches are looked for across every source the view privately owns
    // rather than in the one file the list happens to live in — moving a draw
    // site one file across is not a defect and must not be read as one.
    test('every watch of the view\'s async providers reverts a refresh to loading', () {
      final view = StorageViewSources.read();
      expect(view.rosterNames, isNotEmpty);

      // Counted per provider, not as one running total. The guarantee here used
      // to be `checked >= names.length` — a sum — and the measurement is five
      // qualifying watches for five providers, one each, so the two sides met
      // exactly at the equals sign. A provider losing its only watch while
      // another gained a second left the sum at five and this guard green, which
      // is the single failure it exists to catch.
      final watches = {for (final name in view.rosterNames) name: 0};
      for (final source in view.sources.values) {
        for (final line in source.split('\n')) {
          for (final name in view.rosterNames) {
            // `.future` reads the value and not the `AsyncValue`, so there is no
            // previous state to unwrap; that is how one provider aggregates others.
            if (!RegExp(r'ref\.watch\(' + name + r'[(),]').hasMatch(line) || line.contains('.future')) {
              continue;
            }
            watches[name] = watches[name]! + 1;
            expect(
              line.contains('unwrapPrevious()'),
              isTrue,
              reason:
                  '$name is watched without unwrapPrevious(), so a re-read shows the previous answer: ${line.trim()}',
            );
          }
        }
      }
      // Every listed provider is drawn somewhere, so a provider the scan finds no
      // watch for has either lost its draw site or stopped being matched — and
      // neither is visible in a total.
      for (final entry in watches.entries) {
        expect(
          entry.value,
          greaterThanOrEqualTo(1),
          reason: '${entry.key} is in storageTabContentProviders but nothing in the view watches it',
        );
      }
    });
  });

  group('one mount is one entry', () {
    testWidgets('a file written while the user was elsewhere appears on the next mount', (tester) async {
      _write('documents/umacapture/temp/a.bin', 4);
      final container = _container();
      await _pumpView(tester, container);
      await _settle(tester);

      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));
      expect(find.text('a.bin'), findsOneWidget);

      // Something else in the app writes into a directory this view lists.
      // Nothing tells the view.
      _write('documents/umacapture/temp/b.bin', 4);

      // A build is not an entry. Opening another group rebuilds the whole tree —
      // it is the gesture the "do not re-walk while the user is here" rule is
      // about — and the figures must not move.
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.quarantine, path: null));
      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));
      expect(find.text('b.bin'), findsNothing);

      await _leaveAndReturn(tester);
      await _settle(tester);

      // 8 and not 4 is what says the totals cache went with the providers: the
      // group total is answered by `DirectoryTotalsCache`, and a provider rebuilt
      // over a warm cache would redraw `4 B`.
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(8));
      expect(find.text('b.bin'), findsOneWidget);
      expect(find.text('a.bin'), findsOneWidget);
    });

    testWidgets('the re-read says it is working rather than leaving the old figures up', (tester) async {
      _write('documents/umacapture/temp/a.bin', 4);
      final container = _container();
      await _pumpView(tester, container);
      await _settle(tester);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));

      await _leaveAndReturn(tester);

      // A walk of the whole data directory takes real time on a real machine, and
      // a number that simply sits there while it runs is indistinguishable from a
      // number that is current. Both of the view's two vocabularies are on screen:
      // the size columns say 「計算中…」 and the levels being listed say 「読み込み中…」,
      // which are the keys stage 7 already defined — no new wording for this.
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), appSentenceAt('pages.storage.status.calculating'));
      expect(_cellText(storageAppDataTotalKey), appSentenceAt('pages.storage.status.calculating'));
      expect(find.text(appSentenceAt('pages.storage.status.loading')), findsWidgets);
      expect(find.text(formatByteSize(4)), findsNothing);

      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));
    });
  });
}
