import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/long_read_declarations.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempRoot;
  late DirectoryPath storageDir;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_record_zip_test');
    storageDir = DirectoryPath(tempRoot.path) / 'storage';
    originalBackend = fsBackend;
    // Import/export is shared, but the OPFS write is the risky half, so it runs
    // against `WebLikeFsBackend`: a sync FS call added here fails on the VM
    // instead of passing CI and breaking only on web. That pins OPFS's
    // *synchronous* prohibition and nothing else -- see
    // `support/web_like_fs_backend.dart` for what this backend does not model.
    fsBackend = WebLikeFsBackend(originalBackend);
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('imports valid active records transactionally', () async {
    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
        'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList([1, 2, 3]),
        'chara_detail/active/uuid-2/record.json': _recordJson('uuid-2'),
      }),
      storageDir,
    );
    final active = _active(storageDir);
    expect(result.recordIds, {'uuid-1', 'uuid-2'});
    expect(result.skippedEntries, 0);
    expect(await (active / 'uuid-1').filePath('record.json').readAsBytes(), _recordJson('uuid-1'));
    expect(await (active / 'uuid-1').filePath('trainee.jpg').readAsBytes(), [1, 2, 3]);
  });

  test('counts skipped directory entries', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.directory('chara_detail/active/uuid-1/'))
      ..addFile(
        ArchiveFile('chara_detail/active/uuid-1/record.json', _recordJson('uuid-1').length, _recordJson('uuid-1')),
      );

    final result = await RecordZipService.import(Uint8List.fromList(ZipEncoder().encode(archive)), storageDir);

    expect(result.recordIds, {'uuid-1'});
    expect(result.skippedEntries, 1);
  });

  test('rejects zip-slip before writing any accepted entry', () async {
    final zip = _zip({
      'chara_detail/active/good/record.json': _recordJson('good'),
      'chara_detail/active/../../evil.txt': Uint8List.fromList([1]),
    });
    await expectLater(RecordZipService.import(zip, storageDir), throwsFormatException);
    expect(await (_active(storageDir) / 'good').exists(), isFalse);
    expect(await File('${tempRoot.path}/evil.txt').exists(), isFalse);
  });

  test('replaces only supplied files for a colliding record id', () async {
    await RecordZipService.import(
      _zip({
        'chara_detail/active/dup/record.json': _recordJson('dup'),
        'chara_detail/active/dup/value.bin': Uint8List.fromList([1]),
        'chara_detail/active/dup/keep.bin': Uint8List.fromList([7]),
      }),
      storageDir,
    );
    await RecordZipService.import(
      _zip({
        'chara_detail/active/dup/record.json': _recordJson('dup'),
        'chara_detail/active/dup/value.bin': Uint8List.fromList([2]),
      }),
      storageDir,
    );
    final record = _active(storageDir) / 'dup';
    expect(await record.filePath('value.bin').readAsBytes(), [2]);
    expect(await record.filePath('keep.bin').readAsBytes(), [7]);
  });

  test('rejects total size over the injected limit, writing nothing', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
      'chara_detail/active/uuid-2/record.json': _recordJson('uuid-2'),
      'chara_detail/active/uuid-2/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
    });
    await expectLater(
      RecordZipService.import(zip, storageDir, maxTotalUncompressedBytes: 100),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
    expect(await (_active(storageDir) / 'uuid-2').exists(), isFalse);
  });

  test('rejects entry count over the injected limit, writing nothing', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-2/record.json': _recordJson('uuid-2'),
    });
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryCount: 1),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
    expect(await (_active(storageDir) / 'uuid-2').exists(), isFalse);
  });

  test('rejects a single entry over the injected limit, writing nothing', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
    });
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryUncompressedBytes: 10),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
  });

  test('imports normally when within the injected limits', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
    });
    final result = await RecordZipService.import(
      zip,
      storageDir,
      maxTotalUncompressedBytes: 1000,
      maxEntryCount: 10,
      maxEntryUncompressedBytes: 100,
    );
    expect(result.recordIds, {'uuid-1'});
    expect(await (_active(storageDir) / 'uuid-1').filePath('trainee.jpg').readAsBytes(), List.filled(50, 1));
  });

  test('rejects a lying per-entry declared size once the real bytes exceed the limit', () async {
    // The header declares 50 bytes (well within any of the limits below), but
    // the entry actually deflates 2,000,000 zero bytes -- reproducing the
    // "declared size understates reality" attack that a header-only guard
    // would miss (see _BoundedOutputStream's doc in record_zip.dart).
    final zip = _zipWithLyingSizes([
      (name: 'chara_detail/active/uuid-1/big.bin', declaredUncompressedSize: 50, realUncompressedLength: 2000000),
    ]);
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryUncompressedBytes: 1000),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
  });

  test('rejects a lying declared size once the real cumulative bytes exceed the total limit', () async {
    // Both entries declare 50 bytes and individually stay under the
    // (generous) per-entry limit once inflated, but their combined real size
    // exceeds the small total limit injected here.
    final zip = _zipWithLyingSizes([
      (name: 'chara_detail/active/uuid-1/big1.bin', declaredUncompressedSize: 50, realUncompressedLength: 700),
      (name: 'chara_detail/active/uuid-2/big2.bin', declaredUncompressedSize: 50, realUncompressedLength: 700),
    ]);
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryUncompressedBytes: 1000, maxTotalUncompressedBytes: 1000),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
    expect(await (_active(storageDir) / 'uuid-2').exists(), isFalse);
  });

  test('exports STORED entries that round-trip through transactional import', () async {
    final active = _active(storageDir);
    await (active / 'uuid-a').create(recursive: true);
    await (active / 'uuid-b').create(recursive: true);
    await (active / 'uuid-a').filePath('record.json').writeAsBytes(_recordJson('uuid-a'));
    await (active / 'uuid-a').filePath('trainee.jpg').writeAsBytes([9, 8, 7]);
    await (active / 'uuid-b').filePath('record.json').writeAsBytes(_recordJson('uuid-b'));
    final bytes = await RecordZipService.export([active / 'uuid-a', active / 'uuid-b'], declaration: undeclaredInTest);
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.files.map((entry) => entry.name).toSet(), {
      'chara_detail/active/uuid-a/record.json',
      'chara_detail/active/uuid-a/trainee.jpg',
      'chara_detail/active/uuid-b/record.json',
    });
    expect(archive.files.map((entry) => entry.compression), everyElement(CompressionType.none));

    final fresh = Directory.systemTemp.createTempSync('umacapture_record_zip_roundtrip');
    addTearDown(() => fresh.deleteSync(recursive: true));
    final freshStorage = DirectoryPath(fresh.path) / 'storage';
    expect((await RecordZipService.import(bytes, freshStorage)).recordIds, {'uuid-a', 'uuid-b'});
    expect(await (_active(freshStorage) / 'uuid-a').filePath('record.json').readAsBytes(), _recordJson('uuid-a'));
    expect(await (_active(freshStorage) / 'uuid-a').filePath('trainee.jpg').readAsBytes(), [9, 8, 7]);
  });
}

DirectoryPath _active(DirectoryPath storage) => storage / 'chara_detail' / 'active';

Uint8List _zip(Map<String, Uint8List> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _recordJson(String id) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {
        'record_id': {'self': id},
      },
    }),
  ),
);

/// Builds a zip, by hand, whose local file headers *and* central directory
/// entries declare `declaredUncompressedSize` for each entry while the entry
/// actually deflates `realUncompressedLength` zero bytes.
///
/// `ArchiveFile.size`/`entry.size` reads straight from the central directory
/// header's declared uncompressed-size field with no cross-check against
/// what inflate actually produces, so a hand-built zip can lie about it. This
/// can't be produced through `package:archive`'s own `ZipEncoder` (which
/// always writes the true size), so the zip bytes are assembled directly per
/// the ZIP local/central-directory/EOCD layout, using `archive`'s public
/// `Deflate` class (raw deflate, no zlib wrapper) for the entry payloads.
Uint8List _zipWithLyingSizes(List<({String name, int declaredUncompressedSize, int realUncompressedLength})> entries) {
  final localSections = <Uint8List>[];
  final centralSections = <Uint8List>[];
  final localOffsets = <int>[];
  var offset = 0;

  for (final entry in entries) {
    final deflated = Deflate(Uint8List(entry.realUncompressedLength), level: DeflateLevel.bestCompression).getBytes();
    final nameBytes = utf8.encode(entry.name);

    final local = BytesBuilder();
    _writeU32(local, 0x04034b50); // local file header signature
    _writeU16(local, 20); // version needed to extract
    _writeU16(local, 0); // general purpose flag
    _writeU16(local, 8); // compression method = deflate
    _writeU16(local, 0); // last mod file time
    _writeU16(local, 0); // last mod file date
    _writeU32(local, 0); // crc-32 (unverified by RecordZipService.import)
    _writeU32(local, deflated.length); // compressed size (true)
    _writeU32(local, entry.declaredUncompressedSize); // uncompressed size (the lie)
    _writeU16(local, nameBytes.length);
    _writeU16(local, 0); // extra field length
    local.add(nameBytes);
    local.add(deflated);
    final localBytes = local.toBytes();

    localOffsets.add(offset);
    localSections.add(localBytes);
    offset += localBytes.length;

    final central = BytesBuilder();
    _writeU32(central, 0x02014b50); // central directory file header signature
    _writeU16(central, 20); // version made by
    _writeU16(central, 20); // version needed to extract
    _writeU16(central, 0); // general purpose flag
    _writeU16(central, 8); // compression method = deflate
    _writeU16(central, 0); // last mod file time
    _writeU16(central, 0); // last mod file date
    _writeU32(central, 0); // crc-32
    _writeU32(central, deflated.length); // compressed size (true)
    _writeU32(central, entry.declaredUncompressedSize); // uncompressed size (the lie)
    _writeU16(central, nameBytes.length);
    _writeU16(central, 0); // extra field length
    _writeU16(central, 0); // file comment length
    _writeU16(central, 0); // disk number start
    _writeU16(central, 0); // internal file attributes
    _writeU32(central, 0); // external file attributes
    _writeU32(central, localOffsets.last); // relative offset of local header
    central.add(nameBytes);
    centralSections.add(central.toBytes());
  }

  final centralDirectoryOffset = offset;
  final centralBytes = centralSections.fold(<int>[], (bytes, section) => bytes..addAll(section));

  final eocd = BytesBuilder();
  _writeU32(eocd, 0x06054b50); // end of central directory signature
  _writeU16(eocd, 0); // disk number
  _writeU16(eocd, 0); // disk with the start of the central directory
  _writeU16(eocd, entries.length); // entries on this disk
  _writeU16(eocd, entries.length); // total entries
  _writeU32(eocd, centralBytes.length); // size of the central directory
  _writeU32(eocd, centralDirectoryOffset); // offset of the central directory
  _writeU16(eocd, 0); // comment length

  return Uint8List.fromList([for (final section in localSections) ...section, ...centralBytes, ...eocd.toBytes()]);
}

void _writeU16(BytesBuilder builder, int value) {
  builder.addByte(value & 0xff);
  builder.addByte((value >> 8) & 0xff);
}

void _writeU32(BytesBuilder builder, int value) {
  builder.addByte(value & 0xff);
  builder.addByte((value >> 8) & 0xff);
  builder.addByte((value >> 16) & 0xff);
  builder.addByte((value >> 24) & 0xff);
}
