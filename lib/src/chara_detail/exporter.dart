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

  Exporter(this.dialogTitle, this.defaultFileName, this.ref, this.recordIds);

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

  CsvExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds, this.encoding);

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
    final grid = ref.read(currentGridProvider);
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
  JsonExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds);

  static void _run(_JsonExporterArgs args) {
    initializeMappers();
    args.path.writeAsStringSync(const JsonEncoder.withIndent('    ').convert(args.data.toMap()));
  }

  @override
  Future<dynamic> _export(FilePath path) {
    // Export only the selected rows, drawn from the table's current source so the
    // archive view exports its own records.
    final records = ref.read(displayedRecordsProvider).where((record) => recordIds.contains(record.id)).toList();
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
  ZipExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds);

  static Future<void> _run(_ZipExporterArgs args) async {
    final encoder = ZipFileEncoder();
    encoder.create(args.path.path);
    // Bundle each selected record's directory (keyed by its id) plus the shared
    // label map, rather than the whole storage tree. addDirectory/addFile stream
    // the file contents asynchronously, so they must be awaited before close():
    // otherwise endEncode() runs before any file body is written and the archive
    // comes out empty.
    for (final dir in args.recordDirs) {
      await encoder.addDirectory(dir.toDirectory(), followLinks: false);
    }
    await encoder.addFile(args.labelsFile.toFile());
    encoder.close();
  }

  @override
  Future<dynamic> _export(FilePath path) {
    final info = ref.read(pathInfoProvider);
    final source = ref.read(recordSourceProvider);
    final recordDirs = ref
        .read(displayedRecordsProvider)
        .where((record) => recordIds.contains(record.id))
        .map((record) => recordDirOf(info, source, record))
        .toList();
    final labelsFile = info.modulesDir.filePath("labels.json");
    return compute(_run, _ZipExporterArgs(path, recordDirs, labelsFile));
  }
}
