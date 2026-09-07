// The three settings-value rendering tiers against a real browser settings store
// (stage 4e).
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/settings_value_render_web_test.dart
//
// WHY THIS EXISTS. The settings group is required to
// work on web, and the settings group is a synthetic node -- a list of stores
// rather than part of the filesystem tree -- because on web a settings store is
// not a file at all: `hive_ce` keeps it in IndexedDB. Everything the VM suites assert about a
// store's contents therefore rests on an assumption they cannot check -- that a
// value put into a store comes back the same on the platform where the store is a
// database. This suite checks it, on the same three rules, against real
// IndexedDB.
//
// It deliberately does not import `storage_box.dart`, for the reason
// `settings_box_deletion_web_test.dart` gives: that library reaches
// `package:hive_ce_flutter` and therefore `package:flutter`, which `dart test`
// cannot compile for a browser. `package:hive_ce` has no Flutter dependency and
// is the same `Hive` global `StorageBox` uses, and `settings_value_render.dart`
// is pure Dart on purpose -- that is the whole reason the rendering decision was
// kept out of the widget layer.
//
// WHAT IT DOES NOT REACH. The second tier, `encodeRegisteredHiveValue`, is
// unreachable here: the six registered types are `dart:ui` and Material ones, so
// the encoder cannot be compiled for this suite. Tier 2 is exercised through a
// stand-in encoder, which shows the *ordering* holds on web; the membership of
// tier 2 is `hive_adapter_roster_test.dart`'s, on the VM. Nothing here says
// anything about the tab's widgets, which `package:flutter` puts out of reach.
@TestOn('browser')
library;

import 'package:hive_ce/hive.dart';
// `package:test` resolves transitively through `flutter_test`, so no
// dev_dependency entry is added -- see the sibling browser suites for the same
// note.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:umacapture/src/core/json_format.dart';
import 'package:umacapture/src/core/storage/settings_value_render.dart';

/// A preset string of the shape `spec/base.dart` writes into `column_spec`: one
/// line, no spaces, so re-indentation is a visible difference.
const _columnSpecJson = '{"presets":[{"id":"a","columns":[1,2,3]}],"version":3}';

/// Stands in for the app's registered-type encoder, which cannot be compiled
/// here. See the header.
String? _fakeEncoder(Object value) => value is Duration ? '{"ms":${value.inMilliseconds}}' : null;

/// A database name per run, so a previous run's records cannot answer for this
/// one. `Hive.init`'s path argument is ignored by the web backend, so the name is
/// the only thing separating two stores in a browser profile.
String _storeName() => 'umacapture_render_${DateTime.now().microsecondsSinceEpoch}';

void main() {
  late Box<dynamic> box;
  late String name;

  setUp(() async {
    name = _storeName();
    // Ignored on web, as `settings_box_deletion_web_test.dart` records; passed
    // anyway so this reads like the call `StorageBox.ensureOpened` makes.
    Hive.init('umacapture/settings');
    box = await Hive.openBox<dynamic>(name);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(name);
    await Hive.close();
  });

  test('a JSON string survives IndexedDB and lands in tier 1', () async {
    // The web half of that same check. `column_spec` is the largest store
    // on a real installation and holds plain JSON strings, so it is the one whose
    // rendering the browser has to agree with Windows about.
    await box.put('preset', _columnSpecJson);

    final view = renderSettingsValue(box.get('preset'), encodeRegistered: _fakeEncoder);

    expect(view.tier, SettingsValueTier.jsonString);
    expect(view.isJson, isTrue);
    expect(view.text, prettyPrintJson(_columnSpecJson));
    expect(view.text, isNot(_columnSpecJson), reason: 'the stored string is not indented');
  });

  test('the value read back is the value written, not a browser rendition of it', () async {
    // The assumption the VM suites cannot check, stated on its own: if IndexedDB
    // handed back anything but the identical string, the tier above would be an
    // accident of this particular payload.
    await box.put('preset', _columnSpecJson);

    expect(box.get('preset'), _columnSpecJson);
  });

  test('the tiers keep their order on web', () async {
    await box.put('trainer', 'trainer-abc');
    await box.put('count', 3);
    await box.put('flag', true);

    expect(renderSettingsValue(box.get('trainer'), encodeRegistered: _fakeEncoder).tier, SettingsValueTier.plain);
    expect(renderSettingsValue(box.get('trainer'), encodeRegistered: _fakeEncoder).text, 'trainer-abc');
    expect(renderSettingsValue(box.get('count'), encodeRegistered: _fakeEncoder).text, '3');
    expect(renderSettingsValue(box.get('flag'), encodeRegistered: _fakeEncoder).text, 'true');
    expect(
      renderSettingsValue(const Duration(seconds: 2), encodeRegistered: _fakeEncoder).tier,
      SettingsValueTier.registeredType,
    );
  });

  test('every key of the store is enumerable, which is what a listing needs', () async {
    // `StorageBox.entries()` is built on `Box.keys` + `Box.get`. That pair is
    // what makes the settings group non-empty on web -- the check point for
    // showing it as a list of stores rather than as files -- and it
    // is a browser fact rather than a Dart one.
    await box.put('a', '{"x":1}');
    await box.put('b', 'plain');

    final entries = [for (final key in box.keys) (key: '$key', value: box.get(key))];

    expect(entries.map((e) => e.key), containsAll(<String>['a', 'b']));
    expect(renderSettingsValue(entries.firstWhere((e) => e.key == 'a').value).tier, SettingsValueTier.jsonString);
    expect(renderSettingsValue(entries.firstWhere((e) => e.key == 'b').value).tier, SettingsValueTier.plain);
  });
}
