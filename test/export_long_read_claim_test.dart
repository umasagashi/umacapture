// The record export is the third long reader to register, and the first one the
// gate itself claims for: `ZipExporter` hands `RecordRecoveryGate` a
// `LongReadDeclaration.claim`, and the gate — not the exporter — puts it on the
// registry and takes it off again.
//
//   .fvm/flutter_sdk/bin/flutter test test/export_long_read_claim_test.dart
//
// WHY THIS OPERATION. It is a pure long reader: it opens every file of every
// selected record and copies the bytes out, on desktop inside a `compute`
// isolate whose handles outlive the acquisition. `ZipExporter` had already
// written down, in its own comment, that nothing in the UI prevents an overlap —
// and the sentence was true of deletes as well as of writers. Wiring it is
// therefore the smallest honest demonstration of the gate claiming: no new
// window has to be invented, only announced.
//
// WHERE THE CLAIM IS TAKEN. At the gate, from a declaration both legs build with
// one function (`exportLongReadDeclaration`). Desktop reaches the gate in
// `ZipExporter._export`, web inside `RecordZipService.export`; the declaration is
// the same object shape in both, which is what keeps the two legs from claiming
// different paths — the defect the shared `exportRecoveryGateProvider` already
// exists to prevent for the lock.
//
// WHAT THIS SUITE CANNOT REACH.
//  * The real web build. `exportBytes` is exercised over the web-faithful async
//    FS backend on the VM, which reaches the same Dart but not a browser.
//  * The handle-release window on Windows. The claim exists so that timing is
//    unreachable; observing it needs a real export with a delete timed into it.
//  * Anything about the record lock. The registry grants nothing and refuses
//    nothing; these cases are about what the two delete surfaces offer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/records.dart';
import 'support/riverpod.dart';
import 'support/storage_row_menu.dart';
import 'support/web_like_fs_backend.dart';

late Directory _tempRoot;
late PathInfo _layout;
late FsBackend _originalBackend;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

final _refProvider = Provider<RefBase>((ref) => ref.base);

/// Record storage that holds ids in memory, so the delete dialog has something
/// to be opened over without a disk scan a `testWidgets` clock cannot drive.
mixin _FakeRecordStore on CharaDetailRecordMutator {
  final deleteAllCalls = <Set<String>>[];

  final Set<String> _held = {'a', 'b'};

  @override
  CharaDetailRecord? getBy({required String id}) => _held.contains(id) ? makeRecord(id: id, card: 1) : null;

  @override
  Future<RecordDeleteResult> deleteAsync(String id) => deleteAllAsync([id]);

  @override
  Future<RecordDeleteResult> deleteAllAsync(Iterable<String> ids) async {
    final idSet = ids.toSet();
    deleteAllCalls.add(idSet);
    _held.removeAll(idSet);
    return RecordDeleteResult(succeeded: Set.unmodifiable(idSet), failed: const {});
  }
}

class _FakeRecordStorage extends CharaDetailRecordStorage with _FakeRecordStore {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

class _FakeArchiveStorage extends CharaDetailArchiveStorage with _FakeRecordStore {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

/// A gate whose exclusive acquisitions stop, so the export can be observed
/// standing still with its claim on.
///
/// It also samples the registry at two moments the claim's window is supposed to
/// enclose: the very first acquisition of any name, and the return of the
/// guarded body. Both are the lock's, and the claim has to be on at each.
class _PinnedGate {
  _PinnedGate({this.abandon = true});

  final bool abandon;
  final reached = Completer<void>();
  final release = Completer<void>();

  /// Reads the live claims; assigned once the container exists.
  late List<LongReadClaim> Function() readClaims;

  List<LongReadClaim>? claimsAtFirstAcquisition;
  List<LongReadClaim>? claimsWhenBodyReturned;

  late final RecordRecoveryGate gate = RecordRecoveryGate(mutationLock: RecordMutationLock(_run));

  Future<Object?> _run(String name, RecordMutationLockMode mode, Future<Object?> Function() action) async {
    claimsAtFirstAcquisition ??= readClaims();
    if (mode != RecordMutationLockMode.exclusive) {
      return action();
    }
    if (!reached.isCompleted) reached.complete();
    await release.future;
    if (abandon) {
      throw StateError('the export was abandoned');
    }
    try {
      return await action();
    } finally {
      claimsWhenBodyReturned = readClaims();
    }
  }
}

/// Seeds `active/<id>` the way a captured record looks on disk.
CharaDetailRecord _seedRecord(String id) {
  final record = makeRecord(id: id, card: 1);
  final directory = Directory((_activeDir / id).path)..createSync(recursive: true);
  File('${directory.path}/record.json').writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  File('${directory.path}/trainee.jpg').writeAsBytesSync([9, 8, 7]);
  final labels = File(_layout.modulesDir.filePath('labels.json').path)..createSync(recursive: true);
  labels.writeAsStringSync(jsonEncode({'character': <String>[]}));
  return record;
}

/// The app with nothing else going on, both record stores faked, and the export
/// wired to [gate].
///
/// The capture and import blockers are pinned for the reason
/// `archive_long_read_claim_test.dart` states: the active record group is one a
/// capture writes into, so an unpinned activity blocker would disable the very
/// buttons these cases are about.
///
/// [saveFile] stands in for the native save dialog, and a case that overrides it
/// is a case about the window that dialog is open for: everything the picker can
/// see happen while it is up happens inside that callback.
ProviderContainer _container(
  _PinnedGate gate,
  List<CharaDetailRecord> records, {
  _FakeRecordStorage? storage,
  bool web = false,
  ExportSaveFile? saveFile,
}) {
  final output = File('${_tempRoot.path}/export.zip');
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      capturingStateProvider.overrideWithValue(false),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
      charaDetailRecordStorageLoaderProvider.overrideWith(() => storage ?? _FakeRecordStorage()),
      charaDetailArchiveStorageLoaderProvider.overrideWith(_FakeArchiveStorage.new),
      charaDetailRecordStorageProvider.overrideWithValue(records),
      labelMapProvider.overrideWithValue(const {}),
      exportIsWebProvider.overrideWithValue(web),
      exportInitialDirectoryProvider.overrideWithValue(() async => _tempRoot.path),
      exportSaveFileProvider.overrideWithValue(
        saveFile ??
            ({
              required String dialogTitle,
              required String fileName,
              String? initialDirectory,
              required Uint8List bytes,
              required bool lockParentWindow,
            }) async => output.path,
      ),
      exportRecoveryGateProvider.overrideWithValue(gate.gate),
    ],
  );
  addTearDown(container.dispose);
  gate.readClaims = () => container.read(longReadRegistryProvider).values.toList();
  return container;
}

ZipExporter _exporter(ProviderContainer container, Set<String> ids) =>
    ZipExporter('Export records', 'records.zip', container.read(_refProvider), ids, RecordSource.active);

Finder get _confirm => find.widgetWithIcon(FilledButton, Symbols.delete_rounded);

bool _confirmLive(WidgetTester tester) {
  final button = tester.widget<FilledButton>(_confirm);
  return button.onLongPress != null && button.onPressed != null;
}

/// Collects every toast raised while [container] is alive.
///
/// Must be attached before the export starts: the toast stream is an event
/// stream, so a listener added afterwards sees nothing.
List<ToastData> _observedToasts(ProviderContainer container) {
  final toasts = <ToastData>[];
  final subscription = container.listen<AsyncValue<ToastData>>(
    plainToastEventProvider,
    (_, current) => current.whenData(toasts.add),
  );
  addTearDown(subscription.close);
  return toasts;
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

class _ShowSingle extends ConsumerWidget {
  final String recordId;

  const _ShowSingle(this.recordId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => DeleteRecordDialog.show(ref.base, recordId: recordId, source: RecordSource.active),
      child: const Text('open'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _originalBackend = fsBackend;
    _tempRoot = Directory.systemTemp.createTempSync('uma_export_long_read');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    fsBackend = _originalBackend;
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('the claim', () {
    test('the desktop leg holds every exported record directory, as one token', () async {
      final records = [_seedRecord('a'), _seedRecord('b')];
      final pinned = _PinnedGate();
      final container = _container(pinned, records);

      final exporting = _exporter(container, const {'a', 'b'}).export();
      await pinned.reached.future;

      final claims = container.read(longReadRegistryProvider);
      expect(claims, hasLength(1), reason: 'an export is one registration, not one per record');
      final claim = claims.values.single;
      expect(claim.kind, LongReadKind.export);
      // `modules/labels.json` is in the list because the desktop zip packs it
      // beside the records and holds it open for the whole walk; see
      // `recordExportLongReadPaths`, and `module_install_long_read_claim_test.dart`
      // for the writer this half of the claim is there to be seen by.
      expect(claim.holds.map((hold) => hold.directoryPath), [
        (_activeDir / 'a').path,
        (_activeDir / 'b').path,
        _layout.modulesDir.filePath('labels.json').path,
      ]);

      // Both delete surfaces answer over it.
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'a']), claims.values), LongReadKind.export);
      expect(
        recordDeleteBlockedBy(
          pathInfo: _layout,
          source: RecordSource.active,
          recordIds: const ['b'],
          claims: claims.values,
        ),
        LongReadKind.export,
      );

      pinned.release.complete();
      await exporting;
      expect(container.read(longReadRegistryProvider), isEmpty);
    });

    test('a record the export did not name keeps its delete', () async {
      final records = [_seedRecord('a'), _seedRecord('b')];
      final pinned = _PinnedGate();
      final container = _container(pinned, records);

      final exporting = _exporter(container, const {'a'}).export();
      await pinned.reached.future;
      final claims = container.read(longReadRegistryProvider).values;

      // The control for every refusal above: a gate that refused everything
      // would satisfy them and ship a delete that never works.
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'b']), claims), isNull);
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'ab']), claims),
        isNull,
        reason: 'a prefix is not containment: `ab` is a different record with a different lock',
      );
      expect(
        recordDeleteBlockedBy(pathInfo: _layout, source: RecordSource.active, recordIds: const ['b'], claims: claims),
        isNull,
      );
      expect(
        recordDeleteBlockedBy(pathInfo: _layout, source: RecordSource.archive, recordIds: const ['a'], claims: claims),
        isNull,
        reason: 'the archived copy of an exported active record is a different directory and is not held',
      );

      pinned.release.complete();
      await exporting;
    });

    test('the claim encloses the acquisition at both ends', () async {
      // WHY THIS CASE EXISTS. Every other case here observes the export pinned
      // *inside* the record lock, so all of them stay green if the claim were
      // narrowed to the lock's own window — which is exactly the defect the seam
      // was built for: on the real filesystem the handles outlive the
      // acquisition, and a delete let through the instant the lock opened is the
      // failure that was reproduced by hand twice.
      //
      // So the two moments sampled here are the lock's own: its first
      // acquisition of any name, and the return of the body it guarded. The
      // claim has to be on at both, and off once `export()` has returned.
      final records = [_seedRecord('a')];
      final pinned = _PinnedGate(abandon: false);
      final container = _container(pinned, records);

      final exporting = _exporter(container, const {'a'}).export();
      await pinned.reached.future;
      pinned.release.complete();
      await exporting;

      expect(
        pinned.claimsAtFirstAcquisition?.map((claim) => claim.kind),
        [LongReadKind.export],
        reason: 'the claim is registered before the first lock name is requested, not after it is granted',
      );
      expect(
        pinned.claimsWhenBodyReturned,
        isNotNull,
        reason: 'the guarded body never ran, so this case measured nothing about the far end',
      );
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'a']), pinned.claimsWhenBodyReturned!),
        LongReadKind.export,
        reason: 'the packing had finished and the acquisitions were unwinding; a delete offered here is the defect',
      );
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'and off again once the export has returned');
      expect(File('${_tempRoot.path}/export.zip').existsSync(), isTrue, reason: 'the export really ran');
    });

    test('an export that ends by throwing still releases', () async {
      final records = [_seedRecord('a')];
      final pinned = _PinnedGate();
      final container = _container(pinned, records);

      final exporting = _exporter(container, const {'a'}).export();
      await pinned.reached.future;
      expect(container.read(longReadRegistryProvider), hasLength(1));

      pinned.release.complete();
      await exporting;

      // `Exporter.export` swallows the failure into a toast, so the future
      // completes normally and nothing here would notice a claim left on: the
      // release belongs to the registry's own `finally`, not to a call site.
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'a claim nobody releases greys the delete for the rest of the session',
      );
    });

    test('the web leg claims the same paths, through the same declaration', () async {
      // Parity half. The legs reach the gate at different depths — desktop in
      // `ZipExporter._export`, web inside `RecordZipService.export` — so this is
      // what says the second one announces at all, and announces the same thing.
      fsBackend = WebLikeFsBackend(_originalBackend);
      final records = [_seedRecord('a'), _seedRecord('b')];
      final pinned = _PinnedGate();
      final container = _container(pinned, records, web: true);

      final exporting = _exporter(container, const {'a', 'b'}).exportBytes();
      await pinned.reached.future;

      final claims = container.read(longReadRegistryProvider);
      expect(claims, hasLength(1));
      expect(claims.values.single.kind, LongReadKind.export);
      expect(claims.values.single.holds.map((hold) => hold.directoryPath), [
        (_activeDir / 'a').path,
        (_activeDir / 'b').path,
      ]);

      pinned.release.complete();
      // Called directly rather than through `export()`, so the abandoned lock
      // surfaces here instead of being turned into a toast — which is also what
      // makes the release below a statement about the gate and not about a
      // `catch` in the exporter.
      await expectLater(exporting, throwsA(isA<StateError>()));
      expect(container.read(longReadRegistryProvider), isEmpty);
    });
  });

  group('the surfaces', () {
    testWidgets('the record delete dialog goes dead while the export holds the record, and comes back', (tester) async {
      final records = [_seedRecord('a'), _seedRecord('b')];
      final storage = _FakeRecordStorage();
      final pinned = _PinnedGate();
      final container = _container(pinned, records, storage: storage);
      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: DialogLayer(child: Scaffold(body: _ShowSingle('a'))),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(_confirmLive(tester), isTrue, reason: 'the control that separates the gate from a broken dialog');

      final exporting = _exporter(container, const {'a'}).export();
      await pinned.reached.future;
      await tester.pump();
      expect(_confirmLive(tester), isFalse);

      // The refusal says so on screen, and the assertion a finder cannot fake:
      // press it and read what the store was asked to do.
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, isEmpty, reason: 'a delete started over a running export');

      pinned.release.complete();
      await exporting;
      await tester.pump();
      expect(_confirmLive(tester), isTrue, reason: 'withheld for the length of the export, not of the session');
    });

    // The row's delete is now one entry of the row's menu rather than a button of
    // its own, so the claim moved up one level — the export's hold closes the
    // menu's ⋮, and with it all three entrances. That the control still leads to
    // a delete is asserted at the end, once the claim is released: with it in
    // force no entrance opens, so there is no menu to read.
    testWidgets('ストレージ管理: the row s menu goes dead while the export holds the folder', (tester) async {
      final records = [_seedRecord('a'), _seedRecord('b')];
      final pinned = _PinnedGate();
      final container = _container(pinned, records);
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
      await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
      await _settle(tester);

      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(_activeDir / 'a')), isTrue);
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(_activeDir / 'b')), isTrue);

      final exporting = _exporter(container, const {'a'}).export();
      await pinned.reached.future;
      await tester.pump();

      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(_activeDir / 'a')), isFalse);
      // The reason reaches the user, which with the delete button gone is the
      // whole of what the view says about a row it will not act on.
      expect(storageRowMenuTooltip(tester, storageRowMenuEntityKey(_activeDir / 'a')), longReadBusyMessage());
      expect(
        storageRowMenuEnabled(tester, storageRowMenuEntityKey(_activeDir / 'b')),
        isTrue,
        reason: 'a record the export is not reading takes a different lock; refusing it would refuse nothing',
      );

      pinned.release.complete();
      await exporting;
      await tester.pump();
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(_activeDir / 'a')), isTrue);

      // What the returned control leads to is still the delete.
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(_activeDir / 'a'));
      expect(storageMenuEntryEnabled(tester, storageActionLabel('delete')), isTrue);
    });
  });

  // THE OTHER SIDE OF THE SAME QUESTION. Everything above is about what the
  // export's claim withholds from somebody else. These two are about the moment
  // *before* the claim exists: `export_button.dart` asks the registry while it
  // draws the confirm, and the native save dialog then runs for as long as the
  // user takes to choose a file. It locks the parent window; it does not stop the
  // event loop, so a module install that started on its own can register in that
  // window — and `modules/labels.json`, which the desktop zip packs, is written by
  // an installer that takes no lock at all. The registry is the only thing
  // standing between the two.
  //
  // The claim is registered by hand here rather than through `runModuleInstall`:
  // what is under test is the export reading the registry, and that the installer
  // registers itself is `record_action_extraction_gate_test.dart`'s to assert.
  group('the picker window', () {
    /// A save dialog that returns [output], having let [duringPicker] happen while
    /// it was up.
    ExportSaveFile pickerDuring(void Function() duringPicker, String output) {
      return ({
        required String dialogTitle,
        required String fileName,
        String? initialDirectory,
        required Uint8List bytes,
        required bool lockParentWindow,
      }) async {
        duringPicker();
        return output;
      };
    }

    test('a claim that lands while the picker is open stops the export and says why', () async {
      final records = [_seedRecord('a')];
      final pinned = _PinnedGate();
      final output = '${_tempRoot.path}/export.zip';
      late ProviderContainer container;
      container = _container(
        pinned,
        records,
        saveFile: pickerDuring(() {
          container
              .read(longReadRegistryProvider.notifier)
              .claimUntilReleased(kind: LongReadKind.moduleInstall, paths: [_layout.modulesDir]);
        }, output),
      );
      final toasts = _observedToasts(container);
      // The layout resolved, which it always has by the time a record page can
      // offer an export: the re-check asks `pathLayoutProvider`, and an unresolved
      // layout is nothing to ask about.
      await container.read(pathLayoutLoader.future);
      // The gate is left open rather than pinned, so an export that is *not*
      // refused runs to its end and this case fails on its assertions. Pinned, the
      // same defect would show up as a test that never finishes, which is a red
      // that cannot tell "the export ran" from "something else hung".
      pinned.release.complete();

      await _exporter(container, const {'a'}).export();

      expect(
        pinned.claimsAtFirstAcquisition,
        isNull,
        reason: 'the export walked into an install rewriting the labels it packs',
      );
      expect(File(output).existsSync(), isFalse, reason: 'a zip was written after the export was refused');
      expect(container.read(exportingStateProvider), isFalse);
      // Said, not merely declined: the user has chosen a file and pressed save, so
      // silence here reads as an export that worked. Compared against the shipped
      // sentence, because `.tr()` renders a missing key as the key.
      //
      // The toast travels through an event stream, so it arrives a turn after
      // `export` returns; waited for by polling the thing being waited on rather
      // than by a delay long enough to be safe.
      for (var round = 0; round < 100 && toasts.isEmpty; round++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(toasts.map((toast) => toast.description), [longReadBusyMessage()]);
      expect(toasts.single.description, appSentenceAt(longReadBusyKey));
    });

    test('a claim on something the export does not read lets it through', () async {
      // The control that separates "refused because of what this claim holds" from
      // "refused because the registry is not empty". Another record's directory is
      // held by the same kind at the same moment, and the export goes on to the
      // gate — which is as far as anything gets here, since the gate is pinned.
      final records = [_seedRecord('a'), _seedRecord('b')];
      final pinned = _PinnedGate();
      final output = '${_tempRoot.path}/export.zip';
      late ProviderContainer container;
      container = _container(
        pinned,
        records,
        saveFile: pickerDuring(() {
          container
              .read(longReadRegistryProvider.notifier)
              .claimUntilReleased(kind: LongReadKind.moduleInstall, paths: [_activeDir / 'b']);
        }, output),
      );
      final toasts = _observedToasts(container);
      await container.read(pathLayoutLoader.future);

      final exporting = _exporter(container, const {'a'}).export();
      await pinned.reached.future;

      expect(pinned.claimsAtFirstAcquisition, isNotNull, reason: 'the export was refused over a folder it never reads');
      // Read here and not after the export: this gate abandons what it holds, so
      // the run ends with the failure toast `_reportFailure` raises, and only the
      // window before it began can say that no *refusal* was shown.
      expect(toasts, isEmpty);

      pinned.release.complete();
      await exporting;
    });
  });
}
