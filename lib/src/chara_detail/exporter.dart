import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:charset_converter/charset_converter.dart';
import 'package:csv/csv.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/app/providers.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/json_adapter.dart';
import '/src/core/utils.dart';

final exportingStateProvider = StateProvider<bool>((ref) {
  return false;
});

abstract class Exporter {
  final String dialogTitle;

  final String defaultFileName;

  final WidgetRef ref;

  Exporter(this.dialogTitle, this.defaultFileName, this.ref);

  void export({StringCallback? onSuccess}) {
    FilePicker.platform.saveFile(dialogTitle: dialogTitle, fileName: defaultFileName).then((path) {
      if (path != null) {
        ref.read(exportingStateProvider.notifier).update((_) => true);
        _export(path).then((_) {
          ref.read(exportingStateProvider.notifier).update((_) => false);
          onSuccess?.call(path);
        });
      }
    });
  }

  Future<void> _export(String path);
}

class CsvExporter extends Exporter {
  final String encoding;

  CsvExporter(super.dialogTitle, super.defaultFileName, super.ref, this.encoding);

  @override
  Future<void> _export(String path) async {
    logger.d(path);
    final grid = ref.watch(currentGridProvider);
    final table = grid.rows.map((row) => row.cells.entries.map((e) => e.value.getUserData()).toList()).toList();
    table.insert(0, grid.columns.map((e) => e.title).toList());
    final content = CharsetConverter.encode(encoding, const ListToCsvConverter().convert(table));
    return content.then((e) => File(path).writeAsBytes(e));
  }
}

class _JsonExporterArgs {
  final File outputFile;
  final List<CharaDetailRecord> records;

  _JsonExporterArgs(this.outputFile, this.records);
}

class JsonExporter extends Exporter {
  JsonExporter(super.dialogTitle, super.defaultFileName, super.ref);

  static void _run(_JsonExporterArgs args) {
    initializeJsonReflectable();
    final options = SerializationOptions(caseStyle: CaseStyle.snake, indent: " " * 4);
    args.outputFile.writeAsStringSync(JsonMapper.serialize(args.records, options));
  }

  @override
  Future<void> _export(String path) {
    final records = ref.read(charaDetailRecordStorageProvider);
    return compute(_run, _JsonExporterArgs(File(path), records));
  }
}

class _ZipExporterArgs {
  final File outputFile;
  final PathInfo pathInfo;

  _ZipExporterArgs(this.outputFile, this.pathInfo);
}

class ZipExporter extends Exporter {
  ZipExporter(super.dialogTitle, super.defaultFileName, super.ref);

  static void _run(_ZipExporterArgs args) {
    final encoder = ZipFileEncoder();
    encoder.create(args.outputFile.path);
    encoder.addDirectory(Directory(args.pathInfo.charaDetail));
    encoder.close();
  }

  @override
  Future<void> _export(String path) {
    final info = ref.read(pathInfoProvider);
    return compute(_run, _ZipExporterArgs(File(path), info));
  }
}
