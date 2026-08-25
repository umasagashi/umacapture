// The dashboard's announcement card is a cross-origin GET. In a browser the
// news origin's CORS headers decide whether it can be read at all, and that is
// not something the app can see, fix, or predict from here -- so the card is
// kept on every platform and has to *say* when the fetch failed. An empty card
// reads as "no announcements", which is the wrong story and the reason the
// failure went unnoticed.
//
// The real translations are installed, so a renamed or reworded key fails here
// instead of shipping a card that explains nothing.
//
// `kIsWeb` is false on the VM, so this covers the rendering, not the browser's
// CORS decision -- the point is that the *failure path* has a visible outcome,
// whatever produced it.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/dashboard_news_failure_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/gui/dashboard.dart';

import 'support/localization.dart';

const _fetchFailed = 'お知らせの取得に失敗しました。';

Future<void> _pumpNews(WidgetTester tester, Future<String> Function() load) async {
  final container = ProviderContainer.test(overrides: [newsMarkdownLoader.overrideWith((ref) => load())]);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: NewsGroup())),
      ),
    ),
  );
  // The loader is asynchronous on every platform; let it settle before asserting.
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppTranslations);

  testWidgets('says the announcements could not be loaded when the fetch fails', (tester) async {
    await _pumpNews(tester, () => Future<String>.error(Exception('blocked by CORS')));

    expect(find.text(_fetchFailed), findsOneWidget);
    // The card itself stays: hiding it on web would replace one silent state
    // with another.
    expect(find.byType(NewsGroup), findsOneWidget);
  });

  testWidgets('renders the announcements when the fetch succeeds', (tester) async {
    await _pumpNews(tester, () async => '# Headline');

    expect(find.text(_fetchFailed), findsNothing);
    expect(find.textContaining('Headline'), findsOneWidget);
  });
}
