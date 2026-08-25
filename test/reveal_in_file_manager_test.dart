// The "open the containing folder" capability and the single gate that enforces it.
//
// Every reveal affordance in the app funnels through `PathEntity.launch()`, and
// whether it does anything is decided by `CurrentPlatform.canRevealInFileManager()`.
// Neither had any coverage: the platform predicates in `const.dart` could be
// inverted without a single failing test, and the web gate existed at exactly one
// of the four call sites, which is how a browser ended up with clickable buttons
// that opened nothing.
//
// Scope note: the VM reports `kIsWeb == false`, so the `isWeb()` term of the
// capability cannot be exercised here. The tests below drive the *other* term
// (`isDesktop()`) instead, which reaches the same false branch of the same gate --
// a mobile target and a browser are indistinguishable to `launch()`.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/reveal_in_file_manager_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/const.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel("plugins.flutter.io/url_launcher");
  late List<MethodCall> shellCalls;
  late bool shellResult;

  setUp(() {
    shellCalls = <MethodCall>[];
    shellResult = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      shellCalls.add(call);
      return shellResult;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  FilePath probePath() => FilePath(File("reveal_probe.txt").absolute.path);

  group("canRevealInFileManager", () {
    const withFileManager = [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS];
    const withoutFileManager = [TargetPlatform.android, TargetPlatform.iOS];

    for (final platform in withFileManager) {
      test("is true on $platform", () {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.canRevealInFileManager(), isTrue);
        // The capability is defined as a delegation; keep it one decision.
        expect(CurrentPlatform.canRevealInFileManager(), CurrentPlatform.hasWindowFrame());
      });
    }

    for (final platform in withoutFileManager) {
      test("is false on $platform", () {
        debugDefaultTargetPlatformOverride = platform;
        expect(CurrentPlatform.canRevealInFileManager(), isFalse);
        expect(CurrentPlatform.canRevealInFileManager(), CurrentPlatform.hasWindowFrame());
      });
    }
  });

  group("PathEntity.launch", () {
    test("asks the shell to open the path where there is a file manager", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await probePath().launch();
      expect(shellCalls, hasLength(1));
      expect(shellCalls.single.method, "launch");
      expect((shellCalls.single.arguments as Map)["url"], startsWith("file:"));
    });

    test("returns without touching the shell where there is none", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await probePath().launch();
      expect(shellCalls, isEmpty);
    });

    test("reports a shell that refuses, so awaiting callers can surface it", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      shellResult = false;
      await expectLater(probePath().launch(), throwsA(isA<FileSystemException>()));
    });

    test("launchQuietly swallows that refusal instead of raising a second error", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      shellResult = false;
      await probePath().launchQuietly();
      expect(shellCalls, hasLength(1));
    });

    test("launchQuietly is also a no-op where there is no file manager", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await probePath().launchQuietly();
      expect(shellCalls, isEmpty);
    });
  });
}
