/// What may be read from a file the user selected, and how much of it.
///
/// This is the **decision**, not the display. The preview dialog in
/// `gui/storage_file_preview.dart` renders whatever comes back;
/// nothing here knows about widgets, and nothing here touches a
/// filesystem directly -- bytes arrive through [PreviewByteSource]. Two reasons
/// for the separation:
///
/// * *How much* of a file is read before it is refused is a property of the
///   decision, and it is only checkable while the decision is separable from the
///   widget that would show the result. A counting [PreviewByteSource] makes the
///   bound each call asked for assertable; a widget test cannot see it at all --
///   the same "cannot be shown" panel appears whether the refusal cost 8 KiB or
///   the whole file.
/// * It keeps the decision pure Dart. `web_vfs.dart` is the cautionary case in
///   this repository: web-only Dart that imports Flutter is reachable from
///   neither a VM test nor, in practice, any test at all. This library imports
///   `dart:convert`, `dart:typed_data`, `package:charset` and `file_kind.dart`,
///   all of which compile for both the VM and the browser -- `charset`'s
///   Shift-JIS converter is a table lookup in plain Dart, with no `dart:io` and
///   no JS interop behind it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';

import '/src/core/storage/file_kind.dart';

/// The most bytes a text preview will read from a file.
///
/// 256 KiB. *Some* cap is required because `readString` is unbounded and a web
/// tab dies on a large one; the size of the cap is what this number answers, and
/// it was chosen against a census of a real installation (1,763 files):
///
/// * `record.json` -- the per-run data a user actually opens this view to read --
///   is 164 files, largest 22,126 B, median 13,088 B. The cap clears the largest
///   by roughly 12x, so no file of the kind the feature exists for is ever
///   truncated.
/// * Two generated reference tables sit far above it: `modules/skill_info.json`
///   (2,209,590 B) and `factor_info.json` (651,661 B). Those are lookup data, not
///   something a user reads top to bottom, and they are exactly the files that
///   would stall a browser tab.
/// * **`prediction.json` straddles the cap, and 31 files are over it**
///   (262,877 B to 359,104 B, out of 157 in the census). These are *not*
///   reference tables: one sits beside each `record.json` in
///   `storage/chara_detail/active/<uuid>/`, so a user browsing their own records
///   reaches a truncated preview in the ordinary case, not an exotic one.
///
/// So there is no empty gap to place the cap in, and no value that leaves the
/// corpus alone: raising it to 512 KiB would show those 31 files whole, and the
/// figure here truncates them. **256 KiB is the user's decision, taken with that
/// consequence in view** -- the preview is a viewer, not an exporter, and a
/// quarter-megabyte head is enough to see what a `prediction.json` is while the
/// bound stays a round power of two that also holds the reference tables out.
/// It is not a claim that nothing is affected.
///
/// Truncation is reported, never silent: a cut preview carries
/// [TextFilePreview.truncated] and the real [TextFilePreview.byteLength], so a
/// reader of one of those 31 files is told the rest exists.
const int textPreviewByteLimit = 262144;

/// The largest image the preview will read into memory at all.
///
/// 16 MiB. This cap exists for the same reason [textPreviewByteLimit] does --
/// an unbounded read takes the web tab with it -- and the image path was the one
/// kind that returned before any bound was applied, so a file of any size named
/// `.png` was read whole. The unclassified group lists files the *user* dropped
/// into the store, so the input is not bounded by what the app writes.
///
/// The size is chosen against the same real installation the text cap was, now
/// counting only its images (834 files, 703 of them PNG):
///
/// * The largest image the app itself writes is a stitched `campaign.png` at
///   **5,194,128 B**; the 99th percentile is 2,797,284 B and the median
///   839,044 B. 16 MiB clears the largest by 3.2x, so no image of the kind this
///   feature exists to show is ever refused.
/// * It declines a file whose size is evidence on its own that it is not one of
///   those -- a video or a disk image renamed to `.png`, which is what an
///   arbitrary-file bucket eventually holds.
///
/// **A byte cap alone is not the whole guard, and this constant does not claim to
/// be.** Decoding costs pixels, not file bytes: the same 5,194,128 B
/// `campaign.png` is 1080x9513 = 10,274,040 px = **41 MB of RGBA**, and a
/// deliberately crafted 8000x8000 PNG is ~2 MB of file and ~256 MB decoded. This
/// bound is the one on what is copied into the heap; the bound on what is decoded
/// is the caller's decode box (`RecordImage.maxDecodePixels`), and both are
/// needed because neither predicts the other.
const int imagePreviewByteLimit = 16777216;

/// How much of the head is inspected for the binary check.
///
/// The preview's second safety device is a NUL scan over "the first few KB"
/// before any text is decoded. Reading more does not make
/// the check stronger: a file that is binary but whose first 8 KiB contain no
/// NUL is not made textual by a NUL at offset 100,000 -- it was already going to
/// be decoded with replacement characters rather than throwing. The bound exists
/// so the scan cost does not track the file size.
const int _binarySniffBytes = 8192;

/// Supplies a file's size and the head of its bytes to [resolveFilePreview].
///
/// Deliberately narrower than `FsBackend`: the decision layer must be unable to
/// read a whole file even by accident, so the only read it can perform is a
/// bounded one. `file_preview_source.dart` implements this over `FsBackend`.
abstract interface class PreviewByteSource {
  /// The file's size in bytes, **without reading its contents**.
  ///
  /// Both backends answer this from metadata (`File.length()` on io, the `size`
  /// of the `File` that `FileSystemFileHandle.getFile()` hands back on web), so
  /// a size is available for a file whose bytes must never be read.
  Future<int> length();

  /// The first [maxBytes] bytes, or the whole file when it is shorter.
  ///
  /// Must never return more than [maxBytes]; the truncation flag on the result
  /// is derived from [length], and the two disagreeing would show a complete
  /// file with an "omitted" notice or vice versa.
  Future<Uint8List> readHead(int maxBytes);
}

/// What stage 4b should render for the selected file.
sealed class FilePreview {
  const FilePreview({required this.byteLength});

  /// The file's size in bytes, always available -- the preview shows the size even
  /// for the kinds it refuses to decode.
  final int byteLength;
}

/// What [resolveFilePreview] decided a text file's bytes *were*.
///
/// Carried on the result rather than left implicit in the decoded string,
/// because the two are not the same claim. `utf8.decode` of Shift-JIS bytes
/// returns a string; so does the correct decode. A test that inspects only
/// [TextFilePreview.text] passes for the wrong reason whenever the two happen to
/// agree -- which they do for every file that is pure ASCII, i.e. for most of the
/// fixtures a suite reaches for. The verdict is data so that "read as Shift-JIS"
/// can be asserted directly.
///
/// Nothing in the display layer reads this: the panel renders [
/// TextFilePreview.text] and says nothing about encodings (the storage view's
/// wording rules keep that vocabulary off the screen). It exists for the
/// decision's own tests and for whoever next has to answer "what did it think
/// this file was".
enum PreviewTextEncoding {
  /// Decoded as UTF-8.
  ///
  /// Also the value the last-resort lenient decode reports, because that decode
  /// *is* a UTF-8 decode -- one that substitutes replacement characters instead
  /// of failing. Bytes that are neither valid UTF-8 nor valid Shift-JIS land
  /// here, and they are the case the replacement characters were always for.
  utf8,

  /// Decoded as UTF-16, little-endian.
  utf16le,

  /// Decoded as UTF-16, big-endian.
  utf16be,

  /// Decoded as Shift-JIS, after a strict UTF-8 decode of the same bytes failed.
  shiftJis,
}

/// The file is text (possibly JSON), and [text] is what was read.
final class TextFilePreview extends FilePreview {
  const TextFilePreview({
    required super.byteLength,
    required this.text,
    required this.encoding,
    required this.truncated,
    required this.isJson,
  });

  /// The decoded head of the file. Equal to the whole file iff [truncated] is
  /// false.
  final String text;

  /// What [text] was decoded from. See [PreviewTextEncoding].
  final PreviewTextEncoding encoding;

  /// Whether [text] stops short of the end of the file.
  ///
  /// This is what makes the cap visible to the caller. Without it stage 4b would
  /// present a 256 KiB prefix of a 2 MB table as the file's whole content, and a
  /// JSON parse of that prefix would fail for a reason the user cannot see.
  final bool truncated;

  /// Whether the extension says JSON, so 4b re-indents and highlights it.
  ///
  /// Not a claim that [text] parses: a [truncated] JSON file does not.
  final bool isJson;
}

/// The file is an image; 4b decodes it, and this layer read none of it.
final class ImageFilePreview extends FilePreview {
  const ImageFilePreview({required super.byteLength});
}

/// The file is an image, but larger than [imagePreviewByteLimit].
///
/// Separate from [BinaryFilePreview] rather than a flag on it:
/// "there is nothing here a viewer could show" and "this is a picture, and it is
/// too big to open" are different answers to the user, and the panel that says
/// the first one would be false for this file. Carries [limitBytes] beside the
/// inherited size for the reason `StorageZipLimitDecision` carries both -- a
/// refusal has to be able to say how big and how big is allowed without the
/// caller re-deriving either number.
final class OversizeImageFilePreview extends FilePreview {
  const OversizeImageFilePreview({required super.byteLength, required this.limitBytes});

  final int limitBytes;
}

/// The file will not be shown, because its head holds a NUL byte.
///
/// That is now the *only* way to reach this class, and it used to be one of two:
/// a `PreviewRefusal` enum also carried `binaryExtension`, produced whenever the
/// extension table did not name the file textual. That arm has been deleted
/// along with the enum, because the answer it stood for was wrong -- see
/// [resolveFilePreview]. A one-valued enum kept "there are several reasons"
/// alive in the type after only one was left, so the reason is stated here, in
/// prose, where it cannot go stale against a `switch`.
final class BinaryFilePreview extends FilePreview {
  const BinaryFilePreview({required super.byteLength});
}

/// Decides what to do with the file called [name], reading through [source].
///
/// **The extension table is a fast path, not an authority.** Whether a file can
/// be shown as text is decided by its *bytes*: the head is read and a NUL byte
/// in it -- and nothing else -- is what makes the answer [BinaryFilePreview].
/// [storageFileKindOfName] is consulted only for the two questions a name can
/// actually answer:
///
/// * **is it an image**, which has to be settled without reading, because the
///   bytes of a PNG say "binary" as loudly as a Hive box does and the decoder,
///   not this function, is what reads them; and
/// * **is it JSON**, which selects the re-indented rendering and is a *display*
///   choice, not a claim about readability.
///
/// This is what the table stopped doing, and why. It used to answer the whole
/// question: an extension it did not list returned [BinaryFilePreview]
/// immediately, with no byte read. That bought "a binary file has none of its
/// content read" -- and paid for it by telling the user that a `.html`, an
/// `.svg`, an `.ini` or a `.tsv` could not be shown, which for the first two is
/// plainly false, because a hand-written list of extensions is a list of the
/// formats *someone thought of*. The list of formats a user may drop into their
/// own data folder is not bounded by that, so its misses are the ordinary case
/// rather than the exotic one, and every miss is a false statement on screen.
///
/// The cost is bounded rather than paid in full. A file whose extension the
/// table does *not* already trust as text is sniffed through a
/// [_binarySniffBytes]-sized head first, so refusing a multi-megabyte `.onnx`
/// still reads 8 KiB of it and never [byteLimit]; only a head with no NUL in it
/// is read out to the preview bound. An extension the table already calls
/// textual keeps its single read, because there the two bounds coincide.
///
/// **Which encoding the bytes are read in is decided too, and before the NUL
/// rule, not after it.** UTF-16 text holds a NUL in every second byte of its
/// ASCII, so a bare NUL rule refuses it -- and that refusal is the same false
/// statement on screen the extension table used to make about `.html`, aimed at
/// a file this app itself writes (`CharCodec.utf16leBom`, `exporter.dart`).
/// Shift-JIS is the other half: it holds no NUL, so it is shown, and every
/// Japanese character in it comes out as a replacement character with nothing on
/// screen saying so. The order is:
///
///  1. **A UTF-16 byte order mark** -- `FF FE` or `FE FF` -- settles the
///     encoding outright, because it is a declaration rather than an inference.
///     The one thing that overrides it is the file's own length: UTF-16 is a
///     whole number of two-byte units, so an odd-sized file is not UTF-16
///     however it opens, and the mark is read as ordinary bytes. That condition
///     is shared with rule 2 and applied before either of them, so the two
///     cannot disagree about what a length proves.
///  2. **Otherwise, the NUL positions in the sniff window are counted by
///     parity.** UTF-16 puts the zero high byte of a Latin-1 character at odd
///     offsets when little-endian and at even offsets when big-endian, so the
///     evidence is NULs at one parity and none at the other. One further
///     condition, because parity alone is not evidence: *more than half*
///     the units in the window must carry the zero byte. A lone NUL satisfies a
///     parity test by construction -- it is at exactly one parity whatever the
///     file is -- and a real binary head in this app's own store is exactly that
///     shape: a `.json` holding a Hive box begins `7B 22 61 00 01 02`, one NUL
///     in three units, and it is the majority condition and nothing else that
///     keeps it binary. Requiring the file to read *predominantly* as Latin-1 in
///     one endianness is the weakest claim that separates that from text.
///
///     The other head the suite pins, `prediction.onnx`, is **not** evidence for
///     this condition and is not claimed as such: it is protobuf, its first NUL
///     is a few hundred bytes in, and the seventeen-byte fixture that carries
///     one is ruled out by its odd length before the parity scan runs -- and
///     would be ruled out anyway, since a scan over whole units never reaches a
///     final byte at an even offset. It pins the NUL rule, not this one.
///  3. **Only then the NUL rule**, unchanged, on the bytes it always applied to.
///  4. **Then UTF-8, strictly, and Shift-JIS only if that fails.** The order
///     cannot be reversed: UTF-8 Japanese (`E3 81 82`) is also a legal Shift-JIS
///     sequence, so a Shift-JIS-first rule turns every correctly-encoded
///     Japanese file into mojibake. A strict UTF-8 decode that succeeds is
///     therefore taken as the answer, and Shift-JIS gets only the bytes UTF-8
///     rejected. When -- and only when -- the cap cut the head, both are
///     attempted on it trimmed to the last *complete* character, since a cut at
///     a fixed byte offset splits a multi-byte sequence by construction. A
///     complete file is decoded whole, because there the same trailing bytes are
///     the file's own ending and removing them would lose content silently (see
///     [_completeLength]).
///  5. **Failing both, the original lenient UTF-8 decode**, with its replacement
///     characters. Behaviour there is unchanged.
///
/// **What this rule misses, on purpose.** Four things, and they are all of
/// them:
///
/// * A file that is genuinely binary but carries no NUL in its first
///   [_binarySniffBytes] is shown as text. This app writes one such file:
///   `.onnx_ready`, the OPFS extraction sentinel (`version_check.dart`), is a
///   single `0x01` byte, so it previews as one control character rather than as
///   a refusal.
/// * UTF-16 **without a BOM** whose content is majority non-Latin-1 -- Japanese
///   prose, most of all -- is not detected, because rule 2's evidence is exactly
///   the ASCII it does not contain. What happens to it is not a refusal, and the
///   difference matters: a Japanese character's two bytes are *both* non-zero,
///   so such a file holds no NUL for rule 3 to catch either, and it reaches the
///   lenient decode and is shown as mojibake -- a wrong answer presented as a
///   right one, where a refusal would at least have said something was amiss.
///   (Enough ASCII mixed in brings the NULs back, and then rule 3 refuses it
///   instead; which of the two happens depends on the file's own mixture.) The
///   app's own UTF-16 output carries a BOM and so goes through rule 1; this is
///   the hand-made file's case.
/// * Encodings other than the four in [PreviewTextEncoding] -- EUC-JP, the
///   Windows code pages, any other 8-bit set -- are not detected. They hold no
///   NUL, so they are shown, decoded as UTF-8 with replacement characters, which
///   is where Shift-JIS was before rule 4.
/// * Rule 2 runs the other way too, and this is the miss it bought. Binary that
///   is an array of small 16-bit little-endian values -- raw PCM, a `uint16`
///   buffer, a heightmap -- has a zero high byte in every unit at one parity and
///   none at the other, which is the same evidence UTF-16 text presents, so it
///   is shown as text where the NUL rule alone would have refused it. Measured:
///   400 units of `xx 00` come back as 400 characters of `utf16le`. Rule 2 buys
///   real UTF-16 files at this price, and the price is paid on files a store of
///   arbitrary user drops may hold.
///
/// Each of those is a real, if small, wrong answer, and each is accepted rather
/// than patched: the fix for the first and the fourth is a second content
/// heuristic -- a printable-byte ratio, a magic-number table, a size floor --
/// and the fix for the third is a statistical charset detector. Each invents its
/// own false answers on files nobody has looked at, which is precisely how the
/// extension table came to lie about `.html`. Rules that are wrong in ways that
/// can be written down here beat rules whose interaction cannot be.
///
/// The NUL check itself is unchanged and still catches a file whose *name* lies
/// -- a `.json` holding a Hive box, a `.txt` that is really a zip. Feeding such
/// bytes to `WebVfs.readString`, which is `utf8.decode(await readBytes(path))`
/// with malformed input rejected, throws where a preview should merely decline.
Future<FilePreview> resolveFilePreview({
  required String name,
  required PreviewByteSource source,
  int byteLimit = textPreviewByteLimit,
  int imageByteLimit = imagePreviewByteLimit,
}) async {
  final kind = storageFileKindOfName(name);

  // The one verdict the name is allowed to reach on its own, and the only path
  // below that reads no byte at all.
  if (kind == StorageFileKind.image) {
    // The size, then the verdict -- and never the contents. This layer still
    // reads no pixel of an image; what it decides is whether stage 4b is allowed
    // to. Bounded here rather than in the widget so the answer is one pure
    // function both suites can assert, and so it is the same answer on desktop
    // and in a browser: the file is read whole on both, and neither is a place
    // to pull an arbitrary-sized file into memory.
    final byteLength = await source.length();
    if (byteLength > imageByteLimit) {
      return OversizeImageFilePreview(byteLength: byteLength, limitBytes: imageByteLimit);
    }
    return ImageFilePreview(byteLength: byteLength);
  }
  final byteLength = await source.length();

  // An extension the table trusts as text needs one read: the head the preview
  // will show is also the head the sniff inspects. Every other extension --
  // including one the table has never heard of -- is sniffed through the
  // smaller bound first, so a file that turns out to be binary costs
  // [_binarySniffBytes] and not [byteLimit].
  final sniffFirst = !kind.isTextual;
  var head = await source.readHead(_bound(byteLength, sniffFirst ? _binarySniffBytes : byteLimit));

  // Taken on the sniff window, and taken once: the window is the first
  // [_binarySniffBytes] bytes on either branch, and the second read below only
  // appends to the same prefix, so re-running this afterwards could not change
  // the answer.
  final utf16 = _sniffUtf16(head, byteLength);

  // The NUL rule, now qualified by the one encoding whose text legitimately
  // contains NULs. Everything else it used to refuse, it still refuses.
  if (utf16 == null && _holdsNul(head)) {
    return BinaryFilePreview(byteLength: byteLength);
  }

  // It is text whatever it is called. Only now is the rest of the preview bound
  // worth reading.
  if (sniffFirst && byteLength > head.length) {
    head = await source.readHead(_bound(byteLength, byteLimit));
  }

  // Settled before the decode, not after it, because the decode needs it: the
  // trailing trim below is a repair for the cap's cut, and asking for it on a
  // head that was never cut deletes bytes the file really ends with.
  final truncated = byteLength > head.length;
  final decoded = _decodeText(head, utf16, truncated: truncated);
  return TextFilePreview(
    byteLength: byteLength,
    text: decoded.text,
    encoding: decoded.encoding,
    truncated: truncated,
    isJson: kind == StorageFileKind.json,
  );
}

/// A UTF-16 verdict: which endianness, and how many bytes of BOM to step over.
final class _Utf16Sniff {
  const _Utf16Sniff(this.encoding, this.bomBytes);

  final PreviewTextEncoding encoding;

  /// 2 when the file declared itself with a byte order mark, 0 when the
  /// endianness was inferred. The mark is not part of the text.
  final int bomBytes;
}

/// Whether [head] is UTF-16, and in which endianness -- see rules 1 and 2 on
/// [resolveFilePreview]. `null` means "not UTF-16", which is every file that
/// reached this function before it existed.
_Utf16Sniff? _sniffUtf16(Uint8List head, int byteLength) {
  // A UTF-16 file is a whole number of two-byte units, so an odd size rules the
  // encoding out on the file's own length -- which is known even when the head
  // is a cut prefix of it, because it is the *file's* length and not the head's.
  //
  // Ahead of the mark, and deliberately: the length is the one thing here that
  // can contradict a declaration. A BOM says what the writer meant; an odd
  // length says the bytes on disk are not that, whatever was meant. Behind the
  // mark this read `FF FE 41` as UTF-16, found no whole unit after the mark, and
  // previewed a three-byte file as the empty string -- indistinguishable on
  // screen from an empty file, with nothing saying otherwise. Note that an
  // *even* file with nothing after the mark is a different case and still
  // reaches rule 1: `FF FE` alone is a legitimately empty UTF-16 document, and
  // empty is the right answer for it.
  if (!byteLength.isEven) {
    return null;
  }

  if (head.length >= 2) {
    if (head[0] == 0xff && head[1] == 0xfe) {
      return const _Utf16Sniff(PreviewTextEncoding.utf16le, 2);
    }
    if (head[0] == 0xfe && head[1] == 0xff) {
      return const _Utf16Sniff(PreviewTextEncoding.utf16be, 2);
    }
  }

  // Bounded to the same window [_holdsNul] scans, and for the same reason: a
  // verdict that scanned the whole 256 KiB head would make its cost track the
  // file size, and a NUL past the window is already outside the rule this one
  // qualifies.
  final end = head.length < _binarySniffBytes ? head.length : _binarySniffBytes;
  final units = end ~/ 2;
  if (units == 0) {
    return null;
  }
  var evenNul = 0;
  var oddNul = 0;
  for (var i = 0; i + 1 < end; i += 2) {
    if (head[i] == 0) {
      evenNul++;
    }
    if (head[i + 1] == 0) {
      oddNul++;
    }
  }
  if (evenNul == 0 && oddNul * 2 > units) {
    return const _Utf16Sniff(PreviewTextEncoding.utf16le, 0);
  }
  if (oddNul == 0 && evenNul * 2 > units) {
    return const _Utf16Sniff(PreviewTextEncoding.utf16be, 0);
  }
  return null;
}

/// Turns [head] into text, and reports what it was read as -- rules 4 and 5 on
/// [resolveFilePreview], with [utf16] short-circuiting them when rules 1 or 2
/// already answered.
///
/// [truncated] is whether [head] stops short of the file, and it decides whether
/// the trailing trim applies at all -- see [_completeLength]. It is passed in
/// rather than inferred here because it cannot be inferred here: a head that
/// ends mid-sequence and a file that ends mid-sequence are the same bytes, and
/// only the caller knows which one it is holding.
({String text, PreviewTextEncoding encoding}) _decodeText(
  Uint8List head,
  _Utf16Sniff? utf16, {
  required bool truncated,
}) {
  // The whole head when it is the whole file. Trimming a complete file would
  // drop bytes it really ends with, and report neither the loss nor a
  // truncation -- the file would simply be shown short.
  int decodeEnd(int start, PreviewTextEncoding encoding) =>
      truncated ? _completeLength(head, start, encoding) : head.length;

  if (utf16 != null) {
    final start = utf16.bomBytes < head.length ? utf16.bomBytes : head.length;
    final end = decodeEnd(start, utf16.encoding);
    final endian = utf16.encoding == PreviewTextEncoding.utf16le ? Endian.little : Endian.big;
    return (text: _decodeUtf16(head, start, end, endian), encoding: utf16.encoding);
  }

  try {
    final end = decodeEnd(0, PreviewTextEncoding.utf8);
    return (text: const Utf8Decoder().convert(head, 0, end), encoding: PreviewTextEncoding.utf8);
  } catch (_) {
    // Not UTF-8. Fall through rather than refuse: the point of the strict decode
    // is to *ask*, and a failure is the question's other answer.
  }

  try {
    final end = decodeEnd(0, PreviewTextEncoding.shiftJis);
    // Caught broadly on purpose: `ShiftJISDecoder` reports an unmapped byte as a
    // `FormatException` but runs off the end of its input as a `RangeError`, and
    // both mean the same thing here -- these bytes are not Shift-JIS.
    return (
      text: const ShiftJISDecoder().convert(Uint8List.sublistView(head, 0, end)),
      encoding: PreviewTextEncoding.shiftJis,
    );
  } catch (_) {
    // Not Shift-JIS either.
  }

  // `allowMalformed` rather than a second refusal path: genuinely broken bytes
  // reach a replacement character, which is the right answer for a viewer that
  // must not crash.
  return (text: utf8.decode(head, allowMalformed: true), encoding: PreviewTextEncoding.utf8);
}

/// Reads [head] between [start] and [end] as UTF-16 in [endian].
///
/// `String.fromCharCodes` takes UTF-16 code units, so a surrogate pair spanning
/// two units composes on its own; a lone surrogate left by the cut survives as
/// itself rather than throwing.
String _decodeUtf16(Uint8List head, int start, int end, Endian endian) {
  final data = ByteData.sublistView(head);
  final units = Uint16List((end - start) ~/ 2);
  for (var i = 0; i < units.length; i++) {
    units[i] = data.getUint16(start + i * 2, endian);
  }
  return String.fromCharCodes(units);
}

/// Where in [head] the last character that is *complete* in [encoding] ends.
///
/// One function for all three because there is one reason: the preview cuts at a
/// fixed byte offset, so a truncated head ends mid-character by construction,
/// and each encoding merely spells "mid-character" differently -- up to three
/// trailing bytes of a UTF-8 sequence, a single odd byte of a UTF-16 unit, a
/// lone Shift-JIS lead byte. Trimming is what lets the strict decodes above be
/// strict: without it every truncated file would fail them and fall to the
/// lenient path, and the encoding question would be decided by the cap.
///
/// **Only ever asked of a head the cap actually cut**, which is why
/// [_decodeText] takes `truncated` rather than working it out from the bytes.
/// The bytes cannot tell the two apart: a cut head and a complete file that
/// simply ends in a byte this function calls incomplete are the same input. On a
/// complete file the trim is not a repair but a deletion -- `63 61 66 E9`, a
/// CP1252 "cafe" with the accent, would come back as `caf` with
/// [TextFilePreview.truncated] false and nothing on screen saying a byte was
/// dropped. Left whole, those bytes fail both strict decodes and reach the
/// lenient one, which is where a viewer shows an unreadable byte as U+FFFD.
int _completeLength(Uint8List head, int start, PreviewTextEncoding encoding) {
  switch (encoding) {
    case PreviewTextEncoding.utf16le:
    case PreviewTextEncoding.utf16be:
      return head.length - ((head.length - start) % 2);
    case PreviewTextEncoding.utf8:
      // A sequence is at most four bytes, so the lead of an incomplete one is
      // within four bytes of the end. Anything longer is malformed rather than
      // cut, and is the lenient decode's business.
      final floor = head.length - 4 > start ? head.length - 4 : start;
      for (var i = head.length - 1; i >= floor; i--) {
        final byte = head[i];
        if (byte & 0xc0 == 0x80) {
          continue; // A continuation byte; the lead is further back.
        }
        final width = switch (byte) {
          < 0x80 => 1,
          _ when byte & 0xe0 == 0xc0 => 2,
          _ when byte & 0xf0 == 0xe0 => 3,
          _ when byte & 0xf8 == 0xf0 => 4,
          _ => 1, // Not a lead byte at all; malformed, not cut.
        };
        return i + width > head.length ? i : head.length;
      }
      return head.length;
    case PreviewTextEncoding.shiftJis:
      var i = start;
      while (i < head.length) {
        final byte = head[i];
        final width = (byte >= 0x81 && byte <= 0x9f) || (byte >= 0xe0 && byte <= 0xef) ? 2 : 1;
        if (i + width > head.length) {
          return i;
        }
        i += width;
      }
      return head.length;
  }
}

/// The smaller of the file's own size and [cap], so a short file is never asked
/// for more than it has and a long one is never asked for more than the bound.
int _bound(int byteLength, int cap) => byteLength < cap ? byteLength : cap;

/// Whether the first [_binarySniffBytes] of [head] contain a NUL byte.
///
/// Bounded independently of [head]'s own length: the head handed in may be a
/// whole 256 KiB preview, and scanning all of it would make the check's cost
/// track the file size for no gain (see [_binarySniffBytes]).
bool _holdsNul(Uint8List head) {
  final end = head.length < _binarySniffBytes ? head.length : _binarySniffBytes;
  for (var i = 0; i < end; i++) {
    if (head[i] == 0) {
      return true;
    }
  }
  return false;
}
