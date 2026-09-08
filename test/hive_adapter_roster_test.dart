// The sentry over the second settings-value rendering tier
// (`SettingsValueTier.registeredType`): the rule that a value whose runtime type
// carries a registered Hive adapter is shown as its `dart_mappable` JSON, and
// everything else falls through to `toString()`.
//
//   .fvm/flutter_sdk/bin/flutter test test/hive_adapter_roster_test.dart
//
// WHY THIS IS A TEST AND NOT A COUNT. The requirement is to enumerate
// `hive_adapter.dart`'s registrations and split them into the types that can be
// JSON-encoded and the types that cannot, because a type that cannot would have
// to be handled by the three rendering tiers explicitly. Counting once answers that for today
// and for nobody else: `hive_adapter.dart` says in its own comment that new types
// are expected ("Add new types at the end with the next unused id"), and the
// storage view renders an unencodable value as `toString()` **successfully** —
// there is no error, no empty screen, nothing a later reader would notice. So the
// count is kept here, where adding an adapter makes it fail.
//
// It is written in the shape `storage_group_test.dart` and `app_root_scrub_test.dart`
// use: read the declaration out of the source, because nothing can enumerate a
// library's registrations at runtime.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/storage/settings_value_render.dart';
import 'package:umacapture/src/preference/hive_adapter.dart';

/// Every `JsonAdapter<T>(id)` written in [source], as `T#id`.
///
/// The `(id)` in the pattern is what keeps it from matching the class
/// declaration (`class JsonAdapter<T> extends …`) or a doc comment, so the
/// extractor finds registrations and only registrations.
Set<String> declaredAdapters(String source) {
  return RegExp(
    r'JsonAdapter<(\w+)>\((\d+)\)',
  ).allMatches(source).map((match) => '${match.group(1)}#${match.group(2)}').toSet();
}

/// The same set, read out of the running program instead of out of the source.
Set<String> visitedAdapters() {
  final found = <String>{};
  visitHiveAdapters(<T>(JsonAdapter<T> adapter) => found.add('$T#${adapter.typeId}'));
  return found;
}

/// The typeId of every adapter [visitHiveAdapters] visits, **as a list and not a
/// set**, so that two adapters claiming the same id survive the collection
/// instead of collapsing into a single entry.
///
/// Read from the visitor rather than from a table, so it counts whatever the
/// declaration list happens to hold — a seventh adapter is covered the day it is
/// written, without this file being told about it.
List<int> visitedTypeIds() {
  final ids = <int>[];
  visitHiveAdapters(<T>(JsonAdapter<T> adapter) => ids.add(adapter.typeId));
  return ids;
}

/// Every value of [ids] that occurs more than once.
Set<int> duplicateTypeIds(List<int> ids) {
  return ids.where((id) => ids.where((other) => other == id).length > 1).toSet();
}

/// Whether [source] calls `registerAdapter`, ignoring anything inside comments.
///
/// **Receiver-free on purpose.** `Hive.registerAdapter(` is the only spelling in
/// the repository today — one call, in [declarationFile]; every other occurrence
/// of the identifier under `lib/` is prose — but the identifier is what makes a
/// registration a registration, so the scan keys on the identifier and accepts
/// any receiver. That is what lets it see `Hive.registerAdapter<Size>(`,
/// `Hive\n    .registerAdapter(`, `Hive..registerAdapter(` and
/// `h.registerAdapter(`, none of which the earlier
/// `contains('Hive.registerAdapter(')` could match. The lookbehind is what keeps
/// it from firing on an unrelated `myRegisterAdapter(`.
///
/// It is still a textual scan and not a parse: an identifier assembled at runtime
/// (`Function.apply`, mirrors) evades it. That has no plausible accidental
/// motivation, so the guard accepts the gap rather than growing into a parser.
bool callsRegisterAdapter(String source) {
  return RegExp(r'(?<![\w$])registerAdapter\s*(<[^()]*?>)?\s*\(').hasMatch(withoutComments(source));
}

/// [source] with `//` line comments and `/* … */` block comments removed, so a
/// scan reads what the file *does* and not what it says about itself.
String withoutComments(String source) {
  final withoutBlockComments = source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlockComments.split('\n').where((line) => !line.trimLeft().startsWith('//')).join('\n');
}

/// The name of every class in [source] whose declaration derives from
/// `TypeAdapter`.
///
/// The offender scan skips [declarationFile] — that file is the one place
/// allowed to register — so nothing else looks *inside* it. A second
/// `TypeAdapter` subclass written there would be registered legitimately, be
/// invisible to [declaredAdapters] (which only matches `JsonAdapter<T>(id)`),
/// and reach the storage view as `toString()` with no error. This reads the
/// declarations instead of the registrations, so it sees such a class.
Set<String> typeAdapterSubclasses(String source) {
  return RegExp(
    r'class\s+(\w+)[^{;]*\b(?:extends|implements|with)\b[^{;]*\bTypeAdapter\b',
  ).allMatches(withoutComments(source)).map((match) => match.group(1) ?? '').toSet();
}

/// The argument text of every `registerAdapter(…)` call in [source].
///
/// The companion to [typeAdapterSubclasses]: a `TypeAdapter` declared in another
/// package (a generated adapter, say) could be registered inside
/// [declarationFile] without any class being declared there, so the subclass
/// check alone would not see it. Reading the arguments makes any registration
/// other than the visitor's own parameter visible.
Set<String> registeredAdapterArguments(String source) {
  return RegExp(
    r'(?<![\w$])registerAdapter\s*(?:<[^()]*?>)?\s*\(([^()]*(?:\([^()]*\))?[^()]*)\)',
  ).allMatches(withoutComments(source)).map((match) => (match.group(1) ?? '').trim()).toSet();
}

/// The one file allowed to register adapters.
const declarationFile = 'lib/src/preference/hive_adapter.dart';

/// The call [callsRegisterAdapter]'s positive control is calibrated against.
const theOneRegistration = 'Hive.registerAdapter(adapter);';

/// The roster as it has been reviewed against the rendering tiers.
///
/// **A literal on purpose.** Everything else in this file is derived, so a
/// derived-vs-derived comparison would agree with itself forever; this is the
/// side a human wrote, and it is what a new adapter has to be brought past.
const _reviewedRoster = <String>{
  'Size#0',
  'Offset#1',
  'ThemeMode#2',
  'CharaDetailRecordImageMode#3',
  'ClipboardPasteImageMode#4',
  'RowHeightMode#5',
};

/// One value of each registered type, so "can this be JSON-encoded" is answered
/// by encoding one rather than by assuming.
const _samples = <String, Object>{
  'Size#0': Size(1280, 720),
  'Offset#1': Offset(12, 34),
  'ThemeMode#2': ThemeMode.dark,
  'CharaDetailRecordImageMode#3': CharaDetailRecordImageMode.skillPlain,
  'ClipboardPasteImageMode#4': ClipboardPasteImageMode.file,
  'RowHeightMode#5': RowHeightMode.autoPerRow,
};

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/src/preference/hive_adapter.dart').readAsStringSync();
    initializeMappers();
  });

  test('the set of registered adapters is the one tier 2 was reviewed against', () {
    // When this fails, the adapter set changed. Check the new type against the
    // rendering rules: if `MapperContainer.globals.toJson` can encode it, the
    // tier-2 case below will already be green and this roster only needs the new
    // entry; if it cannot, the view will render it with `toString()` and the
    // rendering rules need a decision before the roster is updated.
    expect(declaredAdapters(source), _reviewedRoster);
  });

  test('no two adapters claim the same typeId', () {
    // Asserted as its own claim, not left to fall out of the roster comparison
    // above. typeId is the on-disk identity, and `registerHiveAdapters` guards
    // every call with `Hive.isAdapterRegistered`, so a repeated id does not throw:
    // the second adapter is silently never registered and its type is written by
    // the first one's mapper. The roster comparison would only notice such a
    // change by disagreeing with `_reviewedRoster` — and `_reviewedRoster` is the
    // literal a developer edits when this file turns red, so the disagreement is
    // exactly the evidence that gets edited away.
    final ids = visitedTypeIds();
    expect(duplicateTypeIds(ids), isEmpty, reason: 'typeId is the on-disk identity and must be unique: $ids');
  });

  test('the duplicate-typeId check reports a repeated id rather than always finding none', () {
    // Without this, `duplicateTypeIds` returning a constant empty set would look
    // exactly like a roster that is in order.
    expect(duplicateTypeIds([0, 1, 2]), isEmpty);
    expect(duplicateTypeIds([0, 1, 0]), {0});
    expect(duplicateTypeIds([3, 3, 3]), {3});
  });

  test('the extractor is looking at something (it would pass on an empty file)', () {
    // A regex that stops matching — a rename, a reformat that splits the call
    // across lines — empties the left-hand side of the comparison above, and an
    // empty set is exactly what "no adapters were added" looks like. Asserting a
    // known member is what makes the sentry fail loudly rather than pass
    // vacuously.
    expect(declaredAdapters(source), contains('Size#0'));
    expect(declaredAdapters(''), isEmpty);
  });

  test('the source-derived and program-derived readings of the same list agree', () {
    // This does NOT catch a direct `Hive.registerAdapter` call written outside
    // `visitHiveAdapters`: both sides here are derived from this one file (the
    // regex from its text, `visitedAdapters` from actually running its
    // function), so a registration elsewhere is invisible to both and the
    // comparison would still agree. What this guards is narrower — that the
    // regex above still parses every entry `visitHiveAdapters` really visits
    // (a reformat that the pattern stops matching would desync the two).
    // The out-of-band-registration claim is checked below instead, by reading
    // every other file `visitHiveAdapters` cannot see.
    expect(visitedAdapters(), declaredAdapters(source));
  });

  test('no direct Hive.registerAdapter call exists outside the single declaration list', () {
    // The claim the previous test's old comment mistakenly attributed to
    // itself: that a registration written outside `visitHiveAdapters` (a
    // stray `Hive.registerAdapter(...)` in some other file) cannot ship
    // unnoticed. Unlike the comparison above, this reads files other than
    // `hive_adapter.dart`, which is what makes it able to see a call the
    // single declaration list does not own.
    //
    // The spellings this reaches, and the one it does not, are stated on
    // [callsRegisterAdapter] and pinned by the control test below.
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) {
        continue;
      }
      if (file.path.replaceAll('\\', '/').endsWith(declarationFile)) {
        continue;
      }
      if (callsRegisterAdapter(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Hive.registerAdapter must only be called from registerHiveAdapters() in $declarationFile',
    );
  });

  test('the registerAdapter scan fires on the one real registration and stops when it is removed', () {
    // The scan above is the only one in this file whose corpus contains no
    // positive example: `lib/` has exactly one registration and it is the file
    // the loop skips, so an always-false detector would pass it forever. This
    // feeds the detector the declaration file directly, then the same file with
    // the registration deleted, so the pass above means "found none", not
    // "cannot find any".
    final declaration = File(declarationFile).readAsStringSync();
    expect(declaration, contains(theOneRegistration), reason: 'the calibration call moved or was rewritten');
    expect(callsRegisterAdapter(declaration), isTrue, reason: 'the scan cannot see the app\'s only registration');
    expect(
      callsRegisterAdapter(declaration.replaceAll(theOneRegistration, '')),
      isFalse,
      reason: 'the scan fires on prose about the call rather than on the call',
    );

    // Spellings `lib/` does not contain, so nothing else could show the pattern
    // reaches them. The first is the one the old `contains(...)` missed.
    expect(callsRegisterAdapter('Hive.registerAdapter<Size>(adapter);'), isTrue);
    expect(callsRegisterAdapter('Hive.registerAdapter<Map<String, int>>(adapter);'), isTrue);
    expect(callsRegisterAdapter('Hive\n    .registerAdapter(adapter);'), isTrue);
    expect(callsRegisterAdapter('Hive..registerAdapter(a)..registerAdapter(b);'), isTrue);
    expect(callsRegisterAdapter('final h = Hive;\nh.registerAdapter(adapter);'), isTrue);

    // …and the things it must keep quiet about.
    expect(callsRegisterAdapter('// Hive.registerAdapter(adapter);'), isFalse);
    expect(callsRegisterAdapter('/// See `Hive.registerAdapter`, which resolves by `value is T`.'), isFalse);
    expect(callsRegisterAdapter('/* Hive.registerAdapter(adapter); */'), isFalse);
    expect(callsRegisterAdapter('registerHiveAdapters();'), isFalse);
    expect(callsRegisterAdapter('myRegisterAdapter(adapter);'), isFalse);
  });

  test('JsonAdapter is the only TypeAdapter the declaration file declares', () {
    // The blind spot left by the two scans above: `declaredAdapters` matches
    // `JsonAdapter<T>(id)` and nothing else, and the offender scan skips this
    // file by path. A second `TypeAdapter` subclass written here would therefore
    // be registered correctly, be absent from the roster, and reach the storage
    // view through `toString()` — no error, no empty screen. Everything else in
    // this file assumes `JsonAdapter` is the whole story; this is where that
    // assumption is checked rather than relied on.
    expect(
      typeAdapterSubclasses(File(declarationFile).readAsStringSync()),
      {'JsonAdapter'},
      reason: 'a TypeAdapter other than JsonAdapter is not covered by the roster or by rendering tier 2',
    );
  });

  test('the declaration file registers nothing but the visitor\'s own adapter', () {
    // The other half: a `TypeAdapter` declared in another library needs no class
    // declaration here to be registered here, so the subclass check above would
    // not see it. `adapter` is `visitHiveAdapters`'s callback parameter, so this
    // says every registration still comes from the single declaration list.
    expect(
      registeredAdapterArguments(File(declarationFile).readAsStringSync()),
      {'adapter'},
      reason: 'every registration must come from visitHiveAdapters, not from a hand-written call',
    );
  });

  test('the TypeAdapter-declaration and registration-argument scans see what is really there', () {
    // Both assertions above pass by finding one known thing, so an extractor that
    // returned a constant would look identical to a file in order.
    expect(typeAdapterSubclasses('class Foo extends TypeAdapter<int> {}'), {'Foo'});
    expect(typeAdapterSubclasses('class Bar implements TypeAdapter<int> {}'), {'Bar'});
    expect(typeAdapterSubclasses('class Baz<T> extends TypeAdapter<T?> with Mixin {}'), {'Baz'});
    expect(typeAdapterSubclasses('class Plain extends Other {}'), isEmpty);
    expect(typeAdapterSubclasses('// class Ghost extends TypeAdapter<int> {}'), isEmpty);

    expect(registeredAdapterArguments('Hive.registerAdapter(GeneratedAdapter());'), {'GeneratedAdapter()'});
    expect(registeredAdapterArguments('Hive.registerAdapter<Size>(const JsonAdapter<Size>(0));'), {
      'const JsonAdapter<Size>(0)',
    });
    expect(registeredAdapterArguments('// Hive.registerAdapter(sneaky);'), isEmpty);
    expect(registeredAdapterArguments('nothing here'), isEmpty);
  });

  test('every registered type encodes to JSON, so tier 2 covers all of them', () {
    expect(_samples.keys.toSet(), _reviewedRoster, reason: 'a sample per registered type');
    for (final entry in _samples.entries) {
      final encoded = encodeRegisteredHiveValue(entry.value);
      expect(encoded, isNotNull, reason: '${entry.key} produced no JSON');
      // Encoding to *something* is not enough: the view hands the result to a JSON
      // pretty-printer, so it has to parse.
      expect(() => jsonDecode(encoded ?? ''), returnsNormally, reason: '${entry.key} did not encode to JSON');
    }
  });

  test('a type outside the roster is declined rather than guessed at', () {
    // The other half of tier 2: it has to say "not mine" for the strings, ints
    // and bools that make up most of a settings box, or tier 3 would never be
    // reached and every plain value would be run through a mapper.
    expect(encodeRegisteredHiveValue('trainer-abc'), isNull);
    expect(encodeRegisteredHiveValue(42), isNull);
    expect(encodeRegisteredHiveValue(const Duration(seconds: 1)), isNull);
  });

  test('a registered value reaches rendering tier 2 end to end', () {
    // The roster and the renderer are separately correct above; this is the one
    // case that says they are wired to each other.
    final view = renderSettingsValue(ThemeMode.dark, encodeRegistered: encodeRegisteredHiveValue);

    expect(view.tier, SettingsValueTier.registeredType);
    expect(view.isJson, isTrue);
  });
}
