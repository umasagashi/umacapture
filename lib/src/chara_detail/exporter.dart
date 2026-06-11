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

abstract class Exporter {
  final String dialogTitle;

  final String defaultFileName;

  final WidgetRef ref;

  Exporter(this.dialogTitle, this.defaultFileName, this.ref);

  void export({PathEntityCallback? onSuccess}) {
    getDownloadsDirectory().then((initialDirectory) {
      // file_picker 12 removed the `FilePicker.platform` instance accessor and
      // changed `saveFile` to require the file bytes up-front, which is
      // incompatible with the path-based exporters below (the Zip encoder and
      // the isolate-based JSON writer produce the file themselves). Instead we
      // let the user pick a directory and build the full output path here.
      FilePicker.getDirectoryPath(dialogTitle: dialogTitle, initialDirectory: initialDirectory?.path).then((directory) {
        if (directory != null) {
          final path = DirectoryPath(directory).filePath(defaultFileName);
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

  CsvExporter(super.dialogTitle, super.defaultFileName, super.ref, this.encoding);

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
    final grid = ref.watch(currentGridProvider);
    final table = [
      grid.columns.map((e) => e.title).toList(),
      // A broken placeholder cell carries no Exportable userData; export it as an
      // empty field rather than crashing the whole export on a null unwrap.
      ...grid.rows.map((row) => row.cells.entries.map((e) => e.value.getUserData<Exportable>()?.csv ?? "").toList()),
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
  JsonExporter(super.dialogTitle, super.defaultFileName, super.ref);

  static void _run(_JsonExporterArgs args) {
    initializeMappers();
    args.path.writeAsStringSync(const JsonEncoder.withIndent('    ').convert(args.data.toMap()));
  }

  @override
  Future<dynamic> _export(FilePath path) {
    final records = ref.read(charaDetailRecordStorageProvider);
    final labelMap = ref.read(labelMapProvider);
    return compute(_run, _JsonExporterArgs(path, JsonExportData(records, labelMap)));
  }
}

class _ZipExporterArgs {
  final FilePath path;
  final PathInfo pathInfo;

  _ZipExporterArgs(this.path, this.pathInfo);
}

class ZipExporter extends Exporter {
  ZipExporter(super.dialogTitle, super.defaultFileName, super.ref);

  static void _run(_ZipExporterArgs args) {
    final encoder = ZipFileEncoder();
    encoder.create(args.path.path);
    encoder.addDirectory(args.pathInfo.charaDetailDir.toDirectory(), followLinks: false);
    encoder.addFile((args.pathInfo.modulesDir.filePath("labels.json")).toFile());
    encoder.close();
  }

  @override
  Future<dynamic> _export(FilePath path) {
    final info = ref.read(pathInfoProvider);
    return compute(_run, _ZipExporterArgs(path, info));
  }
}
