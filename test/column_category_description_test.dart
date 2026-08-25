// THE COLUMN DIALOG'S PER-CATEGORY GUIDANCE: silent when the omission is deliberate, loud when it
// is not.
// Run: .fvm/flutter_sdk/bin/flutter test test/column_category_description_test.dart
//
// `categoryDescription` was `key.trExists() ? key.tr() : null` -- the naive silencer. Most
// categories have no guidance line, so the "absent" branch is the common case and answering it with
// null looks right. It is not: it makes a RENAMED or DELETED key indistinguishable from a category
// that never wanted a line. The guidance simply stops appearing, and nothing anywhere says so --
// not the app log, not a breadcrumb, not the screen.
//
// So the deliberate case is written into the data (`""` for every category that wants no line) and
// the code reads the two apart: `""` -> nothing to show, absent -> resolve through `tr()`, which
// logs `Localization key [...] not found` and puts the raw key on screen exactly as a missing
// mandatory line does. Both halves are pinned here, in the same file, because satisfying either one
// alone is easy and useless.
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:easy_logger/easy_logger.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/gui/chara_detail/column_builder_dialog.dart';

import 'support/localization.dart';

const _descriptionBase = '$tr_chara_detail.column_spec.dialog.category_description';

void main() {
  setUpAll(loadAppTranslations);

  test('a category key that is not in the translations is still reported as missing', () {
    // Not a category this app has -- which is exactly what a renamed key, or a category added
    // without its entry, looks like from inside the lookup. THE POINT OF THIS FILE: the naive
    // silencer passes every other case here and fails this one.
    const absent = '$_descriptionBase.no_such_category';
    late String? line;
    final logs = localizationLogsDuring(() => line = optionalGuidanceLine(absent));

    expect(logs.map((l) => l.message), contains(contains(absent)), reason: 'a key that should exist and does not');
    expect(logs.map((l) => l.level), contains(LevelMessages.warning), reason: 'reported as a fault, not as chatter');
    expect(line, absent, reason: 'and it reaches the screen as the raw key, as a missing mandatory line does');
  });

  test('a deliberately empty guidance line is answered with null and logged nowhere', () {
    // Which categories want no line is the translators' decision, so it is read out of the shipped
    // file rather than listed here; a list in this file would be a second copy of it that drifts.
    final descriptions = mapAt(localeJson(appLocaleFiles().first), _descriptionBase) ?? const {};
    final silent = ColumnCategory.values.where((c) => descriptions[c.name] == '').toList();
    expect(silent, isNotEmpty, reason: 'there must be a deliberate omission to be quiet about');

    for (final cat in silent) {
      late String? line;
      final logs = localizationLogsDuring(() => line = optionalGuidanceLine(columnCategoryDescriptionKey(cat)));

      expect(line, isNull, reason: '${cat.name}: the chips speak for themselves; there is nothing to add');
      expect(
        logs,
        isEmpty,
        reason: '${cat.name}: THE OTHER POINT -- a probe designed to find nothing must not report it as a fault',
      );
    }
  });

  test('every category resolves its guidance line without warning about it', () {
    // The enumeration is `ColumnCategory.values`, not a list written here: a category added to the
    // enum without an entry in the translations turns this red on its own, which is precisely the
    // event the old code could not report. Run as one body so a single missing entry names itself.
    final logs = localizationLogsDuring(() {
      for (final cat in ColumnCategory.values) {
        optionalGuidanceLine(columnCategoryDescriptionKey(cat));
      }
    });

    expect(ColumnCategory.values, isNotEmpty, reason: 'the loop must have something to loop over');
    expect(logs.map((l) => l.message), isEmpty, reason: 'every category has an entry, empty or not');
  });

  test('at least one category actually has guidance, so the rule is not vacuously satisfied', () {
    // A file where every entry is `""` would pass everything above while showing the user nothing.
    final shown = ColumnCategory.values
        .map((cat) => optionalGuidanceLine(columnCategoryDescriptionKey(cat)))
        .nonNulls
        .toList();

    expect(shown, isNotEmpty);
    expect(
      optionalGuidanceLine(columnCategoryDescriptionKey(ColumnCategory.logic)),
      appSentenceAt('$_descriptionBase.logic'),
      reason: 'read out of the shipped file as a literal, so a rename cannot make this compare a key to itself',
    );
  });

  test('the deliberate omission is an empty string in every shipped locale, not a missing key', () {
    // Pins the representation itself, per locale file. Without this, a well-meaning cleanup that
    // deletes the empty values -- or a second locale that never wrote them -- silently restores the
    // defect, and only the behaviour tests above would notice, and only for the locale they load.
    final locales = appLocaleFiles();
    expect(locales, isNotEmpty, reason: 'the scan must find the locale files, not zero of them');

    for (final path in locales) {
      final descriptions = mapAt(localeJson(path), _descriptionBase);
      expect(descriptions, isNotNull, reason: '$path: defines nothing at $_descriptionBase');
      for (final cat in ColumnCategory.values) {
        expect(
          descriptions?.containsKey(cat.name),
          isTrue,
          reason: '$path: ${cat.name} wants no guidance -- write it as "", do not leave the key out',
        );
        expect(descriptions?[cat.name], isA<String>(), reason: '$path: ${cat.name}');
      }
      expect(
        descriptions?.keys,
        everyElement(isIn(ColumnCategory.values.map((c) => c.name))),
        reason: '$path: an entry for a category that no longer exists is guidance nothing can ever show',
      );
    }
  });

  test('the capture tab\'s deliberate omission is written down in every shipped locale too', () {
    // Stage 5f established `""` for `capture_control.message.importing.action` in `ja.json` and left
    // "any language added later must carry it too" as a note. This is that note, mechanised: the
    // scan is over the files on disk, so the second locale cannot be added without answering it.
    for (final path in appLocaleFiles()) {
      final importing = mapAt(localeJson(path), 'pages.capture.capture_control.message.importing');
      expect(importing?.containsKey('action'), isTrue, reason: '$path: importing.action');
      expect(importing?['action'], '', reason: '$path: the importing state deliberately asks nothing of the user');
    }
  });
}
