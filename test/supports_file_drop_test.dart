// The "files can be dropped on the window" capability.
//
// The manual module-update dialog used to gate its drop zone on
// `CurrentPlatform.hasWindowFrame() || CurrentPlatform.isWeb()` -- an inline
// disjunction that reached past the capability layer to name a platform. It is
// now `CurrentPlatform.supportsFileDrop()`, and these tests hold the folded
// predicate to the truth values of the expression it replaced.
//
// Scope note: `isWeb()` is `kIsWeb`, a compile-time constant that is false under
// `flutter test` on the VM and is not injectable, so NO behavioural case here can
// drive the web axis. The platform-driven cases pin the `isDesktop()` axis only.
//
// The web term is therefore pinned the one way that is left: by reading
// `lib/const.dart` as text and requiring `supportsFileDrop`'s body to name
// `isWeb`. That is a weaker instrument than driving the function and it is
// written down as one -- but it does exclude the implementations that matter
// (`return isDesktop();`, `return hasWindowFrame();`, `return false;`), each of
// which takes the drop zone away in a browser with nothing else in this suite
// noticing. An algebraic case used to stand here instead; it re-implemented both
// sides of the fold as local closures and compared them to each other, so it was
// true by boolean algebra for every implementation of `supportsFileDrop`,
// including a constant `false`. It has been removed rather than reworded.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/supports_file_drop_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/const.dart';

/// The source of `lib/const.dart`, read as text.
const _constSourcePath = 'lib/const.dart';

/// The body of the `static bool <name>()` method declared in [_constSourcePath].
///
/// Throws rather than returning null when the method is not found: "the method moved" is not
/// "the method has no web term", and a case that tolerated it would pass on a file it never read.
String _methodBody(String name) {
  final source = File(_constSourcePath).readAsStringSync();
  final start = source.indexOf('static bool $name() {');
  if (start < 0) {
    throw StateError('$_constSourcePath declares no `static bool $name()`; this guard read nothing');
  }
  final open = source.indexOf('{', start);
  final close = source.indexOf('}', open);
  if (close < 0) {
    throw StateError('could not find the end of `$name` in $_constSourcePath');
  }
  return source.substring(open + 1, close).trim();
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('supportsFileDrop', () {
    const withDropSurface = [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS];
    const withoutDropSurface = [TargetPlatform.android, TargetPlatform.iOS];

    for (final platform in withDropSurface) {
      test('is true on $platform', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.supportsFileDrop(), isTrue);
      });
    }

    for (final platform in withoutDropSurface) {
      test('is false on $platform', () {
        debugDefaultTargetPlatformOverride = platform;
        // Mobile has no drop surface, and must not inherit one from the fact
        // that a browser does.
        expect(CurrentPlatform.supportsFileDrop(), isFalse);
      });
    }

    for (final platform in [...withDropSurface, ...withoutDropSurface]) {
      test('matches the expression the dialog used to inline, on $platform', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.supportsFileDrop(), CurrentPlatform.hasWindowFrame() || CurrentPlatform.isWeb());
      });
    }

    test('still names the web term the VM cannot drive', () {
      // `debugDefaultTargetPlatformOverride` moves the host OS, never `kIsWeb`, so an
      // implementation that dropped the web term would answer identically to this one on
      // every platform above. Read from the source instead.
      final body = _methodBody('supportsFileDrop');
      expect(body, isNotEmpty, reason: 'the body came back empty; this case is looking at nothing');
      expect(
        body,
        contains('isWeb'),
        reason: 'supportsFileDrop no longer consults isWeb, so a browser gets no drop zone',
      );
      // The negative control for the reader above: the same extractor on the neighbouring
      // capability must NOT report a web term, or `contains` is matching the whole file.
      expect(
        _methodBody('canRevealInFileManager'),
        isNot(contains('isWeb')),
        reason: 'the extractor is not reading one method; the assertion above proves nothing',
      );
    });

    test('canRevealInFileManager is a separate decision, and is answered on the same hosts', () {
      // The two capabilities differ on exactly one input -- a browser can receive a drop but has
      // no file manager to reveal into -- and that input is the one the VM cannot drive. So this
      // does NOT check that they differ; it pins their absolute values on the hosts it can reach,
      // in both directions, and the source case above carries the web term.
      for (final platform in withDropSurface) {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.supportsFileDrop(), isTrue, reason: '$platform');
        expect(CurrentPlatform.canRevealInFileManager(), isTrue, reason: '$platform');
      }
      for (final platform in withoutDropSurface) {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.supportsFileDrop(), isFalse, reason: '$platform');
        expect(CurrentPlatform.canRevealInFileManager(), isFalse, reason: '$platform');
      }
    });
  });
}
