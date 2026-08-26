// Widget tests for the web live-capture banner.
// Run: .fvm/flutter_sdk/bin/flutter test test/web_capture_tutorial_dialog_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';

class _TutorialButton extends ConsumerWidget {
  final Future<void> Function() startCapture;

  const _TutorialButton({required this.startCapture});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => WebCaptureTutorialDialog.show(ref.base, startCapture),
      child: const Text('show tutorial'),
    );
  }
}

class _DefaultDialogButton extends ConsumerWidget {
  const _DefaultDialogButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => CardDialog.show(
        ref.base,
        (_) => const CardDialog(
          key: Key('default-dialog'),
          dialogTitle: 'default dialog title',
          usePageView: false,
          content: SizedBox(width: 100, height: 100),
        ),
      ),
      child: const Text('show default dialog'),
    );
  }
}

Future<ProviderContainer> _pumpDialogLayer(WidgetTester tester, Widget child) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: DialogLayer(child: Scaffold(body: child)),
      ),
    ),
  );
  return container;
}

Future<ProviderContainer> _pumpTutorial(WidgetTester tester, Future<void> Function() startCapture) {
  return _pumpDialogLayer(tester, _TutorialButton(startCapture: startCapture));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  testWidgets('shows a compact capture banner without optional controls', (tester) async {
    final start = Completer<void>();
    await _pumpTutorial(tester, () => start.future);

    await tester.tap(find.text('show tutorial'));
    await tester.pump();

    expect(find.descendant(of: find.byType(WebCaptureTutorialDialog), matching: find.byType(ListTile)), findsNothing);
    expect(find.text('上に表示されている選択画面でゲーム画面を選び、「共有」または「許可する」を押してください。\nゲーム画面のウィンドウタイトルは以下の通りです。'), findsOneWidget);
    expect(find.text('DMM版: umamusume'), findsOneWidget);
    expect(find.text('Steam版: UmamusumePrettyDerby_Jpn'), findsOneWidget);
    expect(find.text('Tips'), findsNothing);
    expect(find.textContaining('アップロード'), findsNothing);
    expect(find.text('OK'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.byIcon(Symbols.close_rounded), findsNothing);

    // The banner is guidance only, so its barrier is dismissible: the browser's own share picker is what the
    // user has to act on, and the start future has no timeout. Tapping the barrier hides the banner while the
    // capture start it kicked off keeps running (the `startCapture` future here is still pending).
    await tester.tapAt(const Offset(1, 1));
    await tester.pump();
    expect(find.byType(WebCaptureTutorialDialog), findsNothing);
    expect(start.isCompleted, isFalse);
  });

  testWidgets('positions the compact banner at the bottom center', (tester) async {
    final start = Completer<void>();
    final container = await _pumpTutorial(tester, () => start.future);

    await tester.tap(find.text('show tutorial'));
    await tester.pump();

    expect(container.read(dialogBuilderProvider)?.alignment, Alignment.bottomCenter);
    final rect = tester.getRect(find.byType(WebCaptureTutorialDialog));
    final viewportHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(rect.bottom, closeTo(viewportHeight - 32, 0.01));
    expect(rect.width, closeTo(720, 0.01));
    // `maxHeight: 180` is an upper bound, not a target: the card shrink-wraps its content, so the banner is
    // exactly as tall as the guidance text with no trailing dead space.
    expect(rect.height, closeTo(156, 0.01));
  });

  testWidgets('fits the banner in a 900 by 600 content viewport', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final start = Completer<void>();
    await _pumpTutorial(tester, () => start.future);

    await tester.tap(find.text('show tutorial'));
    await tester.pump();

    final rect = tester.getRect(find.byType(WebCaptureTutorialDialog));
    expect(rect.bottom, closeTo(568, 0.01));
    expect(rect.height, closeTo(156, 0.01));
    expect(rect.width, lessThanOrEqualTo(836));
    expect(find.text('上に表示されている選択画面でゲーム画面を選び、「共有」または「許可する」を押してください。\nゲーム画面のウィンドウタイトルは以下の通りです。'), findsOneWidget);
    expect(find.text('DMM版: umamusume'), findsOneWidget);
    expect(find.text('Steam版: UmamusumePrettyDerby_Jpn'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps banner content reachable at narrow width and large text', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 500);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final start = Completer<void>();
    await _pumpTutorial(tester, () => start.future);

    await tester.tap(find.text('show tutorial'));
    await tester.pump();

    final rect = tester.getRect(find.byType(WebCaptureTutorialDialog));
    expect(rect.bottom, closeTo(468, 0.01));
    // Here the content really is taller than the bound, so the card stops at 180 and scrolls.
    expect(rect.height, closeTo(180, 0.01));
    expect(rect.width, lessThanOrEqualTo(366));
    final scrollable = find.descendant(of: find.byType(WebCaptureTutorialDialog), matching: find.byType(Scrollable));
    expect(scrollable, findsOneWidget);
    await tester.scrollUntilVisible(find.text('Steam版: UmamusumePrettyDerby_Jpn'), 100, scrollable: scrollable);
    expect(find.text('Steam版: UmamusumePrettyDerby_Jpn'), findsOneWidget);
    expect(find.text('Tips'), findsNothing);
    expect(find.text('OK'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismisses the banner after capture starts', (tester) async {
    final start = Completer<void>();
    var startCount = 0;
    await _pumpTutorial(tester, () {
      startCount++;
      return start.future;
    });

    await tester.tap(find.text('show tutorial'));
    await tester.pump();
    expect(startCount, 1);
    expect(find.byType(WebCaptureTutorialDialog), findsOneWidget);

    start.complete();
    await tester.pump();
    expect(find.byType(WebCaptureTutorialDialog), findsNothing);
  });

  testWidgets('dismisses the banner after capture fails or throws', (tester) async {
    await _pumpTutorial(tester, () => Future<void>.error(StateError('start failed')));

    await tester.tap(find.text('show tutorial'));
    await tester.pump();
    expect(find.byType(WebCaptureTutorialDialog), findsNothing);

    await _pumpTutorial(tester, () => throw StateError('start threw'));
    await tester.tap(find.text('show tutorial'));
    await tester.pump();
    expect(find.byType(WebCaptureTutorialDialog), findsNothing);
  });

  testWidgets('leaves a dialog opened meanwhile alone when capture starts', (tester) async {
    final start = Completer<void>();
    final container = await _pumpTutorial(tester, () => start.future);

    await tester.tap(find.text('show tutorial'));
    await tester.pump();
    expect(find.byType(WebCaptureTutorialDialog), findsOneWidget);

    // Only one dialog exists at a time, so showing another one replaces the banner. The pending start must
    // not take that unrelated dialog down with it when it finally settles.
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => const CardDialog(
            key: Key('default-dialog'),
            dialogTitle: 'default dialog title',
            usePageView: false,
            content: SizedBox(width: 100, height: 100),
          ),
        );
    await tester.pump();
    expect(find.byType(WebCaptureTutorialDialog), findsNothing);
    expect(find.byKey(const Key('default-dialog')), findsOneWidget);

    start.complete();
    await tester.pump();
    expect(find.byKey(const Key('default-dialog')), findsOneWidget);
  });

  testWidgets('keeps dialogs centered by default', (tester) async {
    final container = await _pumpDialogLayer(tester, const _DefaultDialogButton());

    await tester.tap(find.text('show default dialog'));
    await tester.pump();

    expect(container.read(dialogBuilderProvider)?.alignment, Alignment.center);
    expect(find.text('default dialog title'), findsOneWidget);
    final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      tester.getRect(find.byKey(const Key('default-dialog'))).center,
      Offset(viewport.width / 2, viewport.height / 2),
    );
  });
}
