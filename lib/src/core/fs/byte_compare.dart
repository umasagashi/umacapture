import 'dart:typed_data';

/// Chunk size used by the streaming file comparison every `FsBackend` provides.
///
/// Large enough that a record image is compared in a handful of reads, small
/// enough that peak memory stays flat (two buffers) instead of scaling with the
/// file size. A multiple of four, so a full chunk is compared entirely by the
/// word-wise loop below.
const int fileCompareChunkSize = 256 * 1024;

/// Whether the first [length] bytes of [a] and [b] are identical.
///
/// Compares 32-bit words where the views are word-aligned — roughly four times
/// fewer Dart loop iterations than a byte-wise scan — and falls back to bytes
/// for the trailing one to three bytes, and for the (rare) unaligned view.
///
/// [Uint64List] is deliberately not used: dart2js has no 64-bit integer
/// representation and `ByteBuffer.asUint64List` throws [UnsupportedError]
/// there, so a 64-bit loop would work on the VM and break on web.
bool sameByteRange(Uint8List a, Uint8List b, int length) {
  assert(length <= a.length && length <= b.length);
  var index = 0;
  // `asUint32List` requires the view's byte offset to be a multiple of four;
  // buffers we allocate and blobs we read start at zero, but a caller-supplied
  // view need not, so fall through to the byte loop when it does not.
  if (a.offsetInBytes % 4 == 0 && b.offsetInBytes % 4 == 0) {
    final words = length >> 2;
    if (words > 0) {
      final aWords = a.buffer.asUint32List(a.offsetInBytes, words);
      final bWords = b.buffer.asUint32List(b.offsetInBytes, words);
      for (var i = 0; i < words; i++) {
        if (aWords[i] != bWords[i]) return false;
      }
    }
    index = words << 2;
  }
  for (; index < length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
