// The storage-management view's read-only tree (stage 3b-1).
//
// Three of these tests are the stage's stated completion conditions and are
// written to fail for the reason they name, not merely to exercise the widget:
//
//  * the twelve groups are asserted by their **shipped Japanese labels**, read
//    out of `ja.json` as literals. Counting `storageGroups` instead would make
//    the assertion agree with whatever the definition happens to say, so a group
//    dropped from both the table and the screen would stay green.
//  * "expansion is lazy" is asserted by counting *recursive* listings through
//    the backend. A test that merely observed the right rows cannot tell a lazy
//    tree from one that enumerated everything and drew the first level of it.
//  * "the view survives a store outage" is asserted with `pathInfoProvider`
//    itself proven to be dead in the same container, so the test cannot pass
//    against a state in which there was nothing to survive.
//  * the root totals and the per-group totals are asserted as **exact byte
//    strings** derived from what the fixture wrote, not as "some number is
//    shown", and each is read through its own key. A group's total and one of its
//    files' sizes are routinely the same string on this screen.
//  * "web hides the two groups it does not have" is asserted by *building the
//    web tab*, which is possible only because the platform arrives through
//    `storageOnWebProvider`. `kIsWeb` is a compile-time `false` here, so a tab
//    that read it at the use site could not be tested in that arrangement at all.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_tree_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/byte_size_format.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/settling.dart';
import 'support/web_like_fs_backend.dart';

/// A backend that additionally counts the listings that asked for a *recursive*
/// walk.
///
/// `WebLikeFsBackend` counts listings and `length()` calls; the claim under test
/// here is narrower than either — one level per opened node — so the recursive
/// ones have to be counted apart. Subclassed rather than added to the shared
/// helper so this stage does not change a file every other suite runs on.
class _RecursionCountingBackend extends WebLikeFsBackend {
  _RecursionCountingBackend(super.inner);

  int recursiveListCalls = 0;

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) {
    if (recursive) {
      recursiveListCalls++;
    }
    return super.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
  }

  void resetAllCounts() {
    resetCallCounts();
    recursiveListCalls = 0;
  }
}

/// A backend that refuses to list one directory, so the tree's "this level could
/// not be read" row is reachable from a VM test.
///
/// A refusal at the backend rather than an overridden provider, because the row
/// under test is what the view shows when the *platform* says no — a store outage,
/// a directory removed underneath it — and an overridden provider would assert
/// the rendering of an error nothing on either platform produces.
class _ListFailingBackend extends WebLikeFsBackend {
  _ListFailingBackend(super.inner, this.refusedSuffix);

  /// The directory to refuse, matched on the tail of the path so the test does
  /// not have to spell the temp root.
  final String refusedSuffix;

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) {
    if (path.replaceAll(r'\', '/').endsWith(refusedSuffix)) {
      return Future.error(const FileSystemException('refused by the test backend'));
    }
    return super.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
  }
}

/// Every group's label key, written out. The point of this list is that it is
/// *not* derived from `storageGroups`.
///
/// Its order carries nothing: the list is only ever iterated to assert that each
/// label is on screen. The order the view actually shows the groups in is stated
/// once, as a literal, by 'the view lists the groups in the order that was chosen
/// for it' -- do not read this roster as a second copy of it.
const _groupLabelKeys = <String>[
  'pages.storage.group.active_records.label',
  'pages.storage.group.archived_records.label',
  'pages.storage.group.quarantine.label',
  'pages.storage.group.retired.label',
  'pages.storage.group.metadata.label',
  'pages.storage.group.modules.label',
  'pages.storage.group.settings.label',
  'pages.storage.group.temp.label',
  'pages.storage.group.custom_sound.label',
  'pages.storage.group.data_root_config.label',
  'pages.storage.group.font_cache.label',
  'pages.storage.group.unclassified.label',
];

/// The twelve standing descriptions, **as literal sentences**.
///
/// Written out rather than read through `storageGroups`: a list derived from the
/// definition agrees with whatever the definition says, so a group whose
/// description was dropped from the table *and* from the screen would keep this
/// green. They are literals rather than `appSentenceAt` lookups for the
/// neighbouring reason — these twelve sentences are the wording the user
/// approved, so a silent edit to `ja.json` is a change this test should notice,
/// and the assertion that the file still carries them is made below.
const _groupDescriptions = <StorageGroupId, String>{
  StorageGroupId.activeRecords: 'キャプチャした現役ウマ娘のストレージ',
  StorageGroupId.archivedRecords: 'キャプチャしたアーカイブウマ娘のストレージ',
  // Reworded on 2026-09-06, and approved in that wording: the group holds saves
  // that stopped part-way as well as records the app could not read, and the
  // sentence said only the second.
  StorageGroupId.quarantine: '読み込めなくなったウマ娘のデータや、保存の途中で残ったデータの退避先',
  StorageGroupId.retired: '処理の途中で残ったファイル',
  StorageGroupId.metadata: 'キャプチャ済みウマ娘に付けたメモやレーティングなどのメタデータ',
  StorageGroupId.modules: '画像認識のためのモデルとラベル',
  StorageGroupId.settings: 'アプリのすべての設定',
  StorageGroupId.temp: 'アプリが処理の途中で生成する一時ファイル',
  StorageGroupId.customSound: 'ユーザーが追加した通知音のファイル',
  StorageGroupId.dataRootConfig: '各種ストレージの保存先を既定以外にするための設定ファイル',
  StorageGroupId.fontCache: '画面表示に使うフォントのキャッシュ',
  StorageGroupId.unclassified: '何に利用されているか・どう生じたか不明なファイル',
};

late Directory _root;
late PathInfo _info;
late _RecursionCountingBackend _backend;
late FsBackend _originalBackend;

void _write(String relative, int bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

/// Pumps the view, at a viewport tall enough to hold the whole tree.
///
/// The default 800x600 test surface fits about fourteen rows, and the view now
/// opens with the summary header above twelve group rows — each of which carries
/// its standing description as a second line — so the last group's children land
/// outside both the viewport and `ListView`'s cache extent, and a `find.text` for
/// one of them reports "not found" when the truth is "not built". That failure
/// mode points at the enumeration and is nothing to do with it. A taller surface
/// is also closer to the window this view actually ships in.
///
/// The height is the *reason* the assertions below can be about the tree rather
/// than about scrolling; it is not a way of making a failing assertion pass.
Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, _tree());
}

Widget _tree() => const MaterialApp(home: Scaffold(body: StorageTreeView()));

/// A container for the view.
///
/// [onWeb] is what makes the web arrangement reachable at all: `kIsWeb` is a
/// compile-time `false` here, so without overriding the provider the web branches
/// are folded out of the program before the test runs. [originUsage] stands in
/// for `navigator.storage.estimate()`, which no VM test can call.
ProviderContainer _container({Object? outage, bool? onWeb, int? originUsage, bool retryOnError = true}) {
  return ProviderContainer(
    // Riverpod 3 retries a provider that threw, so a listing this test refuses
    // *forever* leaves the view cycling error → loading → error. That is right for
    // the app — a store that comes back should be picked up — and it makes "the
    // error is on screen" a race for a test. Switching the retry off is what makes
    // the refused state a state, rather than a phase.
    retry: retryOnError ? null : (_, _) => null,
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _info),
      if (outage != null) pathInfoLoader.overrideWith((ref) async => throw outage),
      if (onWeb != null) storageOnWebProvider.overrideWith((ref) => onWeb),
      if (originUsage != null) originStorageUsageProvider.overrideWith((ref) async => originUsage),
    ],
  );
}

/// The text inside one keyed cell.
///
/// Every size on this screen is matched through its own key rather than by
/// searching the whole tree for the string: a group's total and one of its files'
/// sizes are routinely the same number of bytes, so a bare `find.text` would be
/// satisfied by the wrong row and would keep being satisfied after the row it was
/// written for stopped showing anything.
String _cellText(Key key) {
  // `matchRoot`, because a file's cell *is* the `Text` while a directory's cell
  // is a widget that holds one.
  final text = find.descendant(of: find.byKey(key), matching: find.byType(Text), matchRoot: true);
  return (text.evaluate().single.widget as Text).data ?? '';
}

/// Pumps until nothing in the tree is pending.
///
/// Not `pumpAndSettle`, for two independent reasons. `testWidgets` runs its body
/// under a fake clock, and a `dart:io` future completes on the *real* event
/// loop, so a listing never resolves without stepping outside it — that is what
/// `runAsync` does. And the tree's pending row is a `CircularProgressIndicator`,
/// which schedules a frame on every tick, so `pumpAndSettle` would spin until
/// its own timeout even if the clock were real.
///
/// Bounded, and fails loudly at the bound rather than returning quietly: a
/// silent give-up would turn "the listing never completed" into "the rows were
/// not found", which points at the wrong thing.
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
  fail('the storage tree still had a pending row after 60 rounds');
}

/// Opens every group root without going through the rows, so the assertion does
/// not depend on which rows happen to fit the 800x600 test viewport.
void _expandEveryGroup(ProviderContainer container) {
  final expansion = container.read(storageTreeExpansionProvider.notifier);
  for (final group in storageGroups) {
    expansion.toggle((group: group.id, path: null));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_tree_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    // A record with two files in it, so a leaf is reachable and a directory
    // total has something to add up.
    _write('documents/umacapture/storage/chara_detail/active/rec1/record.json', 100);
    _write('documents/umacapture/storage/chara_detail/active/rec1/skill.png', 200);
    _write('support/modules/version_info.json', 40);
    // The single-file group.
    _write('support/data_root.json', 50);
    // A font-cache member and a stray file, both sitting directly in the support
    // directory, which the app does not own exclusively.
    _write('support/MPLUS1Code_regular_x.ttf', 10);
    _write('support/modules.zip', 20);
    _write('documents/umacapture/leftover.txt', 30);
    // A settings store's file. The settings group is a synthetic node: it shows
    // the *store*, never this file name.
    _write('documents/umacapture/settings/settings.hive', 30);
    // One of the metadata group's two directories, so the group has a level that
    // is neither "one directory's contents" nor a single file.
    _write('documents/umacapture/storage/chara_detail/metadata/rating/main.json', 60);
    _originalBackend = fsBackend;
    _backend = _RecursionCountingBackend(_originalBackend);
    fsBackend = _backend;
  });

  tearDown(() {
    fsBackend = _originalBackend;
    // The fixture is this test's own temp tree; nothing else reads it.
    _root.deleteSync(recursive: true);
  });

  testWidgets('the twelve logical groups are the roots, under their shipped labels', (tester) async {
    await _pumpTree(tester, _container());
    await _settle(tester);

    for (final key in _groupLabelKeys) {
      expect(find.text(appSentenceAt(key)), findsOneWidget, reason: key);
    }
    expect(_groupLabelKeys.length, 12);
  });

  testWidgets('every group explains itself with nothing expanded', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    // The state the view opens in. Asserted rather than assumed, because every
    // expectation below is about what is readable *without* opening anything: if
    // something had opened a group, the description could be arriving with the
    // hint and this test would be blind to the regression it exists to catch.
    expect(container.read(storageTreeExpansionProvider), isEmpty);
    expect(find.text('rec1'), findsNothing);

    for (final entry in _groupDescriptions.entries) {
      // Through the group's own key, so this cannot pass by finding the sentence
      // somewhere else on the screen. `matchRoot`, for the reason `_cellText`
      // states: the key sits on the `Text` itself, so a plain descendant search
      // would exclude the very widget being matched.
      expect(
        find.descendant(
          of: find.byKey(storageGroupDescriptionKey(entry.key)),
          matching: find.text(entry.value),
          matchRoot: true,
        ),
        findsOneWidget,
        reason: entry.key.name,
      );
    }
    expect(_groupDescriptions, hasLength(12));

    // "Under the name", geometrically. Containment in the group's tile is not the
    // same claim: a description rendered above the label, or to the right of the
    // size column, would satisfy every expectation above.
    final label = tester.getRect(find.text(appSentenceAt('pages.storage.group.active_records.label')));
    final description = tester.getRect(find.byKey(storageGroupDescriptionKey(StorageGroupId.activeRecords)));
    expect(description.top, greaterThanOrEqualTo(label.bottom));
    expect(description.left, greaterThanOrEqualTo(label.left));
    // And still inside the row it belongs to: the next group's name starts below
    // it, so the description has not overflowed into a neighbour.
    final next = tester.getRect(find.text(appSentenceAt('pages.storage.group.archived_records.label')));
    expect(next.top, greaterThanOrEqualTo(description.bottom));
  });

  test('the shipped ja.json still carries the twelve approved sentences', () {
    // The other half of the literals above: they assert what is on screen, this
    // asserts the app ships it. Without this, a description key silently renamed
    // in both `storage_group.dart` and `ja.json` would still render *something*
    // and the widget test would only say the two agree with each other.
    for (final group in storageGroups) {
      expect(appSentenceAt(group.descriptionKey), _groupDescriptions[group.id], reason: group.id.name);
    }
  });

  testWidgets('the delete warning is nowhere on the tree, opened or closed', (tester) async {
    // The regression guard on the other side of this change. The warnings used to
    // be the first thing an opened group showed; they now belong to the delete
    // confirmation alone, and the description is what the tree says instead. So a
    // version that put the paragraph back — under the expander where it used to
    // live, or promoted to the group row — would satisfy the test above and still
    // be wrong.
    //
    // Every group with a warning, not just one: putting the paragraph back is the
    // sort of change that would be made in the one shared row builder, but a
    // per-group special case is exactly what a single-group assertion would miss.
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    final warnings = {
      for (final group in storageGroups)
        if (group.deleteWarningKey case final key?) group.id: appSentenceAt(key),
    };
    // The set is counted, so a rename that emptied it would not make this pass by
    // asserting nothing.
    expect(warnings, hasLength(11));

    for (final entry in warnings.entries) {
      expect(entry.value, isNot(_groupDescriptions[entry.key]), reason: entry.key.name);
      expect(find.text(entry.value), findsNothing, reason: entry.key.name);
    }

    final expansion = container.read(storageTreeExpansionProvider.notifier);
    for (final id in warnings.keys) {
      expansion.toggle((group: id, path: null));
    }
    await _settle(tester);

    for (final entry in warnings.entries) {
      expect(find.text(entry.value), findsNothing, reason: entry.key.name);
    }
    // And the descriptions did not go away with them: the tree still says what
    // each group is, which is the sentence that replaced the paragraph.
    for (final id in warnings.keys) {
      expect(find.text(_groupDescriptions[id] ?? ''), findsOneWidget, reason: id.name);
    }
  });

  testWidgets('an opened group with nothing to delegate adds no row of its own', (tester) async {
    // The other half of "the paragraph is gone": a row that draws *nothing* is
    // invisible to every `find.text` above and still costs the reader a band of
    // padding between the group's name and its first entry. Counted structurally
    // — the flattened list's `itemCount` is the number of rows the view decided to
    // build — because that is the only reading that can tell "no row" from "an
    // empty one".
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    // Closed: the summary row plus one row per group, and nothing else.
    int rowCount() => tester.widget<ListView>(find.byType(ListView)).semanticChildCount ?? -1;
    expect(rowCount(), 1 + 12);

    // `active_records` delegates nothing, and its level here is the single record
    // the fixture wrote, so opening it may add exactly one row.
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);
    expect(rowCount(), 1 + 12 + 1);

    // `data_root_config` does delegate, so its button *is* a row — the one row
    // this assertion must not forbid.
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.dataRootConfig, path: null));
    await _settle(tester);
    expect(rowCount(), 1 + 12 + 1 + 1 + 1);
  });

  testWidgets('the retired note is gone from the tree with the rest of the prose', (tester) async {
    // `custom_sound` was the one group that carried a second standing paragraph
    // (`…custom_sound.note`), and it was retired with the warnings. Asserted
    // against `ja.json` itself rather than against a literal on screen: the key no
    // longer exists, so the only thing left to check is that nothing still asks
    // for it — a `.tr()` of a deleted key renders the key, which is a row reading
    // `pages.storage.group.custom_sound.note` to the user.
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.customSound, path: null));
    await _settle(tester);

    expect(find.text('pages.storage.group.custom_sound.note'), findsNothing);
    // And the key really is gone from the shipped file, so the line above is not
    // merely passing because the sentence is rendered rather than the key.
    expect(() => appSentenceAt('pages.storage.group.custom_sound.note'), throwsStateError);
  });

  testWidgets('expanding reaches the files at the leaves, one level per open node', (tester) async {
    await _pumpTree(tester, _container());
    await _settle(tester);
    _backend.resetAllCounts();

    // Closed: nothing below the group is on screen.
    expect(find.text('rec1'), findsNothing);

    await tester.tap(find.text(appSentenceAt('pages.storage.group.active_records.label')));
    await _settle(tester);
    // The entries come with the level it opened, and nothing is inserted above
    // them: the group's own paragraph belongs to the delete confirmation now.
    expect(find.text('rec1'), findsOneWidget);
    // One level only: the record's contents are not listed until it is opened.
    expect(find.text('record.json'), findsNothing);

    await tester.tap(find.text('rec1'));
    await _settle(tester);
    expect(find.text('record.json'), findsOneWidget);
    expect(find.text('skill.png'), findsOneWidget);
    // Both sizes came out of the enumerations, not from a probe per row: every
    // row here was produced by a listing, so a single `length()` call would mean
    // the metadata the listing already carried was thrown away.
    expect(find.text('100 B'), findsOneWidget);
    expect(find.text('200 B'), findsOneWidget);
    expect(_backend.lengthCalls, 0);
  });

  testWidgets('the residual bucket shows what no other group named', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.unclassified, path: null));
    await _settle(tester);

    expect(find.text('modules.zip'), findsOneWidget);
    expect(find.text('leftover.txt'), findsOneWidget);
    // Named by another group, so not residue.
    expect(find.text('modules'), findsNothing);
    expect(find.text('data_root.json'), findsNothing);
    expect(find.text('MPLUS1Code_regular_x.ttf'), findsNothing);
  });

  testWidgets('opening every root issues no recursive enumeration', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    _backend.resetAllCounts();

    _expandEveryGroup(container);
    await _settle(tester);

    // The listings did happen -- otherwise "zero recursive listings" would be
    // the trivially true statement that nothing was listed at all.
    expect(_backend.listCalls, greaterThan(0));
    expect(_backend.recursiveListCalls, 0);
  });

  testWidgets('the view builds and enumerates while the record store is unavailable', (tester) async {
    final outage = RecordStoreUnavailable(StateError('the store could not be opened'), transient: false);
    final container = _container(outage: outage);
    await _pumpTree(tester, container);
    await _settle(tester);

    // The outage is real in this container: the path every other screen reads is
    // dead. Without this, the test could pass against a healthy app.
    final failure = await tester.runAsync(() async {
      try {
        await container.read(pathInfoLoader.future);
        return null;
      } catch (error) {
        return error;
      }
    });
    expect(failure, same(outage));
    expect(() => container.read(pathInfoProvider), throwsA(anything));

    final label = appSentenceAt('pages.storage.group.active_records.label');
    expect(find.text(label), findsOneWidget);
    await tester.tap(find.text(label));
    await _settle(tester);
    expect(find.text('rec1'), findsOneWidget);
  });

  testWidgets('the directory totals cache is one shared instance the rows read', (tester) async {
    final container = _container();
    expect(
      identical(container.read(directoryTotalsCacheProvider), container.read(directoryTotalsCacheProvider)),
      isTrue,
    );

    // Total the record directory through the container's cache, before the tree
    // has drawn a single row.
    final recordDir = _info.charaDetailActiveDir / 'rec1';
    // `runAsync` for the same reason `_settle` uses it: the walk is real file
    // I/O and would never complete under the test's fake clock.
    final totals = await tester.runAsync(() => container.read(directoryTotalsCacheProvider).totalsOf(recordDir));
    expect(totals?.knownBytes, 300);
    expect(_backend.recursiveListCalls, 1);

    await _pumpTree(tester, container);
    await _settle(tester);
    _backend.resetAllCounts();

    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);

    // The row shows a total it never computed. Were the cache built per row (or
    // per widget), `peek` would miss and the cell would still read as unknown.
    expect(_cellText(storageSizeCellKey(recordDir)), '300 B');
    expect(_backend.recursiveListCalls, 0);
  });

  testWidgets('a group that is not one whole directory shows the entities it names', (tester) async {
    // The metadata group's *second* directory, written here rather than in
    // `setUp` so the byte totals every other test asserts stay as they are. It
    // has to exist for this test to be about "two directories, one group": with
    // `memo/` absent the row under test would be the one
    // 'a member of a group that is not there is not a row' forbids, and this
    // test asserted exactly that for as long as the fixture never created it.
    _write('documents/umacapture/storage/chara_detail/metadata/memo/main.json', 70);
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    // Two directories, one group.
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.metadata, path: null));
    await _settle(tester);
    expect(find.text('rating'), findsOneWidget);
    expect(find.text('memo'), findsOneWidget);
    await tester.tap(find.text('rating'));
    await _settle(tester);
    expect(find.text('main.json'), findsOneWidget);

    // A group that is a single file.
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.metadata, path: null));
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.dataRootConfig, path: null));
    await _settle(tester);
    expect(find.text('data_root.json'), findsOneWidget);
    expect(_cellText(storageSizeCellKey(_info.supportDir.filePath('data_root.json'))), '50 B');
  });

  testWidgets('a member of a group that is not there is not a row', (tester) async {
    // Both shapes of the branch that draws named entities, in their default
    // state. `memo/` is what the app has not created yet -- nothing has been
    // typed into it -- and `data_root.json` is removed here to reach the same
    // state for the group whose whole content is that one file (a default
    // install has never moved its data root).
    File([_root.path, 'support', 'data_root.json'].join(Platform.pathSeparator)).deleteSync();

    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.metadata, path: null));
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.dataRootConfig, path: null));
    await _settle(tester);

    // The present sibling is on screen, so "no row" below is not the trivially
    // true statement that nothing was listed at all.
    expect(find.text('rating'), findsOneWidget);
    expect(find.text('memo'), findsNothing);
    expect(find.text('data_root.json'), findsNothing);

    // The row is what carries the actions, and they are what made an absent row
    // worse than merely redundant: the metadata group offers delete, zip and
    // copy, and none of the three can do anything to a directory that is not
    // there. Named on the row's one control, which is the entrance to all three.
    // The sibling that *is* there carries one, so this is an absent row and not a
    // key nobody produces.
    expect(find.byKey(storageRowMenuEntityKey(_info.charaDetailMemoDir)), findsNothing);
    expect(find.byKey(storageRowMenuEntityKey(_info.charaDetailRatingDir)), findsOneWidget);

    // ...while the groups keep their own rows, so an empty level is not read as
    // a group that vanished. That is the other half of the position: absent
    // members disappear, absent groups do not.
    expect(find.text(appSentenceAt('pages.storage.group.metadata.label')), findsOneWidget);
    expect(find.text(appSentenceAt('pages.storage.group.data_root_config.label')), findsOneWidget);
  });

  testWidgets('a directory row dates itself by its newest file when the platform has no directory mtime', (
    tester,
  ) async {
    // `WebLikeFsBackend.list` reports every directory with `modified: null`,
    // which is web's whole answer here (`FileSystemDirectoryHandle` exposes no
    // metadata), so this fixture *is* the arrangement the fallback rule was
    // written for: 「子孫ファイルの最大 mtime で代用する」 -- stand in the newest
    // descendant file's mtime. The Windows arrangement -- a real
    // `Directory.stat().modified` on the listing -- is reached by 'a directory
    // row keeps the timestamp the platform gave it, and takes no walk to show
    // it', which simply does not put the shared backend in the way: the
    // suppression is `WebLikeFsBackend`'s, so `fsBackend = _originalBackend` is
    // the whole of getting the io answer back. Written out because this comment
    // once claimed that arrangement was beyond this suite, which is exactly what
    // left the `ownModified` branch unasserted.
    final older = DateTime(2025, 1, 2, 3, 4);
    final newest = DateTime(2026, 3, 4, 5, 6);
    final recordDir = _info.charaDetailActiveDir / 'rec1';
    File(
      [_root.path, 'documents/umacapture/storage/chara_detail/active/rec1/record.json'].join('/'),
    ).setLastModifiedSync(older);
    File(
      [_root.path, 'documents/umacapture/storage/chara_detail/active/rec1/skill.png'].join('/'),
    ).setLastModifiedSync(newest);

    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);

    // Before the walk there is no value to show, and the directory's own mtime
    // -- which this row used to print -- does not exist on this backend.
    expect(_cellText(storageModifiedCellKey(recordDir)), unknownSizeLabel);

    // One tap, one walk, two cells: the timestamp arrives with the size because
    // it is the same `DirectoryTotals`.
    await tester.tap(find.byKey(storageSizeCellKey(recordDir)));
    await _settle(tester);
    expect(_cellText(storageSizeCellKey(recordDir)), '300 B');
    expect(_cellText(storageModifiedCellKey(recordDir)), formatStorageTimestamp(newest));
    // The *newest*, not whichever the enumeration happened to reach last.
    expect(_cellText(storageModifiedCellKey(recordDir)), isNot(formatStorageTimestamp(older)));
  });

  testWidgets('a directory with no files in it has no timestamp to show', (tester) async {
    // The rule 「空ディレクトリは `—` を出す」 -- an empty directory shows a dash --
    // -- because there is no descendant to take a
    // value from, so the value does not exist: it is not the epoch, and it is
    // not the moment the walk ran.
    final empty = _info.charaDetailActiveDir / 'rec0_empty';
    Directory(empty.path).createSync(recursive: true);

    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);

    await tester.tap(find.byKey(storageSizeCellKey(empty)));
    await _settle(tester);
    // Walked -- the size proves the cell was answered rather than left alone.
    expect(_cellText(storageSizeCellKey(empty)), '0 B');
    expect(_cellText(storageModifiedCellKey(empty)), unknownSizeLabel);
  });

  testWidgets('a folder that scrolls out from under a row does not leave its total behind', (tester) async {
    // `ListView.builder` items carry no key of their own, so a row's `Element`
    // is matched to the next build **by index**. The cells that hold a walk's
    // result in `State` therefore need a key that says *which directory* they
    // are for, or collapsing a level hands one folder's total and timestamp to
    // whichever folder inherits its index. Only the collapsing direction
    // exposes it: inserting rows puts a pending row of a different type at the
    // index first, and the mismatch discards the state on its own.
    _write('documents/umacapture/storage/chara_detail/active/rec1/aaa/f.txt', 7);
    _write('documents/umacapture/storage/chara_detail/active/rec2/g.txt', 500);
    final inner = _info.charaDetailActiveDir / 'rec1' / 'aaa';
    final sibling = _info.charaDetailActiveDir / 'rec2';

    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    final expansion = container.read(storageTreeExpansionProvider.notifier);
    expansion.toggle((group: StorageGroupId.activeRecords, path: null));
    expansion.toggle((group: StorageGroupId.activeRecords, path: (_info.charaDetailActiveDir / 'rec1').path));
    await _settle(tester);

    await tester.tap(find.byKey(storageSizeCellKey(inner)));
    await _settle(tester);
    expect(_cellText(storageSizeCellKey(inner)), '7 B');

    // Collapse `rec1`, which takes `aaa`'s row away and moves `rec2` up into the
    // index it had.
    expansion.toggle((group: StorageGroupId.activeRecords, path: (_info.charaDetailActiveDir / 'rec1').path));
    await _settle(tester);
    expect(find.text('aaa'), findsNothing);
    expect(find.text('rec2'), findsOneWidget);

    // `rec2` has never been asked for a total, so it has none -- and it is not
    // `aaa`'s. Both halves matter: the leaked value is a plausible size, and the
    // row it appears on is the one a delete or a zip would be decided from.
    expect(_cellText(storageSizeCellKey(sibling)), unknownSizeLabel);
    expect(_cellText(storageSizeCellKey(sibling)), isNot('7 B'));
    expect(_cellText(storageModifiedCellKey(sibling)), unknownSizeLabel);

    // ...and asking it directly still answers with its own bytes, so the fix is
    // not "the cell stopped working".
    await tester.tap(find.byKey(storageSizeCellKey(sibling)));
    await _settle(tester);
    expect(_cellText(storageSizeCellKey(sibling)), '500 B');
  });

  testWidgets('a level re-opened from a warm listing does not inherit the row it displaced', (tester) async {
    // The other direction, and the one that shows why "key the rows that can
    // collapse" is not a fix. `storageTreeChildrenProvider` is a family that is
    // not `autoDispose`, so a level listed once stays listed: re-opening it
    // emits its rows in the same build instead of a pending row first, and the
    // pending row is the only thing that would have discarded the `State` under
    // that index. Cold, the defect hides; warm, nothing hides it.
    _write('documents/umacapture/storage/chara_detail/active/rec1/aaa/f.txt', 7);
    _write('documents/umacapture/storage/chara_detail/active/rec2/g.txt', 500);
    final rec1 = _info.charaDetailActiveDir / 'rec1';
    final inner = rec1 / 'aaa';
    final sibling = _info.charaDetailActiveDir / 'rec2';

    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    final expansion = container.read(storageTreeExpansionProvider.notifier);
    expansion.toggle((group: StorageGroupId.activeRecords, path: null));
    // Open `rec1` and close it again, which is what warms its listing without
    // leaving its children on screen.
    expansion.toggle((group: StorageGroupId.activeRecords, path: rec1.path));
    await _settle(tester);
    expansion.toggle((group: StorageGroupId.activeRecords, path: rec1.path));
    await _settle(tester);

    // `rec2` now sits at the index `aaa` will take back.
    await tester.tap(find.byKey(storageSizeCellKey(sibling)));
    await _settle(tester);
    expect(_cellText(storageSizeCellKey(sibling)), '500 B');

    expansion.toggle((group: StorageGroupId.activeRecords, path: rec1.path));
    await _settle(tester);
    expect(find.text('aaa'), findsOneWidget);

    // `aaa` was never asked for a total. It is 7 B, and it is certainly not the
    // 500 B of the folder whose row it took over.
    expect(_cellText(storageSizeCellKey(inner)), unknownSizeLabel);
    expect(_cellText(storageSizeCellKey(inner)), isNot('500 B'));
    await tester.tap(find.byKey(storageSizeCellKey(inner)));
    await _settle(tester);
    expect(_cellText(storageSizeCellKey(inner)), '7 B');
  });

  testWidgets("a directory row keeps the timestamp the platform gave it, and takes no walk to show it", (tester) async {
    // **Without `WebLikeFsBackend`**, so the io backend answers and a directory
    // listing carries the real `Directory.stat().modified` only Windows has.
    // That is the arrangement the derived-timestamp rule must *not* reach: the
    // fallback exists for a platform that has no such value, and a suite that
    // only ever ran the web-shaped backend could not tell the fallback from a
    // replacement. Swapping the backend for one test is what the two subclasses
    // above already do for their own questions.
    fsBackend = _originalBackend;
    final recordDir = _info.charaDetailActiveDir / 'rec1';
    // Distinctly old descendants, so the derived answer and the OS answer cannot
    // be the same string by accident.
    final descendant = DateTime(2001, 2, 3, 4, 5);
    for (final name in ['record.json', 'skill.png']) {
      File(
        [_root.path, 'documents/umacapture/storage/chara_detail/active/rec1/$name'].join('/'),
      ).setLastModifiedSync(descendant);
    }
    final own = Directory(recordDir.path).statSync().modified;
    expect(formatStorageTimestamp(own), isNot(formatStorageTimestamp(descendant)));

    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);

    // Shown before anything is walked: the value came with the listing.
    expect(_cellText(storageModifiedCellKey(recordDir)), formatStorageTimestamp(own));

    // ...and the walk does not overwrite it. The newest descendant is older than
    // the folder itself here, which is the ordinary case on Windows and the one
    // a fallback applied unconditionally would get wrong.
    await tester.tap(find.byKey(storageSizeCellKey(recordDir)));
    await _settle(tester);
    expect(_cellText(storageSizeCellKey(recordDir)), '300 B');
    expect(_cellText(storageModifiedCellKey(recordDir)), formatStorageTimestamp(own));
    expect(_cellText(storageModifiedCellKey(recordDir)), isNot(formatStorageTimestamp(descendant)));
  });

  testWidgets('the font cache takes only its own files out of a directory it shares', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.fontCache, path: null));
    await _settle(tester);

    expect(find.text('MPLUS1Code_regular_x.ttf'), findsOneWidget);
    // The support directory's other children belong to other groups.
    expect(find.text('modules'), findsNothing);
    expect(find.text('modules.zip'), findsNothing);
    expect(find.text('data_root.json'), findsNothing);
  });

  testWidgets('the settings group keeps its Hive files off the screen', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.settings, path: null));
    await _settle(tester);

    // The group opened -- its stores are on screen, which the two tests below
    // assert -- and still shows no `.hive`. This one is only about the file names
    // staying off, so it asserts the opening happened by one of them.
    expect(
      find.text(appSentenceAt('pages.storage.store.name.${storageBoxNameOf(StorageBoxKey.settings)}')),
      findsOneWidget,
    );
    expect(find.text('settings.hive'), findsNothing);
  });

  /// The pair of files one store occupies, written into the fixture.
  ///
  /// Written per test rather than in `setUp`, so the byte totals every other test
  /// in this file asserts stay the ones those tests were written against: the
  /// settings group's contribution to the root total is a fixture fact, and
  /// moving it here would have re-tuned three unrelated expectations.
  void writeStore(String name, int hiveBytes) {
    _write('documents/umacapture/settings/$name.hive', hiveBytes);
    // 18 bytes is what `hive_ce` actually writes into a lock file; the number
    // matters only in that it is not zero, so a sum that dropped it is visible.
    _write('documents/umacapture/settings/$name.lock', 18);
  }

  /// Dates the pair the way the real directory is dated: the lock is newer than
  /// the store, because `hive_ce` takes every lock at startup while a `.hive` is
  /// only touched when that setting changes. Two years apart so the row's
  /// timestamp says unambiguously which of the two it read — on the real machine
  /// the two are minutes apart and either would look plausible.
  void dateStore(String name, {required DateTime hive, required DateTime lock}) {
    final directory = '${_root.path}${Platform.pathSeparator}documents/umacapture/settings';
    File('$directory/$name.hive').setLastModifiedSync(hive);
    File('$directory/$name.lock').setLastModifiedSync(lock);
  }

  testWidgets('the settings group lists the stores themselves, sized in pairs', (tester) async {
    // `settings.hive` is already there from `setUp`; give it its lock and add a
    // second store, so a size that counted only `.hive` and a size that counted
    // only one store are both distinguishable from the right answer.
    _write('documents/umacapture/settings/settings.lock', 18);
    writeStore('column_spec', 100);

    final container = _container(onWeb: false);
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.settings, path: null));
    await _settle(tester);

    // Every store, by the name it is stored under. Enumerated from
    // `StorageBoxKey` rather than written out: the claim is that the view shows
    // *the app's* stores, and a list copied into this file would agree with
    // itself after the app gained a ninth.
    for (final name in storageBoxNames) {
      expect(find.byKey(storageBoxRowKey(name)), findsOneWidget, reason: name);
    }
    // And there are eight of them, which is the number of settings stores the
    // synthetic node was specified to list and the
    // count stage 4e's value-rendering rules were derived against. A ninth is not
    // a failure of this screen, but it is a fact that has to be looked at rather
    // than absorbed silently.
    expect(storageBoxNames.length, 8);

    // Stage 4e: the row opens the store. Asserted as the row's own callback and
    // not by driving a tap, because what the dialog then shows is
    // `settings_box_preview_view_test.dart`'s subject; the fact worth pinning
    // here is that the row has a callback at all, which until stage 4e it did
    // not.
    final row = find
        .ancestor(of: find.byKey(storageBoxRowKey('column_spec')), matching: find.byType(InkWell))
        .evaluate()
        .single
        .widget;
    expect((row as InkWell).onTap, isNotNull);

    // The pair, added up: 30 + 18 and 100 + 18. A `.hive`-only sum reads 30 B and
    // 100 B here.
    expect(_cellText(storageBoxSizeKey('settings')), '48 B');
    expect(_cellText(storageBoxSizeKey('column_spec')), '118 B');
    // A store with no files yet is unmeasured, not empty: `0 B` would assert an
    // emptiness nothing checked.
    expect(_cellText(storageBoxSizeKey('addon')), unknownSizeLabel);

    // The group's own total and the stores under it describe the same bytes.
    // Stage 3 computes that total by walking the settings directory and knows
    // nothing about stores; this asserts the two readings agree, which is what
    // makes the group row and its children one statement rather than two.
    expect(_cellText(storageGroupSizeKey(StorageGroupId.settings)), '166 B');

    // Still no file names on screen: the rows are `settings`, not
    // `settings.hive`, and the lock the size counted is not a row of its own.
    expect(find.text('settings.hive'), findsNothing);
    expect(find.text('settings.lock'), findsNothing);
  });

  testWidgets('a store is stamped with when it was written, not when it was locked', (tester) async {
    _write('documents/umacapture/settings/settings.lock', 18);
    writeStore('column_spec', 100);
    dateStore('settings', hive: DateTime(2020, 1, 2, 3, 4), lock: DateTime(2022, 11, 12, 13, 14));
    dateStore('column_spec', hive: DateTime(2021, 5, 6, 7, 8), lock: DateTime(2022, 11, 12, 13, 14));

    final container = _container(onWeb: false);
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.settings, path: null));
    await _settle(tester);

    // Each store's own `.hive` date. Reading the locks would give both rows
    // `2022/11/12 13:14` -- one date for eight stores, which is when the app
    // started and not when anything was configured.
    expect(_cellText(storageBoxModifiedKey('settings')), '2020/01/02 03:04');
    expect(_cellText(storageBoxModifiedKey('column_spec')), '2021/05/06 07:08');
    // A store with no file has no date to show, and says so with the same em dash
    // a missing size uses.
    expect(_cellText(storageBoxModifiedKey('addon')), unknownSizeLabel);
  });

  testWidgets('on web the settings group is not empty, and reports no sizes', (tester) async {
    // The same files on the fake disk as the Windows case above. On web they are
    // not where the stores are — `hive_ce` puts them in IndexedDB — so an
    // implementation that listed or walked the settings directory would produce
    // sizes here, and this test is what tells those two implementations apart.
    _write('documents/umacapture/settings/settings.lock', 18);
    writeStore('column_spec', 100);
    dateStore('settings', hive: DateTime(2020, 1, 2, 3, 4), lock: DateTime(2022, 11, 12, 13, 14));

    final container = _container(onWeb: true, originUsage: 4096);
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.settings, path: null));
    await _settle(tester);

    // The actual check point for the settings group being a synthetic node --
    // a list of Hive stores rather than part of the filesystem tree -- on both
    // platforms. The defect this guards against is a settings
    // group that comes out empty on web — which is what a filesystem listing
    // would give, since OPFS holds nothing for it — and it is reachable from the
    // VM only because the platform arrives through `storageOnWebProvider`.
    for (final name in storageBoxNames) {
      expect(find.byKey(storageBoxRowKey(name)), findsOneWidget, reason: name);
    }

    // Unmeasurable, and every one of them: IndexedDB reports no per-store usage.
    // Asserted for all eight rather than for a sample, because the failure being
    // excluded is a size leaking through from the files that are sitting right
    // there in the fixture.
    for (final name in storageBoxNames) {
      expect(_cellText(storageBoxSizeKey(name)), unknownSizeLabel, reason: name);
    }
    // And no timestamps either, for a different browser reason than the sizes:
    // an IndexedDB record carries no modification time at all. The dated `.hive`
    // in the fixture is what makes this an assertion rather than a coincidence --
    // a passthrough to the filesystem shows `2020/01/02 03:04` here.
    for (final name in storageBoxNames) {
      expect(_cellText(storageBoxModifiedKey(name)), unknownSizeLabel, reason: name);
    }

    // Which is also why the group's own total stays a dash rather than becoming
    // `0 B` — the reading stage 3 settled on, unchanged by this stage.
    expect(_cellText(storageGroupSizeKey(StorageGroupId.settings)), unknownSizeLabel);
  });

  test('the settings group offers no filesystem level to anything that asks for one', () async {
    final container = _container();
    addTearDown(container.dispose);

    // The tree does not take this route for a synthetic group, so this is about
    // the route itself: were something to ask the settings group for a listing,
    // the answer is empty and not the contents of the settings directory. The
    // fixture has a `.hive` in there, so a passthrough implementation returns one
    // entry here.
    final children = await container.read(
      storageTreeChildrenProvider((group: StorageGroupId.settings, path: null)).future,
    );
    expect(children, isEmpty);
  });

  testWidgets('a directory total is computed only when its own cell is asked for one', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);
    _backend.resetAllCounts();

    final sizeCell = find.byKey(storageSizeCellKey(_info.charaDetailActiveDir / 'rec1'));
    expect(sizeCell, findsOneWidget);
    // Drawn, and still unknown: drawing the row must not start the walk.
    expect(find.descendant(of: sizeCell, matching: find.text(unknownSizeLabel)), findsOneWidget);
    expect(_backend.recursiveListCalls, 0);

    await tester.tap(sizeCell);
    await _settle(tester);
    expect(find.descendant(of: sizeCell, matching: find.text('300 B')), findsOneWidget);
    expect(_backend.recursiveListCalls, 1);
  });

  testWidgets('every settings store is named in Japanese, not by the name it is kept under', (tester) async {
    final container = _container(onWeb: false);
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.settings, path: null));
    await _settle(tester);

    // Enumerated from `StorageBoxKey`, so a ninth store is a red row here rather
    // than a row nobody wrote an expectation for; the sentences come out of the
    // shipped `ja.json` as literals, because `expect(shown, someKey.tr())`
    // compares a key with itself and passes for a key that was never added.
    for (final key in StorageBoxKey.values) {
      final name = storageBoxNameOf(key);
      expect(_cellText(storageBoxRowKey(name)), appSentenceAt('pages.storage.store.name.$name'), reason: name);
      // The other half, and the one an equality check cannot make on its own: the
      // internal spelling is not on the screen at all. A row that showed both
      // would satisfy the assertion above.
      expect(find.text(name), findsNothing, reason: name);
    }
  });

  testWidgets('a total being walked says so in words, not only by spinning', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);

    final sizeCell = find.byKey(storageSizeCellKey(_info.charaDetailActiveDir / 'rec1'));
    await tester.tap(sizeCell);
    // One frame, deliberately: the walk is a real `dart:io` future, so this is
    // the state between the tap and the answer — the one that must read
    // 「計算中…」 rather than a number or a blank, because a recursive walk is
    // asynchronous and the row has to say so.
    await tester.pump();
    expect(
      find.descendant(of: sizeCell, matching: find.text(appSentenceAt('pages.storage.status.calculating'))),
      findsOneWidget,
    );

    await _settle(tester);
    expect(find.descendant(of: sizeCell, matching: find.text('300 B')), findsOneWidget);
  });

  testWidgets('a level that has not been read yet says it is being read', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await tester.pump();
    expect(find.text(appSentenceAt('pages.storage.status.loading')), findsWidgets);

    // And the word goes away once the level is there, so this is a state and not
    // a permanent caption.
    await _settle(tester);
    expect(find.text(appSentenceAt('pages.storage.status.loading')), findsNothing);
    expect(find.text('rec1'), findsOneWidget);
  });

  testWidgets('a level that could not be read says so in Japanese', (tester) async {
    fsBackend = _ListFailingBackend(_originalBackend, 'chara_detail/active');
    final container = _container(retryOnError: false);
    await _pumpTree(tester, container);

    // Not `_settle`, here or below: riverpod 3 retries a provider that threw, so
    // a tab holding a directory it cannot list never reaches a frame with nothing
    // pending on it — the group's own total cycles error → loading → error for as
    // long as the refusal lasts. Each wait names the condition it is actually
    // waiting for instead.
    //
    // The roots first, because `storageTreeExpansionProvider` is only alive while
    // something watches it: toggling before the tree has built reaches a notifier
    // that is disposed on the next tick, and the expansion is silently lost.
    await settleUntil(
      tester,
      () => find.text(appSentenceAt('pages.storage.group.active_records.label')).evaluate().isNotEmpty,
      describe: 'the group roots to be drawn',
    );
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await settleUntil(
      tester,
      () => find.text(appSentenceAt('pages.storage.status.list_failed')).evaluate().isNotEmpty,
      describe: 'the tree to say that the level could not be read',
    );

    // The row this replaces was an error glyph and nothing else, which says
    // "something" to a sighted reader and nothing at all to a screen reader.
    expect(find.text(appSentenceAt('pages.storage.status.list_failed')), findsOneWidget);
  });

  testWidgets('off web the root carries one total, and it is the sum of the groups', (tester) async {
    await _pumpTree(tester, _container(onWeb: false));
    await _settle(tester);

    expect(find.text(appSentenceAt('pages.storage.summary.app_total')), findsOneWidget);
    // 300 (the record) + 60 (rating) + 40 (modules) + 30 (the Hive box)
    // + 50 (data_root.json) + 10 (the font) + 50 (the residue): every byte the
    // fixture wrote, which is what "this app's data" has to mean.
    expect(_cellText(storageAppDataTotalKey), '540 B');

    // Windows has no notion of what this site costs a browser, so the second row
    // is *absent* rather than present-and-unknown: a dash would claim the concept
    // exists and merely could not be read.
    expect(find.byKey(storageOriginUsageKey), findsNothing);
    expect(find.text(appSentenceAt('pages.storage.summary.browser_total')), findsNothing);
    expect(find.text(appSentenceAt('pages.storage.summary.browser_total_note')), findsNothing);
  });

  testWidgets('on web the root carries a second total, the browser\'s own', (tester) async {
    await _pumpTree(tester, _container(onWeb: true, originUsage: 4096));
    await _settle(tester);

    expect(find.text(appSentenceAt('pages.storage.summary.app_total')), findsOneWidget);
    expect(find.text(appSentenceAt('pages.storage.summary.browser_total')), findsOneWidget);
    // The note is required, not decorative: without it the second row looks like a
    // contradiction of the first.
    expect(find.text(appSentenceAt('pages.storage.summary.browser_total_note')), findsOneWidget);

    // The browser's figure is the browser's. It is not folded into the app total
    // and is not derived from any walk.
    expect(_cellText(storageOriginUsageKey), '4.0 KB');
    // The app total drops the two groups web does not have (50 + 10) and reports
    // the settings group as unmeasurable instead of as zero -- so it is a marked
    // lower bound, not a number.
    expect(_cellText(storageAppDataTotalKey), '450 B+');
    expect(_cellText(storageGroupSizeKey(StorageGroupId.settings)), unknownSizeLabel);
  });

  testWidgets('every group carries its own total with nothing tapped', (tester) async {
    await _pumpTree(tester, _container());
    await _settle(tester);

    // Nothing was expanded and no size cell was tapped: this is the state the view
    // is in the moment it opens.
    expect(find.text('rec1'), findsNothing);
    expect(_cellText(storageGroupSizeKey(StorageGroupId.activeRecords)), '300 B');
    expect(_cellText(storageGroupSizeKey(StorageGroupId.metadata)), '60 B');
    expect(_cellText(storageGroupSizeKey(StorageGroupId.modules)), '40 B');
    expect(_cellText(storageGroupSizeKey(StorageGroupId.settings)), '30 B');
    expect(_cellText(storageGroupSizeKey(StorageGroupId.dataRootConfig)), '50 B');
    expect(_cellText(storageGroupSizeKey(StorageGroupId.fontCache)), '10 B');
    expect(_cellText(storageGroupSizeKey(StorageGroupId.unclassified)), '50 B');
    // A group whose directory is not there yet holds nothing, which is a
    // measurement and not an absence of one.
    expect(_cellText(storageGroupSizeKey(StorageGroupId.quarantine)), '0 B');
    // And no group is left without one. Enumerated from the table rather than
    // listed here, so a thirteenth group cannot be added without a total.
    for (final group in storageGroups) {
      expect(find.byKey(storageGroupSizeKey(group.id)), findsOneWidget, reason: group.id.name);
    }
  });

  // These two are one guard in two halves, and neither half stands alone: the
  // negative one is also satisfied by a tab that shows no groups at all, and the
  // positive one by a tab that ignores the platform entirely. Both are only
  // reachable because the platform arrives through a provider -- read from
  // `kIsWeb` at the use site, the web arrangement is a branch the VM compiler
  // deletes before either test runs, and building the tree straight off
  // `storageGroups` would stay green forever.
  //
  // They are two `testWidgets` and not one body pumping twice, because
  // `pumpWithContainer` ties the container to the scope widget's lifetime and a
  // second pump *updates* that scope rather than remounting it -- the first
  // container would never be disposed.
  testWidgets('a web build shows only the groups web has', (tester) async {
    const webAbsent = ['pages.storage.group.font_cache.label', 'pages.storage.group.data_root_config.label'];
    await _pumpTree(tester, _container(onWeb: true));
    await _settle(tester);

    for (final key in _groupLabelKeys) {
      expect(
        find.text(appSentenceAt(key)),
        webAbsent.contains(key) ? findsNothing : findsOneWidget,
        reason: 'on web: $key',
      );
    }
  });

  testWidgets('an off-web build shows all twelve, including the two web lacks', (tester) async {
    await _pumpTree(tester, _container(onWeb: false));
    await _settle(tester);

    for (final key in _groupLabelKeys) {
      expect(find.text(appSentenceAt(key)), findsOneWidget, reason: 'off web: $key');
    }
  });

  test('the view lists the groups in the order that was chosen for it', () {
    // Literal, and deliberately not derived from `storageGroups`: the sequence is
    // a decision about how the screen reads, not a consequence of anything the
    // code computes, so it has to exist as data somewhere a reordering cannot
    // quietly agree with. A test that read the order off the definition would
    // stay green for every possible order, which is the same as not testing it —
    // and until this test existed, nothing did.
    const expectedOrder = <StorageGroupId>[
      StorageGroupId.activeRecords,
      StorageGroupId.archivedRecords,
      StorageGroupId.metadata,
      StorageGroupId.quarantine,
      StorageGroupId.modules,
      StorageGroupId.settings,
      StorageGroupId.customSound,
      StorageGroupId.dataRootConfig,
      StorageGroupId.fontCache,
      StorageGroupId.retired,
      StorageGroupId.temp,
      StorageGroupId.unclassified,
    ];
    expect(visibleStorageGroups(onWeb: false).map((group) => group.id).toList(), expectedOrder);

    // Web is the same order with two rows taken out, not an order of its own: the
    // filter drops `fontCache` and `dataRootConfig` and must not disturb what is
    // left. Written out in full for the same reason as above — deriving it by
    // removing two entries from `expectedOrder` would pass whatever the filter
    // did to the rest.
    expect(visibleStorageGroups(onWeb: true).map((group) => group.id).toList(), <StorageGroupId>[
      StorageGroupId.activeRecords,
      StorageGroupId.archivedRecords,
      StorageGroupId.metadata,
      StorageGroupId.quarantine,
      StorageGroupId.modules,
      StorageGroupId.settings,
      StorageGroupId.customSound,
      StorageGroupId.retired,
      StorageGroupId.temp,
      StorageGroupId.unclassified,
    ]);
  });

  test('web drops exactly the two groups that do not exist there', () {
    expect(visibleStorageGroups(onWeb: false).length, 12);

    final onWeb = visibleStorageGroups(onWeb: true).map((group) => group.id).toList();
    expect(onWeb.length, 10);
    expect(onWeb, isNot(contains(StorageGroupId.fontCache)));
    expect(onWeb, isNot(contains(StorageGroupId.dataRootConfig)));
    expect(onWeb, contains(StorageGroupId.activeRecords));
  });
}
