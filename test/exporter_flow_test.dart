// Focused control-flow tests for desktop file writes and Web download requests.
// Run: .fvm/flutter_sdk/bin/flutter test test/exporter_flow_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/addon/trigger_catalog.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/records.dart';

final _refProvider = Provider<RefBase>((ref) => ref.base);

/// Label fixture carrying a code point above U+00FF.
///
/// Not decoration: it is what makes the "exportBytes is UTF-8 of buildJson"
/// assertion falsifiable. An all-ASCII document encodes identically under UTF-8,
/// Latin-1 and ASCII, so the claim would hold for any of them.
const _labels = <String, List<String>>{
  'character': ['キタサンブラック'],
};

ProviderContainer _container({
  required bool web,
  required ExportSaveFile saveFile,
  Future<String?> Function()? initialDirectory,
}) {
  final record = makeRecord(id: 'record-1', card: 7);
  return ProviderContainer.test(
    overrides: [
      exportIsWebProvider.overrideWithValue(web),
      exportSaveFileProvider.overrideWithValue(saveFile),
      exportInitialDirectoryProvider.overrideWithValue(initialDirectory ?? () async => null),
      charaDetailRecordStorageProvider.overrideWithValue([record]),
      labelMapProvider.overrideWithValue(_labels),
    ],
  );
}

JsonExporter _exporter(ProviderContainer container, {Set<String> ids = const {'record-1'}}) {
  return JsonExporter('Export records', 'records.json', container.read(_refProvider), ids, RecordSource.active);
}

/// Collects every toast raised while [container] is alive.
///
/// Both legs report failures through the one `Toaster.show` in
/// `Exporter._reportFailure`, so the *subscription* is common to every case here
/// and belongs in one place. What each case expects to find in the returned list
/// stays written in that case -- a shared helper that also asserted would hide
/// which leg is pinning which outcome, which is exactly what let the Web
/// failures go unobserved.
///
/// Must be called before the export starts: the toast stream is an event stream,
/// so a listener attached afterwards sees nothing.
List<ToastData> _observedToasts(ProviderContainer container) {
  final toasts = <ToastData>[];
  final subscription = container.listen<AsyncValue<ToastData>>(
    plainToastEventProvider,
    (_, current) => current.whenData(toasts.add),
  );
  addTearDown(subscription.close);
  return toasts;
}

void main() {
  setUpAll(initializeMappers);

  test('a Web null save result is a successful download request with no fabricated path', () async {
    final saveEntered = Completer<void>();
    final finishSave = Completer<String?>();
    Uint8List? receivedBytes;
    final container = _container(
      web: true,
      saveFile:
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) {
            expect(dialogTitle, 'Export records');
            expect(fileName, 'records.json');
            expect(initialDirectory, isNull);
            expect(lockParentWindow, isFalse);
            receivedBytes = bytes;
            saveEntered.complete();
            return finishSave.future;
          },
    );
    addTearDown(container.dispose);
    final results = <ExportResult>[];
    final toasts = _observedToasts(container);

    final export = _exporter(container).export(onSuccess: results.add);
    await saveEntered.future;

    expect(container.read(exportingStateProvider), isTrue);
    expect(results, isEmpty, reason: 'success follows the download dispatch future');
    // The web download must carry exactly UTF-8(buildJson(...)) -- the same document
    // the desktop isolate writes through writeAsStringSync. Asserting it on the bytes
    // that actually reached saveFile is the only place JsonExporter.exportBytes is
    // pinned; the pure helper alone cannot make this claim.
    expect(
      receivedBytes,
      utf8.encode(JsonExporter.buildJson(JsonExportData([makeRecord(id: 'record-1', card: 7)], _labels))),
    );

    // file_picker Web deliberately returns null after clicking its download anchor.
    finishSave.complete(null);
    await export;
    await pumpEventQueue();

    expect(container.read(exportingStateProvider), isFalse);
    // A null return is the browser's *success*, so it must stay as quiet as the
    // desktop picker cancellation below: an implementation that reports the null
    // as a failure and still calls onSuccess would otherwise pass here.
    expect(toasts, isEmpty);
    expect(results, hasLength(1));
    expect(results.single.delivery, ExportDelivery.downloadRequested);
    expect(results.single.fileName, 'records.json');
    expect(results.single.path, isNull);
    expect(recordExportedPayload(results.single), {
      'event': 'record_exported',
      'export_file_name': 'records.json',
      'export_delivery': 'download_requested',
    });
  });

  test('a Web save failure emits one error toast, no success, and always clears the exporting state', () async {
    final container = _container(
      web: true,
      saveFile:
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async {
            throw StateError('download dispatch failed');
          },
    );
    addTearDown(container.dispose);
    final results = <ExportResult>[];
    final toasts = _observedToasts(container);

    await _exporter(container).export(onSuccess: results.add);
    await pumpEventQueue();

    expect(results, isEmpty);
    expect(container.read(exportingStateProvider), isFalse);
    // A browser that refuses the download (extension block, storage exhaustion,
    // a throwing saveFile) must not leave the user believing the file was
    // written. Without this the whole `catch` in _exportWeb can be emptied and
    // both Web failure cases still pass -- the silent failure this export flow
    // exists to rule out.
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
  });

  test('a Web byte-build failure reports one error toast and never calls save or success', () async {
    var saveCalls = 0;
    final container = _container(
      web: true,
      saveFile:
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async {
            saveCalls++;
            return null;
          },
    );
    addTearDown(container.dispose);
    final results = <ExportResult>[];
    final toasts = _observedToasts(container);

    await _exporter(container, ids: const {'missing'}).export(onSuccess: results.add);
    await pumpEventQueue();

    expect(saveCalls, 0);
    expect(results, isEmpty);
    expect(container.read(exportingStateProvider), isFalse);
    // Failing before the bytes exist is still a failure the user has to be told
    // about; the desktop initial-directory case pins the same thing.
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
  });

  test('desktop success preserves the real selected path and writes before callback', () async {
    final temp = await Directory.systemTemp.createTemp('umacapture-export-test-');
    addTearDown(() => temp.delete(recursive: true));
    final output = File([temp.path, 'chosen-name.json'].join(Platform.pathSeparator));
    var fileExistedAtSuccess = false;
    final container = _container(
      web: false,
      initialDirectory: () async => temp.path,
      saveFile:
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async {
            expect(initialDirectory, temp.path);
            expect(bytes, isEmpty, reason: 'desktop saveFile remains a path picker');
            expect(lockParentWindow, isTrue);
            return output.path;
          },
    );
    addTearDown(container.dispose);
    final results = <ExportResult>[];
    final toasts = _observedToasts(container);

    await _exporter(container).export(
      onSuccess: (result) {
        fileExistedAtSuccess = output.existsSync();
        results.add(result);
      },
    );
    await pumpEventQueue();

    expect(fileExistedAtSuccess, isTrue);
    // The Web case pins the bytes handed to saveFile; pin the desktop bytes to
    // the same document here, otherwise "both legs emit byte-identical output"
    // is only ever checked on one leg. The isolate writer goes through
    // writeAsStringSync, whose default encoding is UTF-8.
    expect(
      output.readAsBytesSync(),
      utf8.encode(JsonExporter.buildJson(JsonExportData([makeRecord(id: 'record-1', card: 7)], _labels))),
    );
    expect(container.read(exportingStateProvider), isFalse);
    expect(toasts, isEmpty);
    expect(results, hasLength(1));
    expect(results.single.delivery, ExportDelivery.fileWritten);
    expect(results.single.fileName, 'chosen-name.json');
    expect(results.single.path?.path, FilePath(output.path).path);
    expect(recordExportedPayload(results.single), {
      'event': 'record_exported',
      'export_file_name': 'chosen-name.json',
      'export_delivery': 'file_written',
      'export_path': FilePath(output.path).path,
    });
  });

  test('desktop picker cancellation remains a quiet non-success', () async {
    final container = _container(
      web: false,
      saveFile:
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async {
            return null;
          },
    );
    addTearDown(container.dispose);
    final results = <ExportResult>[];
    final toasts = _observedToasts(container);

    await _exporter(container).export(onSuccess: results.add);
    await pumpEventQueue();

    expect(results, isEmpty);
    expect(container.read(exportingStateProvider), isFalse);
    expect(toasts, isEmpty);
  });

  test('desktop initial-directory failure emits one error toast without starting export', () async {
    var saveCalls = 0;
    final container = _container(
      web: false,
      initialDirectory: () async => throw StateError('downloads directory unavailable'),
      saveFile:
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async {
            saveCalls++;
            return null;
          },
    );
    addTearDown(container.dispose);
    final results = <ExportResult>[];
    final toasts = _observedToasts(container);

    await _exporter(container).export(onSuccess: results.add);
    await pumpEventQueue();

    expect(saveCalls, 0);
    expect(results, isEmpty);
    expect(container.read(exportingStateProvider), isFalse);
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
  });

  test('desktop save-dialog failure emits one error toast without starting export', () async {
    final container = _container(
      web: false,
      initialDirectory: () async => 'C:/Downloads',
      saveFile:
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async {
            expect(initialDirectory, 'C:/Downloads');
            throw StateError('save dialog unavailable');
          },
    );
    addTearDown(container.dispose);
    final results = <ExportResult>[];
    final toasts = _observedToasts(container);

    await _exporter(container).export(onSuccess: results.add);
    await pumpEventQueue();

    expect(results, isEmpty);
    expect(container.read(exportingStateProvider), isFalse);
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
  });
}
