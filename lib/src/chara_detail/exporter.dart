import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:charset/charset.dart';
import 'package:csv/csv.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_zip.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

part 'exporter.mapper.dart';

final exportingStateProvider = settableNotifierProvider<bool>(false);

enum ExportDelivery {
  fileWritten("file_written"),
  downloadRequested("download_requested");

  final String payloadValue;

  const ExportDelivery(this.payloadValue);
}

@immutable
class ExportResult {
  final String fileName;
  final FilePath? path;
  final ExportDelivery delivery;

  const ExportResult._({required this.fileName, required this.path, required this.delivery});

  factory ExportResult.fileWritten(FilePath path) {
    return ExportResult._(fileName: path.name, path: path, delivery: ExportDelivery.fileWritten);
  }

  const ExportResult.downloadRequested(String fileName)
    : this._(fileName: fileName, path: null, delivery: ExportDelivery.downloadRequested);
}

typedef ExportResultCallback = Callback<ExportResult>;

typedef ExportSaveFile =
    Future<String?> Function({
      required String dialogTitle,
      required String fileName,
      String? initialDirectory,
      required Uint8List bytes,
      required bool lockParentWindow,
    });

Future<String?> _saveExportFile({
  required String dialogTitle,
  required String fileName,
  String? initialDirectory,
  required Uint8List bytes,
  required bool lockParentWindow,
}) {
  return FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    initialDirectory: initialDirectory,
    bytes: bytes,
    lockParentWindow: lockParentWindow,
  );
}

final exportSaveFileProvider = Provider<ExportSaveFile>((_) => _saveExportFile);
final exportInitialDirectoryProvider = Provider<Future<String?> Function()>(
  (_) =>
      () async => (await getDownloadsDirectory())?.path,
);
final exportIsWebProvider = Provider<bool>((_) => kIsWeb);

/// The gate [ZipExporter] takes the exported records' mutation locks on.
///
/// One provider for both legs, so the desktop and web zip exports cannot end up
/// locking differently. Defaults to the same platform gate every other record
/// reader and writer uses; tests override it to observe the acquisitions.
final exportRecoveryGateProvider = Provider<RecordRecoveryGate>((_) => platformRecordRecoveryGate);

abstract class Exportable {
  String get csv;
}

/// Drives an [Exporter] from a container-scoped ref.
///
/// The directory picker and file write run long after the triggering widget
/// (the format-picker dialog) is gone, so the exporter must not borrow that
/// widget's `WidgetRef` — reading a disposed ref throws and the write silently
/// fails. Routing through this notifier gives the exporter a ref that lives for
/// the app's lifetime, mirroring how the archive flow uses its controller.
class ExportRunner extends Notifier<void> {
  @override
  void build() {}

  Future<void> run(Exporter Function(RefBase ref) builder, {ExportResultCallback? onSuccess}) {
    return builder(ref.base).export(onSuccess: onSuccess);
  }
}

final exportRunnerProvider = NotifierProvider<ExportRunner, void>(ExportRunner.new);

abstract class Exporter {
  final String dialogTitle;

  final String defaultFileName;

  /// Container-scoped ref (see [ExportRunner]) used to read the records, grid and
  /// path info needed by the export, and to flip [exportingStateProvider].
  final RefBase ref;

  /// Ids of the records to export. Snapshotted when the export is triggered so a
  /// later change to the live selection (e.g. leaving selection mode) cannot
  /// alter the set midway through the asynchronous export.
  final Set<String> recordIds;

  /// Record source snapshotted at trigger time. The picker and write run after
  /// the selection scrim is gone (which makes the source dropdown live again), so
  /// the exporter must not re-read [recordSourceProvider] mid-flight — otherwise a
  /// source switch could redirect the write to the other set's directories.
  final RecordSource source;

  Exporter(this.dialogTitle, this.defaultFileName, this.ref, this.recordIds, this.source);

  /// The records to export, drawn from the snapshotted [source] and filtered to
  /// [recordIds].
  ///
  /// Throws [StateError] when the source resolves to no records while ids were
  /// requested — e.g. the archive store is still loading (its read view yields an
  /// empty list), which would otherwise silently write an empty file and fire a
  /// success toast. Surfacing it routes through the export's error handler.
  List<CharaDetailRecord> resolveSelectedRecords() {
    final records = recordsForSource(ref, source).where((record) => recordIds.contains(record.id)).toList();
    if (records.isEmpty && recordIds.isNotEmpty) {
      throw StateError("No records resolved for export (source not ready or all ids missing).");
    }
    return records;
  }

  Future<void> export({ExportResultCallback? onSuccess}) async {
    // Web has no writable OS path and no native Save dialog: the browser can
    // only receive the finished bytes and offer them as a download. So on web
    // the exporter produces the whole file in memory ([exportBytes]) and hands
    // it to `saveFile(bytes:)`, bypassing the path-based desktop writers below.
    // The desktop path is left byte-identical.
    if (ref.read(exportIsWebProvider)) {
      await _exportWeb(onSuccess: onSuccess);
      return;
    }
    String? savedPath;
    try {
      final initialDirectory = await ref.read(exportInitialDirectoryProvider)();
      // Use the native Save-File dialog so the user picks the exact file name and
      // location. file_picker 12's saveFile would also write its `bytes` to the
      // chosen path, but the path-based exporters below produce the file themselves.
      // An empty byte list therefore makes it a path picker only.
      savedPath = await ref.read(exportSaveFileProvider)(
        dialogTitle: dialogTitle,
        fileName: defaultFileName,
        initialDirectory: initialDirectory,
        bytes: Uint8List(0),
        lockParentWindow: true,
      );
    } catch (e, st) {
      _reportFailure(e, st);
      return;
    }
    if (savedPath == null) {
      return;
    }
    final path = FilePath(savedPath);
    final notifier = ref.read(exportingStateProvider.notifier);
    notifier.set(true);
    try {
      await _export(path);
      onSuccess?.call(ExportResult.fileWritten(path));
    } catch (e, st) {
      _reportFailure(e, st);
    } finally {
      notifier.set(false);
    }
  }

  Future<dynamic> _export(FilePath path);

  /// Builds the export's bytes in memory for the web download path.
  ///
  /// Every format exposed on Web implements it; the default rejects, which surfaces as an error toast rather
  /// than crashing. The desktop path never calls this.
  Future<Uint8List> exportBytes() {
    throw UnsupportedError("Web export is not implemented for this format.");
  }

  /// Web export: build the bytes, then let the browser download them.
  ///
  /// Mirrors the desktop [export] control flow (flip [exportingStateProvider],
  /// surface failures via a toast, always clear the flag) but replaces the
  /// directory-picker + path-write with `saveFile(bytes:)`, which triggers a
  /// browser download on web.
  Future<void> _exportWeb({ExportResultCallback? onSuccess}) async {
    final notifier = ref.read(exportingStateProvider.notifier);
    notifier.set(true);
    try {
      final bytes = await exportBytes();
      // file_picker's Web implementation starts an anchor download and intentionally returns null. Reaching
      // this point without an exception therefore means "download requested", not "file written to a known
      // path". Never fabricate an export_path for a browser download.
      await ref.read(exportSaveFileProvider)(
        dialogTitle: dialogTitle,
        fileName: defaultFileName,
        bytes: bytes,
        lockParentWindow: false,
      );
      onSuccess?.call(ExportResult.downloadRequested(defaultFileName));
    } catch (e, st) {
      _reportFailure(e, st);
    } finally {
      notifier.set(false);
    }
  }

  void _reportFailure(Object error, StackTrace stackTrace) {
    logger.e("Failed to export records", error, stackTrace);
    Toaster.show(ToastData.error(description: "toast.record_export_failure".tr()));
  }
}

enum CharCodec { shiftJis, utf8Bom, utf16leBom }

class CsvExporter extends Exporter {
  final CharCodec encoding;

  /// Grid snapshotted at export-trigger time. CSV exports the *displayed*
  /// columns and formatted cells (not the raw records), so it needs the grid;
  /// capturing it here keeps the same snapshot guarantee as [Exporter.source],
  /// since the picker/write run after the selection scrim makes the grid live
  /// again (and #3 freezes it only while selecting).
  final Grid grid;

  CsvExporter(
    super.dialogTitle,
    super.defaultFileName,
    super.ref,
    super.recordIds,
    super.source,
    this.encoding,
    this.grid,
  );

  /// Encodes [content] to bytes in [encoding]. Pure and platform-independent
  /// (all three codecs are in-memory `dart:convert`/`charset` converters, so
  /// this runs unchanged on web), letting the CSV byte output be verified on its
  /// own and shared by the desktop and web writers.
  static List<int> encodeCsv(String content, CharCodec encoding) {
    switch (encoding) {
      case CharCodec.shiftJis:
        return const ShiftJISEncoder().convert(content);
      case CharCodec.utf8Bom:
        return [0xEF, 0xBB, 0xBF, ...utf8.encode(content)];
      case CharCodec.utf16leBom:
        return const Utf16Encoder().encodeUtf16Le(content, true);
    }
  }

  List<int> encode(String content) => encodeCsv(content, encoding);

  /// Builds the encoded CSV bytes from the snapshotted grid and [encoding].
  ///
  /// Shared by the desktop file writer ([_export]) and the web in-memory
  /// [exportBytes] path so both emit byte-identical output. Runs synchronously
  /// (no isolate) — the CSV formatting reads the captured grid directly.
  List<int> buildBytes() {
    // Guard the same not-ready/empty case JsonExporter and ZipExporter reject:
    // surface a StateError (routed to export()'s catchError) instead of writing a
    // header-only CSV and firing a misleading success toast. CSV still formats
    // from the snapshotted grid below; this only enforces the shared guard.
    resolveSelectedRecords();
    // Drop the synthetic checkbox column injected while selecting; it carries no
    // title or exportable data and would otherwise emit a leading empty column.
    final columns = grid.columns.where((column) => column.field != checkColumnField).toList();
    final rows = grid.rows.where((row) => recordIds.contains(row.getUserData<CharaDetailRecord>()?.id));
    final table = [
      columns.map((column) => column.title).toList(),
      // A broken placeholder cell carries no Exportable userData; export it as an
      // empty field rather than crashing the whole export on a null unwrap.
      ...rows.map(
        (row) => columns.map((column) => row.cells[column.field]?.getUserData<Exportable>()?.csv ?? "").toList(),
      ),
    ];
    return encode(const CsvEncoder().convert(table));
  }

  @override
  Future<dynamic> _export(FilePath path) async {
    return path.writeAsBytes(buildBytes());
  }

  @override
  Future<Uint8List> exportBytes() async {
    // Web build: no OS path. Produce the same encoded bytes the desktop writer
    // emits and hand them to the browser download via _exportWeb.
    return Uint8List.fromList(buildBytes());
  }
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class JsonExportData with JsonExportDataMappable {
  final List<CharaDetailRecord> charaDetail;
  final LabelMap labels;

  JsonExportData(this.charaDetail, this.labels);
}

class _JsonExporterArgs {
  final FilePath path;
  final JsonExportData data;

  _JsonExporterArgs(this.path, this.data);
}

class JsonExporter extends Exporter {
  JsonExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds, super.source);

  /// Builds the pretty-printed JSON document for [data].
  ///
  /// Shared by the desktop isolate writer ([_run]) and the web in-memory
  /// [exportBytes] path so both emit byte-identical JSON. The caller must ensure
  /// the mappers are initialized (the isolate does so in [_run]; the main
  /// isolate already has them).
  static String buildJson(JsonExportData data) => const JsonEncoder.withIndent('    ').convert(data.toMap());

  static void _run(_JsonExporterArgs args) {
    initializeMappers();
    args.path.writeAsStringSync(buildJson(args.data));
  }

  @override
  Future<dynamic> _export(FilePath path) async {
    // Export only the selected rows, drawn from the snapshotted source so the
    // archive view exports its own records. async so a resolve failure rejects
    // the future (caught by export()'s catchError) rather than throwing
    // synchronously past it.
    final records = resolveSelectedRecords();
    final labelMap = ref.read(labelMapProvider);
    return compute(_run, _JsonExporterArgs(path, JsonExportData(records, labelMap)));
  }

  @override
  Future<Uint8List> exportBytes() async {
    // Web build: no isolate/OS path. Mappers are already initialized on the main
    // isolate, so build the same JSON string the desktop isolate writes and
    // UTF-8-encode it (writeAsStringSync's default encoding) for the download.
    final records = resolveSelectedRecords();
    final labelMap = ref.read(labelMapProvider);
    return Uint8List.fromList(utf8.encode(buildJson(JsonExportData(records, labelMap))));
  }
}

class _ZipExporterArgs {
  final FilePath path;
  final List<DirectoryPath> recordDirs;
  final FilePath labelsFile;

  _ZipExporterArgs(this.path, this.recordDirs, this.labelsFile);
}

class ZipExporter extends Exporter {
  ZipExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds, super.source);

  /// Desktop zip layout: `<uuid>/<file>` per record plus a top-level
  /// `labels.json`, i.e. the basenames `ZipFileEncoder` derives from the paths
  /// it is handed. It differs from the web/Stage-4 layout below, and it is kept
  /// as it is because it is what every already-exported archive on a user's disk
  /// looks like; `RecordZipService.import` accepts both layouts so either
  /// artefact re-imports (see that class's doc).
  static Future<void> _run(_ZipExporterArgs args) async {
    final encoder = ZipFileEncoder();
    encoder.create(args.path.path);
    // Bundle each selected record's directory (keyed by its id) plus the shared
    // label map, rather than the whole storage tree. addDirectory/addFile stream
    // the file contents asynchronously, so they (and close(), which flushes the
    // output and writes the central directory) must all be awaited: otherwise
    // endEncode() runs before any file body is written, or the isolate tears
    // down before the final flush, and the archive comes out empty/truncated.
    for (final dir in args.recordDirs) {
      await encoder.addDirectory(dir.toDirectory(), followLinks: false);
    }
    await encoder.addFile(args.labelsFile.toFile());
    await encoder.close();
  }

  @override
  Future<dynamic> _export(FilePath path) async {
    // async so a resolve failure rejects the future (caught by export()'s
    // catchError) rather than throwing synchronously past it.
    final info = ref.read(pathInfoProvider);
    final records = resolveSelectedRecords();
    final recordDirs = records.map((record) => recordDirOf(info, source, record)).toList();
    final labelsFile = info.modulesDir.filePath("labels.json");
    if (recordDirs.isEmpty) {
      return compute(_run, _ZipExporterArgs(path, recordDirs, labelsFile));
    }
    // Hold every exported record's mutation lock across the walk, exactly as the
    // web leg does inside [RecordZipService.export] and as the desktop archive
    // does around its own `compute`. Reading a record directory is not exempt
    // from the exclusion its writers obey: an inheritance write-back or a
    // regeneration batch started by a capture running in another tab of the app
    // rewrites `record.json` and the images in place, and `addDirectory` walking
    // them at that moment either packs a torn file or throws on one that moved.
    // Nothing in the UI prevents that overlap -- the export button is disabled
    // only while another export runs, and the capture card's mutual exclusion
    // covers the four capture features, not exporting.
    //
    // The lock is taken here on the main isolate rather than inside `_run`, for
    // the same platform reason `archive_executor_io.dart` states: the desktop
    // lock is per-isolate state, so one taken in the spawned isolate would
    // exclude none of the writers, which all run here.
    //
    // `storageDir` is the root every other caller derives as
    // `<root>/chara_detail/{active,archive}/<id>`'s great-grandparent, so both
    // sources lock against the same recovery root.
    final gate = ref.read(exportRecoveryGateProvider);
    return gate.runForRecords(
      info.storageDir,
      records.map((record) => record.id),
      () => compute(_run, _ZipExporterArgs(path, recordDirs, labelsFile)),
    );
  }

  @override
  Future<Uint8List> exportBytes() {
    // Web build: read the selected record directories from OPFS via the async FS
    // backend and pack the Stage-4-compatible `chara_detail/active/<uuid>/<file>`
    // layout in memory. This intentionally differs from the desktop zip (which
    // uses per-id basenames plus a top-level labels.json) so the result
    // round-trips with RecordZipService.import and the Stage-4 harness.
    final info = ref.read(pathInfoProvider);
    final recordDirs = resolveSelectedRecords().map((record) => recordDirOf(info, source, record)).toList();
    // Same gate as the desktop leg above, so the two zip exports are locked by
    // one decision rather than two: [RecordZipService.export] wraps its whole
    // read in it.
    return RecordZipService.export(recordDirs, recoveryGate: ref.read(exportRecoveryGateProvider));
  }
}
