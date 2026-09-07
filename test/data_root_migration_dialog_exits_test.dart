// The data-root migration dialog's exits.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/data_root_migration_dialog_exits_test.dart
//
// The migration closes Hive part-way through and can only be finished by a
// restart, so this dialog is opened non-dismissible and hides its × for the
// steps the session may not survive. Both of those are decisions with nothing
// asserting them: the scrim flag is one argument at the `show` call site, and
// flipping it back to the default would look like a tidy-up.
//
// WHAT THIS FILE DOES NOT REACH. Only the scrim is covered, at the overview
// step. The × is absent for `_Phase.migrating` and for a result the session did
// not survive, and neither phase is reachable from a widget test: entering them
// means actually running `DataRootMigrationController.migrate`, which takes the
// real root record lock, calls `StorageBox.markHiveClosed()` and `Hive.close()`
// on the test process, and on success writes a real bootstrap override. The
// dialog builds its own controller and passes no `recoveryGate`, so there is no
// seam to hold it at either. The scrim flag is set once at `show` and never
// changed afterwards, so this case does police it for every phase; the ×,
// which is decided per phase, is not policed at all.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_settings.dart';

import 'support/localization.dart';

final _root = DirectoryPath('/umacapture-test');

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathLayoutLoader.overrideWith(
        (ref) async => PathInfo(documentDir: _root, supportDir: _root, executableDir: _root, downloadDir: _root),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  // Taller than the default surface: the overview lists a path box per resolved
  // directory and does not scroll at 600px.
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: DialogLayer(child: const Scaffold(body: DataRootTile())),
      ),
    ),
  );
  // One frame for the layout loader to resolve; the row is disabled until it has.
  await tester.pump();
}

/// The migration dialog, found by its own title rather than by its type, which
/// is private to `storage_settings.dart`.
Finder _migrationDialog() => find.text(appSentenceAt('pages.settings.storage.dialog.title'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  testWidgets('the scrim does not close the migration dialog', (tester) async {
    final container = _container();
    await _pump(tester, container);

    await tester.tap(find.byType(DataRootTile));
    await tester.pump();
    expect(_migrationDialog(), findsOneWidget, reason: 'the dialog did not open');

    // Outside the dialog's own card (the layer pads it), so this is the scrim.
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(
      _migrationDialog(),
      findsOneWidget,
      reason: 'a tap on the scrim closed the migration dialog, whose only safe exit after Hive closes is a restart',
    );
  });

  // **The positive control.** The case above taps a bare coordinate and asserts
  // nothing happened, which is what a tap that *missed* the scrim looks like
  // too: change [DialogLayer]'s padding, or align dialogs elsewhere, and it
  // would go on passing while testing nothing. This states that the same
  // coordinate does reach a scrim that is live.
  testWidgets('the same tap does close an ordinary dialog', (tester) async {
    final container = _container();
    await _pump(tester, container);
    CardDialog.show(
      container.read(containerRefProvider),
      (_) => const CardDialog(
        key: Key('ordinary-dialog'),
        dialogTitle: 'ordinary dialog',
        usePageView: false,
        content: SizedBox(width: 100, height: 100),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('ordinary-dialog')), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(
      find.byKey(const Key('ordinary-dialog')),
      findsNothing,
      reason: 'the tap the case above relies on does not reach the scrim at all',
    );
  });
}
