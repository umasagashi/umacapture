// Tests for [ResolveInheritanceTile]'s long-read gate — the settings page's "re-resolve
// parent/child links across the whole store" entry.
// Run: .fvm/flutter_sdk/bin/flutter test test/resolve_inheritance_tile_long_read_test.dart
//
// The defect this pins: the tile watched `inheritanceResolutionRunningProvider` and nothing else.
// `CharaDetailRecordStorage.resolveAllInheritance` has announced itself to the registry for some
// time (`LongReadKind.inherit`, over the record store root), so every *other* surface is withheld
// while a resolution runs — but the tile itself asked the registry nothing, so the opposite order
// was wide open: a zip, an export, a whole-store scan or a data-root relocation could have both
// stores open, and the entry was still live to start a pass that reads every record and writes the
// changed ones back.
//
// Its neighbour `RegenerateAllRecordsTile` is gated on exactly this and was the model; the sentence
// is the app's one long-read refusal, so closing this cost no translation entry.
//
// The "is inert while a resolution runs, and says why" half lives in
// `import_refusal_surface_disabled_reasons_test.dart` (S12-01), which is where that defect was
// filed. Only the registry half and the precedence between the two are here.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/localization.dart';

ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

/// A data root the tile can ask about. Nothing is written to it: the gate is a question about
/// paths, and no file has to exist for a path to be covered.
final _layout = PathInfo(
  documentDir: DirectoryPath('/tmp/uma_resolve_tile/documents'),
  supportDir: DirectoryPath('/tmp/uma_resolve_tile/support'),
  executableDir: DirectoryPath('/tmp/uma_resolve_tile/exe'),
  downloadDir: DirectoryPath('/tmp/uma_resolve_tile/downloads'),
);

Future<void> _pumpTile(
  WidgetTester tester, {
  bool resolving = false,
  List<PathEntity> held = const [],
  bool withLayout = true,
  LongReadKind kind = LongReadKind.zip,
}) async {
  final container = ProviderContainer.test(
    overrides: [
      if (withLayout) pathInfoProvider.overrideWithValue(_layout),
      // The tile asks the *layout* where the store is, so that it can answer during a store
      // outage; the store-prepared provider above is left in place for anything else this tree
      // reaches.
      if (withLayout) pathLayoutProvider.overrideWithValue(_layout),
    ],
  );
  // Set before the pump so the tile builds in the state under test rather than rebuilding into it:
  // a tooltip that only appears on the second frame is one the user meets a frame late.
  container.read(inheritanceResolutionRunningProvider.notifier).set(resolving);
  if (held.isNotEmpty) {
    // Deliberately not `inherit`: "a long reader holds the store" and "a resolution of my own is
    // running" have to stay separable, because the tile's precedence between them is what the
    // cases below pin.
    container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: kind, paths: held);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: _theme(),
        home: const Scaffold(body: ResolveInheritanceTile()),
      ),
    ),
  );
  await tester.pump();
}

bool _isInert(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).disabled;

String? _reasonShown(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).tooltip;

/// Every tooltip message currently rendered — what the user could actually hover, rather than what
/// was passed as a parameter.
List<String> _tooltipsShown(WidgetTester tester) => [
  for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) tooltip.message ?? '',
];

void main() {
  setUpAll(loadAppTranslations);

  testWidgets('is inert while a long reader holds the record store, and says why', (tester) async {
    await _pumpTile(tester, held: [_layout.charaDetailDir]);

    expect(_isInert(tester), isTrue, reason: 'a resolution here would rewrite records that reader has open');
    // The shipped sentence read out of `ja.json` as a literal, NOT `key.tr()`: easy_localization
    // renders an unresolved key AS the key, so `contains(key.tr())` would compare the tooltip with
    // itself and stay green with the entry deleted.
    final sentence = appSentenceAt(longReadBusyKey);
    expect(_reasonShown(tester), sentence);
    expect(_tooltipsShown(tester), contains(sentence), reason: 'a Disabled wraps a Tooltip only when given one');
  });

  testWidgets('one record inside the active store is enough, because the pass reads all of them', (tester) async {
    // The shape every record-level claim has: an archive, a regeneration batch and an export all
    // claim `active/<id>` rather than the store. A rule that compared paths for equality would have
    // left this entry live for all three.
    await _pumpTile(tester, held: [_layout.charaDetailActiveDir / 'a-record-id']);

    expect(_isInert(tester), isTrue);
  });

  testWidgets('the archive half holds it too, and not only the active one', (tester) async {
    // The resolution writes back to whichever store owns the changed record, so asking about
    // `active/` alone would have been a right-looking question with half the answer missing.
    await _pumpTile(tester, held: [_layout.charaDetailArchiveDir], kind: LongReadKind.archive);

    expect(_isInert(tester), isTrue);
  });

  testWidgets('a relocation holding the whole data root holds it as well', (tester) async {
    // Containment the other way round: `LongReadKind.relocate` renames `storage/` away wholesale,
    // so its claim sits above the path this tile asks about.
    await _pumpTile(tester, held: [_layout.storageDir], kind: LongReadKind.relocate);

    expect(_isInert(tester), isTrue);
  });

  testWidgets('a long read outside the record store leaves the entry alone', (tester) async {
    // The negative control. Without it every case above would also pass on a tile that went inert
    // for any claim at all — a different, wrong rule that is indistinguishable from here.
    await _pumpTile(tester, held: [_layout.modulesDir], kind: LongReadKind.moduleInstall);

    expect(_isInert(tester), isFalse);
    expect(_reasonShown(tester), isNull);
  });

  testWidgets('a resolution of its own outranks it, and keeps its own specific sentence', (tester) async {
    // Both are true for the whole of the most common case: a running resolution claims the store it
    // is resolving. 「再解決の実行中です」 is the true and specific answer there, and the long
    // reader's sentence would answer "why?" with 「他の処理」 about the user's own resolution.
    await _pumpTile(tester, resolving: true, held: [_layout.charaDetailDir], kind: LongReadKind.inherit);

    expect(_isInert(tester), isTrue);
    expect(
      _reasonShown(tester),
      appSentenceAt('pages.settings.about.resolve_inheritance.blocked.resolving'),
      reason: 'the tile must not rename its own running resolution 「他の処理」',
    );
  });

  testWidgets('an empty registry never asks where the record store is', (tester) async {
    // The guard on the new branch. `pathInfoProvider` is `pathInfoLoader.value!` and throws until
    // the data root has resolved; this tile never depended on it before, and a settings page that
    // crashed on open would be a worse defect than the one being fixed. Mounted with no override at
    // all, so the read would throw if it happened.
    await _pumpTile(tester, withLayout: false);

    expect(_isInert(tester), isFalse);
  });

  group('the blocker table', () {
    test('every reason has a sentence, and none of them is a raw key', () {
      // The table is exhaustive by construction (a `switch` expression over a closed enum), so what
      // is left to check is that each arm names a key that resolves. easy_localization renders a
      // missing key as itself, which is the one failure the compiler cannot see.
      for (final blocker in ResolveInheritanceBlocker.values) {
        final key = resolveInheritanceBlockerKey(blocker);
        expect(appSentenceAt(key), isNotEmpty, reason: '$blocker has no shipped sentence');
        expect(appSentenceAt(key), isNot(contains('{')), reason: '$blocker leaves a placeholder unfilled');
      }
    });

    test('the long-read arm is the app s one sentence and not a copy of it', () {
      // A second literal spelling of the key would resolve to itself if it were mistyped.
      expect(resolveInheritanceBlockerKey(ResolveInheritanceBlocker.longRead), longReadBusyKey);
      expect(appSentenceAt(longReadBusyKey), longReadBusyMessage());
    });

    test('the resolver reports nothing when neither reason holds', () {
      expect(resolveInheritanceBlockerOf(resolving: false, heldBy: null), isNull);
      expect(
        resolveInheritanceBlockerOf(resolving: false, heldBy: LongReadKind.zip),
        ResolveInheritanceBlocker.longRead,
      );
      expect(resolveInheritanceBlockerOf(resolving: true, heldBy: null), ResolveInheritanceBlocker.resolving);
      expect(
        resolveInheritanceBlockerOf(resolving: true, heldBy: LongReadKind.zip),
        ResolveInheritanceBlocker.resolving,
        reason: 'precedence must not depend on which of the two was asked about first',
      );
    });
  });
}
