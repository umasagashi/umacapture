// The sentry over the second settings-value rendering tier
// (`SettingsValueTier.registeredType`): the rule that a value whose runtime type
// carries a registered Hive adapter is shown as its `dart_mappable` JSON, and
// everything else falls through to `toString()`.
//
//   .fvm/flutter_sdk/bin/flutter test test/hive_adapter_roster_test.dart
//
// WHY THIS IS A TEST. `hive_adapter.dart` expects new types ("Add new types at
// the end with the next unused id"), and the storage view renders a value it
// cannot JSON-encode as `toString()` **successfully** — no error, nothing a later
// reader would notice. So every adapter the declaration list visits needs a sample
// here that is shown to encode, and a new adapter without one fails the encode case.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/storage/settings_value_render.dart';
import 'package:umacapture/src/preference/hive_adapter.dart';

/// Every adapter [visitHiveAdapters] visits, as `T#typeId`.
Set<String> visitedAdapters() {
  final found = <String>{};
  visitHiveAdapters(<T>(JsonAdapter<T> adapter) => found.add('$T#${adapter.typeId}'));
  return found;
}

/// The typeId of every adapter [visitHiveAdapters] visits, **as a list and not a
/// set**, so that two adapters claiming the same id survive the collection
/// instead of collapsing into a single entry.
///
/// Read from the visitor rather than from a table, so it counts whatever the
/// declaration list happens to hold — a seventh adapter is covered the day it is
/// written, without this file being told about it.
List<int> visitedTypeIds() {
  final ids = <int>[];
  visitHiveAdapters(<T>(JsonAdapter<T> adapter) => ids.add(adapter.typeId));
  return ids;
}

/// Every value of [ids] that occurs more than once.
Set<int> duplicateTypeIds(List<int> ids) {
  return ids.where((id) => ids.where((other) => other == id).length > 1).toSet();
}

/// One value of each registered type, so "can this be JSON-encoded" is answered
/// by encoding one rather than by assuming.
const _samples = <String, Object>{
  'Size#0': Size(1280, 720),
  'Offset#1': Offset(12, 34),
  'ThemeMode#2': ThemeMode.dark,
  'CharaDetailRecordImageMode#3': CharaDetailRecordImageMode.skillPlain,
  'ClipboardPasteImageMode#4': ClipboardPasteImageMode.file,
  'RowHeightMode#5': RowHeightMode.autoPerRow,
};

void main() {
  setUpAll(initializeMappers);

  test('no two adapters claim the same typeId', () {
    // typeId is the on-disk identity, and `registerHiveAdapters` guards every
    // call with `Hive.isAdapterRegistered`, so a repeated id does not throw: the
    // second adapter is silently never registered and its type is written by the
    // first one's mapper.
    final ids = visitedTypeIds();
    expect(duplicateTypeIds(ids), isEmpty, reason: 'typeId is the on-disk identity and must be unique: $ids');
  });

  test('the duplicate-typeId check reports a repeated id rather than always finding none', () {
    // Without this, `duplicateTypeIds` returning a constant empty set would look
    // exactly like a roster that is in order.
    expect(duplicateTypeIds([0, 1, 2]), isEmpty);
    expect(duplicateTypeIds([0, 1, 0]), {0});
    expect(duplicateTypeIds([3, 3, 3]), {3});
  });

  test('every registered type encodes to JSON, so tier 2 covers all of them', () {
    expect(_samples.keys.toSet(), visitedAdapters(), reason: 'a sample per registered type');
    for (final entry in _samples.entries) {
      final encoded = encodeRegisteredHiveValue(entry.value);
      expect(encoded, isNotNull, reason: '${entry.key} produced no JSON');
      // Encoding to *something* is not enough: the view hands the result to a JSON
      // pretty-printer, so it has to parse.
      expect(() => jsonDecode(encoded ?? ''), returnsNormally, reason: '${entry.key} did not encode to JSON');
    }
  });

  test('a type outside the roster is declined rather than guessed at', () {
    // The other half of tier 2: it has to say "not mine" for the strings, ints
    // and bools that make up most of a settings box, or tier 3 would never be
    // reached and every plain value would be run through a mapper.
    expect(encodeRegisteredHiveValue('trainer-abc'), isNull);
    expect(encodeRegisteredHiveValue(42), isNull);
    expect(encodeRegisteredHiveValue(const Duration(seconds: 1)), isNull);
  });

  test('a registered value reaches rendering tier 2 end to end', () {
    // The adapters and the renderer are separately correct above; this is the one
    // case that says they are wired to each other.
    final view = renderSettingsValue(ThemeMode.dark, encodeRegistered: encodeRegisteredHiveValue);

    expect(view.tier, SettingsValueTier.registeredType);
    expect(view.isJson, isTrue);
  });
}
