// The long-read gate on [VideoImportButton] -- the fifth of the five conditions that decide
// whether a clip may be picked.
//
//   .fvm/flutter_sdk/bin/flutter test test/video_import_long_read_gate_test.dart
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *a video import is offered while a
// registered long reader is already holding the record store the import is about to write into.*
//
// WHY IT HAS TO BE HERE AND NOT ONLY IN THE CORE. An import points the recognition pipeline at
// `directory.storage_dir` and the core writes records into it for the whole session, with nothing
// in Dart on the stack between those writes -- which is why the import announces itself with a
// claim taken across the session rather than around a write function. The registry grants nothing,
// so the claim cannot refuse anybody by itself; what it can do is keep the control from being
// offered, and that is the half asserted here. The claim side is
// `video_import_long_read_claim_test.dart`'s.
//
// WHAT THIS FILE DOES NOT REACH.
//  * The press. It opens a native file dialog, which no test may do, so the button's `onPressed`
//    is asserted through the `Disabled` that wraps it and not by tapping.
//  * The pre-flight after the dialog closes. It deliberately passes `heldByLongRead: false` --
//    see `VideoImportButton._preflight` -- and `video_import_gate_test.dart` owns that call.
//  * Whether the paths asked about are the paths the session writes. That is
//    `videoImportLongReadPaths`' job, one definition read by both the check and the claim; no
//    widget test can substitute for it.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/video_import.dart';

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

/// A data root the control can ask about. Nothing is written to it: the gate is a question about
/// paths, and no file has to exist for a path to be covered.
final _layout = PathInfo(
  documentDir: DirectoryPath('/tmp/uma_video_import_gate/documents'),
  supportDir: DirectoryPath('/tmp/uma_video_import_gate/support'),
  executableDir: DirectoryPath('/tmp/uma_video_import_gate/exe'),
  downloadDir: DirectoryPath('/tmp/uma_video_import_gate/downloads'),
);

/// The gate's answer, read off the [Disabled] that wraps the control.
bool _isInert(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).disabled;

/// The sentence the control offers as its reason.
String? _reasonShown(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).tooltip;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  setUp(() {
    // A real controller pushes its initial config from its constructor; answer it so the
    // fire-and-forget call does not surface as a failure toast.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
  });

  /// Mounts the pick control with the front end's capability values supplied, past the `notReady`
  /// gate the resolver would otherwise answer first.
  ///
  /// The container is returned so a case can move the registry after the frame, which is the only
  /// way to tell a control that watches from one that resolved once at build time.
  Future<ProviderContainer> pumpButton(WidgetTester tester) async {
    final importState = ValueNotifier<VideoImportState>(VideoImportState.idle);
    addTearDown(importState.dispose);
    final container = ProviderContainer.test(
      overrides: [
        // The control asks the *layout* where the store is, so that it can answer during a store
        // outage; `pathInfoProvider` throws until the store has been prepared.
        pathLayoutProvider.overrideWithValue(_layout),
        platformControllerProvider.overrideWith((ref) {
          final controller = PlatformController(ref, const {});
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _theme(),
          home: Scaffold(
            // `available`/`supported` supplied for the reason `video_import_gate_test.dart`
            // supplies them: this host is not the front end the gate is about.
            body: VideoImportButton(available: true, supported: true, importState: importState),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('is inert while a long reader holds the record store, and says why', (tester) async {
    final container = await pumpButton(tester);
    expect(_isInert(tester), isFalse, reason: 'the arrangement itself must not withhold the control');

    // A kind that is not `videoImport`, so "a long reader holds the store" and "an import of my own
    // is running" stay separable -- the precedence between those two is `video_import_ops_test`'s.
    container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.zip, paths: [_layout.charaDetailDir]);
    await tester.pump();

    expect(_isInert(tester), isTrue, reason: 'the session would write records under a tree a zip is walking');
    expect(_reasonShown(tester), longReadBusyMessage());
    // Rendered, not merely computed: `Disabled` only wraps a Tooltip while it is disabled.
    final tooltips = [for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip))) t.message ?? ''];
    expect(tooltips, contains(longReadBusyMessage()));
    // And it resolved. `.tr()` renders an unknown key as the key, which would satisfy the two
    // assertions above by being the wrong thing entirely.
    expect(_reasonShown(tester), appSentenceAt(longReadBusyKey));
    // The button itself, not only the wrapper: a press that reached `startVideoImport` would open
    // a file dialog over a store somebody else is holding.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('comes back on its own when the claim is released', (tester) async {
    // WATCHED, NOT READ, and this is the case that tells the two apart. A zip started from the
    // storage dialog outlives the frame this control was built in, and a gate that resolved once
    // would leave the import withheld for the rest of the session.
    final container = await pumpButton(tester);
    final token = container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.zip, paths: [_layout.charaDetailDir]);
    await tester.pump();
    expect(_isInert(tester), isTrue);

    container.read(longReadRegistryProvider.notifier).release(token);
    await tester.pump();

    expect(_isInert(tester), isFalse, reason: 'the hold is over and nothing else is in the way');
    expect(_reasonShown(tester), isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('a long read somewhere else in the data root leaves the control alone', (tester) async {
    // The control that separates this gate from "any claim at all disables it". The settings store
    // is held by a real registered kind and is nowhere near what an import touches — it writes
    // records under `storage/chara_detail` and recognises out of `modules/`, and neither contains
    // it. (`modules/` used to be this control and no longer can be: an import names it now,
    // because the recognizer re-reads it per record it produces.)
    final container = await pumpButton(tester);
    container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.relocate, paths: [_layout.settingsDir]);
    await tester.pump();

    expect(_isInert(tester), isFalse);
    expect(_reasonShown(tester), isNull);
  });
}
