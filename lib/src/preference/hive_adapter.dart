import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/clipboard_alt.dart';

class JsonAdapter<T> extends TypeAdapter<T?> {
  JsonAdapter(this.typeId);

  @override
  final int typeId;

  @override
  T? read(BinaryReader reader) {
    return MapperContainer.globals.fromJson<T>(reader.readString());
  }

  @override
  void write(BinaryWriter writer, T? obj) {
    writer.writeString(MapperContainer.globals.toJson<T?>(obj));
  }
}

void registerHiveAdapters() {
  int index = 0;
  Hive.registerAdapter(JsonAdapter<Size>(index++));
  Hive.registerAdapter(JsonAdapter<Offset>(index++));
  Hive.registerAdapter(JsonAdapter<ThemeMode>(index++));
  Hive.registerAdapter(JsonAdapter<CharaDetailRecordImageMode>(index++));
  Hive.registerAdapter(JsonAdapter<ClipboardPasteImageMode>(index++));
}
