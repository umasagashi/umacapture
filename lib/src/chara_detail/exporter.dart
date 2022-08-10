import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:charset/charset.dart';
import 'package:csv/csv.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
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

  void export({PathEntityCallback? onSuccess}) {
    getDownloadsDirectory().then((initialDirectory) {
      FilePicker.platform
          .saveFile(dialogTitle: dialogTitle, fileName: defaultFileName, initialDirectory: initialDirectory?.path)
          .then((path) {
        if (path != null) {
          ref.read(exportingStateProvider.notifier).update((_) => true);
          _export(FilePath(path)).then((_) {
            ref.read(exportingStateProvider.notifier).update((_) => false);
            onSuccess?.call(FilePath(path));
          });
        }
      });
    });
  }

  Future<dynamic> _export(FilePath path);
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
  Future<dynamic> _export(FilePath path) async {
    logger.d(path);
    final grid = ref.watch(currentGridProvider);
    final table = [
      grid.columns.map((e) => e.title).toList(),
      ...grid.rows.map((row) => row.cells.entries.map((e) => e.value.getUserData<Exportable>()!.csv).toList()).toList(),
    ];
    final content = const ListToCsvConverter().convert(table);
    return path.writeAsBytes(encode(content));
  }
}

@jsonSerializable
class JsonExportData {
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
    initializeJsonReflectable();
    final options = SerializationOptions(caseStyle: CaseStyle.snake, indent: " " * 4);
    args.path.writeAsStringSync(JsonMapper.serialize(args.data, options));
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
    encoder.addDirectory(args.pathInfo.charaDetailActiveDir.toDirectory());
    encoder.addFile((args.pathInfo.modulesDir.filePath("labels.json")).toFile());
    encoder.close();
  }

  @override
  Future<dynamic> _export(FilePath path) {
    final info = ref.read(pathInfoProvider);
    return compute(_run, _ZipExporterArgs(path, info));
  }
}
