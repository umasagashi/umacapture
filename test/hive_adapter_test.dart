// Unit tests for the Hive JsonAdapter read/write contract
// (lib/src/preference/hive_adapter.dart). These guard the data-safety promise
// that a persisted value which can no longer decode must degrade to null instead
// of crashing the provider that reads it -- and that a legitimately persisted
// null round-trips cleanly rather than being logged as corruption.
//
// The adapter is driven through minimal fake BinaryReader/BinaryWriter (only
// readString/writeString are exercised) so the test targets the changed code
// directly, without Hive's box framing.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/hive_adapter_test.dart
import 'dart:convert';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/preference/hive_adapter.dart';

/// A [BinaryReader] that yields a fixed string for [readString] (or throws, to
/// simulate a value framed by a different adapter), and rejects every other call
/// so a test drives [JsonAdapter.read] through exactly the one binary read it does.
class _FakeReader implements BinaryReader {
  _FakeReader(this._payload) : _throwOnRead = false;

  _FakeReader.throwing() : _payload = '', _throwOnRead = true;

  final String _payload;
  final bool _throwOnRead;

  @override
  String readString([int? byteCount, Converter<List<int>, String>? decoder]) {
    if (_throwOnRead) {
      throw const FormatException('simulated binary read failure');
    }
    return _payload;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [BinaryWriter] that captures the single string [JsonAdapter.write] emits.
class _FakeWriter implements BinaryWriter {
  String? written;

  @override
  void writeString(String value, {bool writeByteCount = true, Converter<String, List<int>>? encoder}) {
    written = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(initializeMappers);

  // typeId 2 is ThemeMode in registerHiveAdapters(); ThemeMode is a simple,
  // single-value type registered into MapperContainer.globals by initializeMappers.
  const adapter = JsonAdapter<ThemeMode>(2);

  test('round-trips a value through write then read', () {
    for (final mode in ThemeMode.values) {
      final writer = _FakeWriter();
      adapter.write(writer, mode);
      expect(adapter.read(_FakeReader(writer.written!)), mode);
    }
  });

  test('a persisted null round-trips to null without being treated as corruption', () {
    final writer = _FakeWriter();
    adapter.write(writer, null);
    // write serializes null as the JSON literal; read decodes it back via
    // fromJson<T?> (not <T>), so the null does not fall into the corruption path.
    expect(writer.written, 'null');
    expect(adapter.read(_FakeReader(writer.written!)), isNull);
  });

  test('an undecodable payload degrades to null instead of throwing', () {
    // A retired enum value / corrupt JSON persisted under this typeId.
    expect(adapter.read(_FakeReader('"not_a_theme_mode"')), isNull);
    expect(adapter.read(_FakeReader('{ this is not json')), isNull);
  });

  test('a failure in the binary read itself degrades to null', () {
    // Guards the fix that moved readString() inside the try: a value framed by a
    // different adapter/primitive on this key must degrade to null, not throw out
    // of box.get() and crash the provider that reads it.
    expect(adapter.read(_FakeReader.throwing()), isNull);
  });

  test('fromJson<T?> is what lets a persisted null decode (why read uses it)', () {
    // The nullable decode returns null cleanly, which read() relies on.
    expect(MapperContainer.globals.fromJson<ThemeMode?>('null'), isNull);
  });
}
