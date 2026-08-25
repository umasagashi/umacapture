import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/sentry_util.dart';

/// The account name that must never leave the machine. On Windows every app-managed directory sits
/// under `C:\Users\<account>\`, and the account name is the person's own name often enough to treat
/// it as one — which is what makes a log line that quotes an absolute path a privacy defect rather
/// than a cosmetic one.
const _account = 'hazuki';

/// The three roots `pathInfoLoader` registers on Windows, spelled the way `path_provider` returns
/// them. `PathInfo.documentDir` already has the app name appended, `supportDir` is the vendor/app
/// pair, and `executableDir` is wherever the installer put the exe.
const _documentRoot = r'C:\Users\hazuki\Documents\umacapture';
const _supportRoot = r'C:\Users\hazuki\AppData\Roaming\umasagashi\umacapture';
const _executableRoot = r'C:\Users\hazuki\AppData\Local\umacapture';

/// A place the app does not own: the user's own video folder, which is where an imported clip comes
/// from, and the OS downloads folder, which is where an export goes.
const _videoDirectory = r'C:\Users\hazuki\Videos\';
const _downloadsDirectory = r'C:\Users\hazuki\Downloads\';

const _japaneseLeaf = '育成記録.mkv';

/// [_japaneseLeaf] as CP932, which is what an exception's `what()` carries on a Japanese Windows.
/// Written as bytes rather than as a codec call because Dart ships no CP932 decoder — and the bytes
/// are the honest fixture anyway. Same fixture as `video_import_breadcrumb_privacy_test.dart`.
const _cp932JapaneseLeaf = <int>[0x88, 0xE7, 0x90, 0xAC, 0x8B, 0x4C, 0x98, 0x5E, 0x2E, 0x6D, 0x6B, 0x76];

/// The transformation `native/src/core/native_api_messages.h` applies to a terminal message: decode
/// as UTF-8, replacing every malformed sequence with U+FFFD instead of throwing.
String _asIfDumpedWithReplacement(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

/// Registers the layout a Windows install actually resolves.
void _registerWindowsLayout() => registerAppRoots(const [_documentRoot, _supportRoot, _executableRoot]);

void main() {
  setUp(_registerWindowsLayout);
  // Whole-replacement semantics double as the reset: the next test starts with no roots at all,
  // which is also the state the app is in before `pathInfoLoader` resolves.
  tearDown(() => registerAppRoots(const <String>[]));

  group('a path inside the app keeps everything below the root and loses only the root', () {
    test('the position inside the app tree survives, and the account name does not', () {
      const line =
          'Failed to load record.json. '
          r'path=C:\Users\hazuki\Documents\umacapture\storage\chara_detail\active\7\record.json';

      final scrubbed = withoutUserPaths(line);

      expect(scrubbed, contains(r'<app>\storage\chara_detail\active\7\record.json'));
      expect(scrubbed, isNot(contains(_account)));
      expect(scrubbed, isNot(contains(r'C:\Users')));
      // Redacted, not deleted. A pass that returned the empty string would satisfy every assertion
      // above and destroy every diagnostic in the app.
      expect(scrubbed, startsWith('Failed to load record.json. path='));
    });

    test('a file directly in the root reads as <app> plus its own name', () {
      expect(withoutUserPaths('$_documentRoot\\data_root.json'), r'<app>\data_root.json');
    });

    test('the support root and the executable root are app roots too, not just the document one', () {
      expect(withoutUserPaths('$_supportRoot\\modules\\chara_detail.onnx'), r'<app>\modules\chara_detail.onnx');
      expect(withoutUserPaths('$_executableRoot\\unins000.exe'), r'<app>\unins000.exe');
    });

    test('casing and separator style do not decide it, because a log line may quote either', () {
      // Windows paths are case-insensitive and several producers here emit forward slashes (the
      // native core, `package:path` on a joined URI). Matching only the exact spelling would make
      // the redaction depend on which producer wrote the line.
      const line = 'c:/users/HAZUKI/Documents/UMACAPTURE/storage/sound/ping.wav';

      final scrubbed = withoutUserPaths(line);

      expect(scrubbed, '<app>/storage/sound/ping.wav');
      expect(scrubbed.toLowerCase(), isNot(contains(_account)));
    });

    test('the deepest matching root wins, so a relocated data root is not reported relative to its parent', () {
      // `PathInfo.dataRoot` may sit inside the documents directory. Matching the shorter root first
      // would publish `<app>\umacapture-data\storage\…`, which is right but says less.
      const dataRoot = '$_documentRoot\\relocated';
      registerAppRoots(const [_documentRoot, _supportRoot, dataRoot]);

      expect(withoutUserPaths('$dataRoot\\storage\\a.png'), r'<app>\storage\a.png');
    });
  });

  group('a path outside the app loses its whole directory, exactly as before', () {
    test("the user's own clip keeps its name and nothing in front of it", () {
      final scrubbed = withoutUserPaths('Failed to open: $_videoDirectory$_japaneseLeaf');

      expect(scrubbed, 'Failed to open: <redacted>\\$_japaneseLeaf');
      expect(scrubbed, isNot(contains(_account)));
    });

    test('the downloads folder is deliberately not an app root', () {
      // It is the OS folder, not the app's: calling it `<app>` would be a lie, and keeping what sits
      // under it would publish the names of files the user chose.
      final scrubbed = withoutUserPaths(
        'exported to $_downloadsDirectory'
        'records.csv',
      );

      expect(scrubbed, 'exported to <redacted>\\records.csv');
      expect(scrubbed, isNot(contains('<app>')));
    });
  });

  group('a name the producer mangled is still handled, because the branch does not read the leaf', () {
    test('a CP932 clip name under the user own folder loses the directory that names them', () {
      final mangled = _asIfDumpedWithReplacement(_cp932JapaneseLeaf);
      expect(mangled, contains('\u{FFFD}'), reason: 'the fixture is not actually mangled; it proves nothing');

      final scrubbed = withoutUserPaths('the video import thread threw: Failed to open: $_videoDirectory$mangled');

      expect(scrubbed, isNot(contains(_account)));
      expect(scrubbed, isNot(contains('Videos')));
      expect(scrubbed, contains('<redacted>'));
      expect(scrubbed, contains('Failed to open'));
    });

    test('a CP932 name under the app root still resolves to <app>, mangled leaf and all', () {
      // The reason the `<app>` branch is worth having: it decides on the *directory*, which arrived
      // as ASCII, so a leaf the producer destroyed cannot take the diagnostic down with it.
      final mangled = _asIfDumpedWithReplacement(_cp932JapaneseLeaf);

      final scrubbed = withoutUserPaths('$_documentRoot\\storage\\sound\\$mangled');

      expect(scrubbed, '<app>\\storage\\sound\\$mangled');
      expect(scrubbed, isNot(contains(_account)));
    });

    test('a Japanese name that arrived intact is kept intact', () {
      expect(withoutUserPaths('$_documentRoot\\storage\\$_japaneseLeaf'), '<app>\\storage\\$_japaneseLeaf');
    });
  });

  group('before the layout is resolved, the safe side is the one it falls to', () {
    test('with no root registered every absolute path loses its directory outright', () {
      // Logs are written long before `pathInfoLoader` resolves — the bootstrap layer reports an
      // unusable data root, a plugin can fail during startup. This must neither block nor leak.
      registerAppRoots(const <String>[]);

      final scrubbed = withoutUserPaths('$_documentRoot\\storage\\a.png');

      expect(scrubbed, r'<redacted>\a.png');
      expect(scrubbed, isNot(contains(_account)));
    });

    test("the web backend's virtual roots register as nothing, and an empty root matches nothing", () {
      // `fs/platform_dirs_web.dart` resolves `''` and `'umacapture'`. An empty root stored as a
      // prefix would match every string in the app; a relative one would match none of the paths
      // this pass recognises anyway. Both are refused at registration.
      registerAppRoots(const ['', 'umacapture', 'modules']);

      expect(withoutUserPaths('$_documentRoot\\storage\\a.png'), r'<redacted>\a.png');
      expect(withoutUserPaths('nothing path-like here'), 'nothing path-like here');
    });

    test('a bare drive is refused, or <app> would be a prefix in front of the account name', () {
      // Reachable: `dataRoot` comes from a hand-edited `data_root.json` or an environment variable
      // and is only checked for being absolute and existing (`bootstrap.dart`), so `C:\` passes. If
      // it registered, every path on the drive would read `<app>\Users\hazuki\…` — the account name
      // published as the relative part the design deliberately keeps. The redaction inside out.
      registerAppRoots(const [r'C:\', '//', r'\\fileserver\']);

      final scrubbed = withoutUserPaths(r'C:\Users\hazuki\Videos\clip.mkv');

      expect(scrubbed, r'<redacted>\clip.mkv');
      expect(scrubbed, isNot(contains(_account)));
    });
  });

  group('what is NOT a path is left alone, so the scrub cannot eat diagnostics', () {
    test('URLs, relative paths and prose survive untouched', () {
      const url = 'download failed: https://example.com/a/b.json (404)';
      expect(withoutUserPaths(url), url);
      const relative = r'records\1234\skill.png could not be read';
      expect(withoutUserPaths(relative), relative);
      const prose = 'nothing path-like here, just prose about c: and a / slash';
      expect(withoutUserPaths(prose), prose);
      // OPFS virtual paths have no drive root and name nobody.
      const opfs = 'records/1234/skill.png was not harvested';
      expect(withoutUserPaths(opfs), opfs);
    });

    test('running it twice changes nothing, which is what lets the sink scrub unconditionally', () {
      // Several callers already went through `withoutSecrets`; `AppLogger` scrubs everything again.
      for (final line in <String>[
        '$_documentRoot\\storage\\a.png',
        'Failed to open: $_videoDirectory$_japaneseLeaf',
        'https://example.com/a/b.json',
      ]) {
        final once = withoutUserPaths(line);
        expect(withoutUserPaths(once), once, reason: 'a second pass moved: $line');
      }
    });
  });

  group('every breadcrumb is scrubbed at the one place they are all assembled', () {
    late List<(Level, String, dynamic)> sent;
    late BreadcrumbSink realSink;

    setUp(() {
      sent = [];
      realSink = debugBreadcrumbSink;
      debugBreadcrumbSink = (level, message, error) => sent.add((level, message, error));
    });
    tearDown(() => debugBreadcrumbSink = realSink);

    test('a log line nobody edited for this still reaches Sentry without the account name', () {
      // The point of the whole change: of the order of forty `logger` lines in `lib/` interpolate an
      // absolute path, and none of them was touched. This one stands in for all of them.
      logger.i('Archived record directory. from=$_documentRoot\\storage\\chara_detail\\active\\7');

      expect(sent, hasLength(1), reason: 'nothing was sent, so every assertion below is vacuous');
      expect(sent.single.$2, contains(r'<app>\storage\chara_detail\active\7'));
      expect(sent.single.$2, isNot(contains(_account)));
      expect(sent.single.$2, startsWith('Archived record directory.'));
    });

    test("the error argument is scrubbed too, because the sink serialises its toString", () {
      // `_sentryBreadcrumbSink` puts `error.toString()` into the breadcrumb's `data`, and a
      // `FileSystemException`'s `toString` quotes the path it failed on. Redacting only the message
      // would have left the same path travelling by the other route.
      logger.e('Failed to read.', FileSystemException('Cannot open file', '$_videoDirectory$_japaneseLeaf'));

      expect(sent, hasLength(1));
      expect('${sent.single.$3}', isNot(contains(_account)));
      expect('${sent.single.$3}', contains('<redacted>'));
      expect('${sent.single.$3}', contains('Cannot open file'), reason: 'redacted, not deleted');
    });

    test('an error that names nothing is still passed through, so the field does not just vanish', () {
      logger.e('Parse failed.', StateError('bad token at 3'));

      expect(sent, hasLength(1));
      expect('${sent.single.$3}', contains('bad token at 3'));
    });

    test('a null error stays null, so the breadcrumb carries no empty data map', () {
      logger.w('Nothing attached.');

      expect(sent, hasLength(1));
      expect(sent.single.$3, isNull);
    });

    test('trace is still the one level that never becomes a breadcrumb', () {
      logger.v('provider: something, value: $_documentRoot');

      expect(sent, isEmpty);
    });

    test('the scrub runs before the length cut, so the cut spends its budget on text that is sent', () {
      final long = '$_documentRoot\\storage\\${'a' * 2000}.png';

      logger.i(long);

      expect(sent.single.$2, startsWith(r'<app>\storage\'));
      expect(sent.single.$2, endsWith('...'));
      expect(sent.single.$2.length, 1003);
    });
  });

  group('an event is scrubbed where events converge, which is the only reach the six raw sites have', () {
    // `chara_detail_record.dart:505` and `:538`, `spec/loader.dart:723`, `spec/memo.dart:433`,
    // `version_check.dart:237` and `:271` hand a raw exception to `captureException`. None of them
    // was edited: the SDK builds the event's text from `exception.toString()`, so `beforeSend` is
    // the one place both they and every uncaught error pass through.
    test("a FileSystemException's own text loses the account name but keeps its type", () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'PathAccessException',
            value: "PathAccessException: Cannot open file, path = '$_documentRoot\\storage\\a.png' (OS Error: 5)",
          ),
        ],
      );

      final scrubbed = scrubUserPathsFromEvent(event);

      expect(scrubbed.exceptions?.single.value, contains(r'<app>\storage\a.png'));
      expect(scrubbed.exceptions?.single.value, isNot(contains(_account)));
      expect(scrubbed.exceptions?.single.value, contains('Cannot open file'), reason: 'redacted, not deleted');
      // Grouping is why the throwable is not wrapped: Sentry groups on the type, and a synthetic
      // wrapper class would collapse every redacted failure in the app into one issue.
      expect(scrubbed.exceptions?.single.type, 'PathAccessException');
    });

    test('a message event is scrubbed in all three of the places a message carries text', () {
      final event = SentryEvent(
        message: SentryMessage(
          'install failed at $_supportRoot\\modules',
          template: 'install failed at %s',
          params: ['$_supportRoot\\modules'],
        ),
      );

      final scrubbed = scrubUserPathsFromEvent(event);

      expect(scrubbed.message?.formatted, r'install failed at <app>\modules');
      expect(scrubbed.message?.template, 'install failed at %s');
      expect(scrubbed.message?.params, [r'<app>\modules']);
    });

    test('an event carrying neither is returned unchanged rather than refused', () {
      // Never drop: `beforeSend` returning null throws the whole report away, and a redaction that
      // silently costs the developer the report is worse than the leak it prevents.
      final event = SentryEvent();
      expect(scrubUserPathsFromEvent(event), same(event));
    });

    test('the wiring exists, which the suite cannot observe because no hub runs in a test', () {
      final source = File('lib/src/core/sentry_util.dart').readAsStringSync();
      // Both init paths, desktop and web.
      expect('options.beforeSend = sentryBeforeSend;'.allMatches(source), hasLength(2));
      expect(source, contains('return scrubUserPathsFromEvent(event);'));
    });
  });

  group('the roots are enumerated by the machine, at test time, because Flutter has no mirrors', () {
    // `dart:mirrors` does not exist in Flutter, so nothing can walk `PathInfo`'s fields at runtime.
    // The list in `appOwnedRoots` is therefore hand-written — and this reads the source so a base
    // directory added later cannot silently miss it.
    late String source;

    setUp(() => source = File('lib/src/core/providers.dart').readAsStringSync());

    /// Every `DirectoryPath` field declared on `PathInfo`. Fields, not getters: every getter in that
    /// class is derived from a field with `/`, so covering the fields covers the tree.
    Set<String> declaredBaseFields(String text) {
      final body = text.substring(text.indexOf('class PathInfo {'), text.indexOf('/// Resolves the app'));
      return RegExp(r'final DirectoryPath\??\s+(\w+);').allMatches(body).map((e) => e.group(1) ?? '').toSet();
    }

    test('the extractor really finds the fields, so a green run below means something', () {
      expect(declaredBaseFields(source), containsAll(<String>['documentDir', 'supportDir', 'executableDir']));
      expect(declaredBaseFields(source).length, greaterThanOrEqualTo(5));
      // And it is reading the class, not the whole file: a name from elsewhere must not appear.
      expect(declaredBaseFields(source), isNot(contains('tempDir')));
    });

    test('every base directory is either registered as an app root or excluded on the record', () {
      // The one exclusion, and why: `downloadDir` is the OS downloads folder. It belongs to the
      // user, so it falls through to `<redacted>` — see the doc comment on `appOwnedRoots`.
      const excluded = <String>{'downloadDir'};
      final registered = RegExp(r'List<DirectoryPath> get appOwnedRoots => \[([^\]]*)\]').firstMatch(source)?.group(1);
      expect(registered, isNotNull, reason: 'appOwnedRoots changed shape; this rule reads nothing now');

      for (final field in declaredBaseFields(source)) {
        if (excluded.contains(field)) continue;
        expect(registered, contains(field), reason: '$field is a base directory nobody registered or excluded');
      }
    });

    test('the exclusion list is not a way to opt everything out unnoticed', () {
      // A rule whose escape hatch is a set in the test file is only worth as much as the size of
      // that set. One entry, named, with a reason in the source it guards.
      expect(source, contains('[downloadDir] is deliberately **excluded**'));
    });
  });

  group('the file dialog failure no longer publishes whatever the plugin quoted', () {
    late String source;

    setUp(() => source = File('lib/src/core/video_import_io.dart').readAsStringSync());

    test('the picker catch redacts before it logs or publishes', () {
      expect(source, contains("withoutSecrets('\$error', const <String>[])"));
      expect(source, contains('message: detail'));
    });

    test('the raw interpolation is gone, and the scanner would see it if it came back', () {
      const leak = "message: '\$error'";
      expect(source, isNot(contains(leak)));
      // The scanner is not vacuous: it does find that spelling when it is there.
      expect('outcome: VideoImportOutcome(kind: k, $leak)', contains(leak));
    });
  });
}
