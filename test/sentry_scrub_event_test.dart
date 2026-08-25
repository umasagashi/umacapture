import 'dart:convert';
import 'dart:io';

// `analyzer` reaches this package transitively (through the codegen stack). Depended on here rather
// than promoted to a direct dev_dependency because pinning it would freeze the version the codegen
// packages resolve to, and this guard only ever needs the parser. Same arrangement as
// `disabled_tooltip_visibility_test.dart`.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/sentry_util.dart';

/// The same fixture as `app_root_scrub_test.dart`: the Windows account name that must never leave
/// the machine, and the three roots `pathInfoLoader` registers.
const _account = 'hazuki';
const _documentRoot = r'C:\Users\hazuki\Documents\umacapture';
const _supportRoot = r'C:\Users\hazuki\AppData\Roaming\umasagashi\umacapture';
const _executableRoot = r'C:\Users\hazuki\AppData\Local\umacapture';

/// The path `network_failure.inner_error` actually carried: dio wraps a mid-download write failure
/// as `DioException(error: FileSystemException(...))`, and `version_check.dart` publishes
/// `innerError.toString()` into a context.
const _downloadPath = r'C:\Users\hazuki\AppData\Local\umacapture\temp\7f2\modules.zip';

/// A path the app does not own, so its whole directory goes rather than becoming `<app>`.
const _clipPath = r'C:\Users\hazuki\Videos\training.mkv';

void _registerWindowsLayout() => registerAppRoots(const [_documentRoot, _supportRoot, _executableRoot]);

/// Every string [value] carries, at any depth. The event is inspected through `toJson` — the shape
/// that actually goes on the wire — so a field this test never heard of is still walked.
List<String> _stringsIn(dynamic value) => switch (value) {
  final String text => [text],
  final Map<dynamic, dynamic> map => [...map.keys.expand(_stringsIn), ...map.values.expand(_stringsIn)],
  final List<dynamic> items => items.expand(_stringsIn).toList(),
  _ => const <String>[],
};

/// The strings of [event] that still name the user. This is the invariant, stated once over the
/// whole event rather than per field: **no field of a sent event may contain the account name.**
List<String> _stringsNamingTheUser(SentryEvent event) =>
    _stringsIn(event.toJson()).where((e) => e.contains(_account) || e.contains(r'C:\Users')).toList();

/// Every string of [event], joined — for the "redacted, not deleted" half of each assertion. Read
/// off the same `toJson` rather than off `jsonEncode`, whose escaping hides a `\` behind a `\\`.
String _allTextOf(SentryEvent event) => _stringsIn(event.toJson()).join('\n');

/// An event with a user path in every place this app (or the SDK on its behalf) can put one.
///
/// Built fresh per call because the scrub rewrites in place.
SentryEvent _eventWithPathsEverywhere() {
  final event = SentryEvent(
    message: SentryMessage(
      'module download failed at $_downloadPath',
      template: 'module download failed at %s',
      params: [_downloadPath],
    ),
    exceptions: [
      SentryException(
        type: 'DioException',
        value: "DioException [unknown]: FileSystemException: write failed, path = '$_downloadPath'",
        stackTrace: SentryStackTrace(
          frames: [SentryStackFrame(absPath: _clipPath, fileName: _clipPath)],
        ),
      ),
    ],
    breadcrumbs: [
      Breadcrumb(
        message: 'Extracting the module archive. path=$_downloadPath',
        data: {
          'path': _downloadPath,
          'attempts': [
            {'target': _clipPath},
          ],
        },
      ),
    ],
    tags: {'network.operation': 'download_module', 'network.target': _downloadPath},
    request: SentryRequest(
      url: 'https://example.invalid/modules.zip',
      queryString: 'from=$_downloadPath',
      cookies: 'last=$_clipPath',
      fragment: _clipPath,
      headers: {'X-Source': _clipPath},
    ),
    culprit: 'writing $_downloadPath',
    transaction: _clipPath,
  );
  // Exactly what `logNetworkException` publishes, plus the nesting `statedReportContext` allows.
  event.contexts['network_failure'] = {
    'operation': 'download_module',
    'inner_error': "FileSystemException: write failed, path = '$_downloadPath'",
    'attempted': [_downloadPath, 1, null],
    'nested': {'source': _clipPath},
  };
  event.contexts['tls_probe'] = {'probe_error_message': 'no certificate for $_clipPath'};
  // ignore: deprecated_member_use
  event.extra = {'download': _downloadPath};
  return event;
}

/// The two identifiers a symbolication step matches on. Asserted byte-identical after the scrub:
/// the fix cuts directories out of `debug_meta`, it does not rewrite what identifies a module.
const _debugId = '3f1c9a2e-7b40-4d61-9f2a-0c8e5d1b4a77';
const _codeId = '68A1F2C3452000';

/// The loaded-image list of a native-frame event, as sentry-native actually builds it on Windows.
///
/// The first image is the real leak proven on production 0.2.1 events: OneDrive's shell-integration
/// DLL, which Windows maps into any process that touches Explorer APIs, living under the account
/// directory. The second is one of the app's own modules, present so the assertions can tell
/// `<redacted>` (a place the user chose) from `<app>` (inside the app's own tree) rather than only
/// checking that the account name is gone.
///
/// Built fresh per call because the scrub rewrites in place.
SentryEvent _eventWithDebugImages() => SentryEvent(
  debugMeta: DebugMeta(
    images: [
      DebugImage(
        type: 'pe',
        uuid: _debugId,
        debugId: _debugId,
        codeId: _codeId,
        codeFile: r'C:\Users\hazuki\AppData\Local\Microsoft\OneDrive\26.134.0713.0004\FileSyncShell64.dll',
        debugFile: r'F:\dbs\sh\odct\client\onedrive\Shell\Dll\obj\amd64\FileSyncShell64.pdb',
        imageAddr: '0x7ffb1c2d0000',
        imageVmAddr: '0x0',
        imageSize: 4526080,
        arch: 'x86_64',
      ),
      DebugImage(
        type: 'pe',
        debugId: _debugId,
        codeFile: '$_executableRoot\\umacapture.exe',
        debugFile: '$_executableRoot\\umacapture.pdb',
        imageAddr: '0x140000000',
        imageSize: 8388608,
      ),
    ],
  ),
);

/// An event carrying a path in each of the three modelled fields nothing populates today.
///
/// `unknown` is not among them and is exercised on its own below: it is filled only by `fromJson`,
/// and round-tripping this event to reach it would have made every assertion here depend on which
/// fields the SDK's `toJson`/`fromJson` pair happens to preserve, rather than on the scrub.
///
/// Built fresh per call because the scrub rewrites in place.
SentryEvent _eventWithUnpopulatedFields() => SentryEvent(
  threads: [
    SentryThread(
      id: 1,
      name: 'decoder for $_clipPath',
      stacktrace: SentryStackTrace(
        frames: [SentryStackFrame(absPath: _downloadPath, fileName: _downloadPath)],
      ),
    ),
  ],
  user: SentryUser(
    id: 'b4e1-opaque-uuid',
    // Identity, not a path: this function must hand it back untouched, so it deliberately is not
    // the account name (which would make the "names nobody" assertion below test the wrong rule).
    username: 'uma-player',
    data: {
      'last_import': _downloadPath,
      'nested': [
        {'clip': _clipPath},
      ],
    },
  ),
  fingerprint: ['failed writing $_downloadPath'],
);

/// Every field name declared on [className] in the locked SDK's own source file [relativePath].
///
/// Flutter has no mirrors, so the alternative is a hand-written list that is out of date the first
/// time the SDK grows a field -- which is exactly the failure this whole fix is repairing, one level
/// up. Shared by every "swept or excluded on the record" rule below so that adding a model to the
/// scrub does not add a hand-maintained list next to it.
Set<String> _declaredFieldsOf(String relativePath, String className) =>
    declaredInstanceFields(File.fromUri(_sentryRoot().resolve(relativePath)).readAsStringSync(), className);

/// Every instance field declared on `class [className]` in [source].
///
/// **Parsed rather than pattern-matched.** The pattern this replaced spelled the *type* as an
/// alphabet of characters (`[\w<>?, ]+`), so a field whose type carried anything outside it --
/// `({int width, int height})? layout;`, `void Function(String)? onDrop;` -- did not match, was
/// absent from the returned set, and therefore was never asked whether it is swept or excluded.
/// A missing field cannot fail a per-field rule: the rule simply has nothing to say about it, and
/// stays green. The parser enumerates the class's members instead, so a field is found whatever its
/// type is spelled like, and nothing here names a type.
///
/// Statics are dropped (`SentryEvent.defaultFingerprint` is a constant, not event data), and so are
/// getters and methods, which carry no state of their own. Fields inherited from a superclass or
/// mixed in are *not* walked -- `SentryEventLike` declares none today, and a wholesale move of
/// fields into one would be caught loudly by the `containsAll` and length guards each caller
/// carries, not silently absorbed the way a type spelling was.
Set<String> declaredInstanceFields(String source, String className) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final declared = unit.declarations.whereType<ClassDeclaration>().where((e) => e.name.lexeme == className).toList();
  if (declared.length != 1) {
    throw StateError('expected exactly one `class $className`, found ${declared.length}; this rule reads nothing now');
  }
  return {
    for (final member in declared.single.members.whereType<FieldDeclaration>())
      if (!member.isStatic)
        for (final variable in member.fields.variables) variable.name.lexeme,
  };
}

/// The root of the locked `sentry` package, off the resolution this run itself used.
///
/// `Isolate.resolvePackageUri` throws `Unsupported operation` under `flutter_test`, so the package
/// layout is read where the tool writes it.
Uri _sentryRoot() {
  final config = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync());
  final packages = (config['packages'] as List<dynamic>).cast<Map<String, dynamic>>();
  final sentry = packages.where((e) => e['name'] == 'sentry').toList();
  expect(sentry, hasLength(1), reason: 'the sentry package is not resolvable; this rule reads nothing');
  // The trailing slash matters: without it `resolve` replaces the package's own directory instead of
  // descending into it. A `rootUri` may also be relative to the config file.
  final rootUri = sentry.first['rootUri'] as String;
  return Uri.file('.dart_tool/package_config.json').resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
}

/// A [Hint] that cannot be read. `CustomHint.from(hint)` is the first statement of the callback and
/// sits outside the scrub's own reach, so this is the input that exercises the send-or-drop ruling
/// without having to break the scrubber itself.
class _ExplodingHint extends Hint {
  @override
  dynamic get(String key) => throw StateError('the hint could not be read');
}

void main() {
  setUp(_registerWindowsLayout);
  tearDown(() => registerAppRoots(const <String>[]));

  group('the account name leaves through no field of an event, not through the fields anyone listed', () {
    test('the detector reacts: an unscrubbed event is full of the account name', () {
      // The positive control for every "is not there" assertion below. Without it, a scrub that
      // deleted the event's contents and a `toJson` that returned `{}` would both read as a pass.
      final leaks = _stringsNamingTheUser(_eventWithPathsEverywhere());

      expect(leaks, isNotEmpty);
      // Every carrier planted above shows up, so the walk is reaching all of them rather than
      // stopping at the first one: message x3, exception value, two frame fields, breadcrumb
      // message and its two data leaves, two tags-worth, four request fields, culprit,
      // transaction, four context leaves and one extra.
      expect(leaks.length, greaterThanOrEqualTo(18), reason: 'the walk is not reaching every planted field');
    });

    test('after the scrub the whole event names nobody, and still says what failed', () {
      final event = _eventWithPathsEverywhere();

      final scrubbed = scrubUserPathsFromEvent(event);

      expect(_stringsNamingTheUser(scrubbed), isEmpty);
      // Redacted, not deleted. A scrub that emptied every string would satisfy the line above.
      final text = _allTextOf(scrubbed);
      expect(text, contains(r'<app>\temp\7f2\modules.zip'));
      expect(text, contains('training.mkv'));
      expect(text, contains('FileSystemException'));
      expect(text, contains('download_module'));
    });

    test('a context nobody has read is covered too, because the sweep does not know the keys', () {
      // The three `wasm_worker_client.dart` scopes and every context written after this one: the
      // rule has to hold for a key this file has never seen.
      final event = SentryEvent();
      event.contexts['some_future_report'] = {
        'detail': 'failed on $_downloadPath',
        'deeper': [
          {'and_deeper': _clipPath},
        ],
      };

      scrubUserPathsFromEvent(event);

      expect(_stringsNamingTheUser(event), isEmpty);
      expect(_allTextOf(event), contains(r'<app>\temp\7f2\modules.zip'));
    });

    test('the SDK\'s own typed contexts are handed back untouched, instance for instance', () {
      // The identity rule in `_withoutUserPathsInValue`: `contexts['runtime']` is a
      // `List<SentryRuntime>` read back through a typed getter, so writing a plain list over it
      // would make the event fail to serialise. This is what catches a rewrite of that rule.
      final event = SentryEvent(
        contexts: Contexts(
          device: SentryDevice(name: 'PC'),
          runtimes: [SentryRuntime(name: 'Dart', version: '3.11.0')],
          operatingSystem: SentryOperatingSystem(name: 'Windows'),
        ),
      );
      final device = event.contexts.device;
      final runtimes = event.contexts[SentryRuntime.listType];

      scrubUserPathsFromEvent(event);

      expect(identical(event.contexts.device, device), isTrue);
      expect(identical(event.contexts[SentryRuntime.listType], runtimes), isTrue);
      expect(event.contexts.device?.name, 'PC');
      // Serialising is the thing that would actually break, so assert it rather than infer it.
      expect(_allTextOf(event), contains('Windows'));
    });

    test('a tag keeps its key, because a reader filters an issue list by that key', () {
      final event = SentryEvent(tags: {'network.target': _downloadPath});

      scrubUserPathsFromEvent(event);

      expect(event.tags?.keys, ['network.target']);
      expect(event.tags?['network.target'], r'<app>\temp\7f2\modules.zip');
    });

    test('an event carrying nothing is returned as the same instance, not rebuilt', () {
      final event = SentryEvent();
      expect(scrubUserPathsFromEvent(event), same(event));
    });
  });

  group('a redaction that fails costs the report, never the send', () {
    test('a hint that throws drops the event instead of sending it as assembled', () {
      // The SDK pre-seeds `processedEvent` with the original event and only logs when the callback
      // throws (`sentry-9.23.0/lib/src/sentry_client.dart:532-578`), so a throw that escapes here
      // is a send of the *unscrubbed* event -- the opposite of what a redaction failure should cost.
      expect(sentryBeforeSend(_eventWithPathsEverywhere(), _ExplodingHint()), completion(isNull));
    });

    test('the negative control: an ordinary event comes back, scrubbed, and is not dropped', () async {
      // This is what detects the failure mode the drop above creates -- a redaction that throws for
      // *every* event would silently swallow every report, and this test is what goes red for it.
      final sent = await sentryBeforeSend(_eventWithPathsEverywhere(), Hint());

      expect(sent, isNotNull);
      expect(_stringsNamingTheUser(sent ?? SentryEvent()), isEmpty);
      expect(_allTextOf(sent ?? SentryEvent()), contains('FileSystemException'));
    });

    test('the hint still decides the fingerprint and the title, which the guard must not swallow', () async {
      final hint = CustomHint(useUniqueFingerprint: true, titlePrefix: 'Report').toHint();

      final sent = await sentryBeforeSend(SentryEvent(message: SentryMessage('a message')), hint);

      expect(sent?.message?.formatted, '[Report] a message');
      expect(sent?.fingerprint, [sent?.eventId.toString()]);
    });
  });

  group('the fields are enumerated by the machine, off the SDK it has to cover', () {
    /// Every field declared on `SentryEvent`, read out of the locked SDK's own source. Flutter has
    /// no mirrors, so the alternative is a hand-written list that is out of date the first time the
    /// SDK grows a field -- which is exactly the failure this whole fix is repairing, one level up.
    late Set<String> declaredFields;

    // Read through the same helper every other model below uses. It was a second copy of the
    // pattern until it became a parse: two copies drift, and this one had already lost the indent
    // anchoring the other gained after a measured false positive.
    setUpAll(() async {
      declaredFields = _declaredFieldsOf('lib/src/protocol/sentry_event.dart', 'SentryEvent');
    });

    test('the extractor really finds the fields, so a green run below means something', () {
      expect(declaredFields, containsAll(<String>['message', 'exceptions', 'contexts', 'tags', 'breadcrumbs']));
      expect(declaredFields.length, greaterThanOrEqualTo(20));
      // And it is reading the class, not the whole file: `Contexts` fields must not leak in.
      expect(declaredFields, isNot(contains('device')));
    });

    test('every field of an event is either swept or excluded on the record', () {
      // Swept by `scrubUserPathsFromEvent`; asserted field by field by the planted-event tests above.
      const swept = <String>{
        'message',
        'exceptions',
        'breadcrumbs',
        'contexts',
        'extra',
        'tags',
        'request',
        'culprit',
        'transaction',
        // Path-shaped fields of every loaded image only; the identifiers survive. Asserted by the
        // `debug_meta` group below, which also carries its own positive control.
        'debugMeta',
        // Nothing populates these today. They are swept anyway, because "the SDK does not fill it"
        // is a fact about a version: `threads` carries the same `SentryStackTrace` an exception
        // does, `user.data`/`extras` are untyped maps, `fingerprint` is free text, and `unknown` is
        // the passthrough for keys the model has no field for. Asserted by the group below.
        'threads',
        'user',
        'fingerprint',
        'unknown',
      };
      // Excluded. The function's doc comment states a reason for two of these -- `_throwable` (and
      // for `SentryRequest.data`, which is not a field here) -- and that is all it states; this
      // list is this suite's own and is larger, so the reason for each of the rest is written here,
      // next to the name. An earlier version of this comment claimed the doc comment justified all
      // of them, which was false and is how `debugMeta` became a silent exception to a rule that
      // reads as exhaustive. Nothing is on this list because "nothing writes it today": that
      // reasoning moved every field it applied to into `swept` above.
      const excluded = <String>{
        // Not strings, or strings this app or the SDK chooses from a fixed vocabulary: no
        // filesystem path can reach them.
        'eventId', // a UUID the SDK mints
        'timestamp', // a DateTime
        'platform', // an SDK constant ('dart' / 'native')
        'logger', // a logger name; nothing in this app sets it
        'release', // `const appVersion`, set at init
        'dist', // never set by this app
        'environment', // 'production' / 'desktop' / 'web', set at init
        'modules', // Dart package name -> version, not files
        'level', // a `SentryLevel` enum
        'sdk', // the SDK's own name, version and integration names
        'type', // the event-type discriminator
        'serverName', // config, not observation: the SDK's only writer is `options.serverName`,
        // which this app never sets. Asserted by the test below rather than asserted here.
        // Reason stated at the function's doc comment.
        '_throwable', // not serialised; already read into `exceptions`
      };

      for (final field in declaredFields) {
        expect(
          swept.contains(field) || excluded.contains(field),
          isTrue,
          reason: '$field is a field of a sent event that nobody swept or excluded',
        );
      }
    });

    test('the wiring exists on both platforms, which the suite cannot observe because no hub runs', () {
      final source = File('lib/src/core/sentry_util.dart').readAsStringSync();
      expect('options.beforeSend = sentryBeforeSend;'.allMatches(source), hasLength(2));
      // The guard is the whole body, not a line of it: the scrub is the last statement of the try.
      // What the *catch* returns is asserted by behaviour above, not read out of the source — a
      // `contains('return null;')` here would have matched five other returns in the file.
      expect(source, contains('return scrubUserPathsFromEvent(event);'));
    });
  });

  // The four rules above and below rest entirely on this: a field the extractor does not return is
  // never asked whether it is swept or excluded, so the rule is *vacuously true* for exactly the
  // field the SDK just added. That is a silent green, so the extractor is exercised on sources whose
  // answer is known -- including the shapes the pattern this replaced could not read.
  group('the field extractor itself', () {
    const model = '''
class ModelUnderTest {
  static const String defaultTag = 'x';

  String? plain;
  Map<String, dynamic>? mapped;
  final List<Map<String, String>>? nested;

  /// The shapes the previous `[\\w<>?, ]+` type alphabet could not spell, and therefore dropped.
  ({int width, int height})? layout;
  void Function(String path)? onDrop;
  Map<String, void Function()>? handlers;

  int get computed => 1;
  Map<String, dynamic> toJson() {
    final attributes = <String, dynamic>{};
    return attributes;
  }
}

class NotTheModel {
  String? decoy;
}
''';

    test('a field whose type carries a bracket is returned, not dropped', () {
      expect(declaredInstanceFields(model, 'ModelUnderTest'), {
        'plain',
        'mapped',
        'nested',
        'layout',
        'onDrop',
        'handlers',
      });
    });

    test('statics, getters, method bodies and the other classes in the file stay out', () {
      final fields = declaredInstanceFields(model, 'ModelUnderTest');

      expect(fields, isNot(contains('defaultTag')), reason: 'a constant is not event data');
      expect(fields, isNot(contains('computed')), reason: 'a getter holds nothing of its own');
      // `return attributes;` inside `toJson` was read as a field named `attributes` by the pattern
      // this replaced, until an indent anchor was bolted on. A parse cannot make that mistake.
      expect(fields, isNot(contains('attributes')));
      expect(fields, isNot(contains('decoy')), reason: 'it reads the named class, not the file');
    });

    test('a class that is not there fails loudly rather than returning an empty set', () {
      // The failure a silently empty set produces is the same one this whole group exists for:
      // every per-field rule passes because there are no fields to judge.
      expect(() => declaredInstanceFields(model, 'SentryEvent'), throwsStateError);
    });
  });

  group('the loaded-image list is scrubbed of paths and left alone as identifiers', () {
    test('the detector reacts: an unscrubbed image list names the user', () {
      // Positive control for the two "is not there" assertions below. Without it, a `debugMeta`
      // that failed to serialise -- or a `_stringsIn` walk that never descended into `images` --
      // would read as a pass for exactly the leak this group exists to catch.
      final leaks = _stringsNamingTheUser(_eventWithDebugImages());

      // The third-party DLL's `code_file` and the app's own two paths.
      expect(leaks, isNotEmpty);
      expect(leaks.where((e) => e.contains('FileSyncShell64.dll')), isNotEmpty);
      expect(leaks.length, greaterThanOrEqualTo(3), reason: 'the walk is not reaching every image field');
    });

    test('a third-party DLL under the account directory keeps its file name and loses the account', () {
      final event = _eventWithDebugImages();

      scrubUserPathsFromEvent(event);

      expect(_stringsNamingTheUser(event), isEmpty);
      // Redacted, not deleted -- and asserted as the exact marker, not merely as "no account name",
      // so a scrub that emptied `code_file` cannot pass.
      final text = _allTextOf(event);
      expect(text, contains(r'<redacted>\FileSyncShell64.dll'));
      expect(text, contains(r'<redacted>\FileSyncShell64.pdb'));
      // The app's own modules: `<app>` rather than `<redacted>`, same as everywhere else.
      expect(text, contains(r'<app>\umacapture.exe'));
      expect(text, contains(r'<app>\umacapture.pdb'));
    });

    test('the identifiers survive byte for byte, so symbolication still has something to match on', () {
      final event = _eventWithDebugImages();

      scrubUserPathsFromEvent(event);

      final image = event.debugMeta?.images.first;
      expect(image?.debugId, _debugId);
      expect(image?.codeId, _codeId);
      expect(image?.uuid, _debugId);
      expect(image?.type, 'pe');
      expect(image?.imageAddr, '0x7ffb1c2d0000');
      expect(image?.imageVmAddr, '0x0');
      expect(image?.imageSize, 4526080);
      expect(image?.arch, 'x86_64');
    });

    test('a key the SDK did not recognise is swept too, because this code cannot enumerate those', () {
      // `DebugImage.unknown` is whatever sentry-native returned that the Dart model has no field
      // for. Built through `fromJson` because that is the only way it is ever populated.
      final event = SentryEvent(
        debugMeta: DebugMeta(
          images: [
            DebugImage.fromJson(<String, dynamic>{
              'type': 'pe',
              'debug_id': _debugId,
              'some_future_key': 'loaded from $_clipPath',
            }),
          ],
        ),
      );
      expect(_stringsNamingTheUser(event), isNotEmpty, reason: 'the control: the key is on the wire unscrubbed');

      scrubUserPathsFromEvent(event);

      expect(_stringsNamingTheUser(event), isEmpty);
      expect(_allTextOf(event), contains('training.mkv'));
      expect(event.debugMeta?.images.first.debugId, _debugId);
    });

    test('every field of a debug image is either swept or excluded on the record', () {
      // Same rule as the `SentryEvent` one above and for the same reason: `DebugImage` is the model
      // whose growth would otherwise reintroduce the leak silently. Read off the locked SDK's
      // source, not hand-listed.
      final declaredFields = _declaredFieldsOf('lib/src/protocol/debug_image.dart', 'DebugImage');
      // The extractor really found them, so a green run below means something.
      expect(declaredFields, containsAll(<String>['codeFile', 'debugFile', 'debugId', 'unknown']));
      expect(declaredFields.length, greaterThanOrEqualTo(12));

      const swept = <String>{'codeFile', 'debugFile', 'name', 'unknown'};
      // Excluded because none of them is a path: `type` is `'pe'` / `'macho'` / `'elf'`; `debugId`,
      // `codeId` and `uuid` are the identifiers symbolication matches on and are deliberately left
      // byte-identical; the rest are numbers or an architecture name.
      const excluded = <String>{
        'type',
        'debugId',
        'codeId',
        'uuid',
        'imageAddr',
        'imageVmAddr',
        'imageSize',
        'arch',
        'cpuType',
        'cpuSubtype',
      };

      for (final field in declaredFields) {
        expect(
          swept.contains(field) || excluded.contains(field),
          isTrue,
          reason: '$field is a field of a loaded image that nobody swept or excluded',
        );
      }
    });
  });

  group('the fields nothing populates today are swept anyway, because that is a fact about a version', () {
    test('the detector reacts: threads, user data and fingerprint all carry the path', () {
      // Positive control for the "is not there" assertions below.
      final leaks = _stringsNamingTheUser(_eventWithUnpopulatedFields());

      expect(leaks.length, greaterThanOrEqualTo(5), reason: 'the walk is not reaching every planted field');
    });

    test('a top-level key the SDK does not model is swept, which only `fromJson` can produce', () {
      // The one route by which `unknown` arrives non-empty at `beforeSend`.
      final event = SentryEvent.fromJson(<String, dynamic>{
        'event_id': '00000000000000000000000000000000',
        'a_key_this_sdk_does_not_model': 'extracted to $_downloadPath',
      });
      expect(_stringsNamingTheUser(event), isNotEmpty, reason: 'the control: the key is on the wire unscrubbed');

      scrubUserPathsFromEvent(event);

      expect(_stringsNamingTheUser(event), isEmpty);
      expect(_allTextOf(event), contains(r'<app>\temp\7f2\modules.zip'));
    });

    test('after the scrub none of them names the user, and each still says what it said', () {
      final event = _eventWithUnpopulatedFields();

      scrubUserPathsFromEvent(event);

      expect(_stringsNamingTheUser(event), isEmpty);
      final text = _allTextOf(event);
      // Redacted, not deleted -- asserted as the exact markers, per carrier.
      expect(text, contains(r'<app>\temp\7f2\modules.zip')); // thread frame, user data, unknown
      expect(text, contains('training.mkv')); // thread name and the deep leaf of user data
      expect(RegExp(r'<redacted>').allMatches(text).length, greaterThanOrEqualTo(2));
      // The identity fields of a user are not this function's business and are handed back intact.
      expect(event.user?.id, 'b4e1-opaque-uuid');
      expect(event.user?.username, 'uma-player');
    });

    test('a thread frame is scrubbed by the same rule an exception frame is, not a parallel one', () {
      final event = _eventWithUnpopulatedFields();

      scrubUserPathsFromEvent(event);

      final frame = event.threads?.first.stacktrace?.frames.first;
      expect(frame?.absPath, r'<app>\temp\7f2\modules.zip');
      expect(frame?.fileName, r'<app>\temp\7f2\modules.zip');
    });

    test('a fingerprint of ordinary grouping keys is returned byte for byte', () {
      // The rule that stops the sweep from silently re-grouping every issue in the project.
      final event = SentryEvent(fingerprint: ['{{ default }}', 'abc-123']);

      scrubUserPathsFromEvent(event);

      expect(event.fingerprint, ['{{ default }}', 'abc-123']);
    });

    test('serverName cannot carry an observed path, and that is read off the SDK rather than assumed', () {
      // The one field still excluded that is neither a number nor an SDK constant. Its exclusion is
      // a claim about *who writes it*, so the claim is asserted instead of commented: the SDK's only
      // assignment is from `options.serverName`, and this app never sets that.
      final client = File.fromUri(_sentryRoot().resolve('lib/src/sentry_client.dart')).readAsStringSync();
      final writers = RegExp(r'serverName\s*=(?!=)').allMatches(client).map((e) => e.group(0)).toList();
      expect(writers, hasLength(1), reason: 'the SDK grew another writer of serverName; re-judge the exclusion');
      expect(client, contains('..serverName = event.serverName ?? _options.serverName'));
      // And nothing in this app configures it, so it is null on every event.
      final appSources = Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>().where((e) => e.path.endsWith('.dart'));
      expect(appSources, isNotEmpty, reason: 'the app sources are not where this rule looks');
      for (final file in appSources) {
        expect(file.readAsStringSync(), isNot(contains('serverName')), reason: '${file.path} sets serverName now');
      }
    });

    test('every field of a thread and of a user is either swept or excluded on the record', () {
      final threadFields = _declaredFieldsOf('lib/src/protocol/sentry_thread.dart', 'SentryThread');
      expect(threadFields, containsAll(<String>['stacktrace', 'name', 'unknown']));
      // `unknown` on a thread rides along inside the object the scrub does not rebuild; it is listed
      // as excluded rather than pretended to be covered.
      const threadSwept = <String>{'stacktrace', 'name'};
      const threadExcluded = <String>{'id', 'crashed', 'current', 'unknown'};
      for (final field in threadFields) {
        expect(
          threadSwept.contains(field) || threadExcluded.contains(field),
          isTrue,
          reason: '$field is a field of a thread that nobody swept or excluded',
        );
      }

      final userFields = _declaredFieldsOf('lib/src/protocol/sentry_user.dart', 'SentryUser');
      expect(userFields, containsAll(<String>['data', 'extras', 'id']));
      // Identity is not this function's business; the two untyped maps are the only places a *path*
      // can sit, and they are the two that are swept.
      const userSwept = <String>{'data', 'extras'};
      const userExcluded = <String>{'id', 'username', 'email', 'ipAddress', 'geo', 'name', 'unknown'};
      for (final field in userFields) {
        expect(
          userSwept.contains(field) || userExcluded.contains(field),
          isTrue,
          reason: '$field is a field of a user that nobody swept or excluded',
        );
      }
    });
  });
}
