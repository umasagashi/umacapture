import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:charset/charset.dart';
import 'package:csv/csv.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

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

abstract class Exportable {
  String get csv;
}

abstract class Exporter {
  final String dialogTitle;

  final String defaultFileName;

  final WidgetRef ref;

  Exporter(this.dialogTitle, this.defaultFileName, this.ref);

  void export({StringCallback? onSuccess}) {
    getDownloadsDirectory().then((initialDirectory) {
      FilePicker.platform
          .saveFile(dialogTitle: dialogTitle, fileName: defaultFileName, initialDirectory: initialDirectory?.path)
          .then((path) {
        if (path != null) {
          ref.read(exportingStateProvider.notifier).update((_) => true);
          _export(path).then((_) {
            ref.read(exportingStateProvider.notifier).update((_) => false);
            onSuccess?.call(path);
          });
        }
      });
    });
  }

  Future<dynamic> _export(String path);
}

enum CharCodec {
  shiftJis,
  utf8Bom,
  utf16leBom,
}

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
  Future<dynamic> _export(String path) async {
    logger.d(path);
    final grid = ref.watch(currentGridProvider);
    final table = [
      grid.columns.map((e) => e.title).toList(),
      ...grid.rows.map((row) => row.cells.entries.map((e) => e.value.getUserData<Exportable>()!.csv).toList()).toList(),
    ];
    final content = const ListToCsvConverter().convert(table);
    return File(path).writeAsBytes(encode(content));
  }
}

@jsonSerializable
class JsonExportData {
  final List<CharaDetailRecord> charaDetail;
  final LabelMap labels;

  JsonExportData(this.charaDetail, this.labels);
}

class _JsonExporterArgs {
  final File outputFile;
  final JsonExportData data;

  _JsonExporterArgs(this.outputFile, this.data);
}

class JsonExporter extends Exporter {
  JsonExporter(super.dialogTitle, super.defaultFileName, super.ref);

  static void _run(_JsonExporterArgs args) {
    initializeJsonReflectable();
    final options = SerializationOptions(caseStyle: CaseStyle.snake, indent: " " * 4);
    args.outputFile.writeAsStringSync(JsonMapper.serialize(args.data, options));
  }

  @override
  Future<dynamic> _export(String path) {
    final records = ref.read(charaDetailRecordStorageProvider);
    final labelMap = ref.read(labelMapProvider);
    return compute(_run, _JsonExporterArgs(File(path), JsonExportData(records, labelMap)));
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
    encoder.addFile(File("${args.pathInfo.modules}/labels.json"));
    encoder.close();
  }

  @override
  Future<dynamic> _export(String path) {
    final info = ref.read(pathInfoProvider);
    return compute(_run, _ZipExporterArgs(File(path), info));
  }
}
