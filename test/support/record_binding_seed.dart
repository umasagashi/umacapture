// Seeds a record directory the way the two kinds of record without a binding look on disk — one captured since the
// binding (its `record.json` is the recognizer's result as the capture composed it) and one from v0.3.0 — and works
// out, independently of the code under test, the binding the operations that let go of its images must place.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/image_converter.dart';

/// A record without a binding, by the fixture its `record.json` is copied from.
enum UnboundRecord {
  /// Captured: a capture writes the recognizer's result and no binding.
  captured('test/fixtures/recognized.json'),

  /// Stored by v0.3.0, before the binding existed.
  legacy('test/fixtures/chara_detail_record.json');

  const UnboundRecord(this.fixture);

  final String fixture;

  /// The record id the fixture names, which its directory has to be called.
  String get id => CharaDetailRecord.fromRecordJson(File(fixture).readAsStringSync()).id;
}

/// One PNG per image, each with other pixels, so that a field taken from the wrong image does not match.
Map<String, Uint8List> bindingImagePngs() => {
  for (final (index, name) in ['skill', 'factor', 'campaign'].indexed)
    name: img.encodePng(img.Image(width: 64, height: 96)..clear(img.ColorRgb8(40 * index, 90, 200 - 40 * index))),
};

/// Writes [kind]'s `record.json` and [pngs] into `<store>/<id>`, and answers that directory's path.
String seedUnboundRecord(String store, UnboundRecord kind, Map<String, Uint8List> pngs) {
  final dir = Directory('$store/${kind.id}')..createSync(recursive: true);
  File('${dir.path}/record.json').writeAsBytesSync(File(kind.fixture).readAsBytesSync());
  for (final entry in pngs.entries) {
    File('${dir.path}/${entry.key}.png').writeAsBytesSync(entry.value);
  }
  return dir.path;
}

/// The binding of [pngs]: each PNG's SHA-256, and that of the reduced JPEG an archive makes of it.
RecordBinding expectedBinding(Map<String, Uint8List> pngs) {
  String png(String name) => sha256.convert(pngs[name] ?? Uint8List(0)).toString();
  String? jpeg(String name) {
    final bytes = archiveJpegOf(pngs[name] ?? Uint8List(0));
    return bytes == null ? null : sha256.convert(bytes).toString();
  }

  return RecordBinding(
    skillPng: png('skill'),
    skillJpeg: jpeg('skill'),
    factorPng: png('factor'),
    factorJpeg: jpeg('factor'),
    campaignPng: png('campaign'),
    campaignJpeg: jpeg('campaign'),
  );
}

/// The binding the `record.json` in [bytes] carries.
RecordBinding? bindingIn(List<int> bytes) => CharaDetailRecord.fromRecordJson(utf8.decode(bytes)).metadata.binding;

/// Sets or clears the Windows read-only attribute on [path]. `dart:io` has nothing that writes a mode.
Future<void> setReadOnly(String path, {required bool readOnly}) async {
  final result = await Process.run('attrib', [readOnly ? '+R' : '-R', path]);
  if (result.exitCode != 0) {
    throw StateError('attrib on $path failed: ${result.stderr}');
  }
}

const windowsOnlyReadOnly =
    'The read-only attribute is a Windows one and `attrib` is a Windows command; on POSIX the refusal comes from a '
    'mode bit instead.';

/// The files a record directory holds beside the record, which no export packs: the recognizer's result waiting to
/// be composed, its history of an earlier result (as the recognizer names it), the staging file of each
/// replacement the app or the recognizer makes, and the merges this device started into the record and has not
/// finished.
const recordFilesLeftOnDevice = [
  'recognized.json',
  'merges_in_progress.json',
  'record_1767225600000.json',
  'record.json.part',
  'archive.json.part',
  'recognized.json.part',
];

/// The time [seedRecordLocalFields] writes into the body, and the times it writes into the archive note.
const seededBodyWrittenAt = 1767225600000;

/// Gives the record seeded in [dir] what only this device holds — a body time and a relation bonus in its
/// `record.json`, an archive note with both of its times — and every file of [recordFilesLeftOnDevice].
void seedRecordLocalFields(String dir) {
  final recordFile = File('$dir/record.json');
  final record = jsonDecode(recordFile.readAsStringSync()) as Map<String, Object?>;
  final metadata = record['metadata'] as Map<String, Object?>;
  metadata['body_written_at'] = seededBodyWrittenAt;
  metadata['relation_bonus'] = 42;
  recordFile.writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record));
  File('$dir/archive.json').writeAsStringSync(
    jsonEncode({
      'normal_written_at': seededBodyWrittenAt,
      'archived': {'state': 'jpeg', 'written_at': seededBodyWrittenAt + 1},
    }),
  );
  final recognized = File(UnboundRecord.captured.fixture).readAsBytesSync();
  for (final name in recordFilesLeftOnDevice) {
    File('$dir/$name').writeAsBytesSync(recognized);
  }
}

/// The names of the files in [dir], sorted.
List<String> recordDirectoryNames(String dir) =>
    [for (final entity in Directory(dir).listSync()) entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty)]..sort();

/// [before], the names [recordDirectoryNames] gave for a record directory, as an export that placed the record's
/// binding leaves them: its replacement of `record.json` stages under `record.json.part` and renames it away.
List<String> namesAfterPlacing(List<String> before) => [
  for (final name in before)
    if (name != 'record.json.part') name,
];

/// The names the central directory of the zip in [bytes] lists, one per entry, duplicates kept.
List<String> zipEntryNames(List<int> bytes) {
  final directory = ZipDirectory()..read(InputMemoryStream(Uint8List.fromList(bytes)));
  return [for (final header in directory.fileHeaders) header.filename];
}

/// Asserts that the [names] of a zip packing the record seeded by [seedRecordLocalFields] under [prefix] list each of
/// its packed files once and nothing it leaves on the device, and that [contentOf] gives a `record.json` with neither
/// local field. The record is in the active store, so it is normal whatever its note remembers of an archive, and goes
/// out with no note: a record that carries none is normal.
void expectRecordLeftWithoutLocalFields(List<String> names, String prefix, List<int> Function(String name) contentOf) {
  final packed = [
    for (final name in names)
      if (name.startsWith('$prefix/') && !name.endsWith('/')) name.substring(prefix.length + 1),
  ]..sort();
  expect(packed, ['campaign.png', 'factor.png', 'record.json', 'skill.png']);
  final metadata =
      (jsonDecode(utf8.decode(contentOf('$prefix/record.json'))) as Map<String, Object?>)['metadata']
          as Map<String, Object?>;
  expect(metadata.keys, isNot(contains('body_written_at')));
  expect(metadata.keys, isNot(contains('relation_bonus')));
  expect(metadata['binding'], isNotNull, reason: 'the body still goes out with its binding');
}
