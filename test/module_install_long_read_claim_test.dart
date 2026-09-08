// `modules/` is a `StorageLockScope.unlocked` group: no lock in this app covers
// it, and its writers acquire nothing. Until now they also *announced* nothing,
// so two readers of that directory ran against a module install with no exclusion
// and no refusal between them — the record page's zip export, which packs
// `modules/labels.json` beside the records, and the storage view's own zip of the
// `modules` row.
//
//   .fvm/flutter_sdk/bin/flutter test test/module_install_long_read_claim_test.dart
//
// WHAT THE HARM WAS. Not a thrown error: `package:archive` streams whatever the
// file holds at the moment it reads it. Measured on this machine before the fix,
// a `ZipFileEncoder.addFile` racing an extraction of the same path packed a
// **zero-byte** `labels.json` into an archive that opens cleanly.
//
// WHY A REGISTRATION AND NOT A LOCK. There is no counterparty to lock against:
// every writer of `modules/` — two manual installs, the desktop auto-updater,
// the web bootstrap — takes nothing, so an acquisition on the reading side would
// exclude nobody. What the registry can do for an unlocked group is what it does
// everywhere else: keep the control from being offered. It grants nothing, so a
// reader already walking when an install starts is still not excluded; that
// residual is stated at `runModuleInstall` and is not what these cases assert.
//
// WHAT THIS SUITE CANNOT REACH.
//  * The desktop auto-updater's install. It sits inside `moduleVersionLoader`
//    behind a network download; nothing here can drive it.
//  * The web bootstrap and refresh. `_downloadAndExtractModuleToOpfs` is private
//    and reached only from a provider body that needs a browser and the network.
//    `web_module_refresh_test.dart` covers the shape of its call by reading the
//    source, which is where that decision already lived.
//  * A browser. The web leg's claim is asserted over the VM's path arithmetic.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/records.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _modulesDir => _layout.modulesDir;

FilePath get _labelsFile => _modulesDir.filePath(exportLabelsFileName);

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

final _refProvider = Provider<RefBase>((ref) => ref.base);

Uint8List _bytes(String content) => Uint8List.fromList(utf8.encode(content));

/// A zip shaped like the published module: everything under `modules/`, both
/// payloads present so `_requireModulePayload` accepts it.
Uint8List _moduleZip({String version = '2026-09-05T00:00:00+0900', String labels = '{"character": []}'}) {
  final archive = Archive();
  void add(String name, Uint8List content) => archive.addFile(ArchiveFile(name, content.length, content));
  add('modules/version_info.json', _bytes('{"recognizer_version": "$version"}'));
  add('modules/$exportLabelsFileName', _bytes(labels));
  add('modules/recognizer.json', _bytes('{"module_path": "skill/prediction.onnx"}'));
  add('modules/skill/prediction.onnx', _bytes('onnx-payload'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Every registry state an operation passed through, in order.
///
/// The claim of an install is taken and given back inside one `await`, so a
/// reading taken afterwards sees nothing. Recording the states is what lets a
/// case ask "was it ever registered, and what did the subscribers answer while it
/// was" without pinning the install open.
class _RegistryTrace {
  _RegistryTrace(ProviderContainer container) {
    _record(container.read(longReadRegistryProvider));
    container.listen(longReadRegistryProvider, (_, next) => _record(next));
  }

  final held = <List<LongReadClaim>>[];

  void _record(Map<LongReadToken, LongReadClaim> claims) {
    if (claims.isNotEmpty) {
      held.add(claims.values.toList());
    }
  }

  /// The claims live at the one moment something was registered.
  List<LongReadClaim> get single => held.single;
}

CharaDetailRecord _seedRecord(String id) {
  final record = makeRecord(id: id, card: 1);
  final directory = Directory((_activeDir / id).path)..createSync(recursive: true);
  File('${directory.path}/record.json').writeAsStringSync(jsonEncode(record.toMap()));
  File('${directory.path}/trainee.jpg').writeAsBytesSync([9, 8, 7]);
  return record;
}

void _seedLabels() {
  File(_labelsFile.path)
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode({'character': <String>[]}));
}

ProviderContainer _installContainer() {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The export harness: a gate whose acquisitions are recorded, and a save dialog
/// that answers a path without showing one.
class _RecordingGate {
  final acquisitions = <String>[];
  final claimsAtAcquisition = <List<LongReadClaim>>[];
  late List<LongReadClaim> Function() readClaims;

  late final RecordRecoveryGate gate = RecordRecoveryGate(
    mutationLock: RecordMutationLock((name, mode, action) {
      acquisitions.add('$name/${mode.name}');
      claimsAtAcquisition.add(readClaims());
      return action();
    }),
  );
}

ProviderContainer _exportContainer(_RecordingGate gate, List<CharaDetailRecord> records, {bool web = false}) {
  final output = File('${_tempRoot.path}/export.zip');
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      charaDetailRecordStorageProvider.overrideWithValue(records),
      exportIsWebProvider.overrideWithValue(web),
      exportInitialDirectoryProvider.overrideWithValue(() async => _tempRoot.path),
      exportSaveFileProvider.overrideWithValue(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_module_install_claim');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });
  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('a module install announces itself', () {
    test('the byte route holds the modules directory while it extracts, and gives it back', () async {
      final container = _installContainer();
      final trace = _RegistryTrace(container);

      expect(await installModuleFromZipBytes(container.read(_refProvider), _moduleZip()), isTrue);

      final claim = trace.single.single;
      expect(claim.kind, LongReadKind.moduleInstall);
      expect(claim.holds.map((hold) => hold.directoryPath), [_modulesDir.path]);
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the hold releases itself');
    });

    test('the file route does too, across the compute hand-off', () async {
      final container = _installContainer();
      final trace = _RegistryTrace(container);
      final zip = File('${_tempRoot.path}/modules.zip')..writeAsBytesSync(_moduleZip());

      expect(await installModuleFromZip(container.read(_refProvider), FilePath(zip.path)), isTrue);

      expect(trace.single.single.kind, LongReadKind.moduleInstall);
      expect(await _labelsFile.exists(), isTrue, reason: 'the install has to have happened for this to mean anything');
      expect(container.read(longReadRegistryProvider), isEmpty);
    });

    test('a refused archive gives the hold back too', () async {
      final container = _installContainer();
      final trace = _RegistryTrace(container);

      expect(await installModuleFromZipBytes(container.read(_refProvider), _bytes('not a zip at all')), isFalse);

      expect(trace.held, isNotEmpty, reason: 'the claim is taken before the archive is judged');
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'a claim left on by a failure greys the modules row for the rest of the session',
      );
    });
  });

  group('what the install withholds', () {
    late List<LongReadClaim> claims;

    setUp(() async {
      final container = _installContainer();
      final trace = _RegistryTrace(container);
      await installModuleFromZipBytes(container.read(_refProvider), _moduleZip());
      claims = trace.single;
    });

    test("the storage view's modules row stops offering its zip and its delete", () {
      expect(storageExtractBlockedBy(_modulesDir, claims), LongReadKind.moduleInstall);
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([_modulesDir]), claims), LongReadKind.moduleInstall);
    });

    test('a file inside it is covered as well, which is what the row menu asks about', () {
      expect(storageExtractBlockedBy(_labelsFile, claims), LongReadKind.moduleInstall);
    });

    test("the record page's export confirmation is withheld, because the desktop zip packs labels.json", () {
      final blocked = storageDeleteBlockedBy(
        StorageDeletePathsRequest(
          recordExportLongReadPaths(
            pathInfo: _layout,
            source: RecordSource.active,
            recordIds: const ['a'],
            isWeb: false,
          ),
        ),
        claims,
      );
      expect(blocked, LongReadKind.moduleInstall);
    });

    test('the web export is not withheld by it, because its layout carries no labels.json', () {
      final blocked = storageDeleteBlockedBy(
        StorageDeletePathsRequest(
          recordExportLongReadPaths(
            pathInfo: _layout,
            source: RecordSource.active,
            recordIds: const ['a'],
            isWeb: true,
          ),
        ),
        claims,
      );
      expect(blocked, isNull, reason: 'a refusal here would be one the web build has no reason for');
    });

    test('a record folder the install does not touch keeps its delete', () {
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'a']), claims), isNull);
    });
  });

  group('the export says which files it is holding', () {
    test('the desktop leg claims labels.json beside every record directory', () async {
      final records = [_seedRecord('a')];
      _seedLabels();
      final gate = _RecordingGate();
      final container = _exportContainer(gate, records);

      await ZipExporter('Export records', 'records.zip', container.read(_refProvider), const {
        'a',
      }, RecordSource.active).export();

      final claims = gate.claimsAtAcquisition.first;
      expect(claims.single.holds.map((hold) => hold.directoryPath), [(_activeDir / 'a').path, _labelsFile.path]);
    });

    test('an export of no records still enters the gate and still announces the file it reads', () async {
      _seedLabels();
      final gate = _RecordingGate();
      final container = _exportContainer(gate, const []);

      await ZipExporter(
        'Export records',
        'records.zip',
        container.read(_refProvider),
        const <String>{},
        RecordSource.active,
      ).export();

      expect(
        gate.acquisitions,
        isNotEmpty,
        reason: 'the empty batch used to return before the gate, which is where the declaration is applied',
      );
      final claims = gate.claimsAtAcquisition.first;
      expect(claims.single.kind, LongReadKind.export);
      expect(
        claims.single.holds.map((hold) => hold.directoryPath),
        [_labelsFile.path],
        reason: 'it reads labels.json whether or not it names a record',
      );
      expect(container.read(longReadRegistryProvider), isEmpty);
    });
  });
}
