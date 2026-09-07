// The storage view's delete UI (stage 6b): the two-step confirmation an
// unrecoverable group demands (a warning, then a checkbox the user has to tick
// before the confirm button becomes usable), and the sentence a delete that only
// partly succeeded owes the user.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_delete_action_test.dart
//
// Two claims are pinned here, and each is written so that removing the thing it
// names turns it red rather than merely leaving it unexercised.
//
//  1. **A 復旧不能 group's confirm button is inert until the box is ticked**
//     Asserted twice over: the button reports itself disabled, and
//     -- because "disabled" is a property of a widget a finder can miss --
//     long-pressing it while the box is unticked leaves the file on disk. The
//     second assertion cannot be satisfied by a finder that matches nothing: it
//     reads the filesystem.
//
//     `find.byType` matches on `runtimeType` exactly, so a finder naming an
//     abstract button class matches nothing and passes whatever the screen
//     holds. Every button assertion here goes through `_confirmButton`, which
//     matches with `is`, and the disabled/enabled pair is asserted in both
//     directions in the same test so a finder that found nothing would fail the
//     enabled half.
//
//  2. **A partial delete is reported as one.** The sentence is built
//     from the report's own three-way partition and compared against the shipped
//     `ja.json` read as a literal (`appSentenceAt`): `.tr()` renders an
//     unresolved key *as the key*, so `expect(shown, key.tr())` is key-equals-key
//     and passes with the key deleted.
//
// WHAT THIS SUITE DOES NOT REACH. The delete runs on the io backend behind
// `WebLikeFsBackend`, so OPFS's own refusal modes and the cross-tab lock timeout
// are not exercised here (`storage_delete_test.dart` injects the latter at the
// lock boundary). The settings group's stores are not reached at all: they are
// not paths, and their own removal path -- one `Hive.deleteBoxFromDisk` per store
// -- belongs to a later stage. Nor is anything asserted here about what the view
// shows *after* a delete: the provider-invalidate table now runs inside
// `runStorageDelete`, but what it does is `storage_delete_invalidation_test.dart`'s
// subject, and every group used below is one that table marks 不要 -- so these
// tests stay indifferent to it. The image-cache eviction is a later stage's and is
// absent entirely.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/settings_boxes.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/settings_store_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/chara_detail/common.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_settings.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/web_like_fs_backend.dart';

/// Delegates to the io backend but refuses to delete the paths [refuse] selects.
///
/// Holding a file open for real depends on the operating system's sharing rules,
/// which differ between the two platforms this view ships on, so the refusal is
/// injected at the boundary the engine talks to instead.
class _RefusingFsBackend extends WebLikeFsBackend {
  _RefusingFsBackend(super.inner, {required this.refuse});

  final bool Function(String path) refuse;

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    if (refuse(path)) {
      throw FileSystemException(_refusalDetail, path);
    }
    return super.delete(path, recursive: recursive);
  }
}

const _refusalDetail = 'The process cannot access the file because it is being used';

/// Delegates to the io backend but holds every delete until [until] completes.
///
/// The paths branch's counterpart to `_container`'s `storeGate`: a real io delete
/// finishes on its own schedule, which leaves no window in which the delete is
/// under way and the dialog is still up. Injected at the backend rather than at
/// the runner so everything above it -- the exclusion, the walk, the report -- is
/// the production path.
class _DelayingFsBackend extends WebLikeFsBackend {
  _DelayingFsBackend(super.inner, {required this.until});

  final Future<void> until;

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    await until;
    return super.delete(path, recursive: recursive);
  }
}

late Directory _tempRoot;
late PathInfo _layout;
late FsBackend _realBackend;

StorageGroup _groupOf(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

/// Creates [relative] under the temp root and answers it as a [FilePath].
///
/// Spelled through [PathEntity] and not with a literal separator: the report and
/// the tree's keys carry the paths the engine saw, and on Windows those are
/// backslash-joined. A slash-joined literal compares unequal to every one of
/// them — and, handed to a backend fake as the path to refuse, matches nothing,
/// so the refusal the test is about silently does not happen.
FilePath _seed(String relative) {
  final parts = relative.split('/');
  var directory = DirectoryPath(_tempRoot.path);
  for (final part in parts.take(parts.length - 1)) {
    directory = directory / part;
  }
  final path = directory.filePath(parts.last);
  final file = File(path.path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('x');
  return path;
}

bool _exists(FilePath path) => File(path.path).existsSync();

/// The paths a request names, or null when it names none.
///
/// Null and not `[]`: "this deletes no path" is the settings group's answer and
/// "this deletes nothing" is the answer of a group with no button, and a test
/// that spelled both as the empty list could not tell them apart -- which is the
/// collision the request type was introduced to end.
List<String>? _pathsOf(StorageDeleteRequest? request) {
  return request is StorageDeletePathsRequest ? [for (final target in request.targets) target.path] : null;
}

List<String>? _requestedPaths(StorageGroup group) => _pathsOf(storageGroupDeleteRequest(_layout, group));

ProviderContainer _container({StorageDeleteReport? storeOutcome, Future<void>? storeGate}) {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      // The delete path resolves its own directories from the layout rather than
      // from `pathInfoProvider`, so it keeps working while the record store is
      // unavailable.
      pathLayoutLoader.overrideWith((ref) async => _layout),
      // Substituted rather than driven: removing eight real stores would prove
      // the removal works and say nothing about the announcement, and the
      // announcement -- "delete failed" must never read as "deleted" -- is
      // what this group is about. `settings_store_delete_test.dart` is where the
      // real removal is measured.
      //
      // [storeGate] buys back the one property the substitution throws away:
      // removing eight Hive boxes takes longer than the frame the caller was
      // dismissed on, while a stand-in that answers within a microtask returns
      // while the caller is still mounted. A test about what happens *after* that
      // unmount hands in a future it completes itself, which pins the ordering
      // instead of racing a clock the fake one does not advance. Every other test
      // here passes none and keeps the microtask it was written against.
      if (storeOutcome case final outcome?)
        settingsStoreDeleteProvider.overrideWithValue(() async {
          await storeGate;
          return outcome;
        }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The confirm button of the dialog's action row.
///
/// Matched with `is` and scoped to the row's key. `find.byType` compares
/// `runtimeType` exactly, so it silently matches nothing for a button built
/// through an `.icon` constructor that returns a private subclass -- and a
/// "there is no enabled button" assertion written that way passes with the
/// button right there on screen.
Finder _confirmButton() {
  return find.descendant(
    of: find.byKey(storageDeleteConfirmRowKey),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton && widget is! OutlinedButton),
  );
}

bool _confirmEnabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(_confirmButton()).enabled;

Future<void> _pumpDialog(WidgetTester tester, ProviderContainer container, Widget dialog) {
  return pumpWithContainer(tester, container, MaterialApp(home: Scaffold(body: dialog)));
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does
/// not: an io delete completes off it.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// The confirmation's cancel button, matched the way [_confirmButton] is.
///
/// `find.byType(OutlinedButton)` would match nothing: `OutlinedButton.icon`
/// returns a private subclass and `byType` compares `runtimeType` exactly, so a
/// "cancel is disabled" assertion written that way would pass with the button
/// live on screen.
Finder _cancelButton() {
  return find.descendant(
    of: find.byKey(storageDeleteConfirmRowKey),
    matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
  );
}

/// The dialog title bar's close (×) button.
///
/// Reached through its tooltip rather than its icon, so it is *this* dialog's
/// close button and not any other × the screen happens to carry.
Finder _closeButton() {
  return find.descendant(
    of: find.byTooltip(_sentence('pages.storage.delete.close_tooltip')),
    matching: find.byType(IconButton),
  );
}

/// A settings delete stopped in mid-flight, with the confirmation still up.
typedef _HeldDelete = ({Completer<void> gate, List<ToastData> toasts, ProviderContainer container});

/// Opens the settings confirmation over a real [DialogLayer] and confirms it,
/// leaving the removal held open by the gate it returns.
///
/// The settings branch and not a file delete, because it is the one this suite
/// can hold open: `_container`'s `storeGate` stops the substituted removal from
/// returning, which is exactly the window in which the dialog must refuse to be
/// closed. A file delete on the io backend finishes on its own schedule and
/// offers no such window.
Future<_HeldDelete> _startHeldSettingsDelete(WidgetTester tester) async {
  final subjects = [
    for (final key in StorageBoxKey.values)
      StorageDeleteStoreSubject(name: storageBoxNameOf(key), labelKey: storageBoxLabelKey(key)),
  ];
  final gate = Completer<void>();
  final container = _container(
    storeOutcome: StorageDeleteReport(deleted: subjects),
    storeGate: gate.future,
  );
  final toasts = <ToastData>[];
  final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
  addTearDown(subscription.close);

  await pumpWithContainer(
    tester,
    container,
    const MaterialApp(
      home: Scaffold(body: DialogLayer(child: SizedBox.shrink())),
    ),
  );
  CardDialog.show(
    container.read(refBaseProvider),
    (_) => StorageDeleteConfirmDialog(
      group: _groupOf(StorageGroupId.settings),
      request: const StorageDeleteSettingsRequest(),
      subject: 'settings',
    ),
    over: true,
  );
  await tester.pump();
  // Read from the group rather than written here, as the group above does.
  if (tester.any(find.byKey(storageDeleteAcknowledgeKey))) {
    await tester.tap(find.byKey(storageDeleteAcknowledgeKey));
    await tester.pump();
  }
  await tester.longPress(_confirmButton());
  await tester.pump();
  expect(find.byKey(storageDeleteConfirmRowKey), findsOneWidget, reason: 'the delete was not held open');
  return (gate: gate, toasts: toasts, container: container);
}

/// Releases [held] and asserts the delete finished, announced itself and closed.
///
/// The second half of every exit test: shutting a door must not also stop the
/// delete behind it, and a dialog that survived the exit but silently dropped
/// its delete would satisfy the first assertion alone.
Future<void> _expectHeldDeleteFinished(WidgetTester tester, _HeldDelete held) async {
  held.gate.complete();
  await _settle(tester);
  expect(held.toasts, hasLength(1), reason: 'the delete finished without saying so');
  expect(held.toasts.single.type, ToastType.success, reason: 'the delete that ran was reported as a failure');
  expect(find.byKey(storageDeleteResultKey), findsOneWidget, reason: 'the restart panel never opened');
  expect(find.byKey(storageDeleteConfirmRowKey), findsNothing, reason: 'the confirmation outlived the delete');
}

/// A sentence from the shipped `ja.json` with its placeholders filled in.
String _sentence(String key, [Map<String, String> args = const {}]) {
  var text = appSentenceAt(key);
  for (final entry in args.entries) {
    // The placeholder has to be *there*: interpolating a name `ja.json` does not
    // carry leaves the shipped braces standing on both sides of the comparison,
    // so a renamed placeholder would agree with itself and pass while the app
    // rendered 「{title}を削除します。」. Checked here rather than only in the
    // expectation, because this helper builds the expected value.
    expect(text, contains('{${entry.key}}'), reason: '$key carries no {${entry.key}} to fill in');
    text = text.replaceAll('{${entry.key}}', entry.value);
  }
  expect(text, isNot(contains('{')), reason: '$key still carries a placeholder no argument named');
  return text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_storage_delete_action');
    _realBackend = fsBackend;
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    fsBackend = _realBackend;
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  group('the second confirmation gates the delete', () {
    testWidgets('an unrecoverable group deletes nothing until the box is ticked', (tester) async {
      final file = _seed('documents/storage/chara_detail/metadata/rating/default.json');
      final container = _container();
      await _pumpDialog(
        tester,
        container,
        StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.metadata),
          request: StorageDeletePathsRequest([file]),
          subject: 'default.json',
        ),
      );

      expect(find.byKey(storageDeleteAcknowledgeKey), findsOneWidget);
      expect(_confirmEnabled(tester), isFalse);

      // The assertion that cannot be fooled by a finder: press it anyway and read
      // the disk. A gate that existed only as a greyed-out style would delete
      // here.
      await tester.longPress(_confirmButton());
      await _settle(tester);
      expect(_exists(file), isTrue, reason: 'the delete ran without the acknowledgement');

      await tester.tap(find.byKey(storageDeleteAcknowledgeKey));
      await tester.pump();
      expect(_confirmEnabled(tester), isTrue);

      await tester.longPress(_confirmButton());
      await _settle(tester);
      expect(_exists(file), isFalse, reason: 'the acknowledged delete did not run');
    });

    testWidgets('a harmless group confirms once and deletes', (tester) async {
      final file = _seed('documents/temp/scratch.bin');
      final container = _container();
      await _pumpDialog(
        tester,
        container,
        StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.temp),
          request: StorageDeletePathsRequest([file]),
          subject: 'scratch.bin',
        ),
      );

      expect(find.byKey(storageDeleteAcknowledgeKey), findsNothing);
      expect(_confirmEnabled(tester), isTrue);

      await tester.longPress(_confirmButton());
      await _settle(tester);
      expect(_exists(file), isFalse);
    });

    // Enumerated over the group list rather than over a list of ids written here:
    // a thirteenth group is covered the moment it is declared, and cannot arrive
    // with no friction decided for it.
    for (final group in storageGroups.where(storageGroupOffersDelete)) {
      testWidgets('${group.id.name} shows the friction its group declares', (tester) async {
        final container = _container();
        await _pumpDialog(
          tester,
          container,
          StorageDeleteConfirmDialog(
            group: group,
            // The group's own request where it has one, so the settings group is
            // exercised as the view actually builds it rather than through a path
            // request it would never be given.
            request:
                storageGroupDeleteRequest(_layout, group) ??
                StorageDeletePathsRequest([FilePath('${_tempRoot.path}/nothing.bin')]),
            subject: 'nothing.bin',
          ),
        );

        final doubled = group.deleteFriction == StorageDeleteFriction.doubleConfirm;
        expect(find.byKey(storageDeleteAcknowledgeKey), doubled ? findsOneWidget : findsNothing);
        expect(_confirmEnabled(tester), !doubled);
        // The loud box is the strong-warning half of double confirmation; a
        // single-confirm group shows the same warning as ordinary text.
        expect(find.byType(WarningCard), doubled ? findsOneWidget : findsNothing);
        // **The warning itself, and this dialog is now the only place it is
        // shown.** The tree used to render the same paragraph when the group was
        // expanded, so a version that dropped it here would still have been
        // reachable on screen; it is not any more. Read out of `ja.json` as a
        // literal — `.tr()` renders an unresolved key as the key, so comparing
        // against `group.deleteWarningKey?.tr()` would pass with the entry
        // deleted.
        expect(find.text(appSentenceAt(group.deleteWarningKey ?? '')), findsOneWidget);
        // **Both paragraphs, on screen.** The shape is asserted over `ja.json` in
        // `storage_wording_test.dart`; what is added here is that the card draws the whole of
        // it. `quarantine` shipped with the shared first sentence and nothing else, so this
        // box could be on screen saying only what the acknowledge checkbox beside it says.
        final drawn = tester.widget<Text>(find.text(appSentenceAt(group.deleteWarningKey ?? ''))).data ?? '';
        expect(drawn.split('\n\n'), hasLength(2), reason: '${group.id.name} draws a half warning');
      });
    }

    test('the loop above covers every group that offers a delete, and there are eleven', () {
      // The guard on the loop: `where(storageGroupOffersDelete)` is a filter, and
      // a filter that started matching nothing would leave zero tests registered
      // and a green file. The count is literal so a group gaining or losing its
      // delete is a red line here rather than a silently smaller loop.
      expect(storageGroups.where(storageGroupOffersDelete), hasLength(11));
      expect(storageGroups, hasLength(12));
    });

    // **The friction values themselves are not re-asserted here.**
    // `storage_group_test.dart` already transcribes the friction table literally
    // -- one expected friction per group, for all twelve -- and already
    // asserts that `operations` and `deleteFriction` agree in both directions.
    // Restating either would be this file re-implementing, on the caller side, a
    // classification that is checked where it is declared — and the copy is the
    // one that goes stale. What belongs here is the step after: that the dialog
    // *renders* whatever those values say, which the loop above asserts group by
    // group.
  });

  group('a partial delete is reported as one', () {
    test('the sentence names the total, the count and the cause', () {
      final report = StorageDeleteReport(
        deleted: [StorageDeletePathSubject('a/one.json')],
        failed: [
          StorageDeleteFailure(
            subject: StorageDeletePathSubject('a/two.json'),
            reason: StorageDeleteFailureReason.refused,
            detail: _refusalDetail,
          ),
        ],
        retained: [
          StorageDeleteRetention(
            subject: StorageDeletePathSubject('a'),
            reason: StorageDeleteRetentionReason.blockedBySurvivor,
          ),
        ],
      );

      final message = storageDeleteOutcomeMessage(report);
      expect(message.type, ToastType.warning);
      expect(
        message.description,
        _sentence('pages.storage.delete.partial', {
          'total': '3',
          'deleted': '1',
          'cause': appSentenceAt('pages.storage.delete.cause_in_use'),
        }),
      );
    });

    test('a complete delete says how many, and a refused one says none went', () {
      final complete = storageDeleteOutcomeMessage(
        const StorageDeleteReport(deleted: [StorageDeletePathSubject('a'), StorageDeletePathSubject('b')]),
      );
      expect(complete.type, ToastType.success);
      expect(complete.description, _sentence('pages.storage.delete.completed', {'count': '2'}));

      final refused = storageDeleteOutcomeMessage(
        StorageDeleteReport.wholeRequest(
          subject: StorageDeletePathSubject('a'),
          reason: StorageDeleteFailureReason.lockBusy,
          detail: 'busy',
        ),
      );
      expect(refused.type, ToastType.error);
      expect(
        refused.description,
        _sentence('pages.storage.delete.none', {'cause': appSentenceAt('pages.storage.delete.cause_busy')}),
      );
    });

    test('a real half-failed folder delete announces the split and offers the paths', () async {
      final kept = _seed('documents/temp/session/held.bin');
      final gone = _seed('documents/temp/session/free.bin');
      fsBackend = _RefusingFsBackend(_realBackend, refuse: (path) => path == kept.path);
      final container = _container();
      final toasts = <ToastData>[];
      final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);

      final report = await runStorageDelete(
        container.read(refBaseProvider),
        group: _groupOf(StorageGroupId.temp),
        request: StorageDeletePathsRequest([_layout.tempDir / 'session']),
      );

      // The three-way partition survives to the surface: one file went, one was
      // refused, and the folder was never attempted because of it.
      expect(report.deletedPaths, [gone.path]);
      expect(report.failed.map((e) => e.subject.path), [kept.path]);
      expect(report.retained, [
        StorageDeleteRetention(
          subject: StorageDeletePathSubject((_layout.tempDir / 'session').path),
          reason: StorageDeleteRetentionReason.blockedBySurvivor,
        ),
      ]);

      // The toast travels through a stream provider, so the listener above runs a
      // turn later than the delete returns.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(toasts.single.type, ToastType.warning);
      expect(
        toasts.single.description,
        _sentence('pages.storage.delete.partial', {
          'total': '3',
          'deleted': '1',
          'cause': appSentenceAt('pages.storage.delete.cause_in_use'),
        }),
      );
      // A partial delete owes the user the list of what did not go, and that list
      // cannot fit in a toast, so a panel is opened as
      // well. Its absence is what this assertion is for.
      expect(container.read(dialogBuilderProvider), isNotNull);
    });

    test('a complete delete opens no panel', () async {
      final file = _seed('documents/temp/session/free.bin');
      final container = _container();

      final report = await runStorageDelete(
        container.read(refBaseProvider),
        group: _groupOf(StorageGroupId.temp),
        request: StorageDeletePathsRequest([file]),
      );

      expect(report.isComplete, isTrue);
      expect(container.read(dialogBuilderProvider), isNull);
    });

    testWidgets('the panel names every survivor, attempted or not', (tester) async {
      final report = StorageDeleteReport(
        deleted: [StorageDeletePathSubject('a/one.json')],
        failed: [
          StorageDeleteFailure(
            subject: StorageDeletePathSubject('a/two.json'),
            reason: StorageDeleteFailureReason.refused,
            detail: _refusalDetail,
          ),
        ],
        retained: [
          StorageDeleteRetention(
            subject: StorageDeletePathSubject('a'),
            reason: StorageDeleteRetentionReason.blockedBySurvivor,
          ),
        ],
      );
      final headline = storageDeleteOutcomeMessage(report).description;
      await _pumpDialog(tester, _container(), StorageDeleteResultDialog(report: report, headline: headline));

      expect(find.text(headline), findsOneWidget);
      expect(find.text('a/two.json'), findsOneWidget);
      // The platform's own words about the refused entry, not a house sentence:
      // it is the only thing that tells one refusal from another.
      expect(find.textContaining(_refusalDetail), findsOneWidget);
      // Retained is shown too. Folding it into the failures would report a
      // directory as refused by a platform that was never asked about it.
      expect(find.text('a'), findsOneWidget);
      // And the entry that did go is not listed as a survivor.
      expect(find.text('a/one.json'), findsNothing);
      // The blocked ancestor carries no sentence of its own: the entry holding it
      // is named a row above with the platform's own words, and repeating that
      // per ancestor is what the retained list exists to avoid. In particular it
      // must not borrow the sentence the *other* retention reason ships, which
      // would tell this user their bytes were moved somewhere when nothing was.
      expect(find.text(appSentenceAt('pages.storage.delete.retention_reason.set_aside')), findsNothing);
    });

    testWidgets('a survivor this delete set aside says, on its own row, why it is still there', (tester) async {
      // The other half of the defect the cause clause carried. The row for the
      // shelf the drain filled was rendered with a null detail, so a user whose
      // record had just been moved out of a half-written slot was shown the path
      // and nothing else — at the one moment the app knows exactly what is in it
      // and what to do about it.
      const report = StorageDeleteReport(
        retained: [
          StorageDeleteRetention(
            subject: StorageDeletePathSubject('documents/chara_detail/quarantine'),
            reason: StorageDeleteRetentionReason.setAsideByThisDelete,
          ),
        ],
      );
      final headline = storageDeleteOutcomeMessage(report).description;
      await _pumpDialog(tester, _container(), StorageDeleteResultDialog(report: report, headline: headline));

      expect(find.text('documents/chara_detail/quarantine'), findsOneWidget);
      expect(find.text(appSentenceAt('pages.storage.delete.retention_reason.set_aside')), findsOneWidget);
    });
  });

  group('a settings delete that failed is not announced as one that worked', () {
    // The eight stores, refused. A settings delete failing is the outcome that
    // made reporting failure and partial success a shipping requirement at all:
    // stage 0 measured the raw removal failing on Windows with a sharing
    // violation, so "deleted everything" here can be a lie.
    StorageDeleteReport refusedStores({int deleted = 0}) {
      final subjects = [
        for (final key in StorageBoxKey.values)
          StorageDeleteStoreSubject(name: storageBoxNameOf(key), labelKey: storageBoxLabelKey(key)),
      ];
      return StorageDeleteReport(
        deleted: subjects.take(deleted).toList(),
        failed: [
          for (final subject in subjects.skip(deleted))
            StorageDeleteFailure(subject: subject, reason: StorageDeleteFailureReason.refused, detail: _refusalDetail),
        ],
      );
    }

    Future<List<ToastData>> announce(ProviderContainer container) async {
      final toasts = <ToastData>[];
      final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);
      await runStorageDelete(
        container.read(refBaseProvider),
        group: _groupOf(StorageGroupId.settings),
        request: const StorageDeleteSettingsRequest(),
      );
      // The toast travels through a stream provider, so the listener runs a turn
      // later than the delete returns.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return toasts;
    }

    test('every store refused is announced as a failure, and never as a deletion', () async {
      final container = _container(storeOutcome: refusedStores());
      final toasts = await announce(container);

      expect(toasts.single.type, ToastType.error);
      expect(
        toasts.single.description,
        _sentence('pages.storage.delete.none', {'cause': appSentenceAt('pages.storage.delete.cause_in_use')}),
      );
      // Stated as its own assertion rather than left implied by the one above:
      // this is the sentence a delete that removed nothing must never produce,
      // and a message built some other way
      // that happened not to equal the expected one would still pass that check.
      expect(
        toasts.single.description,
        isNot(_sentence('pages.storage.delete.completed', {'count': '8'})),
        reason: 'a delete that removed nothing was announced as one that removed everything',
      );
      // A failed delete owes the list of what stayed as well as the sentence.
      expect(container.read(dialogBuilderProvider), isNotNull);
    });

    test('a partly refused settings delete is announced as the split it was', () async {
      final container = _container(storeOutcome: refusedStores(deleted: 5));
      final toasts = await announce(container);

      expect(toasts.single.type, ToastType.warning);
      expect(
        toasts.single.description,
        _sentence('pages.storage.delete.partial', {
          'total': '8',
          'deleted': '5',
          'cause': appSentenceAt('pages.storage.delete.cause_in_use'),
        }),
      );
    });

    // The negative control for the two above. Break the report -> sentence path
    // and they go red; this one has to stay green, or the suite is only checking
    // that *something* is announced rather than that the right thing is.
    test('a settings delete that did work says so, and still opens the panel', () async {
      final container = _container(storeOutcome: refusedStores(deleted: StorageBoxKey.values.length));
      final toasts = await announce(container);

      expect(toasts.single.type, ToastType.success);
      expect(toasts.single.description, _sentence('pages.storage.delete.completed', {'count': '8'}));
      // Opened on success too, which no other group does: the forced restart is
      // owed whether or not the stores went, because the boxes are unregistered
      // before the removal is attempted and the session cannot read settings again
      // either way.
      expect(container.read(dialogBuilderProvider), isNotNull);
    });

    testWidgets('the panel demands a restart on both outcomes, and names the stores that stayed', (tester) async {
      final refused = refusedStores(deleted: 5);
      await _pumpDialog(
        tester,
        _container(),
        StorageDeleteResultDialog(
          report: refused,
          headline: storageDeleteOutcomeMessage(refused).description,
          notice: appSentenceAt('pages.storage.delete.restart_required'),
          onRestart: () async => true,
        ),
      );

      expect(find.text(appSentenceAt('pages.storage.delete.restart_required')), findsOneWidget);
      expect(find.byKey(storageDeleteRestartKey), findsOneWidget);
      // The stores that stayed, by the name the view shows them under -- which is
      // the Japanese label the tree gives them, and never `telemetry_id`. The
      // expectation is read out of the shipped `ja.json` (`appSentenceAt`),
      // because `.tr()` renders an unresolved key as the key itself and
      // `expect(shown, key.tr())` would therefore pass with the key deleted.
      final stayed = StorageBoxKey.values.last;
      expect(find.text(appSentenceAt(storageBoxLabelKey(stayed))), findsOneWidget);
      // Stated separately, and over every store rather than the one above: this
      // is the exposure this view is forbidden -- it is written for a general
      // user, so no internal store name reaches the screen -- and a panel that showed the label *and* the
      // internal name would satisfy the assertion above while still putting
      // `column_spec` in front of a general user.
      for (final key in StorageBoxKey.values) {
        expect(find.text(storageBoxNameOf(key)), findsNothing, reason: 'the internal store name reached the screen');
      }
      // Neither does the platform's own English about it. A path failure shows
      // that text and must go on doing so -- the contrast is asserted in "the
      // panel names every survivor, attempted or not", which is the negative
      // control for this line: if the detail were dropped for *every* subject,
      // that test goes red and this one stays green.
      expect(find.textContaining(_refusalDetail), findsNothing);
      expect(find.text(appSentenceAt('pages.storage.delete.result_heading')), findsOneWidget);

      // The same panel after a complete delete: the demand stays, and the
      // "these are still there" heading does not appear over an empty list.
      final complete = refusedStores(deleted: StorageBoxKey.values.length);
      await _pumpDialog(
        tester,
        _container(),
        StorageDeleteResultDialog(
          report: complete,
          headline: storageDeleteOutcomeMessage(complete).description,
          notice: appSentenceAt('pages.storage.delete.restart_required'),
          onRestart: () async => true,
        ),
      );

      expect(find.text(appSentenceAt('pages.storage.delete.restart_required')), findsOneWidget);
      expect(find.byKey(storageDeleteRestartKey), findsOneWidget);
      expect(find.text(appSentenceAt('pages.storage.delete.result_heading')), findsNothing);
    });

    // **A restart that never happened has to be said out loud.** The
    // settings delete closes the stores before removing them, so this panel is
    // shown to a session that can no longer read or write a setting; pressing
    // the button on a machine where the relaunch cannot be scheduled -- no
    // PowerShell, or policy refusing it -- returns to a running app that keeps
    // silently forgetting. Nothing else on the panel changes, so the toast is
    // the whole of the difference between "pressed and the app is going away"
    // and "pressed and nothing happened", and it names the remedy the user still
    // has: restart now, by hand.
    testWidgets('a restart the platform could not schedule is announced as a failure', (tester) async {
      final report = refusedStores(deleted: StorageBoxKey.values.length);
      final container = _container();
      final toasts = <ToastData>[];
      final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);
      var presses = 0;

      await _pumpDialog(
        tester,
        container,
        StorageDeleteResultDialog(
          report: report,
          headline: storageDeleteOutcomeMessage(report).description,
          notice: appSentenceAt('pages.storage.delete.restart_required'),
          onRestart: () async {
            presses++;
            return false;
          },
        ),
      );
      await tester.tap(find.byKey(storageDeleteRestartKey));
      await _settle(tester);

      // The button did run: without this, a panel that had stopped calling
      // `onRestart` at all would satisfy every assertion below by never
      // succeeding.
      expect(presses, 1, reason: 'the button did not attempt the restart');
      expect(toasts, hasLength(1), reason: 'the restart failed and the user was told nothing');
      expect(toasts.single.type, ToastType.error);
      // Read out of the shipped `ja.json`, so a deleted key cannot make this
      // agree with itself the way `expect(shown, key.tr())` would.
      expect(toasts.single.description, appSentenceAt('pages.storage.delete.restart_failed'));
      // Its own sentence, stated as its own assertion: the toast used to
      // repeat the panel's demand, which says a restart is needed but not
      // that the button failed to perform it or that the user must now quit
      // and start the app by hand. Re-pointing it at `restart_required`
      // satisfies neither line.
      expect(
        toasts.single.description,
        isNot(appSentenceAt('pages.storage.delete.restart_required')),
        reason: 'the failed restart was announced with the demand the panel already carries',
      );
      // The panel stays, because the demand and the survivor list are still
      // true; a failed restart is not a reason to take them off the screen.
      expect(find.byKey(storageDeleteRestartKey), findsOneWidget);
    });

    // The negative control for the one above. A restart that *is* under way says
    // nothing -- the process is on its way out, and an error toast there would
    // announce a failure that did not happen. Break the branch so it toasts
    // unconditionally and this goes red while the test above stays green.
    testWidgets('a restart that is under way announces nothing', (tester) async {
      final report = refusedStores(deleted: StorageBoxKey.values.length);
      final container = _container();
      final toasts = <ToastData>[];
      final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);

      await _pumpDialog(
        tester,
        container,
        StorageDeleteResultDialog(
          report: report,
          headline: storageDeleteOutcomeMessage(report).description,
          notice: appSentenceAt('pages.storage.delete.restart_required'),
          onRestart: () async => true,
        ),
      );
      await tester.tap(find.byKey(storageDeleteRestartKey));
      await _settle(tester);

      expect(toasts, isEmpty, reason: 'a restart that was scheduled was announced as a failure');
    });
  });

  group('the tree offers the button exactly where the group allows one', () {
    test('a group row removes its own roots, and two shapes have no root to name', () {
      // Two directories, one group: metadata is `rating/` and `memo/`, which is
      // why the runner takes a list rather than one entity.
      expect(_requestedPaths(_groupOf(StorageGroupId.metadata)), [
        _layout.charaDetailRatingDir.path,
        _layout.charaDetailMemoDir.path,
      ]);
      expect(_requestedPaths(_groupOf(StorageGroupId.activeRecords)), [_layout.charaDetailActiveDir.path]);
      for (final id in [
        // The residue is decided by subtraction, so it has no root of its own.
        StorageGroupId.unclassified,
        // A filter over a directory it does not own: deleting that directory
        // would take the recognition modules with it.
        StorageGroupId.fontCache,
        // Offers no delete at all.
        StorageGroupId.dataRootConfig,
      ]) {
        expect(storageGroupDeleteRequest(_layout, _groupOf(id)), isNull, reason: '\${id.name} asked for a delete');
      }
    });

    test('the settings group asks for its stores, never for the path it also names', () {
      final group = _groupOf(StorageGroupId.settings);
      expect(storageGroupDeleteRequest(_layout, group), isA<StorageDeleteSettingsRequest>());
      // The hazard the ordering inside `storageGroupDeleteRequest` exists for.
      // The group *does* resolve to `settings/` — Windows sizes it by that
      // directory — so a resolver that fell through to the path branch would ask
      // for exactly the raw file delete stage 0 measured failing with a sharing
      // violation on Windows and hanging on web. The stores go through Hive's own
      // `deleteBoxFromDisk` instead, which closes before it removes.
      expect(group.resolve(_layout), isNotEmpty, reason: 'the fall-through this ordering avoids is now unreachable');
      expect(_requestedPaths(group), isNull);
      // An entry row cannot be built for it either, so no path under `settings/`
      // has a per-row delete button behind it.
      expect(storageRowDeleteRequest(group, FilePath('\${_tempRoot.path}/settings/settings.hive')), isNull);
    });

    test('an entry row offers a delete iff its group does and is not synthetic', () {
      final entity = FilePath('\${_tempRoot.path}/whatever.json');
      // Enumerated, so a thirteenth group is covered without editing this test.
      for (final group in storageGroups) {
        final offered = storageGroupOffersDelete(group) && !group.isSynthetic;
        expect(
          _pathsOf(storageRowDeleteRequest(group, entity)),
          offered ? [entity.path] : isNull,
          reason: group.id.name,
        );
      }
      // The two answers are not the same for every group, so the loop above is
      // not vacuously satisfied by one of the two branches.
      expect(storageGroups.where(storageGroupOffersDelete), isNotEmpty);
      expect(storageGroups.where((group) => !storageGroupOffersDelete(group)), isNotEmpty);
    });

    testWidgets('the row buttons are on the tree, and absent where the group refuses', (tester) async {
      final file = _seed('documents/temp/scratch.bin');
      _seed('support/data_root.json');
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer(
        overrides: [pathInfoProvider.overrideWithValue(_layout), pathLayoutLoader.overrideWith((ref) async => _layout)],
      );
      addTearDown(container.dispose);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
      await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
      await _settle(tester);

      // Present: the temp group's own row, and the file row inside it.
      expect(find.byKey(storageDeleteGroupKey(StorageGroupId.temp)), findsOneWidget);
      expect(find.byKey(storageDeleteEntityKey(file)), findsOneWidget);
      // Present: the settings group, whose button removes stores and no path at
      // all. It is the whole of stage 6e's wiring seen end to end -- the
      // resolver, the slot and the key -- and it was absent before, because the
      // slot could not tell "deletes no path" from "deletes nothing".
      expect(find.byKey(storageDeleteGroupKey(StorageGroupId.settings)), findsOneWidget);
      // Absent: `data_root.json` offers no delete of its own -- it delegates to the
      // settings page's reset. Asserted beside the two
      // above so a key scheme that matched nothing at all would fail those.
      expect(find.byKey(storageDeleteGroupKey(StorageGroupId.dataRootConfig)), findsNothing);
    });
  });

  group('a delete finishes after its confirmation has closed itself', () {
    // **Entered through the real [DialogLayer], and that is the whole point of
    // this group.** Every other confirmation test in this file pumps the dialog
    // as a bare widget, so it is never unmounted. `_confirm` closes its own
    // dialog and only then awaits the delete, so on the real layer every step
    // after that await runs through a `ref` whose widget is gone. Measured, not
    // supposed: the first thing to touch it is `runUnderStorageExclusion`, which
    // is *before* the removal, so the file is not deleted either -- and the throw
    // lands in a future nobody awaits, so the user is told nothing about any of
    // it. That is the state the user sees as "the row is still there and nobody
    // said anything", and it is structurally invisible to a suite whose
    // confirmation never unmounts.
    //
    // The confirmation now stays up for the whole delete and is closed by
    // `runStorageDelete` once the report is in, so what is pinned here is the
    // whole of that ordering: the delete happens, the view re-reads, the outcome
    // is announced, and the dialog is gone by the end.
    //
    // Shown through [CardDialog.show] rather than [showStorageDeleteConfirmation]
    // only because that one takes a `WidgetRef`; the two agree in everything else
    // -- same builder, same `over: true`.
    //
    // Every storage read is issued inside [WidgetTester.runAsync]. A `testWidgets`
    // body runs on a fake clock that never drains `dart:io`'s completions, so a
    // listing started outside one never finishes -- not even inside a later
    // `runAsync`, because the future was already created in the fake zone.
    testWidgets('the list re-reads and the outcome is announced', (tester) async {
      final file = _seed('documents/temp/scratch.bin');
      final container = _container();
      const node = (group: StorageGroupId.temp, path: null);
      final toasts = <ToastData>[];
      final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);

      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: Scaffold(body: DialogLayer(child: SizedBox.shrink())),
        ),
      );
      await tester.runAsync(() async {
        // Held open for the rest of the test: a provider nobody listens to is
        // recomputed on the next read whether or not anything invalidated it, so
        // without this the listing assertion below would pass with the refresh
        // deleted.
        final listing = container.listen(storageTreeChildrenProvider(node), (_, _) {});
        addTearDown(listing.close);
        final before = await container.read(storageTreeChildrenProvider(node).future);
        expect(before.map((entry) => entry.entity.path), [file.path]);
      });

      CardDialog.show(
        container.read(refBaseProvider),
        (_) => StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.temp),
          request: StorageDeletePathsRequest([file]),
          subject: 'scratch.bin',
        ),
        over: true,
      );
      await tester.pump();
      expect(_confirmEnabled(tester), isTrue);
      await tester.longPress(_confirmButton());
      await _settle(tester);

      // The removal, which does not survive the defect either: the ref is
      // already gone when the exclusion is resolved, one step before the file
      // would have been touched.
      expect(_exists(file), isFalse, reason: 'the delete never ran');
      // The screen the delete happened on has to re-read. The
      // provider-invalidate table answers the temp group with the empty list --
      // nothing outside this view remembers a temp path -- and its lock scope is
      // `unlocked`, so
      // nothing but `refreshStorageTabAfterDelete` can produce this.
      final after = await tester.runAsync(() => container.read(storageTreeChildrenProvider(node).future));
      expect(after, isEmpty, reason: 'the view was never told to re-read the folder it just emptied');
      // The outcome is announced in a toast -- what went and what did not.
      // Without it the user cannot tell a delete
      // that worked from one that did nothing, and presses the button again.
      expect(toasts, hasLength(1), reason: 'the delete finished without saying so');
      expect(toasts.single.type, ToastType.success);
      expect(toasts.single.description, _sentence('pages.storage.delete.completed', {'count': '1'}));
    });

    // **The settings branch was reported as unaffected, and it is not.** Its own
    // `ref.read` runs before the first await and does survive, which is what that
    // reading was drawn from -- but the restart panel, the view refresh and the
    // toast all come *after* the stores are removed, and removing eight Hive boxes
    // does not finish inside the frame the confirmation was dismissed on. The gate
    // below is what states that ordering: the store delete does not return until
    // the test has pumped the dismiss through, so the dialog is certainly gone by
    // the time the announcement is due. A stand-in that answers immediately makes
    // this branch green for a reason no user's machine supplies. The panel is the
    // assertion that matters, because the store delete leaves the session with no
    // settings at
    // all -- losing it means the app carries on as if nothing had happened.
    testWidgets('the settings branch announces itself and demands the restart', (tester) async {
      final subjects = [
        for (final key in StorageBoxKey.values)
          StorageDeleteStoreSubject(name: storageBoxNameOf(key), labelKey: storageBoxLabelKey(key)),
      ];
      final gate = Completer<void>();
      final container = _container(
        storeOutcome: StorageDeleteReport(deleted: subjects),
        storeGate: gate.future,
      );
      final toasts = <ToastData>[];
      final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);

      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: Scaffold(body: DialogLayer(child: SizedBox.shrink())),
        ),
      );
      CardDialog.show(
        container.read(refBaseProvider),
        (_) => StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.settings),
          request: const StorageDeleteSettingsRequest(),
          subject: 'settings',
        ),
        over: true,
      );
      await tester.pump();
      // The settings group's friction is read from the group rather than written
      // here, so this stays right if the group is ever reclassified to a different
      // delete friction.
      if (tester.any(find.byKey(storageDeleteAcknowledgeKey))) {
        await tester.tap(find.byKey(storageDeleteAcknowledgeKey));
        await tester.pump();
      }
      await tester.longPress(_confirmButton());
      // Mid-flight, with the store delete held open by the gate. The dialog is
      // deliberately still up -- that is what keeps `ref` usable -- so it has to
      // be saying so, and it must not accept a second press: the row's delete
      // would be a real second delete of paths the first one is removing.
      await tester.pump();
      expect(find.byKey(storageDeleteConfirmRowKey), findsOneWidget, reason: 'the confirmation left mid-delete');
      expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'the delete runs with nothing shown');
      expect(_confirmEnabled(tester), isFalse, reason: 'the confirm is pressable while the delete runs');
      gate.complete();
      await _settle(tester);

      expect(toasts, hasLength(1), reason: 'the settings delete finished without saying so');
      expect(toasts.single.type, ToastType.success);
      expect(toasts.single.description, _sentence('pages.storage.delete.completed', {'count': '${subjects.length}'}));
      // The store delete's own last stage: the panel, and the restart button on it.
      expect(find.byKey(storageDeleteResultKey), findsOneWidget, reason: 'the restart panel never opened');
      expect(find.byKey(storageDeleteRestartKey), findsOneWidget);
      // And the confirmation is gone by then, rather than sitting under the panel
      // it was replaced by.
      expect(find.byKey(storageDeleteConfirmRowKey), findsNothing, reason: 'the confirmation outlived the delete');
    });

    // **The result panel opens *over* the storage view, never in place of it.**
    //
    // Written with the real arrangement: the bottom entry is the
    // [StorageManagerDialog] the tree lives in, exactly as the settings page opens
    // it, because that is what `over: false` would destroy. `DialogController.show`
    // clears the whole stack unless `over` is set, so dropping it -- on the reading
    // that "only one dialog is ever up, so `over` is redundant" -- would take the
    // storage view down with the confirmation and leave the user staring at the
    // settings page with a result panel on it.
    //
    // The other two tests in this group cannot see that: their confirmation is the
    // *bottom* entry, so clearing the stack and stacking on an empty one look the
    // same. This one asserts the stack itself, not the pixels, because "the view is
    // still underneath" is a statement about the entries and a covered dialog draws
    // nothing distinguishable.
    testWidgets('the result panel opens over the storage view, not in place of it', (tester) async {
      final subjects = [
        for (final key in StorageBoxKey.values)
          StorageDeleteStoreSubject(name: storageBoxNameOf(key), labelKey: storageBoxLabelKey(key)),
      ];
      final gate = Completer<void>();
      final container = _container(
        storeOutcome: StorageDeleteReport(deleted: subjects),
        storeGate: gate.future,
      );

      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: Scaffold(body: DialogLayer(child: SizedBox.shrink())),
        ),
      );
      StorageManagerDialog.show(container.read(refBaseProvider));
      await _settle(tester);
      final dialogs = container.read(dialogBuilderProvider.notifier);
      final treeToken = dialogs.currentToken;
      expect(dialogs.entries, hasLength(1));

      CardDialog.show(
        container.read(refBaseProvider),
        (_) => StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.settings),
          request: const StorageDeleteSettingsRequest(),
          subject: 'settings',
        ),
        over: true,
      );
      await tester.pump();
      if (tester.any(find.byKey(storageDeleteAcknowledgeKey))) {
        await tester.tap(find.byKey(storageDeleteAcknowledgeKey));
        await tester.pump();
      }
      await tester.longPress(_confirmButton());
      await tester.pump();
      gate.complete();
      await _settle(tester);

      expect(find.byKey(storageDeleteResultKey), findsOneWidget, reason: 'the restart panel never opened');
      // The whole of the claim: the storage view is still the bottom entry, and the
      // panel is above it rather than instead of it. With `over: false` the stack
      // is cleared first, so the view's token is gone and only the panel is left.
      expect(
        dialogs.entries.map((entry) => entry.token).toList(),
        [treeToken, isNot(treeToken)],
        reason: 'the result panel replaced the storage view instead of opening over it',
      );
    });

    // **The dialog has three exits, and the confirm button is not one of them.**
    //
    // `_deleting` disables the confirm, and the group above pins that. It says
    // nothing about the other three ways out of this dialog -- the barrier, the
    // title bar's × and the cancel button -- and each of those unmounts the
    // confirmation just as thoroughly as the dismiss the group above was written
    // to remove. What that costs is not a lost delete: the removal is already
    // under way and finishes, so the user is told it *failed* about stores that
    // are gone, the view goes on listing them, and the settings branch never
    // reaches the restart panel -- the one screen that says the session has no
    // settings left. `ConsumerStatefulElement`'s unmounted-ref check throws a
    // plain `StateError` rather than an assert, so a release build behaves the
    // same way a debug one does.
    //
    // One test per exit, so a guard that is put back for one door and not the
    // others cannot hide behind a neighbour.
    // **The positive control for the barrier test below.** That one taps a bare
    // coordinate and asserts nothing happened, which is exactly what a tap that
    // *missed* the barrier looks like: change [DialogLayer]'s padding, or align
    // the dialog to the top left, and it would go on passing while testing
    // nothing. This states that the same coordinate does reach a barrier that is
    // live, so "nothing happened" there is a refusal and not a miss.
    testWidgets('the same barrier tap does close the confirmation before the delete starts', (tester) async {
      final container = _container();
      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: Scaffold(body: DialogLayer(child: SizedBox.shrink())),
        ),
      );
      CardDialog.show(
        container.read(refBaseProvider),
        (_) => StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.settings),
          request: const StorageDeleteSettingsRequest(),
          subject: 'settings',
        ),
        over: true,
      );
      await tester.pump();
      expect(find.byKey(storageDeleteConfirmRowKey), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pump();

      expect(
        find.byKey(storageDeleteConfirmRowKey),
        findsNothing,
        reason: 'the tap the barrier test relies on does not reach the barrier at all',
      );
    });

    testWidgets('the barrier does not close the confirmation mid-delete', (tester) async {
      final held = await _startHeldSettingsDelete(tester);

      // Outside the dialog's own card (the layer pads it by 32), so this is the
      // scrim and not the confirmation.
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();

      expect(
        find.byKey(storageDeleteConfirmRowKey),
        findsOneWidget,
        reason: 'a tap on the barrier closed the confirmation while its delete was running',
      );
      await _expectHeldDeleteFinished(tester, held);
    });

    testWidgets('the close button does not close the confirmation mid-delete', (tester) async {
      final held = await _startHeldSettingsDelete(tester);

      expect(
        tester.widget<IconButton>(_closeButton()).onPressed,
        isNull,
        reason: 'the title bar × is still live while the delete runs',
      );
      await tester.tap(_closeButton(), warnIfMissed: false);
      await tester.pump();

      expect(
        find.byKey(storageDeleteConfirmRowKey),
        findsOneWidget,
        reason: 'the title bar × closed the confirmation while its delete was running',
      );
      await _expectHeldDeleteFinished(tester, held);
    });

    testWidgets('the cancel button does not close the confirmation mid-delete', (tester) async {
      final held = await _startHeldSettingsDelete(tester);

      expect(
        tester.widget<ButtonStyleButton>(_cancelButton()).enabled,
        isFalse,
        reason: 'cancel is still live while the delete runs',
      );
      await tester.tap(_cancelButton(), warnIfMissed: false);
      await tester.pump();

      expect(
        find.byKey(storageDeleteConfirmRowKey),
        findsOneWidget,
        reason: 'cancel closed the confirmation while its delete was running',
      );
      await _expectHeldDeleteFinished(tester, held);
    });

    // **And the delete survives being closed by something that is not an exit.**
    //
    // Shutting the three doors is not the whole answer: a dialog can still be
    // unmounted by anything that clears the stack -- another dialog opened over
    // this view, the app tearing the layer down -- and none of that asks this
    // widget's permission. So the delete must not be running on a `ref` that dies
    // with the dialog. Dismissed here through the controller directly, which is
    // precisely the route no guard on this dialog can cover.
    testWidgets('a delete finishes and announces itself after the dialog is closed from elsewhere', (tester) async {
      final held = await _startHeldSettingsDelete(tester);

      held.container.read(dialogBuilderProvider.notifier).dismiss();
      await tester.pump();
      expect(find.byKey(storageDeleteConfirmRowKey), findsNothing, reason: 'the dismiss did not take');

      await _expectHeldDeleteFinished(tester, held);
    });

    // **The same claim on the other branch, which has more to lose.** The test
    // above runs the settings branch, whose post-await work is one view refresh.
    // The paths branch runs three provider operations after its removal returns
    // -- `evictRecordImages`, the provider invalidate and the view refresh with the
    // touched paths -- and every one of them would go through the dialog's own
    // `ref` if the runner were handed that. Held open at the backend, so the
    // whole production path above it is what is being interrupted.
    testWidgets('a paths delete finishes and announces itself after the dialog is closed from elsewhere', (
      tester,
    ) async {
      final file = _seed('documents/temp/scratch.bin');
      final gate = Completer<void>();
      fsBackend = _DelayingFsBackend(_realBackend, until: gate.future);
      final container = _container();
      final toasts = <ToastData>[];
      final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);

      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: Scaffold(body: DialogLayer(child: SizedBox.shrink())),
        ),
      );
      CardDialog.show(
        container.read(refBaseProvider),
        (_) => StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.temp),
          request: StorageDeletePathsRequest([file]),
          subject: 'scratch.bin',
        ),
        over: true,
      );
      await tester.pump();
      await tester.longPress(_confirmButton());
      await _settle(tester);
      // The gate is what makes this a mid-flight state rather than a finished
      // one: without it the delete is over before the dismiss below.
      expect(find.byKey(storageDeleteConfirmRowKey), findsOneWidget, reason: 'the delete was not held open');
      expect(_exists(file), isTrue, reason: 'the delete ran past the gate');

      container.read(dialogBuilderProvider.notifier).dismiss();
      await tester.pump();
      expect(find.byKey(storageDeleteConfirmRowKey), findsNothing, reason: 'the dismiss did not take');

      gate.complete();
      await _settle(tester);

      expect(_exists(file), isFalse, reason: 'the delete never finished');
      expect(toasts, hasLength(1), reason: 'the delete finished without saying so');
      expect(toasts.single.type, ToastType.success, reason: 'the delete that ran was reported as a failure');
      expect(toasts.single.description, _sentence('pages.storage.delete.completed', {'count': '1'}));
    });

    // **NOT HERE: the guard's narrowness.** `_confirm` rethrows `ArgumentError`
    // rather than announcing it, because `deleteStorageEntry` states that a path
    // paired with the wrong group is a defect and not a delete outcome. That
    // cannot be asserted from this suite: the button drops `_confirm`'s future,
    // so the rethrow reaches the zone, and `flutter_test` reports a dropped-future
    // error only after the body *and* the tear-downs have run -- `takeException`
    // answers null in both (measured, twice). A test written around it would fail
    // on the very error it is asserting. What is pinned instead is the contract it
    // rests on, in `storage_lock_scope_test.dart` and `storage_delete_test.dart`.
  });
}
