// THE TWO DASHBOARD CARDS THAT SPEAK TO SOMEONE WITH NOTHING CAPTURED YET.
// Run: .fvm/flutter_sdk/bin/flutter test test/dashboard_cards_test.dart
//
// `AboutGroup` is the web front page's opening sentence and its three outbound links, and
// `StatisticGroup` is the card underneath it, which on a first visit has no data to show. Both are
// asserted against the shipped `ja.json` literals rather than against `key.tr()`, because
// easy_localization renders a key it cannot resolve AS THE KEY — so a key comparison passes whether
// or not the entry exists (see `appSentenceAt`).
//
// WHAT IS NOT REACHABLE FROM HERE: that `AboutGroup` is mounted on web only. The gate is
// `CurrentPlatform.isWeb()` in `DashboardPage`, which is false under `flutter test` on the VM, so
// the card's presence on the web dashboard has to be seen in a browser. The card itself is public
// precisely so its content can be pinned here regardless.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/const.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/gui/dashboard.dart';
import 'package:umacapture/src/gui/statistics.dart';

import 'support/localization.dart';
import 'support/records.dart';

/// A store that has finished scanning and holds [preloaded].
class _LoadedRecordStorage extends CharaDetailRecordStorage {
  _LoadedRecordStorage(this.preloaded);

  final List<CharaDetailRecord> preloaded;

  @override
  Future<List<CharaDetailRecord>> build() async => preloaded;
}

/// A store whose scan never finishes — the state a user with many records is in for the first
/// seconds after launch, and the one the empty message must not be shown for.
class _PendingRecordStorage extends CharaDetailRecordStorage {
  @override
  Future<List<CharaDetailRecord>> build() => Completer<List<CharaDetailRecord>>().future;
}

/// Pumps [StatisticGroup] over the given store.
///
/// `statisticsInitialLoader` is held pending on purpose: the tiles guard their bodies with it, so
/// this keeps each tile on its own spinner instead of reaching the label-map and module loaders,
/// which would issue real requests from a widget test. What is under test here is which BODY the
/// card chooses, not what the tiles eventually draw.
Future<void> _pumpStatistics(WidgetTester tester, CharaDetailRecordStorage Function() storage) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        charaDetailRecordStorageLoaderProvider.overrideWith(storage),
        statisticsInitialLoader.overrideWith((ref) => Completer<List<Object>>().future),
      ],
      child: const MaterialApp(
        locale: appTestLocale,
        home: Scaffold(body: SingleChildScrollView(child: StatisticGroup())),
      ),
    ),
  );
  await tester.pump();
}

/// The first semantics node whose label contains [needle], or null.
///
/// Walks the live semantics tree rather than looking a widget up by type: what is under test is what
/// a keyboard user and a screen reader are handed, and that must not depend on which widget happens
/// to produce it.
SemanticsNode? _semanticsNodeLabelled(WidgetTester tester, String needle) {
  SemanticsNode? found;
  void visit(SemanticsNode node) {
    if (found == null && node.label.contains(needle)) {
      found = node;
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  if (root != null) {
    visit(root);
  }
  return found;
}

void main() {
  setUpAll(loadAppTranslations);

  group('AboutGroup', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            locale: appTestLocale,
            home: Scaffold(body: SingleChildScrollView(child: AboutGroup())),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('states what the app is, in the shipped words', (tester) async {
      await pump(tester);

      expect(find.text(appSentenceAt('pages.dashboard.about.title')), findsOneWidget);
      expect(find.text(appSentenceAt('pages.dashboard.about.description')), findsOneWidget);
    });

    testWidgets('lists each destination as its own bullet, with the address in full', (tester) async {
      await pump(tester);

      expect(find.text('•'), findsNWidgets(AboutGroup.links.length));
      for (final link in AboutGroup.links) {
        // The URL is on screen as text, not hidden behind a labelled button: seeing where a link
        // goes before taking it is the whole reason these are written out.
        expect(
          find.textContaining('${link.label}: ${link.url}', findRichText: true),
          findsOneWidget,
          reason: link.label,
        );
      }
    });

    test('the links point where the project actually lives', () {
      // Against `Const` rather than against literals repeated here: what this pins is that the card
      // links to the project's published addresses, not that somebody typed the same URL twice.
      expect(AboutGroup.links.map((e) => e.url).toList(), [Const.githubUrl, Const.discordUrl, Const.xUrl]);
      for (final link in AboutGroup.links) {
        expect(Uri.parse(link.url).scheme, 'https', reason: '${link.label} must not be plain http');
      }
    });

    testWidgets('the address itself is the clickable part, and says so to the pointer', (tester) async {
      await pump(tester);

      // A URL that merely LOOKS like a link is the failure this guards: the address has to be drawn
      // as a link (otherwise nothing on screen tells the reader it is clickable, since an app has no
      // status bar) and the pointer has to say so as it passes over it.
      final spans = <String, TextSpan>{};
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) {
            spans[span.text!] = span;
          }
          return true;
        });
      }
      for (final link in AboutGroup.links) {
        final span = spans[link.url];
        expect(span, isNotNull, reason: '${link.label} is not a span of its own');
        expect(span?.style?.decoration, TextDecoration.underline, reason: '${link.label} is not underlined');
      }

      // The cursor is read off the mouse tracker rather than off a span property: the tap moved from
      // a `TapGestureRecognizer` inside the span to an `InkWell` around the line, and what the reader
      // gets out of that is the cursor the pointer actually shows over the address.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.textContaining(AboutGroup.links.first.url, findRichText: true)));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
        reason: 'nothing tells a reader the address is live',
      );
    });

    testWidgets('every destination can be reached and taken without a mouse', (tester) async {
      // The defect this pins: the three links were `TextSpan`s carrying a `TapGestureRecognizer`, and
      // a span takes no part in focus traversal -- so on the web build, where this card is the front
      // page and a first-time visitor's only route to the project, Tab never stopped on any of them
      // and Enter had nothing to activate. Nothing on screen showed it; the links looked ordinary.
      final semantics = tester.ensureSemantics();
      await pump(tester);

      for (final link in AboutGroup.links) {
        final node = _semanticsNodeLabelled(tester, link.url);
        expect(node, isNotNull, reason: '${link.label} reaches assistive technology as nothing at all');
        expect(node!.hasFlag(SemanticsFlag.isLink), isTrue, reason: '${link.label} is not announced as a link');
        expect(node.hasFlag(SemanticsFlag.isFocusable), isTrue, reason: '${link.label} cannot take focus');
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: '${link.label} cannot be activated',
        );
      }

      // And traversal really visits them, in the order they are listed: focusability that no Tab ever
      // reaches would be the same defect with a flag set.
      for (final link in AboutGroup.links) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          _semanticsNodeLabelled(tester, link.url)?.hasFlag(SemanticsFlag.isFocused),
          isTrue,
          reason: 'Tab did not stop on ${link.label}',
        );
      }

      semantics.dispose();
    });
  });

  group('StatisticGroup', () {
    testWidgets('a settled, empty store is answered with a sentence instead of empty tiles', (tester) async {
      await _pumpStatistics(tester, () => _LoadedRecordStorage(const []));

      expect(find.text(appSentenceAt('pages.dashboard.statistic.empty')), findsOneWidget);
      // The grid is REPLACED, not merely captioned: fourteen tiles all reading "-" is the noise
      // this branch exists to remove.
      expect(find.byType(NumberOfRecordStatisticWidget), findsNothing);
    });

    testWidgets('the card and its title are there either way', (tester) async {
      // The card is never hidden. Hiding it until the scan finished would leave a user with many
      // records looking at a dashboard with no statistics on it for as long as the scan takes.
      await _pumpStatistics(tester, () => _LoadedRecordStorage(const []));

      expect(find.text(appSentenceAt('pages.dashboard.statistic.title')), findsOneWidget);
      expect(find.text(appSentenceAt('pages.dashboard.statistic.description')), findsOneWidget);
    });

    testWidgets('a store with records draws the grid and no empty message', (tester) async {
      await _pumpStatistics(tester, () => _LoadedRecordStorage([makeRecord(id: 'a', card: 1)]));

      expect(find.text(appSentenceAt('pages.dashboard.statistic.empty')), findsNothing);
      expect(find.byType(NumberOfRecordStatisticWidget), findsOneWidget);
    });

    testWidgets('a store that is still scanning is not called empty', (tester) async {
      // THE DISTINCTION THE LOADER EXISTS FOR. A scan in flight holds no records yet, so a check on
      // the list alone would tell a user with a full store that they have captured nobody.
      await _pumpStatistics(tester, _PendingRecordStorage.new);

      expect(find.text(appSentenceAt('pages.dashboard.statistic.empty')), findsNothing);
      expect(find.byType(NumberOfRecordStatisticWidget), findsOneWidget);
    });
  });
}
