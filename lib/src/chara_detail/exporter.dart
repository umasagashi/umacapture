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
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

part 'exporter.mapper.dart';

final exportingStateProvider = settableNotifierProvider<bool>(false);

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

  void run(Exporter Function(RefBase ref) builder, {PathEntityCallback? onSuccess}) {
    builder(ref.base).export(onSuccess: onSuccess);
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

  void export({PathEntityCallback? onSuccess}) {
    getDownloadsDirectory().then((initialDirectory) {
      // Use the native Save-File dialog so the user picks the exact file name and
      // location. file_picker 12's saveFile would also write its `bytes` to the
      // chosen path, but the path-based exporters below (the Zip encoder and the
      // isolate-based JSON/CSV writers) produce the file themselves. Passing an
      // empty byte list makes saveFile a no-op writer (saveBytesToFile skips when
      // bytes are empty), so it only returns the chosen path for us to write to.
      FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: defaultFileName,
        initialDirectory: initialDirectory?.path,
        bytes: Uint8List(0),
        lockParentWindow: true,
      ).then((savedPath) {
        if (savedPath != null) {
          final path = FilePath(savedPath);
          final notifier = ref.read(exportingStateProvider.notifier);
          notifier.set(true);
          // Reset the exporting flag in whenComplete so a failure (disk full,
          // locked file, encode error) cannot leave the UI stuck showing the
          // spinner forever; surface the error instead of swallowing it.
          _export(path)
              .then((_) => onSuccess?.call(path))
              .catchError((Object e, StackTrace st) {
                logger.e("Failed to export records", e, st);
                Toaster.show(ToastData.error(description: "toast.record_export_failure".tr()));
              })
              .whenComplete(() => notifier.set(false));
        }
      });
    });
  }

  Future<dynamic> _export(FilePath path);
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

  List<int> encode(String content) {
    switch (encoding) {
      case CharCodec.shiftJis:
        return const ShiftJISEncoder().convert(content);
      case CharCodec.utf8Bom:
        return [0xEF, 0xBB, 0xBF, ...utf8.encode(content)];
      case CharCodec.utf16leBom:
        return const Utf16Encoder().encodeUtf16Le(content, true);
    }
  }

  @override
  Future<dynamic> _export(FilePath path) async {
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
    final content = const CsvEncoder().convert(table);
    return path.writeAsBytes(encode(content));
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

  static void _run(_JsonExporterArgs args) {
    initializeMappers();
    args.path.writeAsStringSync(const JsonEncoder.withIndent('    ').convert(args.data.toMap()));
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
}

class _ZipExporterArgs {
  final FilePath path;
  final List<DirectoryPath> recordDirs;
  final FilePath labelsFile;

  _ZipExporterArgs(this.path, this.recordDirs, this.labelsFile);
}

class ZipExporter extends Exporter {
  ZipExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds, super.source);

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
    final recordDirs = resolveSelectedRecords().map((record) => recordDirOf(info, source, record)).toList();
    final labelsFile = info.modulesDir.filePath("labels.json");
    return compute(_run, _ZipExporterArgs(path, recordDirs, labelsFile));
  }
}
