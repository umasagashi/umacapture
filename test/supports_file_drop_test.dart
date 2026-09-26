// The "files can be dropped on the window" capability.
//
// The manual module-update dialog gates its drop zone on
// `CurrentPlatform.supportsFileDrop()`: true on the desktop hosts and in a
// browser, false on mobile.
//
// `isWeb()` is `kIsWeb`, a compile-time constant that is false under
// `flutter test` on the VM and is not injectable. The web term is therefore
// driven through `supportsFileDropFor(web:)`, which `supportsFileDrop()` calls
// with `isWeb()`; the cases below pin its truth value for both values of `web`
// on every host, and the host axis through `debugDefaultTargetPlatformOverride`.
// That the wrapper passes `isWeb()` rather than a constant cannot be driven on
// the VM and is not checked here.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/supports_file_drop_test.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/const.dart';

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
      test('is the union of hasWindowFrame and isWeb, on $platform', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.supportsFileDrop(), CurrentPlatform.hasWindowFrame() || CurrentPlatform.isWeb());
      });
    }

    for (final platform in [...withDropSurface, ...withoutDropSurface]) {
      test('is true in a browser on $platform', () {
        // A browser offers a drop zone whatever the host OS, mobile included.
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.supportsFileDropFor(web: true), isTrue);
      });
    }

    for (final platform in [...withDropSurface, ...withoutDropSurface]) {
      test('outside a browser follows the host on $platform', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.supportsFileDropFor(web: false), withDropSurface.contains(platform));
      });
    }

    test('canRevealInFileManager is a separate decision, and is answered on the same hosts', () {
      // The two capabilities differ on exactly one input -- a browser can receive a drop but has
      // no file manager to reveal into -- and that input is the one the VM cannot drive through
      // `canRevealInFileManager`. So this pins their absolute values on the hosts it can reach, in
      // both directions; the browser cases above carry the web term of `supportsFileDrop`.
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
