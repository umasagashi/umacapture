import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/app_logger.dart';
import '/src/core/fs/fs_backend.dart';
import '/src/core/path_entity.dart';

/// Displays a record image from the filesystem, transparently across platforms.
///
/// On desktop, **and only while no [maxDecodePixels] bound is asked for**, this
/// is exactly [Image.file] over [FilePath.toFile] — the same decode, the same
/// global [ImageCache] entry (keyed by the file), and the same
/// [width]/[height]/[fit]/[errorBuilder] semantics — so desktop rendering and
/// caching are unchanged from the raw `Image.file(path.toFile(), ...)` call sites
/// this replaces.
///
/// On web, where a `dart:io` [File] cannot be read at runtime, the bytes are
/// pulled asynchronously from OPFS through [fsBackend] and shown with
/// [Image.memory]. A small in-session LRU keeps recently decoded bytes so the
/// preview's `LayoutBuilder` (which re-runs on resize / splitter drag) does not
/// re-hit OPFS on every layout pass. A bounded image takes this same route on
/// desktop; [build] states the constraint that forces it.
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

  /// The most physical pixels this image may be *decoded* to, or null to decode
  /// at the file's own resolution.
  ///
  /// **A second bound, because the first one cannot see this cost.**
  /// `imagePreviewByteLimit` bounds what is read into the heap; decoding costs
  /// four bytes per pixel of the *image*, which the file's length does not
  /// predict. Measured on this installation, the app's own stitched
  /// `campaign.png` is 5,194,128 B of file and 1080x9513 px = 41 MB of RGBA, and
  /// a crafted 8000x8000 PNG is ~2 MB of file and ~256 MB decoded.
  ///
  /// **Physical pixels, supplied by the call site, never a constant.** What is
  /// worth decoding is the size of the box the picture is painted into, which is
  /// a layout result times the device pixel ratio; a number written here would be
  /// a guess about someone else's window.
  ///
  /// Applied on both platforms. The decode is `dart:ui`'s on either one, so the
  /// cost and the bound are the same fact, and a limit written for the browser
  /// alone would leave the desktop app decoding 256 MB for a 720 px box.
  ///
  /// **Do not combine with [preloaded]**; that method's doc says what misses and
  /// why it is not guarded against.
  final Size? maxDecodePixels;

  const RecordImage(
    this.path, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
    this.preloaded = false,
    this.maxDecodePixels,
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
  ///
  /// **Not paired with [RecordImage.maxDecodePixels], and no call site does pair them.** This warms
  /// the two halves a *bound-free* widget reads: on desktop the global [ImageCache] under a
  /// [FileImage] key, and on web the byte LRU plus a plain [MemoryImage]. A bounded widget resolves
  /// through a [ResizeImage] whose key neither of those equals, so the precache would miss and the
  /// widget would read again -- the preloaded frame would be blank, which is the one thing this
  /// method exists to prevent. It is left unguarded rather than asserted because the combination is
  /// merely unhelpful, not wrong, and an assert would turn a wasted read into a crash; if a call
  /// site ever wants both, warm `boundedRecordImageProvider(MemoryImage(await loadBytes(...)), box)`
  /// instead of adding a branch here.
  static Future<void> preload(FilePath path, BuildContext context) async {
    try {
      if (!kIsWeb) {
        // FileImage's key is the file, so the widget's own Image.file resolves out of the global
        // ImageCache synchronously afterwards -- and [_fileImagePaths] says why handing it over is
        // also the moment it has to be written down.
        _rememberFileImage(path.path);
        await precacheImage(FileImage(path.toFile()), context, onError: _reportPreloadFailure);
        return;
      }
      // Web needs both halves warmed: the OPFS read (the byte LRU) and the decode (the ImageCache).
      // MemoryImage's key compares `bytes` by identity, so the widget must reach the *same*
      // Uint8List instance — which is exactly what the LRU hands back.
      final bytes = await _BytesRecordImageState.loadBytes(path.path);
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

  /// Wrapped so a write that replaced this path's bytes reaches the picture already on screen
  /// ([RecordImageInvalidations] says why a cache eviction alone cannot).
  @override
  Widget build(BuildContext context) => _RecordImageRefresh(path: path, builder: _content);

  Widget _content(BuildContext context) {
    if (!kIsWeb && maxDecodePixels == null) {
      // Identical to the previous call sites: FileImage decode + global cache.
      //
      // Written down here, while the widget builds, for the same reason [RecordImageByteCache.registerBounded] is:
      // the window between here and a post-frame callback is precisely a window in which an
      // eviction could not name the entry it has to drop. [_fileImagePaths] says what it is for.
      _rememberFileImage(path.path);
      return Image.file(path.toFile(), width: width, height: height, fit: fit, errorBuilder: errorBuilder);
    }
    // **A bounded image goes through the bytes on both platforms, and that is
    // what makes the eviction sound rather than a desktop-only hole.** The
    // cached picture is keyed by the provider the decode went through, and a
    // [ResizeImage] key is *not* equal to the key of the provider it wraps
    // ([ResizeImageKey] carries the box). So a delete has to be able to name the
    // wrapper, which means the cache has to have kept it -- and a kept
    // registration is only safe if it becomes unreachable when the LRU drops it.
    // [MemoryImage] compares its key by identity, so a re-read after a delete
    // yields a different `Uint8List` and therefore a key nothing can reconstruct;
    // [FileImage] compares by *path*, so the same wrapper over the same box
    // would be rebuilt identically and hand back the deleted picture. That
    // asymmetry is why the desktop path joins this one when a bound is asked
    // for, instead of wrapping `FileImage`.
    return _BytesRecordImage(
      path: path,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: errorBuilder,
      preloaded: preloaded,
      maxDecodePixels: maxDecodePixels,
    );
  }
}

/// [base], decoded no larger than [maxPixels].
///
/// [ResizeImagePolicy.fit] and not the `cacheWidth`/`cacheHeight` arguments of
/// `Image.memory` / `Image.file`: those go through `ResizeImage.resizeIfNeeded`,
/// whose default policy is `exact`, so passing both axes of a box would squash
/// the picture into it and passing one axis would leave the other unbounded --
/// and an image can be extreme on either axis (this installation's stitched
/// `campaign.png` is 1080x9513). `fit` is the one that means "no larger than this
/// box, aspect kept".
///
/// `allowUpscaling: false` so a small picture is still decoded at its own size;
/// the bound is a ceiling, not a target.
///
/// **Public so the eviction below and its test can name the same key.** A
/// [ResizeImage] keys differently from the provider it wraps, so a caller that
/// built one here and evicted the bare provider would be addressing an entry
/// that does not exist.
ResizeImage boundedRecordImageProvider(ImageProvider base, Size maxPixels) {
  return ResizeImage(
    base,
    width: maxPixels.width.ceil(),
    height: maxPixels.height.ceil(),
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );
}

/// Bounded, in-session LRU of record-image bytes read from OPFS, keyed by path.
///
/// A path is the whole key, so a writer that replaces a tree's pixels under paths
/// that do not change drops the affected entries itself, through
/// [evictRecordImagesWithin]. The cap keeps a long
/// browsing session from growing the LRU without bound. Filled on web for every
/// image, and on desktop for the bounded ones
/// (see [RecordImage._content]), so [remove] is reachable from the VM suite and the
/// eviction below needs no second implementation per platform.
///
/// **It also holds the bounded providers built over each entry's bytes**, which
/// is not a second cache but the same one: those providers are only nameable
/// through the bytes they wrap, so the place that owns the bytes is the only
/// place that can hand them to a delete. Dropping the pair together is what
/// makes the LRU's own eviction safe — the registration and the `Uint8List` that
/// keys it go at the same moment, so a wrapper the LRU forgot can never be
/// rebuilt equal to one the [ImageCache] still holds.
class RecordImageByteCache {
  RecordImageByteCache._();

  static final RecordImageByteCache instance = RecordImageByteCache._();

  static const int _maxEntries = 48;

  /// The most bytes the LRU holds across all of its entries (64 MiB).
  ///
  /// **The entry count alone is not a memory bound, and on this installation it
  /// is not even close to one.** Measured over its 834 image files, the 48
  /// largest sum to 117,428,186 B: the count cap admits 112 MiB of held bytes
  /// from files the app wrote itself, before any file the user dropped into the
  /// unclassified group is considered. Those are capped at
  /// `imagePreviewByteLimit` each, so 48 of them is 768 MiB.
  ///
  /// 64 MiB is what leaves the count cap doing its job for ordinary browsing --
  /// 48 images at this store's median of 839,044 B is 38.4 MB, so the entry the
  /// LRU exists for (a re-layout re-reading the same picture) is still a hit --
  /// while bounding the tail the count cannot see. It is *not* a measurement of
  /// a browser's ceiling; it is the smallest round bound that refuses nothing the
  /// cache was built to hold. Raising it to 128 MiB would readmit the 112 MiB
  /// worst case measured above; lowering it to 32 MiB would start evicting
  /// during ordinary browsing of median-sized images.
  ///
  /// **This bound is now desktop's as well as the browser's.** Before bounded
  /// images existed the LRU was never filled off web, so the only memory at
  /// stake was a browser tab's; a bounded [RecordImage] fills it on either
  /// platform ([RecordImage._content] says why), which means the Windows app can
  /// hold up to this many bytes in a process-lifetime singleton. The figure is
  /// unchanged by that -- it was derived from the image corpus, not from a
  /// browser's ceiling -- but the exposure is no longer one-sided, and 64 MiB is
  /// stated here as an amount a desktop process may retain, not only as an
  /// amount a tab may survive.
  static const int _maxBytes = 67108864;

  final LinkedHashMap<String, _CachedRecordImage> _entries = LinkedHashMap<String, _CachedRecordImage>();
  int _heldBytes = 0;

  /// How many bytes the LRU is currently holding.
  ///
  /// Exposed because the byte bound is otherwise unassertable: a test can count
  /// entries through [get], but nothing outside can add up their lengths.
  int get heldBytes => _heldBytes;

  /// Every path this LRU is holding bytes for.
  ///
  /// **Its keys are its index.** A path is in this cache exactly while its bytes
  /// are, so [evictRecordImagesWithin] needs no second record of what was cached
  /// on this side -- and no record that could disagree with it.
  Iterable<String> get paths => _entries.keys;

  Uint8List? get(String path) {
    final entry = _entries.remove(path);
    if (entry != null) {
      _entries[path] = entry; // Re-insert as most-recently-used.
    }
    return entry?.bytes;
  }

  /// Remembers that [provider] was built over the bytes held for [path].
  ///
  /// **A set, and idempotent, because the caller is a `build` method.** Every
  /// rebuild constructs an equal [ResizeImage] (`ResizeImage.==` compares the
  /// wrapped provider and the box), so re-registering is a hash lookup and the
  /// set holds one member per distinct box the picture was painted into. It is
  /// registered from `build` rather than from a post-frame callback because the
  /// window between the two is precisely a window in which a delete could not
  /// name the entry it has to drop.
  ///
  /// **A path the LRU is not holding registers nothing, silently.** That is the
  /// intended answer rather than an oversight: the provider wraps a `Uint8List`
  /// the cache has already let go of, so nothing can produce an equal key again
  /// and a delete would have nothing to drop. No test asserts the no-op, because
  /// no observable behaviour distinguishes it from registering.
  void registerBounded(String path, ResizeImage provider) {
    _entries[path]?.bounded.add(provider);
  }

  void put(String path, Uint8List bytes) {
    _forget(path);
    _entries[path] = _CachedRecordImage(bytes);
    _heldBytes += bytes.lengthInBytes;
    // Both bounds, and the newest entry is never the one dropped: a cache that
    // evicted what it was just asked to hold would make the very read that
    // overflowed it a permanent miss. An entry larger than [_maxBytes] on its own
    // therefore stays, alone -- which is why the read side has a bound of its
    // own and this one is not asked to be the only guard.
    while (_entries.length > 1 && (_entries.length > _maxEntries || _heldBytes > _maxBytes)) {
      _forget(_entries.keys.first);
    }
  }

  /// Drops [path] and subtracts what it was holding, or does nothing.
  _CachedRecordImage? _forget(String path) {
    final dropped = _entries.remove(path);
    if (dropped != null) {
      _heldBytes -= dropped.bytes.lengthInBytes;
    }
    return dropped;
  }

  /// Forgets [path], answering the bytes that were held for it.
  ///
  /// **Returns the instance rather than a `bool` because the caller needs it.**
  /// The decoded image these bytes produced is in the global [ImageCache] under a
  /// [MemoryImage] whose key compares `bytes` by *identity*, so the only value in
  /// the process that can address that entry is this one. A `remove` that
  /// answered "yes, there was one" would drop the bytes and leave the decoded
  /// image unreachable and undroppable.
  ({Uint8List bytes, Iterable<ResizeImage> bounded})? remove(String path) {
    final dropped = _forget(path);
    return dropped == null ? null : (bytes: dropped.bytes, bounded: dropped.bounded);
  }
}

/// One path's bytes, and every bounded provider built over them.
class _CachedRecordImage {
  _CachedRecordImage(this.bytes);

  final Uint8List bytes;
  final Set<ResizeImage> bounded = <ResizeImage>{};
}

/// Every record-image path this process has handed to the global [ImageCache]
/// under a [FileImage] key.
///
/// **The desktop half of "which pictures are cached", which nothing else in the
/// process can answer.** [RecordImageByteCache] is its own index -- its keys are
/// the paths it is holding -- but an unbounded [RecordImage] resolves through
/// `Image.file` off web ([RecordImage._content]), and [ImageCache] offers no way to
/// enumerate its keys or to match them against a directory. The moment the path
/// is known is the moment it is handed over, so that is where it is written down.
///
/// **Paths, not pixels, and pruned by every eviction.** A path enters only by
/// being displayed, so the set is bounded by how many distinct record images the
/// installation has -- 834 image files, measured for [RecordImageByteCache] --
/// rather than by how long the session runs.
///
/// Over-approximating is the harmless direction: [ImageCache] drops entries under
/// its own bounds, and evicting a key no cache holds is a miss on two hash
/// lookups, which [evictRecordImages] already relies on for the paths it is given.
/// Under-approximating is the direction that would cost an eviction, and `build`
/// is what closes it: an `Image` resolves its provider from
/// `didChangeDependencies`, which a build always follows, so a path that is back
/// in the [ImageCache] is a path that is back in here.
final Set<String> _fileImagePaths = <String>{};

void _rememberFileImage(String path) {
  _fileImagePaths.add(path);
}

/// Drops every cached record image whose path equals one of [scopes] or lies
/// under one.
///
/// **For a writer that replaces a tree's contents under paths that do not
/// change**, where the paths whose pixels went are not the paths the writer
/// named.
///
/// **Which ones those are is a question about the caches, not about the disk.** A
/// path no cache holds needs no eviction, so the complete answer is the two
/// caches' own keys narrowed to [scopes]: [RecordImageByteCache.paths] and
/// [_fileImagePaths]. Both are in memory, so the eviction happens whatever the
/// filesystem is doing. Listing a directory instead would rest the eviction on a
/// call that answers with an empty list for a directory full of files when it
/// fails -- `DirectoryPath.list` collects the whole listing before it yields any
/// of it -- and the caller cannot tell that answer from an empty directory, so
/// the replaced pixels would stay cached exactly when the disk is already in
/// trouble.
///
/// Always reaches [evictRecordImages], even with nothing to drop, so a process
/// with no painting binding fails here the same way whatever was cached.
void evictRecordImagesWithin(Iterable<String> scopes) {
  final scopeList = scopes.toList();
  evictRecordImages(
    <String>{
      ...RecordImageByteCache.instance.paths,
      ..._fileImagePaths,
    }.where((path) => scopeList.any((scope) => isRecordPathWithin(path, scope))).toList(),
  );
}

/// Whether [path] equals [scope] or lies under it.
///
/// Compared segment by segment and not by string prefix: `.../older` and
/// `.../older-2` are in a prefix relation as text and in none as paths, and the
/// caches are keyed by paths the platform joined (backslashes on Windows) while
/// a writer may pass a path built from segments. Case is compared as written:
/// every record path the app builds comes from the record's own id.
bool isRecordPathWithin(String path, String scope) {
  final segments = PathEntity.parseSegments(path);
  final scopeSegments = PathEntity.parseSegments(scope);
  if (segments.length < scopeSegments.length) {
    return false;
  }
  for (var index = 0; index < scopeSegments.length; index++) {
    if (segments[index] != scopeSegments[index]) {
      return false;
    }
  }
  return true;
}

/// Tells every mounted [RecordImage] which paths a write has just replaced.
///
/// **The half of an invalidation a cache eviction cannot reach.** Evicting a
/// path from [ImageCache] drops the entry, but an `Image` already on screen
/// keeps the frame it resolved and re-resolves only when its provider changes --
/// and a write that replaces bytes under an unchanged path changes no provider.
/// So a picture on screen goes on showing the replaced pixels until something
/// rebuilds it under a new element, which is what a [RecordImage] does when this
/// names a path it shows.
///
/// Addressed by the write's own paths and not by the caches' keys: a picture the
/// byte LRU already let go of is still on screen, and still stale.
class RecordImageInvalidations extends ChangeNotifier {
  RecordImageInvalidations._();

  static final RecordImageInvalidations instance = RecordImageInvalidations._();

  List<String> _changed = const [];

  /// The paths of the announcement being delivered.
  List<String> get changed => _changed;

  /// Makes every mounted [RecordImage] whose path equals one of [changed], or
  /// lies under one, read its file again.
  void announce(Iterable<String> changed) {
    _changed = List.unmodifiable(changed);
    notifyListeners();
  }
}

/// Rebuilds a [RecordImage]'s picture under a fresh element when
/// [RecordImageInvalidations] names its path.
class _RecordImageRefresh extends StatefulWidget {
  const _RecordImageRefresh({required this.path, required this.builder});

  final FilePath path;
  final WidgetBuilder builder;

  @override
  State<_RecordImageRefresh> createState() => _RecordImageRefreshState();
}

class _RecordImageRefreshState extends State<_RecordImageRefresh> {
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    RecordImageInvalidations.instance.addListener(_onInvalidated);
  }

  @override
  void dispose() {
    RecordImageInvalidations.instance.removeListener(_onInvalidated);
    super.dispose();
  }

  void _onInvalidated() {
    final path = widget.path.path;
    if (RecordImageInvalidations.instance.changed.any((scope) => isRecordPathWithin(path, scope))) {
      setState(() => _generation++);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A new key and not a plain rebuild: `Image` re-resolves only when its
    // provider changes, and a `FileImage` over an unchanged path is equal to the
    // one it already resolved. Replacing the element is what forces the read.
    return KeyedSubtree(
      key: ValueKey<int>(_generation),
      child: Builder(builder: widget.builder),
    );
  }
}

/// Drops [paths] from every cache a [RecordImage] can answer out of.
///
/// Without this a deleted image keeps being displayed, and the user, seeing the
/// delete apparently do nothing, tries again on a file that is already gone.
///
/// **Called after a delete, never before.** Both caches are readers: evicting
/// first leaves a window in which a repaint reads the file that is still there
/// and re-fills the entry that was just dropped. (The controller invalidation
/// metadata gets in place of a lock runs *before* its delete for the opposite reason — that
/// one owns a writer, and a writer can put the file back.)
///
/// **`includeLive: true` is spelled out, and it is `ImageCache.evict`'s own
/// default.** It is written anyway because the eviction depends on it and a
/// default is not a contract: `putIfAbsent` consults the live-image table after
/// missing the cache proper, so an image some widget is still listening to would
/// be handed straight back to the next resolve if the live half were skipped —
/// and the image a delete removes is, by construction, one the user was looking
/// at a moment ago. Naming it costs nothing and says which behaviour is being
/// relied on. (Measured: removing the argument changes no test, precisely because
/// it restates the default. It is documentation, not a fix.)
///
/// **A picture decoded under a [RecordImage.maxDecodePixels] bound is evicted
/// too, and by name rather than by argument.** Its [ImageCache] entry is keyed
/// by a [ResizeImageKey] carrying the box a layout chose, which this function
/// could not reconstruct -- so the box is not re-derived here, it is *remembered*
/// beside the bytes it was built over ([RecordImageByteCache.registerBounded]),
/// and dropped with them. Every bounded provider is evicted with the same
/// `includeLive: true`, so a bound does not quietly cost this function its live
/// half. The alternative -- leaving the entry orphaned and relying on
/// [MemoryImage]'s identity key to make it unreachable -- would have rested on
/// the storage preview never being mounted when a delete runs, which this
/// library's own header says stage 6 is about to falsify.
///
/// Takes paths and filters nothing. A list of image extensions here would be a
/// hand-kept table that goes stale the first time a format is added, and it would
/// buy nothing: evicting a key no cache holds is a miss on two hash lookups.
void evictRecordImages(Iterable<String> paths) {
  final cache = PaintingBinding.instance.imageCache;
  for (final path in paths) {
    final held = RecordImageByteCache.instance.remove(path);
    if (held != null) {
      cache.evict(MemoryImage(held.bytes), includeLive: true);
      for (final provider in held.bounded) {
        // `obtainKey` over a `MemoryImage` is a `SynchronousFuture`, so this
        // `then` runs before the loop advances and the eviction is as immediate
        // as the two above it. The key is asked for rather than constructed
        // because `ResizeImageKey`'s constructor is private -- and asking the
        // provider is what guarantees the key matches the one the decode was
        // filed under.
        provider.obtainKey(ImageConfiguration.empty).then((key) => cache.evict(key, includeLive: true));
      }
    }
    if (!kIsWeb) {
      // The desktop half, for the images that carry no bound and therefore still
      // resolve through `Image.file`. Not a divergence in the eviction contract:
      // a bounded image is filed under a `MemoryImage` on *both* platforms
      // (`RecordImage._content` says why), so this line covers the unbounded
      // desktop call sites and nothing else. `dart:io`'s `File` is a stub on web
      // that addresses nothing, which is why it is skipped there.
      _fileImagePaths.remove(path);
      cache.evict(FileImage(FilePath(path).toFile()), includeLive: true);
    }
  }
}

class _BytesRecordImage extends StatefulWidget {
  final FilePath path;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final bool preloaded;
  final Size? maxDecodePixels;

  const _BytesRecordImage({
    required this.path,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
    this.preloaded = false,
    this.maxDecodePixels,
  });

  @override
  State<_BytesRecordImage> createState() => _BytesRecordImageState();
}

class _BytesRecordImageState extends State<_BytesRecordImage> {
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
  void didUpdateWidget(_BytesRecordImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path.path != widget.path.path || oldWidget.preloaded != widget.preloaded) {
      _adoptPath();
    }
  }

  void _adoptPath() {
    final preloaded = widget.preloaded ? RecordImageByteCache.instance.get(widget.path.path) : null;
    _preloadedBytes = preloaded;
    _bytesFuture = preloaded != null ? Future<Uint8List>.value(preloaded) : _load();
  }

  /// Reads [path] out of the in-session LRU, or out of OPFS and into it.
  ///
  /// Static so [RecordImage.preload] warms the very same LRU entry the widget will read, and hands
  /// back the identical [Uint8List] instance that [MemoryImage]'s identity-compared key needs.
  static Future<Uint8List> loadBytes(String path) async {
    final cached = RecordImageByteCache.instance.get(path);
    if (cached != null) {
      return cached;
    }
    final bytes = await fsBackend.readBytes(path);
    RecordImageByteCache.instance.put(path, bytes);
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
    final bound = widget.maxDecodePixels;
    if (bound == null) {
      return Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: widget.errorBuilder,
      );
    }
    final provider = boundedRecordImageProvider(MemoryImage(bytes), bound);
    // Registered where it is built: a delete can only drop what the cache was
    // told about, and any later moment is a window in which it could not.
    RecordImageByteCache.instance.registerBounded(widget.path.path, provider);
    return Image(
      image: provider,
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

/// A record's trainee icon, or a placeholder where the file is missing or unreadable.
///
/// The icon is normally always present; the placeholder guards against a missing or corrupt file
/// (e.g. a hand-edited archive) so a dialog shows a symbol instead of a red error box.
class TraineeIcon extends StatelessWidget {
  const TraineeIcon(this.path, {super.key, this.placeholderSize = 64});

  final FilePath path;
  final double placeholderSize;

  @override
  Widget build(BuildContext context) {
    return RecordImage(
      path,
      errorBuilder: (context, error, stackTrace) => Icon(
        Symbols.hide_image_rounded,
        size: placeholderSize,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
