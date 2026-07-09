import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/app_logger.dart';
import '/src/core/clipboard_alt.dart';

class JsonAdapter<T> extends TypeAdapter<T?> {
  const JsonAdapter(this.typeId);

  @override
  final int typeId;

  @override
  T? read(BinaryReader reader) {
    String? raw;
    try {
      // readString stays inside the try: a value framed by a different adapter/primitive on this key can
      // throw on the binary read too, and that must degrade to null like a JSON-decode failure rather than
      // escape box.get(). fromJson<T?> (not <T>) mirrors write's toJson<T?>, so a legitimately persisted
      // null round-trips to null without being logged as corruption.
      raw = reader.readString();
      return MapperContainer.globals.fromJson<T?>(raw);
    } catch (error, stackTrace) {
      // A persisted value that can no longer decode (a retired enum value,
      // corrupt JSON) must not crash the provider that reads it. Fall back to
      // null so callers degrade to their default; the bad string is left on
      // disk and the next write overwrites it.
      logger.w("Failed to decode persisted value (typeId=$typeId): $raw", error, stackTrace);
      return null;
    }
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
  //
  // Guard each registration so registerHiveAdapters is idempotent: Hive keeps
  // adapters registered across Hive.close(), so a second StorageBox.ensureOpened
  // in the same process (e.g. reopening with reset) would otherwise throw
  // HiveError on the already-registered typeId before it could reset any box.
  void register<T>(JsonAdapter<T> adapter) {
    if (!Hive.isAdapterRegistered(adapter.typeId)) {
      Hive.registerAdapter(adapter);
    }
  }

  register(JsonAdapter<Size>(0));
  register(JsonAdapter<Offset>(1));
  register(JsonAdapter<ThemeMode>(2));
  register(JsonAdapter<CharaDetailRecordImageMode>(3));
  register(JsonAdapter<ClipboardPasteImageMode>(4));
  register(JsonAdapter<RowHeightMode>(5));
}
