// The record preview opened over other dialogs: it leaves them where they were, and so does every
// dialog the preview hands over to. Opened the default way, it still replaces them.
// Run: .fvm/flutter_sdk/bin/flutter test test/preview_dialog_over_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/report_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';

class _SilentTransport implements Transport {
  @override
  Future<SentryId?> send(SentryEnvelope envelope) async => const SentryId.empty();
}

const _underneath = Key('dialog_underneath');
final _dirs = [DirectoryPath('/tmp/uma_preview_over/record-a')];

/// The page's ref, the one a real caller of [CharaDetailPreviewDialog.show] passes.
late RefBase _ref;

class _RefGrabber extends ConsumerWidget {
  const _RefGrabber();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _ref = ref.base;
    return const SizedBox.shrink();
  }
}

/// A layer with one dialog already open, standing in for the review list and the merge dialog.
Future<ProviderContainer> _pumpWithDialogUnderneath(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    // No record on disk: the preview renders its "no image" state, and the report button is offered
    // because a prediction is said to exist.
    overrides: [
      imageSizeContainerProvider.overrideWith((ref, path) async => null),
      previewImagePathsProvider.overrideWith((ref, path) async => const PreviewImagePaths()),
      predictionAvailableProvider.overrideWith((ref, path) async => true),
      predictionContainerProvider.overrideWith((ref, path) async => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: appTestLocale,
        home: DialogLayer(child: Scaffold(body: _RefGrabber())),
      ),
    ),
  );
  container.read(dialogBuilderProvider.notifier).show((_) => const SizedBox(key: _underneath, width: 10, height: 10));
  await tester.pumpAndSettle();
  return container;
}

int _openCount(ProviderContainer container) => container.read(dialogBuilderProvider.notifier).entries.length;

Future<void> _pressReport(WidgetTester tester) async {
  await tester.tap(find.byIcon(Symbols.subtitles_rounded));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Symbols.report_rounded));
  // One frame only: the report dialog is up and still loading, which is all these cases look at.
  await tester.pump();
}

/// Takes the report dialog down with the tree, and lets the rate-limit request it started run out.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);
  // The report button is offered only while Sentry is enabled. Nothing is sent; the transport exists
  // so an accidental capture could not leave the machine either.
  setUpAll(
    () => Sentry.init((options) {
      options.dsn = 'https://public@localhost/1';
      options.transport = _SilentTransport();
    }),
  );
  tearDownAll(() => Sentry.close());

  testWidgets('by default the preview replaces the dialogs already open', (tester) async {
    final container = await _pumpWithDialogUnderneath(tester);
    CharaDetailPreviewDialog.show(_ref, _dirs, 0);
    await tester.pumpAndSettle();

    expect(find.byType(CharaDetailPreviewDialog), findsOneWidget);
    expect(find.byKey(_underneath), findsNothing);
    expect(_openCount(container), 1);
  });

  testWidgets('opened over, the preview leaves the dialog underneath, and closing it uncovers that dialog', (
    tester,
  ) async {
    final container = await _pumpWithDialogUnderneath(tester);
    CharaDetailPreviewDialog.show(_ref, _dirs, 0, over: true);
    await tester.pumpAndSettle();
    expect(find.byType(CharaDetailPreviewDialog), findsOneWidget);
    expect(_openCount(container), 2);

    await tester.tap(find.widgetWithIcon(FilledButton, Symbols.close_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(CharaDetailPreviewDialog), findsNothing);
    expect(find.byKey(_underneath), findsOneWidget);
    expect(_openCount(container), 1);
  });

  testWidgets('opened over, the report button replaces only the preview', (tester) async {
    final container = await _pumpWithDialogUnderneath(tester);
    CharaDetailPreviewDialog.show(_ref, _dirs, 0, over: true);
    await tester.pumpAndSettle();

    await _pressReport(tester);

    expect(find.byType(ReportRecordDialog), findsOneWidget);
    expect(find.byType(CharaDetailPreviewDialog), findsNothing);
    expect(_openCount(container), 2, reason: 'the dialog underneath must survive the hand-over to the report');
    await _unmount(tester);
  });

  testWidgets('opened the default way, the report button still replaces every dialog', (tester) async {
    final container = await _pumpWithDialogUnderneath(tester);
    CharaDetailPreviewDialog.show(_ref, _dirs, 0);
    await tester.pumpAndSettle();

    await _pressReport(tester);

    expect(find.byType(ReportRecordDialog), findsOneWidget);
    expect(_openCount(container), 1);
    await _unmount(tester);
  });
}
