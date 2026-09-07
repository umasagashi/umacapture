// What the preview decision reads, and what it refuses to read (stage 4a).
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_file_preview_test.dart
//
// The decision is separated from the widget that will show it precisely so this
// suite can exist: *how much* of a file was read before it was refused is not
// visible in a rendered result -- the same "cannot be shown" panel appears
// whether the refusal cost 8 KiB or the whole file. It is only observable as the
// bound each call asked for, so every source here counts its calls and records
// the bound.
//
// The two things the decision consults are tested through *different*
// observations, because that is what makes them non-redundant:
//
// * the name is observed on the image path, as `readHead` never being called at
//   all -- the one verdict a name is allowed to reach on its own;
// * the content is observed as the verdict flipping with the bytes while the
//   name is held fixed, which no extension table can produce.
//
// WHAT THIS SUITE DOES NOT REACH. `FsBackendPreviewSource` is exercised over the
// io backend wrapped in `WebLikeFsBackend`, so the async semantics observed are
// io's, not OPFS's (see that file's own note). It does not run in a browser, and
// it says nothing about how stage 4b renders any of these results.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/storage/file_kind.dart';
import 'package:umacapture/src/core/storage/file_preview.dart';
import 'package:umacapture/src/core/storage/file_preview_source.dart';

import 'support/web_like_fs_backend.dart';

/// A source over an in-memory buffer that records every call made to it.
class _CountingSource implements PreviewByteSource {
  _CountingSource(this.bytes);

  factory _CountingSource.ofSize(int size, {int fill = 0x61}) =>
      _CountingSource(Uint8List.fromList(List.filled(size, fill)));

  final Uint8List bytes;

  int lengthCalls = 0;
  int readHeadCalls = 0;

  /// The bound the decision asked for on its last read. Checked as well as the
  /// returned length, so a source that silently over-reads cannot pass by
  /// trimming afterwards.
  int? lastRequestedMax;

  @override
  Future<int> length() async {
    lengthCalls++;
    return bytes.length;
  }

  @override
  Future<Uint8List> readHead(int maxBytes) async {
    readHeadCalls++;
    lastRequestedMax = maxBytes;
    return bytes.length <= maxBytes ? bytes : Uint8List.sublistView(bytes, 0, maxBytes);
  }
}

_CountingSource _sourceOfText(String text) => _CountingSource(Uint8List.fromList(utf8.encode(text)));

/// The head bytes the app's own binary files really begin with.
///
/// Read off a real installation rather than invented, because the decision is
/// now taken on content: a fixture of NULs would pass whatever the real file
/// looks like. Two of these would have been got wrong by guessing --
/// **`.onnx` does not start with a NUL** (it is protobuf; the first one is a few
/// hundred bytes in, and its first 8 KiB hold roughly 300), and `.lock` is not
/// binary at all.
const Map<String, List<int>> _realBinaryHeads = {
  // `sandbox/modules/aptitude/prediction.onnx`, verbatim, plus the first NUL.
  'module.onnx': [0x08, 0x04, 0x12, 0x07, 0x70, 0x79, 0x74, 0x6f, 0x72, 0x63, 0x68, 0x1a, 0x06, 0x31, 0x2e, 0x31, 0x00],
  // `settings/addon.hive`, verbatim.
  'settings.hive': [0xd2, 0x01, 0x00, 0x00, 0x01, 0x10, 0x74, 0x61, 0x73, 0x6b],
  // A TrueType font begins 0x00010000.
  'MPLUS1Code_700_x.ttf': [0x00, 0x01, 0x00, 0x00, 0x41, 0x42],
  // A zip local file header: "PK\x03\x04", then the version and flag words.
  'modules.zip': [0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00],
};

/// The letters the unknown-extension corpus is generated from.
const List<String> _alphabet = [
  'a',
  'b',
  'c',
  'd',
  'e',
  'f',
  'g',
  'h',
  'i',
  'j',
  'k',
  'l',
  'm',
  'n',
  'o',
  'p',
  'q',
  'r',
  's',
  't',
  'u',
  'v',
  'w',
  'x',
  'y',
  'z',
];

void main() {
  group('the name decides only what a name can decide', () {
    test('the binary files this app keeps are refused on the heads they really have', () async {
      // The fixtures are the measured heads in [_realBinaryHeads], not a block
      // of NULs: what a file "is" now decides the answer, so a fixture that does
      // not look like the file it is named after asserts nothing about that
      // file. `.lock` used to be in this list and is *not* a binary format --
      // see the test below it.
      for (final entry in _realBinaryHeads.entries) {
        final source = _CountingSource(Uint8List.fromList(entry.value));
        final preview = await resolveFilePreview(name: entry.key, source: source);

        expect(preview, isA<BinaryFilePreview>(), reason: entry.key);
        expect(preview.byteLength, entry.value.length, reason: entry.key);
        expect(source.lengthCalls, 1, reason: '${entry.key}: the size is metadata and is still shown');
        expect(source.readHeadCalls, 1, reason: '${entry.key}: deciding on content means reading, once');
      }
    });

    test('a settings .lock is JSON text on a real installation, and is shown as text', () async {
      // Measured, not assumed: every `settings/*.lock` in a real data root is
      // these eighteen bytes. The old code refused them because `.lock` is not
      // in the extension table, which was one of the false statements this
      // change exists to remove -- showing them is the correct answer.
      final source = _sourceOfText('{"isolated":false}');
      final preview = await resolveFilePreview(name: 'settings.lock', source: source);

      expect((preview as TextFilePreview).text, '{"isolated":false}');
      expect(preview.byteLength, 18);
      expect(preview.isJson, isFalse, reason: 'the JSON *rendering* is still selected by the .json extension alone');
    });

    test('a refusal costs the sniff window and never the preview cap', () async {
      // A size fixture, not a format one: the claim under test is the bound the
      // read asked for. A 64 MiB `.onnx` must not be pulled 256 KiB into memory
      // to be declined.
      final source = _CountingSource.ofSize(1 << 20, fill: 0);
      await resolveFilePreview(name: 'module.onnx', source: source);

      expect(source.lastRequestedMax, lessThan(textPreviewByteLimit));
      expect(source.lastRequestedMax, 8192, reason: 'the sniff window, asked for rather than trimmed afterwards');
      expect(source.readHeadCalls, 1, reason: 'and the second, larger read is never issued for a refusal');
    });

    test('an image is sized but not read here either', () async {
      final source = _CountingSource.ofSize(1234);
      final preview = await resolveFilePreview(name: 'campaign.png', source: source);

      expect(preview, isA<ImageFilePreview>());
      expect(preview.byteLength, 1234);
      expect(source.readHeadCalls, 0);
    });

    test('an image whose bytes look binary is still an image, not a refusal', () async {
      // The one place a name outranks the content, and the reason it has to:
      // every real PNG is full of NULs, so sniffing would refuse all of them.
      final source = _CountingSource.ofSize(1234, fill: 0);
      final preview = await resolveFilePreview(name: 'campaign.png', source: source);

      expect(preview, isA<ImageFilePreview>());
      expect(source.readHeadCalls, 0);
    });
  });

  group('an extension the table does not know is decided by its content', () {
    // The reported defect was `.html`, `.svg`, `.ini` and `.tsv` being told they
    // could not be shown. Those four are witnesses, not the specification: a
    // test that named them would be the same hand-written list that caused the
    // defect, and would pass while `.rst` or `.toml` still lied. So the corpus
    // is machine-generated -- every two-letter extension there is, plus the four
    // reported ones and a few longer shapes -- and filtered by the classifier
    // itself down to the names it says it does not know.
    final unknown = [
      for (final a in _alphabet)
        for (final b in _alphabet) '.$a$b',
      '.html',
      '.svg',
      '.ini',
      '.tsv',
      '.rst',
      '.toml',
      '.qqq',
      '.HTML',
    ].where((ext) => storageFileKindOfName('file$ext') == StorageFileKind.binary).toList();

    test('the corpus is not empty, and is not the table in disguise', () {
      // Without this an over-eager filter would leave nothing to iterate and
      // every assertion below would hold vacuously.
      expect(unknown, hasLength(greaterThan(600)));
      // Intentional: adding one of these four to the table as `text` -- a real
      // improvement -- turns this line red, because the sweep below would then
      // no longer be exercising it as an *unknown* extension. That is a loud,
      // named failure at the moment of an improvement, not a silent loss of
      // coverage, and it is preferred to the second. Do not delete it to make
      // such a change green; move the extension out of this list instead.
      for (final ext in ['.html', '.svg', '.ini', '.tsv']) {
        expect(unknown, contains(ext), reason: '$ext: the reported defect must be inside the corpus');
      }
      // And the table's own entries must be outside it, or the sweep would be
      // asserting about `.txt` rather than about the unknown.
      expect(unknown, isNot(contains('.md')));
    });

    test('one with no NUL in it is shown as text, whatever it is called', () async {
      for (final ext in unknown) {
        final source = _sourceOfText('<p>hello</p>\n');
        final preview = await resolveFilePreview(name: 'file$ext', source: source);

        expect(preview, isA<TextFilePreview>(), reason: ext);
        expect((preview as TextFilePreview).text, '<p>hello</p>\n', reason: ext);
        expect(preview.isJson, isFalse, reason: '$ext: only the .json extension picks the JSON rendering');
      }
    });

    test('one that does hold a NUL is refused, with the same name', () async {
      for (final ext in unknown) {
        final source = _CountingSource(Uint8List.fromList([0x00, 0x01, 0x02, 0x41]));
        final preview = await resolveFilePreview(name: 'file$ext', source: source);

        expect(preview, isA<BinaryFilePreview>(), reason: ext);
        expect(preview.byteLength, 4, reason: ext);
      }
    });

    test('a name with no extension at all reaches the same content decision', () async {
      // `LICENSE` and `.gitignore` are both text and both classify as `binary`.
      for (final name in ['LICENSE', '.gitignore']) {
        final preview = await resolveFilePreview(name: name, source: _sourceOfText('plain\n'));
        expect((preview as TextFilePreview).text, 'plain\n', reason: name);
      }
    });

    test('a long unknown file that is text is read out to the preview cap', () async {
      // The second read, which only a NUL-free head reaches. Its bound is the
      // cap, so an unknown extension is not stuck showing 8 KiB of a long file.
      final source = _CountingSource.ofSize(2209590, fill: 0x61);
      final preview = await resolveFilePreview(name: 'export.tsv', source: source);

      final text = preview as TextFilePreview;
      expect(text.text.length, textPreviewByteLimit);
      expect(text.truncated, isTrue);
      expect(source.readHeadCalls, 2, reason: 'sniff first, then the preview head');
      expect(source.lastRequestedMax, textPreviewByteLimit);
    });

    test('a short unknown file that is text is read once and not again', () async {
      // The negative half of the pair above: when the sniff already reached the
      // end of the file there is nothing left to fetch.
      final source = _sourceOfText('short\n');
      final preview = await resolveFilePreview(name: 'notes.ini', source: source);

      expect((preview as TextFilePreview).text, 'short\n');
      expect(source.readHeadCalls, 1);
    });
  });

  group('a NUL byte overrides an extension that lies', () {
    test('a .json holding binary content is refused rather than decoded', () async {
      final source = _CountingSource(Uint8List.fromList([0x7b, 0x22, 0x61, 0x00, 0x01, 0x02]));
      final preview = await resolveFilePreview(name: 'record.json', source: source);

      expect(preview, isA<BinaryFilePreview>());
      expect(preview.byteLength, 6);
      expect(source.readHeadCalls, 1, reason: 'this has to read in order to decide');
    });

    test('a .txt that is really a font is refused on content', () async {
      // Real `.ttf` head: 0x00010000, i.e. a NUL in the very first byte.
      final source = _CountingSource(Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0x41, 0x42]));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect(preview, isA<BinaryFilePreview>());
    });

    test('a NUL past the sniff window does not turn a long text file binary', () async {
      // The sniff bound is a real bound, not an accident of the fixtures: a file
      // whose first 8 KiB are clean is text, and `allowMalformed` handles the
      // rest.
      final bytes = Uint8List.fromList([...List.filled(9000, 0x61), 0x00, 0x61]);
      final preview = await resolveFilePreview(name: 'notes.txt', source: _CountingSource(bytes));

      expect(preview, isA<TextFilePreview>());
    });

    test('ordinary text with high bytes is not mistaken for binary', () async {
      final source = _sourceOfText('日本語のメモ\nsecond line\n');
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect((preview as TextFilePreview).text, '日本語のメモ\nsecond line\n');
      expect(preview.isJson, isFalse);
    });
  });

  group('the byte cap', () {
    test('is one named constant, and is the 256 KiB the preview was settled at', () {
      expect(textPreviewByteLimit, 262144);
    });

    test('a record.json is well under it and comes back whole', () async {
      // The largest `record.json` measured on a real installation was 22,126 B.
      final source = _CountingSource.ofSize(22126);
      final preview = await resolveFilePreview(name: 'record.json', source: source);

      expect(preview, isA<TextFilePreview>());
      expect((preview as TextFilePreview).truncated, isFalse);
      expect(preview.text.length, 22126);
      expect(preview.isJson, isTrue);
      expect(preview.byteLength, 22126);
    });

    test('a file over the cap is read only to the cap, and says so', () async {
      // The largest textual file measured on a real installation:
      // modules/skill_info.json at 2,209,590 B.
      final source = _CountingSource.ofSize(2209590);
      final preview = await resolveFilePreview(name: 'skill_info.json', source: source);

      final text = preview as TextFilePreview;
      expect(text.truncated, isTrue, reason: 'the caller must be able to see that the tail is missing');
      expect(text.text.length, textPreviewByteLimit);
      expect(source.lastRequestedMax, textPreviewByteLimit, reason: 'the bound is asked for, not trimmed afterwards');
      expect(text.byteLength, 2209590, reason: 'the *file* size is still the full one');
    });

    test('a file of exactly the cap is not reported as truncated', () async {
      final source = _CountingSource.ofSize(textPreviewByteLimit);
      final preview = await resolveFilePreview(name: 'big.txt', source: source);

      expect((preview as TextFilePreview).truncated, isFalse);
      expect(preview.text.length, textPreviewByteLimit);
    });

    test('the image bound is a second constant, not this one', () {
      // Two bounds because they bound two different quantities, and the image
      // one is the larger: a picture is read whole or not at all, while text is
      // read as a head.
      expect(imagePreviewByteLimit, 16777216);
      expect(imagePreviewByteLimit, greaterThan(textPreviewByteLimit));
    });

    test('cutting the head through a multi-byte character does not throw', () async {
      // The cut lands inside the three-byte sequence for U+3042, which is what
      // a fixed byte offset does to valid UTF-8 by construction.
      final source = _sourceOfText('ab${'あ' * 8}');
      final preview = await resolveFilePreview(name: 'notes.txt', source: source, byteLimit: 6);

      final text = preview as TextFilePreview;
      expect(text.truncated, isTrue);
      expect(text.text.startsWith('abあ'), isTrue);
    });
  });

  // The image path used to be the one kind that returned before any bound was
  // applied: `kind == image` answered with the size and nothing else, so a file
  // of any length named `.png` was handed to a decoder that read all of it. The
  // unclassified group lists files the *user* put in the store, so the input
  // here is not bounded by what the app writes.
  group('the image byte cap', () {
    test('the largest image this installation holds passes with room to spare', () async {
      // Measured over the store's 834 image files: the largest is a stitched
      // `campaign.png` at 5,194,128 B. Quoted as a fixture rather than as prose
      // so tightening the constant under it fails here instead of in the field.
      final source = _CountingSource.ofSize(5194128);
      final preview = await resolveFilePreview(name: 'campaign.png', source: source);

      expect(preview, isA<ImageFilePreview>());
      expect(source.readHeadCalls, 0);
    });

    test('an image past the cap is refused, and still without reading a byte of it', () async {
      final source = _CountingSource.ofSize(imagePreviewByteLimit + 1);
      final preview = await resolveFilePreview(name: 'huge.png', source: source);

      final refused = preview as OversizeImageFilePreview;
      // Both numbers, because the refusal has to be able to say how big and how
      // big is allowed without the caller re-deriving either.
      expect(refused.byteLength, imagePreviewByteLimit + 1);
      expect(refused.limitBytes, imagePreviewByteLimit);
      expect(source.readHeadCalls, 0, reason: 'a refusal that read the file first would have refused nothing');
      expect(source.lengthCalls, 1, reason: 'the size is metadata and is what the decision is taken on');
    });

    test('an image of exactly the cap is shown', () async {
      // The limit is the largest size that still works, not the first that
      // fails -- the same boundary `decideStorageZipLimit` states for its own.
      final source = _CountingSource.ofSize(imagePreviewByteLimit);
      final preview = await resolveFilePreview(name: 'big.png', source: source);

      expect(preview, isA<ImageFilePreview>());
    });

    test('the bound is a parameter, so the refusal is the cap and not the fixture', () async {
      final source = _CountingSource.ofSize(1234);
      final preview = await resolveFilePreview(name: 'small.png', source: source, imageByteLimit: 1000);

      expect((preview as OversizeImageFilePreview).limitBytes, 1000);
    });
  });

  group('over the real FsBackend adapter', () {
    late Directory tempRoot;
    late FsBackend originalBackend;
    late WebLikeFsBackend backend;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('umacapture_file_preview_test');
      originalBackend = fsBackend;
      backend = WebLikeFsBackend(originalBackend);
      fsBackend = backend;
    });

    tearDown(() {
      fsBackend = originalBackend;
      tempRoot.deleteSync(recursive: true);
    });

    test('a binary file reaches neither readBytes nor readString', () async {
      final path = '${tempRoot.path}${Platform.pathSeparator}module.onnx';
      File(path).writeAsBytesSync(Uint8List.fromList(List.filled(2048, 0)));
      backend.resetCallCounts();

      final preview = await resolveFilePreview(name: 'module.onnx', source: FsBackendPreviewSource(path));

      expect(preview, isA<BinaryFilePreview>());
      expect(preview.byteLength, 2048);
      // The invariant that survives content sniffing: the refusal reads a
      // bounded head and never one of the two unbounded calls.
      expect(backend.readBytesCalls, 0);
      expect(backend.readStringCalls, 0);
      expect(backend.readHeadBounds, [2048]);
      expect(backend.lengthCalls, 1);
    });

    test('a text file is read through the bounded head and comes back decoded', () async {
      final path = '${tempRoot.path}${Platform.pathSeparator}record.json';
      File(path).writeAsStringSync('{"a": 1}');
      backend.resetCallCounts();

      final preview = await resolveFilePreview(name: 'record.json', source: FsBackendPreviewSource(path));

      expect((preview as TextFilePreview).text, '{"a": 1}');
      expect(preview.truncated, isFalse);
      // `readString` and `readBytes` are the two unbounded calls the preview
      // must never make; the bytes arrive through the ranged `readHead`,
      // carrying the bound the decision layer resolved (here the file's own
      // eight bytes, which are under the limit).
      expect(backend.readStringCalls, 0);
      expect(backend.readBytesCalls, 0);
      expect(backend.readHeadBounds, [8]);
    });

    test('the adapter cuts a file longer than the bound it was given', () async {
      // The other side of `FsBackendPreviewSource.readHead`'s branch: on the
      // test above the file is shorter than the bound and comes back whole.
      final path = '${tempRoot.path}${Platform.pathSeparator}long.txt';
      File(path).writeAsStringSync('0123456789');
      backend.resetCallCounts();

      final preview = await resolveFilePreview(name: 'long.txt', source: FsBackendPreviewSource(path), byteLimit: 4);

      expect((preview as TextFilePreview).text, '0123');
      expect(preview.truncated, isTrue);
      expect(preview.byteLength, 10);
      // The cut is the backend's, not the adapter's: the bound reaches
      // `readHead` and no unbounded read is issued behind it. Read-then-trim
      // would produce this same text while reading all ten bytes, so the text
      // alone cannot tell the two implementations apart.
      expect(backend.readHeadBounds, [4]);
      expect(backend.readBytesCalls, 0);
      expect(backend.readStringCalls, 0);
    });

    test('the backend reads only the bound, not the file behind it', () async {
      // Directly against `FsBackend.readHead`, without the preview above it:
      // the ranged primitive must stop at the bound and must not fall back to
      // a whole-file read on either the short or the long side.
      final path = '${tempRoot.path}${Platform.pathSeparator}ranged.bin';
      File(path).writeAsBytesSync(Uint8List.fromList(List.generate(4096, (i) => i & 0xff)));
      backend.resetCallCounts();

      expect(await fsBackend.readHead(path, 0), isEmpty);
      expect((await fsBackend.readHead(path, 16)).toList(), List.generate(16, (i) => i));
      expect((await fsBackend.readHead(path, 1 << 20)).length, 4096, reason: 'a bound past the end yields the file');
      expect(backend.readBytesCalls, 0);
    });
  });

  // What the bytes are read *as*. These are the encodings a Japanese user's own
  // files actually arrive in, and the two failures they used to produce were
  // opposite ones: UTF-16 was *refused* (its ASCII carries a NUL in every second
  // byte), and Shift-JIS was *shown wrong* (it carries no NUL at all, so it was
  // decoded as UTF-8 into replacement characters with nothing on screen saying
  // so). Both are files this app itself writes -- `CharCodec` in
  // `chara_detail/exporter.dart` offers Shift-JIS, UTF-8 with a BOM, and UTF-16
  // with one.
  //
  // Every assertion here checks `encoding` as well as `text`, because the text
  // alone cannot tell a correct decode from a lucky one: for a pure-ASCII
  // fixture all four encodings agree, and that is what most fixtures are.
  group('the encoding the bytes are read in', () {
    const sample = 'name,備考\r\n1,Special Week\r\n';

    _CountingSource sourceOf(List<int> bytes) => _CountingSource(Uint8List.fromList(bytes));

    test('UTF-16LE with a byte order mark is text, and is read little-endian', () async {
      final source = sourceOf(const Utf16Encoder().encodeUtf16Le(sample, true));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect((preview as TextFilePreview).text, sample);
      expect(preview.encoding, PreviewTextEncoding.utf16le);
      expect(preview.truncated, isFalse);
    });

    test('UTF-16BE with a byte order mark is text, and is read big-endian', () async {
      final source = sourceOf(const Utf16Encoder().encodeUtf16Be(sample, true));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect((preview as TextFilePreview).text, sample);
      expect(preview.encoding, PreviewTextEncoding.utf16be);
    });

    test('UTF-16LE without a mark is inferred from where the NUL bytes fall', () async {
      final source = sourceOf(const Utf16Encoder().encodeUtf16Le(sample, false));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect((preview as TextFilePreview).text, sample);
      expect(preview.encoding, PreviewTextEncoding.utf16le);
    });

    test('UTF-16BE without a mark is inferred the same way, at the other parity', () async {
      final source = sourceOf(const Utf16Encoder().encodeUtf16Be(sample, false));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect((preview as TextFilePreview).text, sample);
      expect(preview.encoding, PreviewTextEncoding.utf16be);
    });

    test('an unknown extension holding UTF-16 is read out past the sniff window', () async {
      // The sniff-first branch: the verdict is taken on the 8 KiB window and
      // must survive the second, larger read that only a non-refusal reaches.
      final text = 'abcdefgh\r\n' * 1200; // 12,000 chars, 24,000 bytes.
      final source = sourceOf(const Utf16Encoder().encodeUtf16Le(text, false));
      final preview = await resolveFilePreview(name: 'export.tsv', source: source);

      expect((preview as TextFilePreview).encoding, PreviewTextEncoding.utf16le);
      expect(preview.text, text);
      expect(source.readHeadCalls, 2, reason: 'sniff first, then the preview head');
    });

    test('an odd size rules UTF-16 out even when the file declares it with a mark', () async {
      // THE FIX. The length rule used to sit *behind* the mark, so `FF FE 41`
      // was called UTF-16LE on the strength of two bytes, and then the decode
      // found no whole two-byte unit after the mark and produced the empty
      // string: a three-byte file rendered as an empty panel, indistinguishable
      // from an empty file, with no error and nothing on screen saying so.
      //
      // UTF-16 is a whole number of two-byte units, so an odd *file* length
      // proves the bytes are not UTF-16 whatever the file declares. The mark is
      // then just two more bytes to show.
      final preview = await resolveFilePreview(name: 'notes.txt', source: sourceOf(const [0xff, 0xfe, 0x41]));

      expect(
        (preview as TextFilePreview).text,
        isNotEmpty,
        reason: 'an odd-sized file that happens to open FF FE was shown as an empty preview',
      );
      expect(preview.encoding, isNot(PreviewTextEncoding.utf16le));
      expect(preview.text, endsWith('A'), reason: 'the byte that is there must be on screen');
    });

    test('a mark with nothing after it is still an empty UTF-16 document', () async {
      // The other side of the same rule, and what keeps it from being "a BOM
      // needs a unit behind it": `FF FE` is even, so it is a legitimately empty
      // UTF-16 file and empty is the correct preview for it. Only an odd length
      // is evidence of malformation.
      final preview = await resolveFilePreview(name: 'notes.txt', source: sourceOf(const [0xff, 0xfe]));

      expect((preview as TextFilePreview).text, isEmpty);
      expect(preview.encoding, PreviewTextEncoding.utf16le);
    });

    test('Shift-JIS is read as Shift-JIS rather than shown as replacement characters', () async {
      const japanese = 'ウマ娘のメモ\nsecond line\n';
      final source = sourceOf(const ShiftJISEncoder().convert(japanese));
      final preview = await resolveFilePreview(name: 'records.csv', source: source);

      expect((preview as TextFilePreview).text, japanese);
      expect(preview.encoding, PreviewTextEncoding.shiftJis);
      expect(preview.text, isNot(contains('�')));
    });

    test('UTF-8 Japanese is read as UTF-8 and is never taken by Shift-JIS', () async {
      // The order that cannot be reversed: `E3 81 82` is legal Shift-JIS too, so
      // a Shift-JIS-first rule would turn every correct Japanese file into
      // mojibake. Held by asserting the verdict, not just the text -- the text
      // would be right here only because the strict UTF-8 decode ran first.
      final source = _sourceOfText('日本語のメモ\nsecond line\n');
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect((preview as TextFilePreview).text, '日本語のメモ\nsecond line\n');
      expect(preview.encoding, PreviewTextEncoding.utf8);

      // And the case that actually discriminates. Most Japanese sentences hit an
      // unmapped pair partway through and would be rejected by Shift-JIS anyway,
      // so they stay right under either order and hold nothing. `亜` is UTF-8
      // `E4 BA 9C`, whose first two bytes are a mapped Shift-JIS pair and whose
      // third is a lead byte with nothing after it: read Shift-JIS first, it
      // decodes to a different single character instead of failing.
      final ambiguous = await resolveFilePreview(name: 'notes.txt', source: _sourceOfText('亜'));
      expect((ambiguous as TextFilePreview).text, '亜');
      expect(ambiguous.encoding, PreviewTextEncoding.utf8);
    });

    test('plain ASCII is UTF-8, which is what it always was', () async {
      final preview = await resolveFilePreview(name: 'settings.lock', source: _sourceOfText('{"isolated":false}'));

      expect((preview as TextFilePreview).encoding, PreviewTextEncoding.utf8);
    });

    // The declared limit of the rule, asserted rather than left to prose: this
    // is what the library doc means by "UTF-16 without a BOM whose content is
    // majority non-Latin-1 is still refused". Japanese in UTF-16 carries no NUL
    // at all, so it is not even refused -- it reaches the lenient decode exactly
    // as it did before this rule existed, and comes out wrong.
    test('UTF-16 without a mark and without ASCII is not detected, and is unchanged', () async {
      const japanese = 'ウマ娘のメモ';
      final source = sourceOf(const Utf16Encoder().encodeUtf16Le(japanese, false));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      final text = preview as TextFilePreview;
      expect(text.encoding, isNot(PreviewTextEncoding.utf16le));
      expect(text.encoding, isNot(PreviewTextEncoding.utf16be));
      expect(text.text, isNot(japanese), reason: 'out of scope, and saying so');
    });

    test('a single NUL at one parity is not a UTF-16 pattern', () async {
      // Parity is evidence only when the NULs are a pattern: one NUL is at
      // exactly one parity whatever the file is. Both fixtures are real heads
      // from this app's own store, and both would be decoded as UTF-16 by a rule
      // that asked for parity alone.
      final hive = sourceOf(const [0x7b, 0x22, 0x61, 0x00, 0x01, 0x02]);
      expect(await resolveFilePreview(name: 'record.json', source: hive), isA<BinaryFilePreview>());

      final onnx = sourceOf(_realBinaryHeads['module.onnx']!);
      expect(await resolveFilePreview(name: 'module.onnx', source: onnx), isA<BinaryFilePreview>());
    });

    test('an odd-sized file is not UTF-16, because a UTF-16 file has whole units', () async {
      final source = sourceOf(const [0x61, 0x00, 0x62]);
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      expect(preview, isA<BinaryFilePreview>());
    });

    test('a UTF-16 head cut by the cap loses the split unit and not the preview', () async {
      final source = sourceOf(const Utf16Encoder().encodeUtf16Le('abcdefgh', false));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source, byteLimit: 7);

      final text = preview as TextFilePreview;
      expect(text.encoding, PreviewTextEncoding.utf16le);
      expect(text.text, 'abc', reason: 'the odd trailing byte is half a unit, not a character');
      expect(text.truncated, isTrue);
      expect(text.byteLength, 16);
    });

    test('a Shift-JIS head cut through a two-byte character does not throw', () async {
      // `ShiftJISDecoder` reports this as a `RangeError`, not a `FormatException`
      // -- it reads the trail byte with `input[++i]` -- so a cut lead byte has to
      // be trimmed before the decode rather than caught after it.
      final source = sourceOf(const ShiftJISEncoder().convert('あいう'));
      final preview = await resolveFilePreview(name: 'notes.txt', source: source, byteLimit: 5);

      final text = preview as TextFilePreview;
      expect(text.encoding, PreviewTextEncoding.shiftJis);
      expect(text.text, 'あい');
      expect(text.truncated, isTrue);
    });
  });

  // The trailing trim above repairs the cap's cut. A complete file was never
  // cut, so the same bytes at its end are its content, and trimming them there
  // deletes content while reporting `truncated` false -- the one shape of loss
  // this preview is not allowed to have, because nothing on screen would say so.
  group('a complete file is decoded whole', () {
    _CountingSource sourceOf(List<int> bytes) => _CountingSource(Uint8List.fromList(bytes));

    test('a byte that ends the file is shown even when it cannot be read', () async {
      // `caf` and an unfinished byte: CP1252 `café`, the plainest way an
      // ordinary text file ends in something that is not valid UTF-8. Nothing
      // here was cut, so the byte is content and a viewer owes the user a mark
      // where it is, not a shorter file.
      final source = sourceOf(const [0x63, 0x61, 0x66, 0xe9]);
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      final text = preview as TextFilePreview;
      expect(text.truncated, isFalse);
      expect(text.byteLength, 4);
      expect(text.text.endsWith('caf'), isFalse, reason: 'a complete file must not come back one byte short');
      expect(text.text, contains('\u{FFFD}'));
      expect(text.text, 'caf\u{FFFD}');
    });

    test('no last byte at all is dropped, whatever it is', () async {
      // Counted rather than listed: a table of trailing bytes to check is a
      // table of the ones someone thought of, and the claim is about all of
      // them. Every value but NUL, which rule 3 refuses before any decode.
      for (var last = 0x01; last <= 0xff; last++) {
        final source = sourceOf([0x63, 0x61, 0x66, last]);
        final preview = await resolveFilePreview(name: 'notes.txt', source: source);

        final text = preview as TextFilePreview;
        expect(text.truncated, isFalse, reason: 'last byte 0x${last.toRadixString(16)}');
        expect(
          text.text.runes.length,
          4,
          reason: 'last byte 0x${last.toRadixString(16)} decoded to "${text.text}" -- a byte went missing',
        );
      }
    });

    test('a Shift-JIS lead byte with nothing after it is a mark, not a deletion', () async {
      // `41 42 82`: the Shift-JIS decode runs off the end and the strict UTF-8
      // one rejects it, so the lenient decode answers -- with a replacement
      // character standing where the unreadable byte is.
      final source = sourceOf(const [0x41, 0x42, 0x82]);
      final preview = await resolveFilePreview(name: 'notes.txt', source: source);

      final text = preview as TextFilePreview;
      expect(text.truncated, isFalse);
      expect(text.text, 'AB\u{FFFD}');
      expect(text.encoding, PreviewTextEncoding.utf8, reason: 'the lenient decode reports itself as UTF-8');
    });

    test('the same trailing byte is trimmed when the cap is what left it there', () async {
      // One pair of assertions over one byte sequence, because the difference
      // between them is the whole rule. `.txt` is in the extension table, so
      // `byteLimit` is the bound of the single read and really cuts here.
      const bytes = [0x41, 0x42, 0xe3, 0x81, 0x82]; // "ABあ"

      final whole = await resolveFilePreview(name: 'notes.txt', source: sourceOf(bytes)) as TextFilePreview;
      expect(whole.truncated, isFalse);
      expect(whole.text, 'ABあ', reason: 'a complete, well-formed file is untouched');
      expect(whole.encoding, PreviewTextEncoding.utf8);

      final cut = await resolveFilePreview(name: 'notes.txt', source: sourceOf(bytes), byteLimit: 3) as TextFilePreview;
      expect(cut.truncated, isTrue);
      expect(cut.text, 'AB', reason: 'the cap split U+3042, and half a character is not shown as a broken one');
      expect(cut.text, isNot(contains('\u{FFFD}')));
    });

    test('a file at the cap exactly is complete, and keeps its last byte', () async {
      // The boundary the two rules meet at: `byteLength == byteLimit` is not a
      // cut, so the head is decoded whole even though the read asked for the
      // bound. Padded past the sniff window so the bound is the only thing that
      // could have cut it.
      final bytes = [...List.filled(9999, 0x61), 0xe9];
      final source = sourceOf(bytes);
      final preview = await resolveFilePreview(name: 'notes.txt', source: source, byteLimit: 10000);

      final text = preview as TextFilePreview;
      expect(source.lastRequestedMax, 10000);
      expect(text.truncated, isFalse);
      expect(text.text.runes.length, 10000, reason: 'the byte at the bound is the file\'s own end, not a cut');
      expect(text.text, endsWith('\u{FFFD}'));
    });
  });
}
