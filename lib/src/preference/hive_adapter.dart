import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/clipboard_alt.dart';

class JsonAdapter<T> extends TypeAdapter<T?> {
  const JsonAdapter(this.typeId);

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
  // typeId is the on-disk identity of each adapter, so these literals must stay
  // stable: never reorder, reuse, or repurpose an existing id. Add new types at
  // the end with the next unused id.
  Hive.registerAdapter(JsonAdapter<Size>(0));
  Hive.registerAdapter(JsonAdapter<Offset>(1));
  Hive.registerAdapter(JsonAdapter<ThemeMode>(2));
  Hive.registerAdapter(JsonAdapter<CharaDetailRecordImageMode>(3));
  Hive.registerAdapter(JsonAdapter<ClipboardPasteImageMode>(4));
}
