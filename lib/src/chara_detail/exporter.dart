import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:charset_converter/charset_converter.dart';
import 'package:csv/csv.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/app/providers.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';

abstract class Exporter {
  final String dialogTitle;

  final String defaultFileName;

  final WidgetRef ref;

  Exporter(this.dialogTitle, this.defaultFileName, this.ref);

  void export({StringCallback? onSuccess}) {
    FilePicker.platform.saveFile(dialogTitle: dialogTitle, fileName: defaultFileName).then((path) {
      if (path != null) {
        _export(path).then((_) => onSuccess?.call(path));
      }
    });
  }

  Future<void> _export(String path);
}

class CsvExporter extends Exporter {
  final String encoding;

  CsvExporter(super.dialogTitle, super.defaultFileName, super.ref, this.encoding);

  @override
  Future<void> _export(String path) {
    logger.d(path);
    final grid = ref.watch(currentGridProvider);
    final table = grid.rows.map((row) => row.cells.entries.map((e) => e.value.getUserData()).toList()).toList();
    table.insert(0, grid.columns.map((e) => e.title).toList());
    return CharsetConverter.encode(encoding, const ListToCsvConverter().convert(table))
        .then((content) => File(path).writeAsBytes(content));
  }
}

class JsonExporter extends Exporter {
  JsonExporter(super.dialogTitle, super.defaultFileName, super.ref);

  @override
  Future<void> _export(String path) {
    logger.d(path);
    final records = ref.read(charaDetailRecordStorageProvider);
    final options = SerializationOptions(
      caseStyle: CaseStyle.snake,
      indent: " " * 4,
    );
    return File(path).writeAsString(JsonMapper.serialize(records, options));
  }
}

class ZipExporter extends Exporter {
  ZipExporter(super.dialogTitle, super.defaultFileName, super.ref);

  @override
  Future<void> _export(String path) {
    logger.d(path);
    final directory = ref.read(pathInfoProvider).charaDetail;
    final encoder = ZipFileEncoder();
    encoder.create(path);
    encoder.addDirectory(Directory(directory));
    encoder.close();
    return Future.value();
  }
}
