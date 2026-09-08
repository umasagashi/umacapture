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

/// Something to do with every adapter the app registers, once each, **with its
/// type argument intact**.
typedef AdapterVisitor = void Function<T>(JsonAdapter<T> adapter);

/// The one declaration of what this app persists through `dart_mappable`.
///
/// A visitor and not a `List<JsonAdapter>`, because a list erases `T` to
/// `dynamic` and `Hive.registerAdapter` resolves an adapter by `value is T` — a
/// `dynamic` T matches *every* value, so the first entry would claim every write
/// in the app. The generic callback keeps each `T` reified, which is also what
/// lets [encodeRegisteredHiveValue] below test a runtime value against it.
///
/// typeId is the on-disk identity of each adapter, so these literals must stay
/// stable: never reorder, reuse, or repurpose an existing id. Add new types at
/// the end with the next unused id — and note that adding one here is what
/// extends the second tier of the storage view's settings-value rendering
/// (`settings_value_render.dart`), which is why
/// `hive_adapter_roster_test.dart` turns red until the addition has been looked
/// at.
void visitHiveAdapters(AdapterVisitor visit) {
  visit(const JsonAdapter<Size>(0));
  visit(const JsonAdapter<Offset>(1));
  visit(const JsonAdapter<ThemeMode>(2));
  visit(const JsonAdapter<CharaDetailRecordImageMode>(3));
  visit(const JsonAdapter<ClipboardPasteImageMode>(4));
  visit(const JsonAdapter<RowHeightMode>(5));
}

void registerHiveAdapters() {
  // Guard each registration so registerHiveAdapters is idempotent: Hive keeps
  // adapters registered across Hive.close(), so a second StorageBox.ensureOpened
  // in the same process (e.g. reopening with reset) would otherwise throw
  // HiveError on the already-registered typeId before it could reset any box.
  visitHiveAdapters(<T>(JsonAdapter<T> adapter) {
    if (!Hive.isAdapterRegistered(adapter.typeId)) {
      Hive.registerAdapter(adapter);
    }
  });
}

/// [value]'s `dart_mappable` JSON when its type is one of the persisted ones,
/// `null` otherwise — the second tier of the storage view's settings-value
/// rendering.
///
/// Derived from [visitHiveAdapters] rather than from a table of its own. A
/// hand-written second list would be a copy of the first that nothing holds to
/// it, so a type added to the registrations would keep persisting correctly while
/// silently dropping to `toString()` on the storage view — the one failure those
/// tiers are ordered to prevent, and an invisible one, because a value rendered
/// by the wrong tier still renders.
String? encodeRegisteredHiveValue(Object value) {
  String? encoded;
  visitHiveAdapters(<T>(JsonAdapter<T> adapter) {
    // `is T` and not a `runtimeType` comparison: a subtype of a registered type
    // is written by that adapter too (this is the same test
    // `Hive.registerAdapter` resolves writes with), so the rendering has to
    // follow the same rule the persistence does.
    if (encoded == null && value is T) {
      // Cast rather than relying on promotion: `value` is captured from the
      // enclosing function, and flow analysis does not promote a capture to the
      // closure's own type parameter. The `is` test above is what makes the cast
      // safe, and it is the same test `Hive.registerAdapter` resolves writes
      // with.
      encoded = MapperContainer.globals.toJson<T>(value as T);
    }
  });
  return encoded;
}
