// The settings page's module row, while an automatic install is waiting its turn.
//
//   .fvm/flutter_sdk/bin/flutter test test/module_version_deferred_display_test.dart
//
// WHAT THE HARM WAS. An automatic module install that reaches a held `modules/`
// parks (`LongReadRegistry.holdWhenFree` with `LongReadContention.defer`) until the
// reader — a re-recognition, a video import — lets go. That install runs inside
// `moduleVersionLoader`'s body, so the loader stays `loading` for the whole park,
// and the settings row read the loader alone: it said 「確認中...」 about a version
// check that had already finished, for as long as a whole-store re-recognition
// takes. Nothing on screen accounted for the wait, and the one place it existed
// was two lines in the log.
//
// WHAT THE FIX IS. The park is now a state and not only an event:
// `holdWhenFree` enters and leaves `longReadDeferralsProvider` on the transitions,
// and the row asks which of the two waits it is in. The sentences are the author's,
// pinned verbatim in `approved_wording_test.dart`; what this file asserts is that
// the right one reaches the row, and that it goes away again.
//
// WHY IT DRIVES THE PRODUCTION METHOD RATHER THAN THE WHOLE PAGE. `AboutGroup`'s
// tile also renders the licence row and the app-version check, neither of which
// this is about, and mounting the settings page pulls in the platform channels a
// VM test has no answer for. `moduleVersion` is the function that decides the
// string, it is called with a `WidgetRef` by the tile, and it is called with one
// here — so the watches are established in a real element and the rebuild on
// release is a real rebuild, which is the half of this that a plain unit call
// could not check.
//
// WHAT IT CANNOT REACH. The download in front of the real loader, and the real
// `modules.zip`: the loader is overridden with a body that runs the same
// `runModuleInstall` seam the desktop auto-updater and both web routes reach, over
// an install that writes nothing. What is asserted is the park and the row, not the
// extraction.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/settings.dart';

import 'support/localization.dart';

late PathInfo _layout;

DirectoryPath get _modulesDir => _layout.modulesDir;

ModuleVersion _installedVersion() =>
    ModuleVersion(recognizerVersion: DateTime.utc(2026, 9, 6), minimumVersion: DateTime.utc(2026, 1, 1));

/// The one line the settings tile puts in the module row.
class _ModuleRow extends ConsumerWidget {
  const _ModuleRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Directionality(textDirection: TextDirection.ltr, child: Text(const AboutGroup().moduleVersion(ref)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _layout = PathInfo(
      documentDir: DirectoryPath('/uma/documents'),
      supportDir: DirectoryPath('/uma/support'),
      executableDir: DirectoryPath('/uma/exe'),
      downloadDir: DirectoryPath('/uma/downloads'),
    );
  });

  testWidgets('a module row waiting behind a reader says so, and goes back to the version when it is let go', (
    tester,
  ) async {
    // The install the loader is waiting on: it completes when this does, so the
    // case controls the park and the extraction separately.
    final installFinished = Completer<void>();

    final container = ProviderContainer(
      overrides: [
        moduleVersionLoader.overrideWith((ref) async {
          // The real loader awaits the app-version check and the path layout
          // before it reaches this seam, and says at that point that it is now
          // past the awaits that make writing a provider safe. This stands in for
          // them: without one, `holdWhenFree` would enter the deferral state
          // during this provider's own initialization.
          await Future<void>.value();
          await runModuleInstall(
            ref.base,
            _modulesDir,
            () => installFinished.future,
            // The three surfaceless routes' answer, and the one this row is about.
            contention: LongReadContention.defer,
          );
          return _installedVersion();
        }),
      ],
    );
    addTearDown(container.dispose);

    // A reader holding `modules/` before the loader is ever read, so the install
    // meets the claim rather than racing it.
    final registry = container.read(longReadRegistryProvider.notifier);
    final reader = registry.claimUntilReleased(kind: LongReadKind.regeneration, paths: [_modulesDir]);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const _ModuleRow()));
    await tester.pump();

    // Non-vacuity: the install really is parked, not merely slow. Without this
    // the sentence below could be the deferred one for the wrong reason.
    expect(
      container.read(longReadDeferralsProvider),
      containsPair(LongReadKind.moduleInstall, 1),
      reason: 'the install did not park behind the reader, so the row below is not showing a deferral',
    );
    expect(find.text('他の処理の完了を待っています...'), findsOneWidget);
    expect(find.text('確認中...'), findsNothing);

    // Released: the park ends here, and the install — not the version — is what
    // is running from now on, so the row goes back to the plain wait.
    registry.release(reader);
    await tester.pump();
    expect(container.read(longReadDeferralsProvider), isEmpty);
    expect(find.text('確認中...'), findsOneWidget);
    expect(find.text('他の処理の完了を待っています...'), findsNothing);

    // And once the install lands, the row shows the version it installed.
    installFinished.complete();
    await tester.pumpAndSettle();
    expect(find.text(_installedVersion().recognizerVersion.toLocal().toString()), findsOneWidget);
  });

  testWidgets('a module row with nothing holding the folder never shows the deferred sentence', (tester) async {
    // The negative control, and the state every ordinary start is in: the same
    // loader, the same seam, no claim. If the row showed the deferred sentence
    // here the case above would be asserting nothing about a deferral.
    final installFinished = Completer<void>();

    final container = ProviderContainer(
      overrides: [
        moduleVersionLoader.overrideWith((ref) async {
          await Future<void>.value();
          await runModuleInstall(
            ref.base,
            _modulesDir,
            () => installFinished.future,
            contention: LongReadContention.defer,
          );
          return _installedVersion();
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const _ModuleRow()));
    await tester.pump();

    expect(container.read(longReadDeferralsProvider), isEmpty);
    expect(find.text('確認中...'), findsOneWidget);
    expect(find.text('他の処理の完了を待っています...'), findsNothing);

    installFinished.complete();
    await tester.pumpAndSettle();
  });
}
