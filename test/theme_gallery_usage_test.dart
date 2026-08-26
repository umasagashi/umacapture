// THE GALLERY'S "USED / NOT USED" MARKS ARE DERIVED FROM THE CODE, SO CHECK THEM AGAINST IT.
// Run: .fvm/flutter_sdk/bin/flutter test test/theme_gallery_usage_test.dart
//
// `lib/src/gui/theme_gallery.dart` shows the whole `ColorScheme` palette with a one-line "what it
// is used for" beside each role, and marks a role "not used" when it has no entry in `_roleUsages`.
// That map is hand-written: it is a snapshot of the code taken by whoever last ran the
// `theme-gallery-refresh` skill, and it goes stale silently -- the gallery keeps asserting a use
// that was deleted, or calls a role unused after somebody started using it. (Measured on
// 2026-08-21: `onSecondaryContainer` claimed "text on the capture info panel" while nothing in
// `lib/` referenced the role at all, and the panel it named no longer existed.)
//
// This test enumerates instead of listing: it derives the role set and the referenced set from the
// source, and compares them. Nothing here names a role, so a role added or dropped anywhere in
// `lib/` is caught without this file being edited -- including a role reached through a local
// alias (`final cs = …colorScheme;`), because the aliases are derived too rather than listed.
//
// The gallery also ships the `ThemeExtension` token sets (`AppSemanticColors`, `AppChartColors`,
// `CodeHighlightColors`), so the second case derives those the same way and checks the gallery
// renders every declared token.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The gallery's own file, read as text: `_roleUsages` is private, and this test is about whether
/// that literal agrees with the code, so reading the literal is the point.
final _gallery = File('lib/src/gui/theme_gallery.dart').readAsStringSync();

/// The extensions file, read as text for the same reason: the token *declarations* are what the
/// gallery has to keep up with, and they are plain fields rather than anything reflectable.
final _extensions = File('lib/src/gui/theme_extensions.dart').readAsStringSync();

/// `ThemeData` accessor -> `ThemeExtension` class, from `AppThemeExtensions`'s own getters
/// (`AppChartColors get chart => extension<AppChartColors>()!;`). A fourth extension is picked up
/// here without this file being edited.
Map<String, String> _extensionAccessors() {
  return {
    for (final match in RegExp(r'\b(\w+)\s+get\s+(\w+)\s*=>\s*extension<').allMatches(_extensions))
      match.group(2)!: match.group(1)!,
  };
}

/// The token fields [className] declares, taken from its class body.
Set<String> _tokenFields(String className) {
  final block = RegExp(
    'class $className extends ThemeExtension<$className> \\{(.*?)\\n\\}',
    dotAll: true,
  ).firstMatch(_extensions);
  expect(block, isNotNull, reason: '$className was renamed or reshaped; this guard is reading nothing');
  return RegExp(
    r'^\s*final\s+[\w<>?, ]+\s+([a-z]\w*);',
    multiLine: true,
  ).allMatches(block!.group(1)!).map((match) => match.group(1)!).toSet();
}

/// Names the gallery itself enumerates as the standard role set, taken from its `roles` list
/// (`('primary', cs.primary, ...)`). Deriving them rather than repeating them means a role the
/// gallery stops showing is not silently dropped from this check too.
Set<String> _knownRoles() {
  return RegExp(r"\('([A-Za-z0-9_]+)', cs\.").allMatches(_gallery).map((m) => m.group(1)!).toSet();
}

/// The keys of the `_roleUsages` map literal.
Set<String> _describedRoles() {
  final block = RegExp(r'const Map<String, String> _roleUsages = \{(.*?)\n\};', dotAll: true).firstMatch(_gallery);
  expect(block, isNotNull, reason: '_roleUsages was renamed or reshaped; this guard is reading nothing');
  return RegExp(
    r"^\s*'([A-Za-z0-9_]+)':",
    multiLine: true,
  ).allMatches(block!.group(1)!).map((m) => m.group(1)!).toSet();
}

/// Roles the gallery deliberately explains as unreferenced, taken from `_unusedNote`'s switch arms.
/// A role listed there is *expected* to be missing from `_roleUsages`, and the arm is where the
/// reason is written down.
Set<String> _explainedUnused() {
  final block = RegExp(
    r'String _unusedNote\(String role\) => switch \(role\) \{(.*?)\n\};',
    dotAll: true,
  ).firstMatch(_gallery);
  expect(block, isNotNull, reason: '_unusedNote was renamed or reshaped; this guard is reading nothing');
  return RegExp(
    r"^\s*'([A-Za-z0-9_]+)' =>",
    multiLine: true,
  ).allMatches(block!.group(1)!).map((m) => m.group(1)!).toSet();
}

/// Names that stand for `<root>` inside one file: `root` itself plus every identifier bound to it.
///
/// Read out of the source rather than listed. Five files under `lib/` bind the scheme to a local
/// (`final cs = Theme.of(context).colorScheme;`) and then use the alias, and a scan that only knows
/// the literal word `colorScheme` sees none of those uses -- measured 2026-08-22: `onTertiaryContainer`
/// had zero `colorScheme.` hits under `lib/` while shipping through `scheme.onTertiaryContainer`.
/// A hand-written alias list would miss whatever name the next author picks, so the *binding* is what
/// is matched, not the name.
Set<String> _aliasesOf(String source, String root) {
  final bound = RegExp('\\b(\\w+)\\s*=\\s*[^;=]*?\\b$root\\s*;').allMatches(source).map((m) => m.group(1)!);
  return {root, ...bound};
}

/// Every `<receiver>.<member>` in [source], for each of [receivers].
Set<String> _membersVia(String source, Set<String> receivers) {
  return {
    for (final receiver in receivers)
      ...RegExp('\\b${RegExp.escape(receiver)}\\.([A-Za-z0-9_]+)').allMatches(source).map((m) => m.group(1)!),
  };
}

/// A `ColorScheme`-typed declaration or parameter, which is the other way a role reaches code
/// without the word `colorScheme` next to it (`AppSemanticColors.light(ColorScheme scheme)`).
final _schemeTyped = RegExp(r'\bColorScheme\??\s+([a-z]\w*)\s*(?=[,)=;])');

/// Every `ColorScheme` role referenced anywhere under `lib/` -- through the getter, a local alias,
/// or a `ColorScheme`-typed parameter -- except the gallery itself (which mentions every role by
/// construction) and generated output.
Set<String> _referencedRoles() {
  final result = <String>{};
  var scanned = 0;
  for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
    final path = file.path.replaceAll(r'\', '/');
    if (!path.endsWith('.dart')) continue;
    if (path.endsWith('/theme_gallery.dart')) continue;
    if (path.endsWith('.g.dart') || path.endsWith('.gr.dart') || path.endsWith('.mapper.dart')) continue;
    scanned += 1;
    final source = file.readAsStringSync();
    final receivers = {
      ..._aliasesOf(source, 'colorScheme'),
      ..._schemeTyped.allMatches(source).map((m) => m.group(1)!),
    };
    result.addAll(_membersVia(source, receivers));
  }
  // Without this the whole test passes by scanning an empty directory.
  expect(
    scanned,
    greaterThan(50),
    reason: 'the lib scan found almost nothing; the guard is looking in the wrong place',
  );
  return result;
}

void main() {
  test('the gallery describes exactly the ColorScheme roles the app references', () {
    final known = _knownRoles();
    expect(known, contains('primary'), reason: 'the role list could not be read out of the gallery');
    expect(known.length, greaterThan(20), reason: 'the role list read back far too short');

    // Restricted to the roles the gallery shows: `colorScheme.brightness` and friends are members
    // of ColorScheme without being colours, and the gallery is the definition of which are roles.
    final referenced = _referencedRoles().intersection(known);
    expect(referenced, isNotEmpty);

    final described = _describedRoles();
    final explained = _explainedUnused();

    // Direction 1 -- the gallery calls a role unused that the code is using. The reviewer reads
    // "not used in the app" beside a colour that ships.
    expect(
      referenced.difference(described),
      isEmpty,
      reason:
          'these roles are referenced under lib/ but have no _roleUsages entry, so the gallery marks '
          'them "not used". Run the theme-gallery-refresh skill.',
    );

    // A role cannot be both described and explained-as-unused: `_roleUsages` wins at render time
    // (`_roleUsages[name] ?? _unusedNote(name)`), so the arm would be dead text and, worse, the
    // exemption below would stop looking at the role entirely. Checked before it is applied.
    // (Measured 2026-08-21: without this, putting the stale `onSecondaryContainer` description back
    // left the whole guard green, because its `_unusedNote` arm excused it.)
    expect(
      described.intersection(explained),
      isEmpty,
      reason: 'these roles carry both a _roleUsages description and an _unusedNote arm; only one can be true',
    );

    // Direction 2 -- the gallery describes a use that no longer exists. Every such role must either
    // come back into use or be moved to _unusedNote with the reason written down.
    expect(
      described.difference(referenced).difference(explained),
      isEmpty,
      reason:
          'these roles have a _roleUsages description but are referenced nowhere under lib/. Remove '
          'the entry (and give _unusedNote an arm if the role is used implicitly).',
    );
  });

  test('the gallery renders every ThemeExtension token declared in theme_extensions.dart', () {
    final accessors = _extensionAccessors();
    expect(
      accessors.keys,
      containsAll(['semantic', 'chart', 'codeHighlight']),
      reason: 'the AppThemeExtensions getters could not be read; this guard is looking at nothing',
    );

    // Only one direction is checkable, and only one needs to be: the gallery renders these by
    // writing `s.<token>` in real Dart, so a token it names that no longer exists is a compile
    // error. A token added to theme_extensions.dart and used in a widget, on the other hand, is
    // silently absent from the gallery -- which is the drift this case exists for.
    for (final MapEntry(key: accessor, value: className) in accessors.entries) {
      final declared = _tokenFields(className);
      expect(declared, isNotEmpty, reason: '$className declared no token fields; the field scan is reading nothing');
      final rendered = _membersVia(_gallery, _aliasesOf(_gallery, accessor));
      expect(
        declared.difference(rendered),
        isEmpty,
        reason:
            'these $className tokens are declared but the gallery never reads them through '
            'Theme.of(context).$accessor, so they ship without a swatch. Run the '
            'theme-gallery-refresh skill.',
      );
    }
  });
}
