// Coverage for the shared byte-building functions the JSON/CSV exporters use.
//
// The web export path ([JsonExporter.exportBytes] / [CsvExporter.exportBytes])
// and the desktop file writers both route through these pure helpers, so the
// desktop output stays byte-identical after the web-enabling refactor. These
// tests pin the helpers directly (constructing a live grid/ref for the full
// exporter is out of scope for a unit test); the desktop-path regression is
// covered by the rest of the suite.
//
// The claim that [JsonExporter.exportBytes] really is UTF-8 of [JsonExporter.buildJson]
// cannot be asserted here -- it needs a live exporter -- so it is pinned where one
// exists, on the bytes handed to `saveFile` in exporter_flow_test.dart.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/exporter_bytes_test.dart
import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/core/mapper_init.dart';

import 'support/records.dart';

void main() {
  setUpAll(initializeMappers);

  group('JsonExporter.buildJson', () {
    test('emits parseable, pretty-printed JSON matching the export shape', () {
      final data = JsonExportData(
        [makeRecord(id: 'uuid-1', card: 1001), makeRecord(id: 'uuid-2', card: 1002)],
        {
          'character': ['A', 'B'],
        },
      );

      final json = JsonExporter.buildJson(data);

      // Pretty-printed with the desktop writer's 4-space indent.
      expect(json.contains('\n    '), isTrue);
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      expect(parsed.keys, containsAll(<String>['chara_detail', 'labels']));
      expect((parsed['chara_detail'] as List), hasLength(2));
      expect(parsed['labels'], {
        'character': ['A', 'B'],
      });
      // Round-trips back to the same document the desktop isolate would write.
      expect(jsonDecode(json), equals(data.toMap()));
    });
  });

  group('CsvExporter.encodeCsv', () {
    const content = 'name,card\nキタサンブラック,1001\n';

    test('UTF-8-BOM output starts with the BOM and decodes to the content', () {
      final bytes = CsvExporter.encodeCsv(content, CharCodec.utf8Bom);

      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(bytes.sublist(3)), equals(content));
    });

    test('ShiftJIS output round-trips through the ShiftJIS decoder', () {
      final bytes = CsvExporter.encodeCsv(content, CharCodec.shiftJis);

      // No UTF-8 BOM, and the ShiftJIS decoder recovers the original content.
      expect(bytes.take(3), isNot([0xEF, 0xBB, 0xBF]));
      expect(const ShiftJISDecoder().convert(bytes), equals(content));
    });

    test('UTF-16LE-BOM output round-trips through the UTF-16LE decoder', () {
      final bytes = CsvExporter.encodeCsv(content, CharCodec.utf16leBom);

      expect(bytes.take(2), [0xFF, 0xFE]);
      // The body, not just the mark. The BOM alone is satisfied by writing the LE mark and then
      // big-endian code units, by appending the UTF-8 bytes, and by writing no body at all — and
      // the encoding is one call into an external package, so a dependency bump is exactly how the
      // code-unit order would change. This is the only one of the three codecs whose body was not
      // decoded back.
      expect(const Utf16Decoder().decodeUtf16Le(bytes), equals(content));
      // Byte order stated directly as well, because `decodeUtf16Le` would also accept a body of
      // ASCII-only text written the wrong way round if every code unit happened to be symmetric.
      // 'n' of "name" is one code unit: low byte first is what little-endian means.
      expect(bytes.skip(2).take(2), [0x6E, 0x00]);
    });
  });
}
