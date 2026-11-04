// The dashboard's "about this site" card (web only), mounted on its own: the notice sentence carries
// two inline links, and each one has to open its own page next to the app.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/const.dart';
import 'package:umacapture/src/gui/dashboard.dart';

import 'support/localization.dart';

void main() {
  setUpAll(loadAppTranslations);

  testWidgets("the notice sentence links the trial-release notice and the privacy policy", (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final opened = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      opened.add((call.arguments as Map)['url'] as String);
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: AboutGroup())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('試験公開中です。利用上の注意は', findRichText: true), findsOneWidget);
    await tester.tap(find.text('試験公開について'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('プライバシーポリシー'));
    await tester.pumpAndSettle();

    // The sharing origin's pages, not ones resolved against the app's own location, which on Windows is a file URL.
    expect(opened, ['${Const.sharingOrigin}/notice/', '${Const.sharingOrigin}/privacy/']);
  });
}
