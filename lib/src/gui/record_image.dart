import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '/src/core/app_logger.dart';
import '/src/core/fs/fs_backend.dart';
import '/src/core/path_entity.dart';

/// Displays a record image from the filesystem, transparently across platforms.
///
/// On desktop this is exactly [Image.file] over [FilePath.toFile] — the same
/// decode, the same global [ImageCache] entry (keyed by the file), and the same
/// [width]/[height]/[fit]/[errorBuilder] semantics — so desktop rendering and
/// caching are unchanged from the raw `Image.file(path.toFile(), ...)` call sites
/// this replaces.
///
/// On web, where a `dart:io` [File] cannot be read at runtime, the bytes are
/// pulled asynchronously from OPFS through [fsBackend] and shown with
/// [Image.memory]. A small in-session LRU keeps recently decoded bytes so the
/// preview's `LayoutBuilder` (which re-runs on resize / splitter drag) does not
/// re-hit OPFS on every layout pass.
class RecordImage extends StatelessWidget {
  final FilePath path;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Declares that [preload] has already been awaited for [path], so the image may be resolved
  /// without an asynchronous step.
  ///
  /// **Opt-in, and false everywhere except the call site that pairs it with [preload].** It changes
  /// nothing about which pixels are shown; it only removes the frames in which *no* pixels are shown
  /// while the load runs. A call site that sets it without preloading first is not wrong, merely
  /// unhelped: a cache miss falls back to the ordinary asynchronous path.
  final bool preloaded;

  const RecordImage(
    this.path, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
    this.preloaded = false,
  });

  /// Loads and decodes [path] into the same cache the widget will read, and completes when the
  /// pixels are ready to be painted.
  ///
  /// **For a call site that replaces one path with another on a mounted [RecordImage] and shows a
  /// caption describing the image beside it.** Without it, swapping the path blanks the image for
  /// the duration of the load: `Image.gaplessPlayback` defaults to false, so `_ImageState` drops the
  /// old frame the instant the provider changes, and a `RenderImage` with no image takes
  /// `constraints.smallest`. Turning `gaplessPlayback` on would trade that for the opposite defect —
  /// the *previous* frame left on screen beside a caption naming the new one — which is why the
  /// wait happens here, before the new path is published, rather than in the widget.
  ///
  /// Never throws: a path that cannot be read or decoded completes normally, and the widget's own
  /// `errorBuilder` renders the failure. Awaiting this is therefore never a way to lose a frame.
  static Future<void> preload(FilePath path, BuildContext context) async {
    try {
      if (!kIsWeb) {
        // FileImage's key is the file, so the widget's own Image.file resolves out of the global
        // ImageCache synchronously afterwards.
        await precacheImage(FileImage(path.toFile()), context, onError: _reportPreloadFailure);
        return;
      }
      // Web needs both halves warmed: the OPFS read (the byte LRU) and the decode (the ImageCache).
      // MemoryImage's key compares `bytes` by identity, so the widget must reach the *same*
      // Uint8List instance — which is exactly what the LRU hands back.
      final bytes = await _WebRecordImageState.loadBytes(path.path);
      if (!context.mounted) {
        return;
      }
      await precacheImage(MemoryImage(bytes), context, onError: _reportPreloadFailure);
    } catch (error, stackTrace) {
      _reportPreloadFailure(error, stackTrace);
    }
  }

  static void _reportPreloadFailure(Object error, StackTrace? stackTrace) {
    logger.w('RecordImage.preload failed; the widget falls back to its own error path: $error');
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      // Identical to the previous call sites: FileImage decode + global cache.
      return Image.file(path.toFile(), width: width, height: height, fit: fit, errorBuilder: errorBuilder);
    }
    return _WebRecordImage(
      path: path,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: errorBuilder,
      preloaded: preloaded,
    );
  }
}

/// Bounded, in-session LRU of record-image bytes read from OPFS, keyed by path.
///
/// Record images are written once per path in a session, so the path alone is a
/// sound key; the cap keeps a long browsing session from growing it without
/// bound. Web-only (never touched on desktop, which reads through [Image.file]).
class _WebImageByteCache {
  _WebImageByteCache._();

  static final _WebImageByteCache instance = _WebImageByteCache._();

  static const int _maxEntries = 48;
  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap<String, Uint8List>();

  Uint8List? get(String path) {
    final bytes = _entries.remove(path);
    if (bytes != null) {
      _entries[path] = bytes; // Re-insert as most-recently-used.
    }
    return bytes;
  }

  void put(String path, Uint8List bytes) {
    _entries.remove(path);
    _entries[path] = bytes;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

class _WebRecordImage extends StatefulWidget {
  final FilePath path;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final bool preloaded;

  const _WebRecordImage({
    required this.path,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
    this.preloaded = false,
  });

  @override
  State<_WebRecordImage> createState() => _WebRecordImageState();
}

class _WebRecordImageState extends State<_WebRecordImage> {
  late Future<Uint8List> _bytesFuture;

  /// Bytes taken straight out of the LRU when the call site declared this path preloaded, or null.
  ///
  /// A [FutureBuilder] cannot report a value on the build in which its future is installed — even an
  /// already-completed future is delivered in a microtask — so a call site that awaited
  /// [RecordImage.preload] would *still* get one frame of empty box out of the branch below.
  /// Reading the LRU synchronously is what makes the new bytes reachable in the same frame that
  /// publishes the new path. Null whenever [RecordImage.preloaded] is false, so the asynchronous
  /// path below is byte-for-byte what every other call site keeps getting.
  Uint8List? _preloadedBytes;

  @override
  void initState() {
    super.initState();
    _adoptPath();
  }

  @override
  void didUpdateWidget(_WebRecordImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path.path != widget.path.path || oldWidget.preloaded != widget.preloaded) {
      _adoptPath();
    }
  }

  void _adoptPath() {
    final preloaded = widget.preloaded ? _WebImageByteCache.instance.get(widget.path.path) : null;
    _preloadedBytes = preloaded;
    _bytesFuture = preloaded != null ? Future<Uint8List>.value(preloaded) : _load();
  }

  /// Reads [path] out of the in-session LRU, or out of OPFS and into it.
  ///
  /// Static so [RecordImage.preload] warms the very same LRU entry the widget will read, and hands
  /// back the identical [Uint8List] instance that [MemoryImage]'s identity-compared key needs.
  static Future<Uint8List> loadBytes(String path) async {
    final cached = _WebImageByteCache.instance.get(path);
    if (cached != null) {
      return cached;
    }
    final bytes = await fsBackend.readBytes(path);
    _WebImageByteCache.instance.put(path, bytes);
    return bytes;
  }

  Future<Uint8List> _load() => loadBytes(widget.path.path);

  @override
  Widget build(BuildContext context) {
    final preloaded = _preloadedBytes;
    if (preloaded != null) {
      return _image(preloaded);
    }
    return FutureBuilder<Uint8List>(
      future: _bytesFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _onError(context, snapshot.error!, snapshot.stackTrace);
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          // Reserves the same layout footprint while the OPFS read is in flight, **only when the
          // caller passed `width`/`height`**. A `SizedBox` with a null dimension imposes no footprint
          // of its own on that axis and instead sizes to whatever the parent already constrains it to.
          // Several call sites pass neither (`report_screen_dialog.dart:197`, `character.dart:305`),
          // and for those this box reserves nothing — the surrounding layout decides what appears
          // while the read is in flight.
          return SizedBox(width: widget.width, height: widget.height);
        }
        return _image(bytes);
      },
    );
  }

  Widget _image(Uint8List bytes) {
    return Image.memory(
      bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorBuilder: widget.errorBuilder,
    );
  }

  Widget _onError(BuildContext context, Object error, StackTrace? stackTrace) {
    final builder = widget.errorBuilder;
    if (builder != null) {
      return builder(context, error, stackTrace ?? StackTrace.empty);
    }
    return SizedBox(width: widget.width, height: widget.height);
  }
}
