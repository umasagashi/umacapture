import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

final _consoleLogger = Logger(
  level: kDebugMode ? Level.trace : Level.info,
  filter: ProductionFilter(),
  printer: PrettyPrinter(
    printEmojis: false,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    lineLength: 80,
    colors: false,
    // On web (dart2js), StackTrace.current is a V8-format stack whose first line
    // is the literal "Error", degrading the default header into a bare "#0 Error";
    // suppress the method trace there while keeping it on desktop.
    methodCount: kIsWeb ? 0 : 2,
  ),
);

SentryLevel _toSentryLevel(Level level) {
  switch (level) {
    case Level.trace:
    case Level.debug:
      return SentryLevel.debug;
    case Level.info:
      return SentryLevel.info;
    case Level.warning:
      return SentryLevel.warning;
    case Level.error:
      return SentryLevel.error;
    case Level.fatal:
      return SentryLevel.fatal;
    default:
      return SentryLevel.info;
  }
}

/// Where an assembled breadcrumb goes. See [debugBreadcrumbSink].
typedef BreadcrumbSink = void Function(Level level, String message, dynamic error);

/// The real sink: Sentry's breadcrumb ring, which rides along with every event this app sends.
void _sentryBreadcrumbSink(Level level, String message, dynamic error) {
  // A hub that was never initialised (a test, a build with no DSN) has nowhere to put this.
  if (!HubAdapter().isEnabled) return;
  Sentry.addBreadcrumb(
    Breadcrumb(
      message: message,
      level: _toSentryLevel(level),
      category: 'log',
      timestamp: DateTime.now().toUtc(),
      data: error == null ? null : {'error': error.toString()},
    ),
  );
}

/// The sink [AppLogger] hands finished breadcrumbs to. **Replaced by tests, never in production.**
///
/// A seam rather than a direct call because the boundary it names is the one that matters for
/// privacy: **every** `logger.d/i/w/e/wtf` line becomes a breadcrumb, and a breadcrumb leaves the
/// machine with the next event. Which strings are allowed through that boundary is therefore a
/// property a test has to be able to observe — and without this seam it cannot, because
/// `Sentry.addBreadcrumb` silently does nothing when no hub is running, so a suite would assert
/// against an empty list and pass no matter what the code logged.
///
/// See `test/video_import_breadcrumb_privacy_test.dart`, which drives the real import front end and
/// asserts the user's clip name reaches no breadcrumb by any route.
@visibleForTesting
BreadcrumbSink debugBreadcrumbSink = _sentryBreadcrumbSink;

/// The stand-in for the part of a path that is the app's own root.
///
/// Distinct from [_redacted] on purpose: `<app>\chara_detail\active\<id>\` still says *where inside
/// the app's own tree* the file was, which is the whole diagnostic value of these lines, while
/// `<redacted>\` says only "somewhere on this machine".
const _appRoot = '<app>';

/// The stand-in for a directory that is **not** under any app root — i.e. a place the user chose.
const _redacted = '<redacted>';

/// What it takes for a string to be a filesystem *root* this pass can recognise: a drive letter or a
/// UNC host, followed by a separator. The same definition [_absoluteDirectoryPrefix] uses for the
/// start of a path, kept as its own pattern so [registerAppRoots] can refuse anything the matcher
/// would never meet.
///
/// This is what keeps web out of it without a `kIsWeb` branch: the web platform-dir backend returns
/// **virtual** roots (`''`, `'umacapture'` — see `fs/platform_dirs_web.dart`), which are not rooted
/// by this definition and so register as nothing. An empty root that did register would prefix-match
/// every string in the app.
final _filesystemRoot = RegExp(r'^(?:[A-Za-z]:|\\\\[^\\/:*?"<>|\r\n]+)[\\/]');

/// The app's own root directories, canonicalised and ordered **longest first**, or empty until
/// [registerAppRoots] runs. See [withoutUserPaths] for what "empty" means for the redaction.
List<String> _appRoots = const <String>[];

/// [path] folded to the form roots are compared in: separators unified and case dropped (Windows
/// paths are case-insensitive and a log line may quote either casing), trailing separators removed.
///
/// Length-preserving except for the trailing separators it drops, which is what lets a caller index
/// back into the **original** string with an offset measured on the canonical one.
String _canonicalise(String path) {
  var canonical = path.replaceAll(r'\', '/').toLowerCase();
  while (canonical.length > 1 && canonical.endsWith('/')) {
    canonical = canonical.substring(0, canonical.length - 1);
  }
  return canonical;
}

/// Declares the directories that belong to the app, so [withoutUserPaths] can name them `<app>`
/// instead of destroying them.
///
/// Called from `pathInfoLoader` with `PathInfo.appOwnedRoots`, which is the one place in the app that
/// resolves a layout. It is a **whole replacement**, not an addition, so re-resolving a layout (a
/// data-root migration, a test) cannot leave a stale root behind.
///
/// Two kinds of root are refused rather than stored, and only one of them is load bearing:
///
/// * **Not rooted at all** — the web backend's virtual roots, one of which is the empty string.
///   Redundant in practice: a relative root can never prefix an absolute path, and the empty one
///   cannot either because the match also requires a `/` at the root's own length. Kept because it
///   states what a root is, and because that second mechanism is not what this function is about.
/// * **Rooted and nothing more** — a bare drive (`C:\`) or UNC host. `dataRoot` comes from a
///   hand-edited file or an environment variable and is checked only for being absolute and
///   existing (`bootstrap.dart`), so `C:\` reaches here. Accepting it would put `<app>` in front of
///   `\Users\<account>\` and publish the account name **as the relative part that is deliberately
///   kept** — the redaction turned inside out. A drive is not a directory anyone owns.
///
/// The residual limit, named rather than defended against: a root that is real but sits *above* the
/// user's profile directory (`C:\Users` as a data root) would still do that. Nothing here can tell
/// which segment is the account name.
void registerAppRoots(Iterable<String> roots) {
  final canonical = <String>{};
  for (final root in roots) {
    final rooted = _filesystemRoot.matchAsPrefix(root);
    if (rooted == null || rooted.end >= root.length) continue;
    canonical.add(_canonicalise(root));
  }
  // Longest first, so a data root nested inside the documents directory wins over the directory that
  // contains it and the reported path keeps the deeper, more informative relative part.
  _appRoots = List.unmodifiable(canonical.toList()..sort((a, b) => b.length.compareTo(a.length)));
}

/// The directory part of an absolute filesystem path, from its root through the **last** separator.
///
/// Rooted at a drive letter (`C:\`, `C:/`) or a UNC host (`\\host\`), then every segment that is
/// followed by another separator. The leaf is deliberately left alone: it is what [withoutSecrets]'s
/// exact substitution is given, and cutting it here as well would take the file's own name out of
/// diagnostics that are allowed to say which file failed once the caller has judged the name safe.
///
/// A segment may contain spaces (`C:\Users\hazuki\Videos\`), so segments are bounded by the
/// separators around them and by the characters Windows forbids in a name (`:*?"<>|`) — never by
/// whitespace, which would leave `C:\Users\hazuki\` standing in front of any path with a space in it.
/// `<` and `>` being excluded is also what stops a second pass from eating a `<redacted>` the first
/// pass wrote.
///
/// The lookbehind is load bearing: without it `https://example.com/a/` is a match starting at the
/// `s`, and every URL in every diagnostic would be destroyed.
final _absoluteDirectoryPrefix = RegExp(
  r'(?<![A-Za-z])(?:[A-Za-z]:|\\\\[^\\/:*?"<>|\r\n]+)[\\/](?:[^\\/:*?"<>|\r\n]*[\\/])*',
);

/// [text] with every occurrence of each of [secrets] replaced by `<redacted>`, **and** with every
/// absolute path in it put through [withoutUserPaths].
///
/// For diagnostics that are assembled somewhere this side does not own — the Windows runner's
/// `startVideoImport failed: <what()>`, a JSON parse error that quotes its input, a plugin exception
/// that names the file it could not open — and then logged, i.e. sent.
///
/// **Two mechanisms, because the first one alone is defeated by an encoding.** The caller knows
/// exactly which strings must not travel, so [secrets] is an exact substitution and not a heuristic.
/// But an exact substitution only matches text that arrived unchanged, and the producers on this
/// path do change it: `native/src/core/native_api_messages.h` dumps an exception's `what()` with the
/// U+FFFD replacement handler, because a Japanese Windows produces CP932 there and a strict dump
/// would throw away the terminal message the import is waiting for. A CP932 clip name therefore
/// arrives as replacement characters and matches no secret — **while the ASCII directory in front of
/// it (`C:\Users\<person>\Videos\`) arrives intact and names the user.** So the directory is removed
/// structurally, by shape, with no dependency on the caller having the right string.
///
/// Limits, stated rather than implied: a **relative** path is not touched (it names no one), and a
/// leaf that arrived transformed still gets through — but a leaf the producer mangled is already
/// unreadable, and an unmangled one is what [secrets] is for.
///
/// An empty secret is skipped: `replaceAll('', …)` splices the placeholder between every character,
/// so a caller that passed a name it did not have would otherwise destroy the message it was trying
/// to keep.
String withoutSecrets(String text, Iterable<String> secrets) {
  var redacted = text;
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    redacted = redacted.replaceAll(secret, _redacted);
  }
  // After the exact pass, not before: a secret that is a whole absolute path should be recognised as
  // that secret, rather than arriving here as a directory plus an orphaned leaf.
  return withoutUserPaths(redacted);
}

/// The replacement for one matched directory run. Never throws: see [withoutUserPaths].
String _replaceDirectoryRun(Match match) {
  final run = match[0]!;
  // The trailing separator is kept so the result still reads as a path with its directory removed,
  // rather than as a placeholder glued to a file name.
  final separator = run.substring(run.length - 1);
  try {
    final canonical = _canonicalise(run);
    for (final root in _appRoots) {
      if (canonical == root) return '$_appRoot$separator';
      if (canonical.length > root.length && canonical.startsWith(root) && canonical[root.length] == '/') {
        // Indexing the *original* run by an offset measured on the canonical one is sound because
        // _canonicalise only lowercases and swaps separators — both length-preserving — before
        // trimming the tail. The remainder therefore keeps its real casing and its real separators.
        return '$_appRoot${run.substring(root.length)}';
      }
    }
  } catch (_) {
    // Degrade towards *more* redaction, never towards less, and only for this one run: the rest of
    // the sentence is untouched, so the diagnostic survives even when this branch is wrong.
    return '$_redacted$separator';
  }
  return '$_redacted$separator';
}

/// [text] with every absolute filesystem path in it stripped of the part that names the user.
///
/// A path under one of the roots [registerAppRoots] was given keeps everything below that root and
/// loses only the root itself (`…\umacapture\chara_detail\active\7\record.json` becomes
/// `<app>\chara_detail\active\7\record.json`). Every other absolute path loses its whole directory
/// and keeps its leaf, exactly as before this existed.
///
/// **Why the app's own root is a token rather than a deletion.** On Windows the root of every
/// app-managed directory sits under `C:\Users\<account>\`, and the account name is the user's own
/// name often enough to treat it as one. But the position *inside* the app's tree is what a
/// diagnostic is for — which record, whether it was active or archived, whether the module install
/// went to the relocated data root — and deleting the directory outright throws that away to protect
/// something that is no longer there.
///
/// **Before any root is registered, everything falls to `<redacted>`.** Logs are written long before
/// `pathInfoLoader` resolves (the bootstrap layer logs an unusable data root; a plugin can fail
/// during startup), and this must neither block on the layout nor wait for it. The unresolved state
/// is therefore the *safe* one, not a hole: it redacts more, not less. The cost is that a startup
/// diagnostic reads `<redacted>\data_root.json` rather than `<app>\data_root.json`.
///
/// **Idempotent.** `<app>` and `<redacted>` contain no drive root, and `<` / `>` are excluded from
/// [_absoluteDirectoryPrefix]'s segment class, so a second pass over an already-scrubbed string
/// matches nothing. That is what lets [AppLogger] scrub unconditionally even though several callers
/// have already been through [withoutSecrets].
String withoutUserPaths(String text) => text.replaceAllMapped(_absoluteDirectoryPrefix, _replaceDirectoryRun);

class AppLogger {
  static const _maxBreadcrumbMessageLength = 1000;

  void v(dynamic message, [dynamic error, StackTrace? stackTrace]) => log(Level.trace, message, error, stackTrace);

  void d(dynamic message, [dynamic error, StackTrace? stackTrace]) => log(Level.debug, message, error, stackTrace);

  void i(dynamic message, [dynamic error, StackTrace? stackTrace]) => log(Level.info, message, error, stackTrace);

  void w(dynamic message, [dynamic error, StackTrace? stackTrace]) => log(Level.warning, message, error, stackTrace);

  void e(dynamic message, [dynamic error, StackTrace? stackTrace]) => log(Level.error, message, error, stackTrace);

  void wtf(dynamic message, [dynamic error, StackTrace? stackTrace]) => log(Level.fatal, message, error, stackTrace);

  void log(Level level, dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _consoleLogger.log(level, message, error: error, stackTrace: stackTrace);
    if (level != Level.trace) {
      _addBreadcrumb(level, message, error);
    }
  }

  /// Assembles one breadcrumb and hands it to [debugBreadcrumbSink].
  ///
  /// **This is the only place a breadcrumb is built**, so it is where the filesystem scrub belongs:
  /// every `logger.d/i/w/e/wtf` line in the app reaches Sentry through here, and there are of the
  /// order of forty that interpolate an absolute path. Scrubbing here covers all of them without
  /// editing one, and covers the ones written after this too — which is the only version of this fix
  /// that stays true, since a list of call sites is out of date the moment someone adds a log line.
  ///
  /// **Both arguments are scrubbed, because both are sent.** [_sentryBreadcrumbSink] serialises
  /// `error.toString()` into the breadcrumb's `data`, and a `FileSystemException`'s `toString` quotes
  /// the absolute path it failed on. The scrubbed text is passed *in place of* the object so the
  /// seam a test observes carries exactly what would be sent, rather than the object it came from.
  void _addBreadcrumb(Level level, dynamic message, dynamic error) {
    final String text;
    final String? detail;
    try {
      var scrubbed = withoutUserPaths(message?.toString() ?? '');
      if (scrubbed.length > _maxBreadcrumbMessageLength) {
        // The truncation happens above the sink, not below it, so a test observing the sink sees
        // exactly the text that would have been sent rather than the text before it was cut. After
        // the scrub, not before, so the cut spends its budget on text that is going to be sent.
        scrubbed = '${scrubbed.substring(0, _maxBreadcrumbMessageLength)}...';
      }
      text = scrubbed;
      detail = error == null ? null : withoutUserPaths(error.toString());
    } catch (_) {
      // The console line has already been written, so the developer running the app still has the
      // full text; what is lost here is one breadcrumb's content, not the diagnostic. Sending a
      // marker rather than nothing keeps the *fact* that a line was logged, and sending the marker
      // rather than the raw text is the only choice that cannot leak while failing.
      debugBreadcrumbSink(level, '<breadcrumb redaction failed>', null);
      return;
    }
    debugBreadcrumbSink(level, text, detail);
  }
}

final logger = AppLogger();

// riverpod 3 made ProviderObserver a `base` class and reshaped didUpdateProvider
// to receive a ProviderObserverContext instead of (provider, container).
base class ProviderLogger extends ProviderObserver {
  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) {
    final provider = context.provider;
    final String p = previousValue.toString();
    final String n = newValue.toString();
    const limit = 300;
    logger.v(
      "provider: ${provider.name ?? provider.runtimeType}, "
      "value: ${p.length < limit ? p : "${p.substring(0, limit)}..."}"
      " -> ${n.length < limit ? n : "${n.substring(0, limit)}..."}",
    );
  }
}
