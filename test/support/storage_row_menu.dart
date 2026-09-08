// Reading the storage view's one trailing control — the ⋮ that opens a row's
// menu — and the entries of the menu behind it.
//
// **Shared rather than copied into each suite.** Eight suites used to name a
// control of their own on a storage row (the copy button, the zip button, the
// delete button); all of them now reach the same actions through one button and
// one menu. A private copy of these readings per file is where those suites
// would come to disagree about what "the entry is withheld" means — and one of
// them already held a hand-copied `_menuEntry` before this file existed.
//
// **Two different questions, deliberately kept apart.**
//
//  * [storageRowMenuEnabled] asks whether the row's menu may be *opened at all*.
//    That is the row-level gate: while it is closed, no entrance opens the menu,
//    so nothing on the menu is observable and the button's tooltip is the whole
//    of what the view says about the row.
//  * [storageMenuEntryEnabled] asks whether one entry of an *open* menu will act.
//    An entry re-reads its own refusal on every frame it paints, so this is the
//    reading that survives a claim beginning while the menu is up.
//
// A suite that wants "this row's delete is withheld" has to choose: with the
// refusal already in force the answer is the first question, because the second
// is unreachable; with the refusal arriving afterwards, both are.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_test/flutter_test.dart';

import 'localization.dart';

/// The shipped label of one storage action, read out of `ja.json`.
///
/// A literal from the translation file and never a second `.tr()`: `.tr()`
/// renders a missing key as the key itself, so a label compared against another
/// `.tr()` of the same key agrees with itself whether or not the entry exists.
String storageActionLabel(String action) => appSentenceAt('pages.storage.actions.$action');

/// The row's ⋮ as the widget it is, so `onPressed` and `tooltip` are read rather
/// than inferred from how the button looks.
IconButton storageRowMenuButton(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget, reason: 'expected exactly one row menu button keyed $key');
  return tester.widget<IconButton>(finder);
}

/// Whether the row keyed [key] will open its menu for any of the three
/// entrances. The button, the secondary press and the long press share one
/// reading (`storageRowMenuRefusalOf`), so this is that reading seen through the
/// only entrance that exposes it as a value.
bool storageRowMenuEnabled(WidgetTester tester, Key key) => storageRowMenuButton(tester, key).onPressed != null;

/// The sentence the withheld row carries, or null when the row is free.
String? storageRowMenuTooltip(WidgetTester tester, Key key) => storageRowMenuButton(tester, key).tooltip;

/// Presses the row's ⋮ and lets the menu route settle.
///
/// `warnIfMissed: false` so the same call is usable on a *disabled* button,
/// which is how a suite asserts that pressing anyway reached nothing.
Future<void> pressStorageRowMenuButton(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key), warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Opens a row's menu with the secondary button — the entrance a mouse has.
Future<void> secondaryPressStorageRow(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Opens a row's menu with a long press — the entrance a touch screen has.
Future<void> longPressStorageRow(WidgetTester tester, Finder target) async {
  await tester.longPress(target);
  await tester.pump(const Duration(milliseconds: 200));
}

/// Closes the menu that is open, so a second row's menu can be read in the same
/// arrangement without two of them being on screen at once — which
/// [storageMenuEntry] would report as an ambiguous label rather than as the
/// mistake it is.
///
/// Popped rather than dismissed by a tap on the barrier: a tap has to land
/// somewhere, and every position on this screen is over a row that has a menu of
/// its own. `showContextMenu` pushes on the root navigator, which in these
/// suites is the one `MaterialApp` builds.
Future<void> dismissStorageMenu(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  expect(navigator.canPop(), isTrue, reason: 'expected a menu route to be open');
  navigator.pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Hovers the row's ⋮ long enough for its tooltip to be painted, and leaves the
/// pointer off it again.
///
/// Read as painted text after a real hover rather than as the string the widget
/// was handed: while the button is dead its tooltip is the only surface the
/// reason has, and asserting the argument asserts nothing about the screen.
/// The caller makes its `find.text` assertion between the two halves — this
/// returns after the tooltip is up.
Future<TestGesture> hoverStorageRowMenuButton(WidgetTester tester, Key key) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byKey(key)));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  return gesture;
}

/// Takes the pointer [gesture] back off the button and lets the tooltip go.
Future<void> unhover(WidgetTester tester, TestGesture gesture) async {
  await gesture.moveTo(Offset.zero);
  await tester.pump(const Duration(seconds: 2));
}

/// The open menu's entry labelled [label], as the model the menu was built from.
///
/// A menu entry is not itself a widget, but the package wraps each one in a
/// `MenuEntryWidget` that holds it in a public `entry` field. That wrapper is not
/// exported from the package's umbrella library, so it is matched by the name its
/// runtime type reports and read dynamically; `ContextMenuItem` — the type that
/// declares `enabled` — *is* exported, so the value that comes back is checked
/// statically and nothing about `enabled` is read through `dynamic`.
///
/// The label is read through `dynamic` because the entry type is private to
/// `storage_tree.dart`; it is a plain `String` there, since the entry decides its
/// own colours from the availability it re-reads on every frame rather than from
/// a `Text` fixed when the menu opened.
ContextMenuItem storageMenuEntry(WidgetTester tester, String label) {
  final matches = tester.allWidgets
      .where((widget) => widget.runtimeType.toString().startsWith('MenuEntryWidget'))
      .map((widget) => (widget as dynamic).entry)
      .whereType<ContextMenuItem>()
      .where((item) => (item as dynamic).label == label)
      .toList();
  expect(matches, hasLength(1), reason: 'expected exactly one menu entry labelled "$label"');
  return matches.single;
}

/// Whether the open menu's entry labelled [label] will act when it is selected.
///
/// The entry's own `enabled`, and not the colour it is drawn in: a regression
/// that greyed the label while leaving the entry pressable would pass a
/// colour-only assertion.
bool storageMenuEntryEnabled(WidgetTester tester, String label) => storageMenuEntry(tester, label).enabled;

/// Whether the open menu's entry labelled [label] is *drawn* in the disabled
/// colour.
///
/// Kept alongside [storageMenuEntryEnabled] rather than replaced by it: one is
/// what the entry does, the other is what the user sees, and a regression can
/// break either without the other. Compared against the same `theme.disabledColor`
/// the entry itself reads, taken from the entry's own context, so a theme change
/// cannot turn this into a comparison with a constant.
bool storageMenuEntryLooksDisabled(WidgetTester tester, String label) {
  final finder = find.text(label);
  expect(finder, findsOneWidget, reason: 'expected exactly one menu entry labelled "$label"');
  final theme = Theme.of(tester.element(finder));
  return tester.widget<Text>(finder).style?.color == theme.disabledColor;
}

/// Whether the open menu's entry labelled [label] is *drawn* as destructive.
///
/// Compared against `colorScheme.error` taken from the entry's own context, for
/// [storageMenuEntryLooksDisabled]'s reason: the assertion has to fail when the
/// entry stops reading the role, not when the palette changes.
bool storageMenuEntryLooksDestructive(WidgetTester tester, String label) {
  final finder = find.text(label);
  expect(finder, findsOneWidget, reason: 'expected exactly one menu entry labelled "$label"');
  final error = Theme.of(tester.element(finder)).colorScheme.error;
  final labelColored = tester.widget<Text>(finder).style?.color == error;
  // The glyph as well as the word: the buttons this menu replaced carried the
  // colour on the icon, and an entry whose label alone turned red would be a
  // half-restored affordance that a label-only assertion would call restored.
  final row = find.ancestor(of: finder, matching: find.byType(Row)).first;
  final icon = find.descendant(of: row, matching: find.byType(Icon));
  expect(icon, findsOneWidget, reason: 'expected the entry labelled "$label" to carry one icon');
  return labelColored && tester.widget<Icon>(icon).color == error;
}
