// A BLOCKED CONTROL CANNOT BE OPERATED -- BY THE KEYBOARD EITHER.
// Run: .fvm/flutter_sdk/bin/flutter test test/disabled_keyboard_activation_test.dart
//
// THE DEFECT THIS FILE EXISTS FOR. `Disabled` was `IgnorePointer + Opacity`. It refused the pointer
// and touched no focus node, so the capture card's greyed-out controls still took Tab focus and
// still fired on Enter and on Space: a keyboard user could start a screen capture, or open a report
// dialog that asks for a screen-share permission, *while a video import owned the pipeline* -- the
// overlap the card's four-feature exclusivity rule exists to forbid. Every gate test in the suite
// stayed green because they all read `Disabled.disabled`, a flag, or pressed with `tester.tap`,
// a pointer event. Neither can see the hole.
//
// WHAT IS ASSERTED, AND WHY IT CANNOT PASS BY ACCIDENT. Every case below is a pair: the blocked
// state AND the same control in the state where it is genuinely offered. Without the second half,
// "the callback did not run" and "the test never managed to press anything" are the same reading --
// and a suite that cannot tell them apart would go green if `sendKeyEvent` stopped working, if the
// finder stopped matching, or if the card stopped mounting the control at all. The positive control
// is what makes the negative one evidence.
//
// The wrong implementations these cases are here to exclude, named:
//   * `Disabled` blocks the pointer only (the shipped defect) -- L1 subject fires, L2 controls are
//     Tab-reachable.
//   * `Disabled` skips traversal but leaves the subtree focusable -- L1's "already focused when it
//     became unavailable" case still fires.
//   * only the three controls named in the report are hand-patched and the primitive is left alone
//     -- L1, which uses a plain `TextButton` no product code touches, still fires.
//   * only Enter is handled -- every case presses Space as well.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/capture_preview.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/hive.dart';
import 'support/keyboard_activation.dart';
import 'support/localization.dart';

const _toggleKey = ValueKey("capture_control_button");
const _importReportKey = ValueKey("report_import_button");
const _pickKey = ValueKey("video_import_pick_button");

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

// ---------------------------------------------------------------------------------------------
// L1 -- the primitive, with a control the product does not touch.
//
// A plain `TextButton` with an unconditionally non-null callback, which is what every call site of
// `Disabled` is allowed to be: the primitive is what has to hold, not the caller's diligence.
// ---------------------------------------------------------------------------------------------

class _PrimitiveHarness extends StatefulWidget {
  const _PrimitiveHarness({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_PrimitiveHarness> createState() => _PrimitiveHarnessState();
}

class _PrimitiveHarnessState extends State<_PrimitiveHarness> {
  bool disabled = false;

  void setDisabled(bool value) => setState(() => disabled = value);

  @override
  Widget build(BuildContext context) {
    return Disabled(
      disabled: disabled,
      child: TextButton(onPressed: widget.onPressed, child: const Text('subject')),
    );
  }
}

Future<_PrimitiveHarnessState> _pumpPrimitive(WidgetTester tester, VoidCallback onPressed) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(),
      home: Scaffold(body: _PrimitiveHarness(onPressed: onPressed)),
    ),
  );
  await tester.pump();
  return tester.state<_PrimitiveHarnessState>(find.byType(_PrimitiveHarness));
}

// ---------------------------------------------------------------------------------------------
// L2 -- the real capture card.
// ---------------------------------------------------------------------------------------------

class _Card {
  _Card(this.container);

  final ProviderContainer container;

  /// Whether a dialog was asked for. `CardDialog.show` only hands the builder to
  /// [dialogBuilderProvider]; with no `DialogLayer` mounted nothing is built, so this observes the
  /// press without letting `ReportScreenDialog` request a real screenshot.
  bool get dialogRequested => container.read(dialogBuilderProvider) != null;
}

Future<_Card> _pumpCard(
  WidgetTester tester, {
  VideoImportState import = VideoImportState.idle,
  bool capturing = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => capturing),
      platformControllerProvider.overrideWith((ref) {
        final controller = PlatformController(ref, const {});
        ref.onDispose(controller.dispose);
        return controller;
      }),
      capturePreviewEnabledProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  addTearDown(container.dispose);
  final notifier = ValueNotifier<VideoImportState>(import);
  addTearDown(notifier.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CaptureControlGroup(importState: notifier, importAvailable: true, frameGrabAvailable: true),
          ),
        ),
      ),
    ),
  );
  // Not `pumpAndSettle`: a running import puts an indeterminate progress indicator in the banner,
  // which animates forever by design.
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
  return _Card(container);
}

/// The capture-error link, which carries no key of its own; found through its label.
///
/// The label is read out of `ja.json` as a literal, not resolved with `.tr()`: an unresolvable key
/// renders AS the key, so `find.text(key.tr())` would keep finding the link after the key was
/// deleted, while the user is shown the raw key.
Finder _captureReportLink() {
  return find
      .ancestor(
        of: find.text(appSentenceAt("$tr_capture.capture_control.report_screen.label")),
        matching: find.byType(TextButton),
      )
      .first;
}

/// The `onPressed` the control currently carries, read from the button itself.
///
/// Complements the reachability check rather than replacing it: a null callback is what makes the
/// button *announce* itself as disabled (Material's disabled foreground, and no semantics tap
/// action), while the focus check is what proves the keyboard cannot get there. Neither implies the
/// other, so both are asserted.
VoidCallback? _onPressedOf(WidgetTester tester, Finder finder) {
  final widget = tester.widget(finder);
  return switch (widget) {
    ButtonStyleButton() => widget.onPressed,
    _ => fail('unexpected control type ${widget.runtimeType}'),
  };
}

/// The capture toggle renders a `FilledButton` or an `OutlinedButton` depending on its state.
///
/// `byWidgetPredicate` rather than `byType`: `find.byType` compares `runtimeType` exactly, so it
/// never matches an abstract base, and `.icon` constructors return private subclasses.
Finder _toggleButton() {
  return find
      .descendant(of: find.byKey(_toggleKey), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton))
      .first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  useHiveForTest(['settings']);

  setUp(() async {
    await Hive.box('settings').clear();
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

  group('L1 -- the Disabled primitive', () {
    testWidgets('positive control: an enabled subtree takes Tab focus and fires on Enter and on Space', (tester) async {
      var fired = 0;
      await _pumpPrimitive(tester, () => fired++);

      final reached = await tabAndActivate(tester, find.byType(TextButton));

      expect(reached, isTrue, reason: 'an enabled button must be reachable by Tab');
      expect(fired, 2, reason: 'Enter and Space each fire once -- this is the measuring instrument');
    });

    testWidgets('a disabled subtree is unreachable by Tab and fires on neither key', (tester) async {
      var fired = 0;
      final state = await _pumpPrimitive(tester, () => fired++);
      state.setDisabled(true);
      await tester.pump();

      final reached = await tabAndActivate(tester, find.byType(TextButton));

      expect(reached, isFalse, reason: 'Disabled must withdraw the subtree from focus traversal');
      expect(fired, 0, reason: 'the shipped defect fired twice here');
    });

    testWidgets('a subtree that already held focus loses it when it becomes disabled', (tester) async {
      var fired = 0;
      final state = await _pumpPrimitive(tester, () => fired++);
      expect(await tabTo(tester, find.byType(TextButton)), isTrue);
      expect(focusIsWithin(find.byType(TextButton)), isTrue, reason: 'focus is on the subject to begin with');

      state.setDisabled(true);
      await tester.pump();

      expect(
        focusIsWithin(find.byType(TextButton)),
        isFalse,
        reason: 'skipping traversal is not enough: focus already inside has to be given up',
      );
      await activateFocused(tester);
      expect(fired, 0);
    });
  });

  group('L2 -- the capture card during a video import', () {
    testWidgets('positive control: with nothing running, all four controls are reachable and live', (tester) async {
      final card = await _pumpCard(tester);

      expect(_onPressedOf(tester, _toggleButton()), isNotNull);
      expect(_onPressedOf(tester, find.byKey(_pickKey)), isNotNull);
      expect(await tabTo(tester, find.byKey(_toggleKey)), isTrue, reason: 'the capture toggle is offered');
      expect(await tabTo(tester, find.byKey(_pickKey)), isTrue, reason: '動画取り込み is offered');

      // Pressing the two report links is observable without mounting anything: they ask for a
      // dialog, and with no `DialogLayer` the request stops at the provider.
      expect(await tabAndActivate(tester, _captureReportLink()), isTrue);
      expect(card.dialogRequested, isTrue, reason: 'キャプチャエラー報告 opens on Enter when it is offered');

      card.container.read(dialogBuilderProvider.notifier).dismiss();
      expect(card.dialogRequested, isFalse);

      expect(await tabAndActivate(tester, find.byKey(_importReportKey)), isTrue);
      expect(card.dialogRequested, isTrue, reason: '取り込みエラー報告 opens on Enter when it is offered');
    });

    testWidgets('while an import runs, the three blocked controls take no key', (tester) async {
      final card = await _pumpCard(
        tester,
        import: const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
      );

      // The flag assertions the suite already made, kept: they are what the sentence beside the
      // control is derived from, and they still have to hold.
      expect(
        tester
            .widget<Disabled>(find.ancestor(of: find.byKey(_toggleKey), matching: find.byType(Disabled)).first)
            .disabled,
        isTrue,
      );

      expect(
        _onPressedOf(tester, _toggleButton()),
        isNull,
        reason: 'the toggle must say it is disabled, not just look it',
      );
      expect(_onPressedOf(tester, _captureReportLink()), isNull);
      expect(_onPressedOf(tester, find.byKey(_importReportKey)), isNull);

      expect(await tabAndActivate(tester, find.byKey(_toggleKey)), isFalse, reason: '画面キャプチャ must not take focus');
      expect(await tabAndActivate(tester, _captureReportLink()), isFalse);
      expect(await tabAndActivate(tester, find.byKey(_importReportKey)), isFalse);
      expect(card.dialogRequested, isFalse, reason: 'no report dialog may be opened during an import');
    });

    testWidgets('while a capture runs, 動画取り込み takes no key either -- the control that was already correct', (
      tester,
    ) async {
      // The negative control for the fix itself. `VideoImportButton` already nulled its callback
      // before this change, so it was the one control the keyboard could not reach. If the fix ever
      // regresses `Disabled` into passing keys through again, this case and the one above go red
      // together; if only this one stays green, the primitive is not what is doing the work.
      await _pumpCard(tester, capturing: true);

      expect(_onPressedOf(tester, find.byKey(_pickKey)), isNull);
      expect(await tabAndActivate(tester, find.byKey(_pickKey)), isFalse);
    });
  });
}
