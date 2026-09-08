// THE CLIP'S FILE NAME MUST NOT LEAVE THE MACHINE, and the payload of the import error report is
// only half of that. `AppLogger.log` turns **every** line at debug level or above into a Sentry
// breadcrumb, and breadcrumbs ride along with the event `captureMessage` sends — so a log line that
// interpolates the file name publishes it just as surely as a report key would, on precisely the
// reports that matter most (an import that was refused, followed by a report about it).
//
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_breadcrumb_privacy_test.dart
//
// TWO GUARDS, because the two legs are not equally reachable.
//
//  1. `the Windows import front end` drives the real `startVideoImport` with a spy installed on
//     `debugBreadcrumbSink` and asserts the name reaches no breadcrumb. It enumerates nothing: it
//     watches the boundary the strings actually cross, so a log line added anywhere on that path
//     later — in any spelling, including a file name that arrived inside somebody else's exception
//     text — turns it red with no edit to this file. That matters, because the same claim is
//     written in this repository in a form no scan of `logger.` calls would find: the clip's name
//     is interpolated into `VideoFrameGrabException`'s message three files away
//     (`video_frame_grab_io.dart`'s `what`), and `error.toString()` is what a breadcrumb carries.
//
//  2. `the web import front end` reads `video_import_web.dart` as text. Not a choice, though the
//     reason is narrower than the one written here before: a browser suite DOES exist — the files
//     carrying `@TestOn('browser')` (`record_mutation_lock_web_test.dart`,
//     `storage_persistence_web_test.dart`), which CI runs in its own `Browser tests` job. That
//     runner is `dart test --platform chrome`, not `flutter test`, and the CI job's own comment
//     states the rule it imposes: "a suite that reaches package:flutter cannot be compiled by
//     `dart test`". `video_import_web.dart` imports `package:flutter/foundation.dart` (and reaches
//     more of the app through `wasm_worker_client.dart`), while `flutter test` cannot compile
//     `package:web` on the VM — so the file is compilable by neither runner as things stand, and
//     the leg is a read rather than a run. Moving it would mean severing its Flutter dependency
//     first, which is a change to the subject, not to this file.
//     The scan enumerates the file's `logger` calls mechanically and rules on each
//     interpolation inside them; it is weaker than (1) — it sees only what is written in that one
//     file, not what a value carries — and the gap is stated rather than papered over.
//
// A THIRD GUARD, on the other boundary. A breadcrumb is not the only thing that leaves with an
// event: `buildImportErrorReportScope` publishes `VideoImportOutcome.message` as `import.message`,
// and that message is written by a producer this side does not own — on Windows it is an exception's
// `what()` relayed by `video_import_session.h`, and the decoder that opens the clip builds one of
// those out of the path it failed on (`native/src/cv/video_loader.h`: `"Failed to open: " <<
// narrow_path`). `the import error report payload` drives the real front end with such a message and
// scans the whole finished scope, values and keys alike, for any fragment of the clip. It enumerates
// no keys: a value added to the report later is walked without an edit to this file.
//
// WHAT NONE OF THE THREE COVERS: `wasm_worker_client.dart` forwards the worker's own text into
// `logger` and into Sentry, and the VM cannot compile it (`dart:js_interop`); the browser runner
// cannot either, for the reason given under (2). The fourth group reads it, and reads it for a
// different property than the web import leg — not "does an interpolation name the clip" (none of
// them does; the name arrives as a *value*) but "is every read of the worker's text wrapped in the
// redaction". That question is answered by FOLLOWING the worker's values out of `Worker.onmessage`
// and `Worker.onerror` with a parser, not by knowing two spellings of a read: the previous rule
// matched `['msg']` and `errorEvent.message` and nothing else, so a third route into the worker's
// text was not a "read", was never asked to redact, and left the group green while the clip's name
// went out on a breadcrumb. See `_workerTextFlows`.
//
// A FIFTH GUARD, on the report's own plumbing rather than on the import. `Scope.addFile` runs
// *because* a report is being sent, and every file this app attaches lives under the user's Windows
// profile; it used to log the absolute path and hand the platform exception (whose `toString` quotes
// that path) to a breadcrumb and to `captureException` alike. `the report's own attachment` drives it
// for real with a probe that throws, and reads the catch for the one route a disabled hub hides.
//
// AND THE MECHANISM ALL OF THEM DEPEND ON: `withoutSecrets` is an exact substitution, so a name the
// producer transformed matches nothing. The `withoutSecrets` group pins the structural half that
// answers that — the directory of an absolute path goes by shape — with a CP932 clip name mangled to
// U+FFFD exactly the way `native/src/core/native_api_messages.h` mangles it. The clip's *leaf* is
// unreadable by then; the directory in front of it is not, and it is the part that names a person.
import 'dart:convert';
import 'dart:io';

// `analyzer` reaches this package transitively (through the codegen stack). Depended on here rather
// than promoted to a direct dev_dependency because pinning it would freeze the version the codegen
// packages resolve to, and this guard only ever needs the parser. Same arrangement as
// `disabled_tooltip_visibility_test.dart` and `sentry_scrub_event_test.dart`.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/video_import_io.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

import 'support/web_like_fs_backend.dart';

/// A clip whose name is a disclosure, not a serial number.
///
/// Deliberately not `clip.mp4`: the users this ruling protects are the ones whose recorder does not
/// choose the name for them, and a fixture named like a recorder's default would pass a build that
/// published the leaf verbatim. The directory names a person too, so a diagnostic that quoted only
/// the folder it failed in is caught as well.
const _leaf = 'Report for Dr Tanaka - salary review.mkv';
const _path = r'C:\Users\hazuki\Videos\Report for Dr Tanaka - salary review.mkv';

/// Every fragment of [_path] that identifies the user or the file. A breadcrumb containing any one
/// of them has leaked, whether or not it contains the whole path.
const _secrets = <String>[_path, _leaf, 'Report for Dr Tanaka - salary review', 'Tanaka', 'hazuki', r'C:\Users'];

/// A second clip, whose name is Japanese — the case the exact substitution cannot serve.
///
/// The directory is the same shape and the same person; only the leaf changes, because the leaf is
/// the part a producer's encoding can destroy and the directory is the part that survives intact.
const _japaneseDirectory = r'C:\Users\hazuki\Videos\';
const _japaneseLeaf = '育成記録.mkv';

/// [_japaneseLeaf] as CP932, which is what a `what()` carries on a Japanese Windows.
///
/// Written as the bytes rather than as a codec call because Dart ships no CP932 decoder — and the
/// bytes are the honest fixture anyway: this is what the runner hands the JSON dump.
const _cp932JapaneseLeaf = <int>[0x88, 0xE7, 0x90, 0xAC, 0x8B, 0x4C, 0x98, 0x5E, 0x2E, 0x6D, 0x6B, 0x76];

/// The same transformation `native/src/core/native_api_messages.h` applies to the terminal message:
/// decode as UTF-8, replacing every malformed sequence with U+FFFD instead of throwing.
String _asIfDumpedWithReplacement(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

/// Where a report's PNG actually lives on Windows. The leaf is this app's own (`takeScreenshot` and
/// the import dialog both mint `<kind>_<microsecondsSinceEpoch>.png`); everything in front of it is
/// the user's profile.
const _attachmentPath = r'C:\Users\hazuki\AppData\Local\Temp\video_frame_1.png';

/// The fragments of [_attachmentPath] that identify the person rather than the file.
const _attachmentSecrets = <String>['hazuki', r'C:\Users', 'AppData'];

typedef _Crumb = ({Level level, String message, String error});

/// What these cases announce to the long-read registry: nothing, and why.
///
/// They drive the front end's own state machine over a method channel, with no provider
/// container anywhere in reach; what the session holds is asserted in
/// `video_import_long_read_claim_test.dart`, which builds a real claim instead.
const _declaresNothing = LongReadDeclaration.none(
  reason: 'this suite drives the import front end directly; the registry is another suite\'s subject',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the Windows import front end sends no clip name to Sentry', () {
    final defaultSink = debugBreadcrumbSink;
    final defaultPicker = videoImportPathPicker;

    late List<_Crumb> crumbs;
    Future<Object?> Function(MethodCall call)? answer;

    setUp(() {
      crumbs = <_Crumb>[];
      answer = null;
      // The seam exists for exactly this. Without it `Sentry.addBreadcrumb` is a no-op in a suite
      // with no hub, so every assertion below would run against an empty list and pass whatever the
      // front end logged — the shape of vacuous guard this stage was sent to remove.
      debugBreadcrumbSink = (level, message, error) =>
          crumbs.add((level: level, message: message, error: error?.toString() ?? ''));
      videoImportPathPicker = () async => _path;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        (call) async => answer == null ? null : await answer!(call),
      );
    });

    tearDown(() async {
      debugBreadcrumbSink = defaultSink;
      videoImportPathPicker = defaultPicker;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        null,
      );
      debugResetVideoImport();
      await pumpEventQueue();
      debugResetVideoImport();
    });

    /// Asserts the run said *something* and that none of it names the clip.
    ///
    /// The emptiness check is not decoration: a case whose branch stopped logging would otherwise
    /// assert nothing at all and stay green forever.
    void expectSaidSomethingButNotTheName() {
      expect(crumbs, isNotEmpty, reason: 'no breadcrumb was produced, so this case asserted nothing');
      for (final crumb in crumbs) {
        final text = '${crumb.message}\n${crumb.error}';
        for (final secret in _secrets) {
          expect(
            text.contains(secret),
            isFalse,
            reason: 'a breadcrumb carries "$secret", which reaches Sentry with the next event: $text',
          );
        }
      }
    }

    test('a refusal names the container and the gate, and neither is the file name', () async {
      var asked = 0;
      await startVideoImport(
        declaration: _declaresNothing,
        preflight: () => asked++ == 0 ? null : VideoImportBlocker.regenerating,
      );

      expectSaidSomethingButNotTheName();
      // The other half of the ruling, and it is what stops "delete the log line" from passing: the
      // clip's *attributes* may travel, so the line still has to say which container failed.
      final text = crumbs.map((crumb) => crumb.message).join('\n');
      expect(text, contains('mkv'), reason: 'the container is publishable and is what makes the line useful');
      expect(text, contains('regenerating'));
    });

    test('a runner that quotes the path back in its error does not get it published', () async {
      // THE CASE THE SIMPLE FIX MISSES. `native_controller.h` parses the request — which holds the
      // path — before the session is started, and `video_import_session.h` answers
      // `"startVideoImport failed: " + e.what()`. Whether some `what()` three layers down quotes
      // the file is not a fact this side can check, so the text is redacted rather than trusted.
      answer = (call) => throw PlatformException(
        code: 'json',
        message: 'startVideoImport failed: parse error while reading {"path":"$_path"}',
      );

      await startVideoImport(declaration: _declaresNothing, preflight: () => null);

      expectSaidSomethingButNotTheName();
      // Redacted, not dropped: the reader still learns the runner refused and why.
      final errors = crumbs.map((crumb) => crumb.error).join('\n');
      expect(errors, contains('startVideoImport failed'));
      expect(errors, contains('<redacted>'));
    });

    test('a stray terminal message is reported without the import it belongs to naming the clip', () async {
      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportDone', 'reason': 'completed', 'message': ''});

      expectSaidSomethingButNotTheName();
    });

    test('a stray terminal message publishes nothing the producer wrote, whatever field it wrote it in', () async {
      // THE CASE THE READING GUARDS CANNOT SEE, and the one that caught the real leak. A scan of the
      // interpolations in this file rules on the *identifier* (`message`), which says nothing at all
      // about what the value holds; this drives the boundary and rules on the text that crosses it.
      //
      // Every value of the payload is the producer's own sentence, including a field this build does
      // not know: the rule is "nothing the producer wrote is republished", not "these named fields
      // are redacted". A field added to `native_api_messages.h` later is covered with no edit here.
      // `videoImportDone` is the reachable case (`videoImportHandleNativeEvent` logs only that one),
      // and it is reachable exactly when a clip fails to open — which is when `message` is
      // `"Failed to open: <path>"`.
      const producerText = 'the video import thread threw: Failed to open: $_path';
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportDone',
        'reason': producerText,
        'reasonKind': producerText,
        'message': producerText,
        'matrixConverted': producerText,
        'somethingTheRunnerStartedSendingLater': producerText,
      });

      expectSaidSomethingButNotTheName();
    });

    test('a dropped terminal message still says which ending was dropped', () async {
      // The other half of the ruling, and what stops "delete the line" from passing: a terminal
      // message the two sides disagree about is worth reporting, and the discriminators are the
      // app's own closed vocabulary rather than anything a producer composed.
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportDone',
        'reason': 'failed',
        'reasonKind': 'file_unreadable',
        'message': 'the video import thread threw: Failed to open: $_path',
      });

      expectSaidSomethingButNotTheName();
      final text = crumbs.map((crumb) => crumb.message).join('\n');
      expect(text, contains('failed'), reason: 'the line no longer says how the dropped import ended');
      expect(text, contains('file_unreadable'), reason: 'the named cause is publishable and is the useful part');
    });

    test('an import that simply worked logs nothing at all', () async {
      // Stated rather than assumed: the happy path is silent, so the cases above are the whole of
      // what this leg can publish about a clip.
      final running = startVideoImport(declaration: _declaresNothing, preflight: () => null);
      await pumpEventQueue();
      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportStarted'});
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportDone',
        'reason': 'completed',
        'decoded': 10,
        'supplied': 10,
        'rejected': 0,
        'durationMs': 1000,
        'matrixConverted': '',
        'message': '',
      });
      await running;

      expect(crumbs, isEmpty);
      // The name is still *read* — the label the user sees, and the report's correlation check.
      // Comparing and publishing are different acts, and removing the first would be a bug.
      expect(videoImportState.value.fileName, _leaf);
    });
  });

  group('withoutSecrets', () {
    test('an empty secret is skipped rather than spliced between every character', () {
      // `replaceAll('', x)` inserts x at every position. A caller that passed a name it did not have
      // would otherwise destroy the diagnostic it was trying to keep.
      expect(withoutSecrets('open failed', <String>['']), 'open failed');
      expect(withoutSecrets('open failed', <String>[]), 'open failed');
    });

    test('every occurrence goes, not just the first, and the rest of the sentence survives', () {
      expect(
        withoutSecrets('could not open a.mkv; a.mkv is locked', <String>['a.mkv']),
        'could not open <redacted>; <redacted> is locked',
      );
    });

    test('the directory goes even when the caller\'s secrets match nothing at all', () {
      // THE HOLE THIS STAGE WAS SENT TO CLOSE, at the level of the function. The exact substitution
      // is fed the right strings and still removes nothing, because the producer changed the text
      // before this side saw it — see the CP932 case below for the real mechanism. What must not
      // survive is the part that names the *person*, and that part never needed the caller's help.
      expect(
        withoutSecrets('Failed to open: $_path', const <String>['a name we do not have']),
        isNot(contains('hazuki')),
      );
      expect(withoutSecrets('Failed to open: $_path', const <String>[]), isNot(contains(r'C:\Users')));
    });

    test('a CP932 clip name arrives as U+FFFD, matches no secret, and still leaves no directory', () {
      // The mechanism, not an invented one. `native/src/core/native_api_messages.h` dumps the
      // terminal `message` with the U+FFFD replacement handler, because an exception's `what()` on a
      // Japanese Windows is CP932 and a strict dump would throw away the one message the import is
      // waiting for. The clip's name therefore arrives mangled — and the ASCII directory in front of
      // it does not.
      final mangledLeaf = _asIfDumpedWithReplacement(_cp932JapaneseLeaf);
      expect(mangledLeaf, contains('\u{FFFD}'), reason: 'the fixture is not actually mangled; it proves nothing');
      final message = 'the video import thread threw: Failed to open: $_japaneseDirectory$mangledLeaf';

      // Exactly the secrets the front end has: the path it picked and its leaf, both well-formed.
      final redacted = withoutSecrets(message, <String>['$_japaneseDirectory$_japaneseLeaf', _japaneseLeaf]);

      expect(redacted, isNot(contains('hazuki')), reason: 'the user is named in a report they cannot see');
      expect(redacted, isNot(contains(r'C:\Users')));
      expect(redacted, isNot(contains('Videos')));
      // Redacted, not deleted: the developer still learns the decoder could not open the file.
      expect(redacted, contains('Failed to open'));
      expect(redacted, contains('<redacted>'));
    });

    test('what is NOT a path is left alone, so diagnostics survive this', () {
      // The lookbehind's whole job: without it `https://…` matches at the `s` and every URL in every
      // diagnostic is destroyed. A relative path names nobody and is deliberately not touched.
      const url = 'download failed: https://example.com/a/b.json (404)';
      expect(withoutSecrets(url, const <String>[]), url);
      const relative = r'records\1234\skill.png could not be read';
      expect(withoutSecrets(relative, const <String>[]), relative);
      const prose = 'nothing path-like here, just prose about c: and a / slash';
      expect(withoutSecrets(prose, const <String>[]), prose);
    });
  });

  group('the web import front end is checked by reading it, because the VM cannot run it', () {
    // `video_import_web.dart` imports `package:web`, so it does not compile on the VM and the
    // behavioural guard above cannot reach it. This scan is the substitute and it is weaker: it
    // rules on what is written in this one file and knows nothing about what a value carries.
    late String source;

    setUpAll(() => source = _read('lib/src/core/video_import_web.dart'));

    test('no logger call in the web leg interpolates the clip name', () {
      final calls = _loggerCalls(source);
      // Vacuity. A scanner that stopped matching would enumerate nothing and the assertion below
      // would pass while reading an empty list — how a guard of this shape dies.
      expect(calls.length, greaterThanOrEqualTo(3), reason: 'the scanner found no logger calls; it is broken');
      expect(calls.join('\n'), contains('could not be started'), reason: 'the scanner missed a known call');

      for (final call in calls) {
        for (final interpolation in _interpolations(call)) {
          expect(
            _namesTheClip(interpolation),
            isFalse,
            reason: 'a web log line interpolates "$interpolation", which reaches Sentry as a breadcrumb: $call',
          );
        }
      }
    });

    test('the web leg redacts the producer\'s settled message before anything can publish it', () {
      final statements = _statementsReadingSettledMessage(source);
      expect(statements, hasLength(1), reason: 'the scanner lost the settled outcome; it is broken');
      expect(statements.single, contains('withoutSecrets'));
    });

    test('the web leg still names the container, which is publishable and is the useful part', () {
      final published = _loggerCalls(source).expand(_interpolations).toSet();
      expect(published, contains('container'), reason: 'the log lines say nothing about the clip at all');
    });

    test('the scanner does flag a leak, so a green run above means something', () {
      // The detector run against the line this stage removed. Without this case, a `_namesTheClip`
      // that had stopped matching would make every assertion above vacuously true.
      const leaking = "logger.i('Video import of \$fileName was not started: \$blocker');";
      final calls = _loggerCalls(leaking);
      expect(calls, hasLength(1));
      expect(_interpolations(calls.single), containsAll(<String>['fileName', 'blocker']));
      expect(_interpolations(calls.single).any(_namesTheClip), isTrue);

      // And the two other spellings the same claim is written in elsewhere in this repository.
      expect(_interpolations(_loggerCalls("logger.e('grab \${file.name} failed');").single).any(_namesTheClip), isTrue);
      expect(_interpolations(_loggerCalls("logger.e('probe \${source.name}');").single).any(_namesTheClip), isTrue);

      // A clean line is not flagged, so the detector is not simply saying yes.
      expect(
        _interpolations(_loggerCalls("logger.i('a \"\$container\" clip: \$blocker');").single).any(_namesTheClip),
        isFalse,
      );
    });
  });

  group('the Windows leg passes the same reading, so the two legs are checked alike', () {
    test('no logger call in the io leg interpolates the clip name', () {
      final calls = _loggerCalls(_read('lib/src/core/video_import_io.dart'));
      expect(calls.length, greaterThanOrEqualTo(6), reason: 'the scanner found too few logger calls; it is broken');
      for (final call in calls) {
        for (final interpolation in _interpolations(call)) {
          expect(_namesTheClip(interpolation), isFalse, reason: 'an io log line interpolates "$interpolation": $call');
        }
      }
      // `withoutSecrets('$error', [path, fileName])` passes the names as *secrets to remove*, not as
      // text, so the rule is about interpolations and not about the identifiers appearing at all.
      expect(calls.join('\n'), contains('withoutSecrets'));
    });

    test('the io leg redacts the producer\'s settled message, read the same way the web leg is', () {
      final statements = _statementsReadingSettledMessage(_read('lib/src/core/video_import_io.dart'));
      expect(statements, hasLength(1), reason: 'the scanner lost the settled outcome; it is broken');
      expect(statements.single, contains('withoutSecrets'));
    });
  });

  group('the import error report payload carries no clip name either', () {
    final defaultSink = debugBreadcrumbSink;
    final defaultPicker = videoImportPathPicker;

    setUp(() {
      // Silenced rather than watched: this group is about the payload, and the breadcrumb group
      // above already owns the log lines the same run produces.
      debugBreadcrumbSink = (level, message, error) {};
      videoImportPathPicker = () async => _path;
      // Answering the post is what lets the import reach the terminal message below. Without it the
      // channel throws `MissingPluginException`, the front end releases the slot with its own
      // `the import never started` outcome — duration 0 — and the correlation drops the whole
      // `import` block, which is a case that asserts nothing. Measured, not foreseen.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        (call) async => null,
      );
    });

    tearDown(() async {
      debugBreadcrumbSink = defaultSink;
      videoImportPathPicker = defaultPicker;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        null,
      );
      debugResetVideoImport();
      await pumpEventQueue();
      debugResetVideoImport();
    });

    test('a producer that quotes the path in its terminal message does not get it published', () async {
      // THE ROUTE THE BREADCRUMB GUARD CANNOT SEE. `native/src/cv/video_loader.h` throws
      // `"Failed to open: " << narrow_path`; `windows/runner/video_import_session.h` relays a throw
      // out of the import thread as `"the video import thread threw: " + e.what()` and hands it to
      // `notifyVideoImportDone` as the payload's `message`. This is that payload, verbatim in shape.
      final running = startVideoImport(declaration: _declaresNothing, preflight: () => null);
      await pumpEventQueue();
      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportStarted'});
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportDone',
        'reason': 'failed',
        'decoded': 12,
        'supplied': 12,
        'rejected': 0,
        // Non-zero, and it has to be: the report attaches the import's result only when the
        // correlation holds, and an unknown duration on either side drops the whole `import` block —
        // which would make this case pass by publishing nothing at all.
        'durationMs': 12000,
        'matrixConverted': '',
        'message': 'the video import thread threw: Failed to open: $_path',
      });
      await running;

      final scope = _scopeForTheImportedClip();
      final import = scope.context['import'] as Map<String, dynamic>;
      // Vacuity, twice over: the block has to be there, and the free-text value has to be in it.
      expect(import['correlation'], 'matched', reason: 'the import block was dropped, so nothing was checked');
      expect(import['message'], isA<String>().having((text) => text, 'message', contains('threw')));

      final visited = _scanForSecrets(scope);
      expect(visited.length, greaterThanOrEqualTo(20), reason: 'the walker visited almost nothing; it is broken');
      // Redacted, not dropped: the developer still sees that the decoder could not open the file.
      expect(import['message'], contains('<redacted>'));
    });

    test('a clip name the producer mangled still does not publish the directory that names the user', () async {
      // THE SAME ROUTE, WITH THE ENCODING THE EXACT SUBSTITUTION CANNOT SURVIVE, driven end to end
      // rather than asserted on the helper. `native_api_messages.h` dumps this message with the
      // U+FFFD replacement handler (a Japanese Windows `what()` is CP932), so the front end's two
      // secrets — the path it picked and its leaf — match nothing in the text that arrives. What
      // arrives unmangled is `C:\Users\hazuki\Videos\`, which is the part that names a person.
      videoImportPathPicker = () async => '$_japaneseDirectory$_japaneseLeaf';
      final mangledLeaf = _asIfDumpedWithReplacement(_cp932JapaneseLeaf);

      final running = startVideoImport(declaration: _declaresNothing, preflight: () => null);
      await pumpEventQueue();
      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportStarted'});
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportDone',
        'reason': 'failed',
        'decoded': 12,
        'supplied': 12,
        'rejected': 0,
        'durationMs': 12000,
        'matrixConverted': '',
        'message': 'the video import thread threw: Failed to open: $_japaneseDirectory$mangledLeaf',
      });
      await running;

      final scope = _scopeForTheImportedClip(clipName: _japaneseLeaf);
      final import = scope.context['import'] as Map<String, dynamic>;
      expect(import['correlation'], 'matched', reason: 'the import block was dropped, so nothing was checked');
      expect(import['message'], isA<String>().having((text) => text, 'message', contains('threw')));

      final visited = _scanForSecrets(scope);
      expect(visited.length, greaterThanOrEqualTo(20), reason: 'the walker visited almost nothing; it is broken');
      // Named explicitly as well as through the walker: this is the one assertion the whole case
      // exists for, and the walker's list is shared with the ASCII case above.
      expect(import['message'], isNot(contains('hazuki')));
      expect(import['message'], isNot(contains('Videos')));
      expect(import['message'], contains('<redacted>'));
    });

    test('the walker really reads every value, including nested and non-string ones', () {
      // Without this the case above would pass for a walker that visited an empty map: the report is
      // two levels deep and its leaves are a mix of strings, ints, bools and nulls.
      final poisoned = (
        context: <String, dynamic>{
          'import': <String, dynamic>{'message': 'could not open $_leaf', 'records': 3, 'ok': false, 'reason': null},
        },
        tags: <String, String>{'report.kind': 'video_import'},
      );
      expect(() => _scanForSecrets(poisoned), throwsA(isA<TestFailure>()));
      // And it does not simply say yes to everything.
      final clean = (
        context: <String, dynamic>{
          'import': <String, dynamic>{'message': 'could not open a "mkv" clip', 'records': 3},
        },
        tags: <String, String>{'report.kind': 'video_import'},
      );
      expect(_scanForSecrets(clean), isNotEmpty);
    });
  });

  group('the worker client is checked by reading it, because the VM cannot run it either', () {
    // `wasm_worker_client.dart` imports `dart:js_interop`, so this file cannot drive it. The property
    // read for here is NOT the one the web import leg is read for: no interpolation in that file
    // names the clip, and none ever will — the name arrives inside text the *worker* wrote, as a
    // value. What is checked instead is that every read of that text goes through the redaction.
    late String source;

    setUpAll(() => source = _read('lib/src/core/wasm_worker_client.dart'));

    test('every string the worker wrote reaches a log or a Sentry call only through the redaction', () {
      final flows = _workerTextFlows(source);
      expect(
        flows.redacted.length,
        greaterThanOrEqualTo(9),
        reason: 'the reader followed fewer worker values than the file redacts today; it is broken',
      );
      // Named, not just counted: the two the file was written for have to be among them, or the
      // reader could be finding nine of something else.
      expect(
        flows.redacted.join('\n'),
        allOf(contains("message['msg']"), contains('errorEvent.message')),
        reason: 'the reader is no longer following the worker message field or the onerror event',
      );
      final unruled = flows.unredacted.where((flow) => !_workerValuesThatCarryNoSentence.containsKey(flow.value));
      expect(
        unruled.map((flow) => '${flow.member}: ${flow.sink} <- ${flow.value}').toList(),
        isEmpty,
        reason:
            'this value came out of the worker and reaches a breadcrumb or a Sentry event without '
            'passing through _withoutClipName. Wrap it, or — if it is not a sentence the worker '
            'composed — rule on it in _workerValuesThatCarryNoSentence with the reason.',
      );
    });

    test('the reader follows a route this file has never seen, so a green run above means something', () {
      // The defect being repaired: the rule this replaced knew two spellings, so a NEW way into the
      // worker's text was not a "read" and was never asked to redact. Every source below uses a key
      // and a local that appear nowhere in `wasm_worker_client.dart`.
      String probe(String body) =>
          '''
class Client {
  void spawn() {
    worker.onmessage = ((web.MessageEvent event) => _onMessage(event)).toJS;
  }

  void _onMessage(web.MessageEvent event) {
    final message = jsonDecode((event.data as JSString).toDart) as Map<String, dynamic>;
$body
  }

  String _withoutClipName(String text) => withoutSecrets(text, <String>[?_importClipName]);
}
''';

      final leaking = _workerTextFlows(probe("    logger.i('worker said \${message['diagnostic']}');"));
      expect(leaking.unredacted.map((flow) => flow.value).toList(), <String>["message['diagnostic']"]);

      // Through a local, two hops from the read, and into a Sentry call rather than a log line.
      final indirect = _workerTextFlows(
        probe(
          "    final note = message['diagnostic'].toString();\n"
          '    final relayed = note;\n'
          "    captureException(WorkerException(relayed), StackTrace.current);",
        ),
      );
      expect(indirect.unredacted.map((flow) => flow.value).toList(), <String>['relayed']);
      expect(indirect.unredacted.single.sink, 'captureException');

      // Redacted on the way: not a leak, and not reported as one.
      final fixed = _workerTextFlows(
        probe("    logger.i('worker said \${_withoutClipName('\${message['diagnostic']}')}');"),
      );
      expect(fixed.unredacted, isEmpty);
      expect(fixed.redacted, hasLength(1));

      // A count is not a sentence, and demanding a redaction of one would make the rule unusable.
      final counted = _workerTextFlows(
        probe(
          "    final frames = (message['frames'] as num?)?.toInt() ?? 0;\n"
          "    logger.i('worker decoded \$frames');",
        ),
      );
      expect(counted.unredacted, isEmpty);
    });

    test('the redaction is fed by a name the client only holds while a clip is open', () {
      // The lifetime, which the statement rule above cannot see: a name left set would go on being
      // cut out of unrelated worker text for the rest of the session.
      // Read inside the method's own braces. A first spelling of this compared positions across the
      // whole file and passed the break it was written for, because an unrelated `} finally {`
      // hundreds of lines earlier satisfied it — measured, not foreseen.
      final body = _methodBody(source, 'Future<VideoImportOutcome> startVideoImport(');
      expect(body.length, greaterThan(500), reason: 'the method body came back nearly empty; the scanner is broken');
      expect(_occurrences(body, '_importClipName = file.name;'), 1, reason: 'the name is not taken exactly once');
      // EXACTLY ONE clear, and that is the whole rule: a second one is a clear on some path, which is
      // how "cleared on the happy path only" is written.
      expect(_occurrences(body, '_importClipName = null;'), 1, reason: 'the name is cleared on more than one path');
      final cleared = body.indexOf('_importClipName = null;');
      final finallyAt = body.lastIndexOf('} finally {');
      expect(finallyAt, greaterThanOrEqualTo(0), reason: 'the import has no finally to clear the name in');
      expect(finallyAt, lessThan(cleared), reason: 'the clear is not inside the finally');
      expect(
        body.substring(finallyAt, cleared).contains('return'),
        isFalse,
        reason: 'a return sits between the finally and the clear, so some path leaves the name set',
      );
    });
  });

  group('the report\'s own attachment never names the user', () {
    // A DIFFERENT FEATURE, THE SAME CLAIM, and it fires on exactly the code path that runs *because*
    // a report is being sent. `Scope.addFile` used to log `file=${path.path}` and hand the raw
    // exception to both the breadcrumb and `captureException` — and every file this app attaches
    // lives under the user's own profile, so all three routes carried `C:\Users\<person>\`.
    //
    // Behavioural, not read: this file compiles on the VM, so the throw is produced for real and the
    // breadcrumb is watched at the seam it crosses.
    final defaultSink = debugBreadcrumbSink;
    final defaultBackend = fsBackend;

    late List<_Crumb> crumbs;

    setUp(() {
      crumbs = <_Crumb>[];
      debugBreadcrumbSink = (level, message, error) =>
          crumbs.add((level: level, message: message, error: error?.toString() ?? ''));
      fsBackend = _ProbeFailingFsBackend(defaultBackend);
    });

    tearDown(() {
      debugBreadcrumbSink = defaultSink;
      fsBackend = defaultBackend;
    });

    test('a file that cannot be probed is reported by its leaf, never by the directory it sits in', () async {
      await Scope(SentryOptions()).addFile(FilePath(_attachmentPath));

      expect(crumbs, isNotEmpty, reason: 'no breadcrumb was produced, so this case asserted nothing');
      final text = crumbs.map((crumb) => '${crumb.message}\n${crumb.error}').join('\n');
      for (final secret in _attachmentSecrets) {
        expect(
          text.contains(secret),
          isFalse,
          reason: 'a breadcrumb carries "$secret", which reaches Sentry with the next event: $text',
        );
      }
      // The leaf is this app's own invention, and dropping it would leave the developer unable to
      // tell which attachment failed — so "delete the line" must not pass either.
      expect(text, contains('video_frame_1.png'));
      expect(text, contains('<redacted>'));
      expect(text, contains('Cannot open file'), reason: 'the reason the attach failed was thrown away');
    });

    test('nothing in the catch republishes the raw exception or the absolute path', () {
      // The route the breadcrumb spy cannot see: `captureException` is a Sentry **event**, and in a
      // suite the hub is disabled, so what it was handed is unobservable. This reads it instead —
      // the same substitute the worker client gets, for the same reason.
      final body = _methodBody(_read('lib/src/core/sentry_util.dart'), 'Future<void> addFile(FilePath path) async');
      expect(body.length, greaterThan(200), reason: 'the method body came back nearly empty; the scanner is broken');
      final statements = _statementsReadingTheAttachmentFailure(body);
      expect(statements, hasLength(1), reason: 'the scanner did not find the one read that exists; it is broken');
      for (final statement in statements) {
        expect(
          statement.contains('withoutSecrets'),
          isTrue,
          reason: 'this statement republishes the platform exception or the absolute path raw: $statement',
        );
      }
    });

    test('the scanner does flag an unredacted read, so a green run above means something', () {
      const leaking =
          'logger.e("Failed to add file attachment. file=\${path.path}", exception, stackTrace);\n'
          'captureException(exception, stackTrace);';
      expect(_statementsReadingTheAttachmentFailure(leaking), hasLength(2));
      expect(_statementsReadingTheAttachmentFailure(leaking).every((s) => s.contains('withoutSecrets')), isFalse);
      // And a comment that merely mentions the word is not a read: prose is stripped before the
      // split, which is what stops this rule from failing on its own explanation.
      const commented = '// the exception is dropped here, path.path with it\nfinal x = 1;';
      expect(_statementsReadingTheAttachmentFailure(commented), isEmpty);
    });
  });
}

/// An io backend whose existence probe throws the way a locked or vanished file makes it throw, with
/// the absolute path quoted inside the exception exactly as `dart:io` quotes it.
class _ProbeFailingFsBackend extends WebLikeFsBackend {
  _ProbeFailingFsBackend(super.inner);

  @override
  Future<bool> exists(String path) async => throw FileSystemException('Cannot open file', path);
}

/// The report scope for a clip that IS the one the last import ran on, so the `import` block is
/// populated and its free-text value is actually published.
///
/// Everything except the outcome is a fixture: the frame and the timeline are measured by the
/// decoder and carry no name (`buildImportErrorReportScope` is given the leaf and publishes only the
/// container). What is under test is what the outcome dragged in.
ImportErrorReportScope _scopeForTheImportedClip({String clipName = _leaf}) => buildImportErrorReportScope(
  clipName: clipName,
  frame: GrabbedVideoFrame(
    png: FilePath('/tmp/video_frame_1.png'),
    requestedMs: 6000,
    mediaTsMs: 5963,
    seekBackoffMs: null,
    decodedFrames: null,
    width: 1920,
    height: 1080,
    format: 'I420',
    rotation: 0,
    matrixConverted: '',
  ),
  timeline: const VideoFrameTimeline(
    firstFrameMs: 0,
    durationMs: 12000,
    fps: 30.0,
    width: 1920,
    height: 1080,
    hasMediaTimeline: true,
  ),
  importState: videoImportState.value,
);

/// Walks [scope] and fails on any string — key or value, at any depth — containing one of [_secrets].
///
/// Returns every string it looked at, so a caller can assert it looked at something: a walker that
/// silently visited nothing is how a guard of this shape dies, and the report is a nested map whose
/// leaves are a mix of types.
List<String> _scanForSecrets(ImportErrorReportScope scope) {
  final visited = <String>[];
  void walk(Object? node, String where) {
    if (node is Map) {
      node.forEach((key, value) {
        walk('$key', '$where/key');
        walk(value, '$where/$key');
      });
      return;
    }
    if (node is Iterable) {
      for (final item in node) {
        walk(item, '$where[]');
      }
      return;
    }
    // Everything else is asked for its printed form, including ints, bools, enums and null: what
    // reaches Sentry is a serialisation, so a name hiding inside a `toString` still leaves.
    final text = '$node';
    visited.add(text);
    for (final secret in _secrets) {
      expect(
        text.contains(secret),
        isFalse,
        reason: 'the report publishes "$secret" at $where, which reaches Sentry with the event: $text',
      );
    }
  }

  walk(scope.context, 'context');
  walk(scope.tags, 'tags');
  return visited;
}

/// The body of the method whose declaration starts with [signature], braces balanced.
///
/// Positions inside one method, and never across the file: a rule written as "this token comes after
/// that one" is satisfied by any earlier occurrence of the second token anywhere, which is how the
/// first version of the lifetime rule passed the very break it existed to catch.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'could not find "$signature"; the source layout changed');
  final open = source.indexOf('{', start + signature.length);
  expect(open, greaterThanOrEqualTo(0), reason: '"$signature" has no body');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') {
      depth++;
    } else if (source[i] == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(open + 1, i);
      }
    }
  }
  fail('"$signature" has no closing brace');
}

int _occurrences(String text, String needle) => needle.allMatches(text).length;

/// Every statement of [source] that reads the settled outcome's message — the producer's own
/// sentence, which `buildImportErrorReportScope` publishes as `import.message`.
///
/// The io leg is guarded behaviourally as well (the payload group drives it), so this rule exists
/// for the web leg, where nothing can be run; it is applied to both so the two legs are read alike
/// and a divergence between them shows up as a failure rather than as an absence.
List<String> _statementsReadingSettledMessage(String source) => source
    .split(';')
    .where((statement) => statement.contains('settled.message'))
    .map((statement) => statement.trim())
    .toList();

/// One string the worker wrote arriving at a log line or a Sentry call.
typedef _WorkerTextFlow = ({String member, String sink, String value});

/// The worker-supplied values this side republishes **without** redacting them, and the ruling that
/// says why each is not a sentence the worker composed.
///
/// This is the judgement half, and it is deliberately the only hand-written thing left: the
/// enumeration is done by [_workerTextFlows], so a value that is neither redacted nor ruled on here
/// fails the group by default. That is the direction the rule this replaced could not fail in — an
/// unknown read was silently outside its two spellings, whereas an unknown read is now a failure
/// naming the value and the method it is logged from.
const Map<String, String> _workerValuesThatCarryNoSentence = <String, String>{
  // Record ids the core minted and this side round-trips as map keys (`_updateSlots.settle`,
  // `_persistLiveRecord`). They are identifiers, not prose: nothing the worker was told about the
  // clip reaches them, and redacting one would also mean redacting the key a later line has to be
  // matched against by eye.
  'recordId': 'a record identifier the core minted, used here as a map key',
  'updatedId': 'the same identifier, on the regeneration path',
};

/// Every string the wasm worker wrote that this file republishes, split by whether the redaction is
/// on the path.
///
/// **The two spellings this replaced were `statement.contains("['msg']")` and
/// `statement.contains('errorEvent.message')`** — a hand-written pair, under a header that claimed
/// to check *every* read of the worker's text. A third route into that text (a new message key, a
/// value destructured into a local, a field of a structured message) was simply not a "read" as far
/// as that rule was concerned, so it was never required to carry the redaction and the group stayed
/// green while the clip's name went out on a breadcrumb. The rule could only ever be as complete as
/// its two literals, and a per-read rule cannot fail for a read it never received.
///
/// So the reads are followed rather than spelled. Starting at the worker's own boundary — the
/// closures assigned to `onmessage` / `onerror`, found by their slot names, which is the one
/// judgement here and is a fixed DOM vocabulary rather than a list that grows — the worker's values
/// are propagated through local declarations, assignments and calls to this file's own methods,
/// and every one of them that reaches a `logger` call or a Sentry call is reported. Passing through
/// `_withoutClipName` (or `withoutSecrets`) clears the value, which is what puts it in `redacted`
/// instead.
///
/// Only *string-valued* reads are asked to be redacted, because redacting a frame count says
/// nothing: [_isWorkerText] classifies each value off the shape the file extracts it with
/// (`(x as JSString).toDart` and `?.toString()` are text; `toDartInt`, `as num`, `== true`, `.length`
/// and a numeric literal fallback are not). The classification defaults to **text**, so a shape it
/// has not seen is reported rather than dropped.
///
/// **Stated limits.** Taint does not survive a call whose result this reader cannot see through
/// (`_parseFiles(obj['files'])`, `_videoImport.handle(message)`) — the callee is still followed for
/// its own sinks, but its *return* is not treated as worker text, and the one real instance of that
/// (`VideoImportOutcome.message`) is what `_statementsReadingSettledMessage` covers. Values stored
/// into a field or a `Completer` and read back elsewhere are likewise not followed.
({List<_WorkerTextFlow> unredacted, List<String> redacted}) _workerTextFlows(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final declared = <String, MethodDeclaration>{
    for (final klass in unit.declarations.whereType<ClassDeclaration>())
      for (final member in klass.members.whereType<MethodDeclaration>()) member.name.lexeme: member,
  };
  final roots = <String, Set<int>>{};
  unit.accept(_WorkerBoundary(roots));
  expect(
    roots,
    isNotEmpty,
    reason:
        'no worker message handler was found, so nothing below is followed and every rule about the '
        "worker's text would pass with nothing to say",
  );
  final unredacted = <_WorkerTextFlow>[];
  final redacted = <String>[];
  final visited = <String, Set<int>>{};
  final queue = <MapEntry<String, int>>[
    for (final entry in roots.entries)
      for (final index in entry.value) MapEntry(entry.key, index),
  ];
  while (queue.isNotEmpty) {
    final job = queue.removeAt(0);
    if (!visited.putIfAbsent(job.key, () => <int>{}).add(job.value)) {
      continue;
    }
    final method = declared[job.key];
    if (method == null) {
      continue;
    }
    final parameters = method.parameters?.parameters ?? const <FormalParameter>[];
    final text = <String>{
      for (var i = 0; i < parameters.length; i++)
        if (visited[job.key]!.contains(i)) parameters[i].name?.lexeme ?? '',
    }..remove('');
    method.body.accept(
      _WorkerTextReader(
        declared: declared,
        text: text,
        member: job.key,
        unredacted: unredacted,
        redacted: redacted,
        enqueue: (name, index) => queue.add(MapEntry(name, index)),
      ),
    );
  }
  return (unredacted: unredacted, redacted: redacted);
}

/// The functions that take a value out of the worker's text, so a value that passed through one is
/// no longer the worker's text.
const _redactions = <String>{'_withoutClipName', 'withoutSecrets'};

/// The DOM slots a worker's own values arrive through. The one hand-written vocabulary in this
/// reader, and a closed one: the platform defines it, not this repository.
const _workerHandlerSlots = <String>{'onmessage', 'onerror', 'onmessageerror'};

/// Where a republished string ends up. `logger` is a Sentry sink like the rest: `AppLogger.log`
/// turns every level above trace into a breadcrumb that rides out with the next event.
const _loggerLevels = <String>{'v', 'd', 'i', 'w', 'e', 'wtf'};
const _sentrySinks = <String>{'captureExceptionWithScope', 'captureException', 'captureMessage', '_failPending'};

/// Whether [expression] can be a string, judged off the shape the source extracts it with.
///
/// Defaulting to `true` is the point: an extraction shape nobody anticipated is reported rather than
/// dropped, which is the direction a guard of this kind has to fail in.
bool _isWorkerText(Expression? expression) {
  final e = expression;
  if (e == null) {
    return false;
  }
  if (e is ParenthesizedExpression) {
    return _isWorkerText(e.expression);
  }
  if (e is ConditionalExpression) {
    return _isWorkerText(e.thenExpression) || _isWorkerText(e.elseExpression);
  }
  if (e is BinaryExpression) {
    // `??` picks one of its two sides; every other operator here yields a bool.
    return e.operator.lexeme == '??' && (_isWorkerText(e.leftOperand) || _isWorkerText(e.rightOperand));
  }
  if (e is IsExpression || e is BooleanLiteral || e is IntegerLiteral || e is DoubleLiteral || e is NullLiteral) {
    return false;
  }
  if (e is PrefixExpression) {
    return _isWorkerText(e.operand);
  }
  if (e is AsExpression) {
    return _isWorkerText(e.expression) || e.type.toSource().contains('String');
  }
  if (e is MethodInvocation) {
    // A call this reader cannot see through. `toString()` is the file's own idiom for taking a
    // worker value as text, and a redaction returns text that is no longer the worker's.
    return e.methodName.name == 'toString' || _redactions.contains(e.methodName.name);
  }
  if (e is PropertyAccess) {
    return switch (e.propertyName.name) {
      'length' || 'toDartInt' || 'toDartDouble' => false,
      'toDart' => _isWorkerText(e.target),
      _ => true,
    };
  }
  if (e is PrefixedIdentifier) {
    return e.identifier.name != 'length';
  }
  return true;
}

/// Finds the methods the worker's own values are handed to, by following the closures assigned to
/// [_workerHandlerSlots] and recording which argument of which method each parameter reaches.
class _WorkerBoundary extends RecursiveAstVisitor<void> {
  _WorkerBoundary(this.roots);

  final Map<String, Set<int>> roots;

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    final slot = left is PropertyAccess
        ? left.propertyName.name
        : (left is PrefixedIdentifier ? left.identifier.name : null);
    if (slot != null && _workerHandlerSlots.contains(slot)) {
      final closures = <FunctionExpression>[];
      node.rightHandSide.accept(_Closures(closures));
      for (final closure in closures) {
        final names = <String>{
          for (final parameter in closure.parameters?.parameters ?? const <FormalParameter>[])
            parameter.name?.lexeme ?? '',
        }..remove('');
        closure.body.accept(_Handoffs(names, roots));
      }
    }
    super.visitAssignmentExpression(node);
  }
}

class _Closures extends RecursiveAstVisitor<void> {
  _Closures(this.found);

  final List<FunctionExpression> found;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    found.add(node);
    super.visitFunctionExpression(node);
  }
}

class _Handoffs extends RecursiveAstVisitor<void> {
  _Handoffs(this.names, this.roots);

  final Set<String> names;
  final Map<String, Set<int>> roots;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final arguments = node.argumentList.arguments;
    for (var i = 0; i < arguments.length; i++) {
      if (_carries(arguments[i], names)) {
        roots.putIfAbsent(node.methodName.name, () => <int>{}).add(i);
      }
    }
    super.visitMethodInvocation(node);
  }
}

bool _carries(AstNode? node, Set<String> names) {
  if (node == null) {
    return false;
  }
  final finder = _CarriesWorkerText(names);
  node.accept(finder);
  return finder.found;
}

/// Whether any of [text]'s names is read in the subtree, ignoring what a redaction returns and what
/// a conditional merely *tests* (a condition yields a bool, not the value it looked at).
class _CarriesWorkerText extends RecursiveAstVisitor<void> {
  _CarriesWorkerText(this.text);

  final Set<String> text;
  bool found = false;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (text.contains(node.name)) {
      found = true;
    }
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    node.thenExpression.accept(this);
    node.elseExpression.accept(this);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_redactions.contains(node.methodName.name)) {
      return;
    }
    super.visitMethodInvocation(node);
  }
}

/// Walks one method with [text] holding the names that carry the worker's own strings.
class _WorkerTextReader extends RecursiveAstVisitor<void> {
  _WorkerTextReader({
    required this.declared,
    required this.text,
    required this.member,
    required this.unredacted,
    required this.redacted,
    required this.enqueue,
  });

  final Map<String, MethodDeclaration> declared;
  final Set<String> text;
  final String member;
  final List<_WorkerTextFlow> unredacted;
  final List<String> redacted;
  final void Function(String method, int index) enqueue;

  void _bind(String name, Expression? initializer) {
    if (_carries(initializer, text) && _isWorkerText(initializer)) {
      text.add(name);
    }
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final list = node.parent;
    final declaredType = list is VariableDeclarationList ? list.type?.toSource().replaceAll('?', '') : null;
    if (declaredType == null || !const <String>{'int', 'double', 'num', 'bool'}.contains(declaredType)) {
      _bind(node.name.lexeme, node.initializer);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    if (left is SimpleIdentifier) {
      _bind(left.name, node.rightHandSide);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target?.toSource();
    if (_redactions.contains(name)) {
      for (final argument in node.argumentList.arguments) {
        if (_carries(argument, text)) {
          redacted.add('$member :: $name(${argument.toSource()})');
        }
      }
      return; // Whatever is inside has been taken out of the worker's text by definition.
    }
    final isSink =
        (target == 'logger' && _loggerLevels.contains(name)) || (target == null && _sentrySinks.contains(name));
    final arguments = node.argumentList.arguments;
    for (var i = 0; i < arguments.length; i++) {
      if (!_carries(arguments[i], text)) {
        continue;
      }
      if (isSink) {
        for (final value in _leavesOf(arguments[i])) {
          unredacted.add((member: member, sink: target == null ? name : '$target.$name', value: value));
        }
      }
      if (target == null && declared.containsKey(name)) {
        enqueue(name, i);
      }
    }
    super.visitMethodInvocation(node);
  }

  /// The smallest expressions inside [argument] that carry the worker's text, so a failure names the
  /// value rather than the whole sentence it was interpolated into.
  List<String> _leavesOf(Expression argument) {
    final found = <String>[];
    _collectWorkerTextLeaves(argument, text, found);
    return found;
  }
}

/// Descends [node] and records the smallest subexpressions that still carry the worker's text.
///
/// A *read* off the worker's payload (`message['msg']`, `errorEvent.message`, `x.toDart`) is a leaf
/// even though its target carries the text too: reporting `message` would name the map rather than
/// the value, and it is the value that is being published. A read whose shape says it is not text
/// (`files.length`) ends the descent without recording anything.
void _collectWorkerTextLeaves(AstNode node, Set<String> text, List<String> found) {
  if (node is MethodInvocation && _redactions.contains(node.methodName.name)) {
    return;
  }
  if (!_carries(node, text)) {
    return;
  }
  final isRead =
      node is IndexExpression ||
      node is PropertyAccess ||
      node is PrefixedIdentifier ||
      (node is MethodInvocation && node.target != null);
  if (isRead) {
    if (_isWorkerText(node as Expression)) {
      found.add(node.toSource());
    }
    return;
  }
  final before = found.length;
  for (final child in node.childEntities.whereType<AstNode>()) {
    _collectWorkerTextLeaves(child, text, found);
  }
  if (found.length == before && node is Expression && _isWorkerText(node)) {
    found.add(node.toSource());
  }
}

/// Every statement of [body] that names the caught platform exception or the attachment's absolute
/// path — i.e. the two values in `Scope.addFile` whose printed form quotes the user's profile.
///
/// The identifier is matched as a word rather than as `$exception`, so `captureException(exception,
/// …)` — the route a suite cannot observe, because the hub is disabled — is caught as well as the
/// interpolated one.
///
/// Line comments are stripped first. Without that the rule fails on its own explanation: the code it
/// guards has to *say* which value it is dropping, and a chunk of prose containing the word would be
/// read as a republication of it. Stripping `//` would also cut a `https://` inside a string literal,
/// which is why it is applied to one extracted method body and not to a file.
List<String> _statementsReadingTheAttachmentFailure(String body) => body
    .replaceAll(RegExp(r'//[^\n]*'), '')
    .split(';')
    .where((statement) => RegExp(r'\bexception\b').hasMatch(statement) || statement.contains('path.path'))
    .map((statement) => statement.trim())
    .toList();

String _read(String relativePath) {
  final file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: 'run this suite from the repository root');
  return file.readAsStringSync();
}

/// Every `logger.<level>(…)` call in [source], as source text, parentheses balanced.
///
/// Quoted spans are skipped so a bracket inside a message cannot end a call early. Raw strings and
/// nested interpolation braces are not modelled; the vacuity cases above are what stands between
/// that simplification and a scanner that silently finds nothing.
List<String> _loggerCalls(String source) {
  final calls = <String>[];
  final start = RegExp(r'logger\.(v|d|i|w|e|wtf)\(');
  for (final match in start.allMatches(source)) {
    var depth = 1;
    var index = match.end;
    String? quote;
    while (index < source.length && depth > 0) {
      final char = source[index];
      if (quote != null) {
        if (char == r'\') {
          index += 2;
          continue;
        }
        if (char == quote) quote = null;
      } else if (char == "'" || char == '"') {
        quote = char;
      } else if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
      }
      index++;
    }
    if (depth == 0) calls.add(source.substring(match.start, index));
  }
  return calls;
}

/// The expressions interpolated into [call]: `$name` and the inside of `${…}`.
List<String> _interpolations(String call) => RegExp(r'\$\{([^}]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')
    .allMatches(call)
    .map((match) => (match.group(1) ?? match.group(2) ?? '').trim())
    .where((expression) => expression.isNotEmpty)
    .toList();

/// Whether [expression] evaluates to something that names the user's clip.
///
/// A short vocabulary rather than a table of call sites: the call sites are enumerated by the
/// scanner, and this is the only part a human has to keep current. `_namesTheClip` is asserted to
/// discriminate by its own case above.
bool _namesTheClip(String expression) =>
    RegExp(r'\b(fileName|clipName|leaf)\b|\b\w*[Ff]ile\.name\b|\bsource\.name\b|\b_?path\b').hasMatch(expression);
