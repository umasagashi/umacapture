// THE FOUR FEATURES OF THE CAPTURE CARD ARE MUTUALLY EXCLUSIVE.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_exclusive_features_test.dart
//
// THE RULE. 画面キャプチャ, 動画取り込み, キャプチャエラー報告 and 取り込みエラー報告 are four
// features and at most one of them runs at a time. While any one is running, the other three are
// unavailable and say which one is holding them.
//
// It is a rule about the product, not a claim about the implementation. Each control used to argue
// from what it happened to touch -- "the screenshot comes from the capture path", "an import is
// decoding through the producer this control needs" -- and those arguments pointed in different
// directions, which is how the capture-error report stayed pressable during a video import.
//
// TWELVE COMBINATIONS, TWO KINDS. Four features against the other three is twelve pairs. Nine of
// them are refusals a control has to make, and this file checks them. The three where a *report
// dialog* is the thing already running are structurally unreachable instead: both dialogs open
// through `CardDialog.show`, `DialogController` holds exactly one dialog, and `DialogLayer` puts
// the whole app behind a barrier -- so while either is up nothing on the card behind it can be
// reached, and a second dialog would replace the first rather than join it. That is why
// `CaptureActivity` has no value for "a report dialog is open": a state nothing can observe and
// nothing can read would only mislead the next reader. The last two cases below check the structure
// that makes that true, so the claim is measured rather than asserted in a comment.
//
// "CANNOT BE REACHED" IS A CLAIM ABOUT EVERY INPUT DEVICE, AND HAS TO BE MEASURED AS ONE. This file
// used to drive one tap and call that measured. A tap says nothing about the keyboard, and the two
// came apart in exactly this layer: the barrier was a `GestureDetector`, which refuses hit-testing
// and touches no focus node, so Tab walked out of the dialog into the page under the scrim and
// Enter fired what it landed on -- the same split `Disabled` carries a comment about. A test that
// drives only the pointer stays green through that, which makes it evidence of nothing. The dialog
// case below therefore drives BOTH devices, and it establishes the control behind is reachable by
// each of them first: an assertion that a control cannot be reached is worthless unless the same
// gesture is shown to reach it when nothing is in the way.
//
// WHERE THE FOURTH GATE LIVES. 動画取り込み's own gate is `resolveVideoImportBlocker`, in
// `lib/src/core/video_import_ops.dart`, called from `lib/src/gui/video_import.dart`. It takes the
// same `CaptureActivity` the other three do -- which it did NOT when this file was written. It took
// `capturing:` and `importing:` as two booleans read a second time from the same providers, so it
// could agree with the rule by accident and disagree with it silently; and it did disagree, naming
// a decode that had not started as the reason a file dialog was open. The agreement asserted here
// is therefore no longer "the two happen to answer alike" but "there is one answer", and what is
// checked is the reason and not merely the refusal.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/common.dart';

/// The import state that reaches [resolveCaptureActivity] as exactly [activity], paired with the
/// live-capture flag that goes with it.
///
/// An exhaustive switch, not a table: a fifth activity is a compile error here.
({bool capturing, VideoImportState importState}) _inputsFor(CaptureActivity activity) => switch (activity) {
  CaptureActivity.idle => (capturing: false, importState: VideoImportState.idle),
  CaptureActivity.capturing => (capturing: true, importState: VideoImportState.idle),
  CaptureActivity.pickingClip => (
    capturing: false,
    importState: const VideoImportState(phase: VideoImportPhase.picking),
  ),
  CaptureActivity.importing => (
    capturing: false,
    importState: const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
  ),
};

void main() {
  test('the inputs and the one state agree, for every activity', () {
    // The helper above is the bridge every case here crosses. If it did not actually reach the
    // activity it names, all of them would be asserting about the wrong state and still pass.
    for (final activity in CaptureActivity.values) {
      final inputs = _inputsFor(activity);
      expect(
        resolveCaptureActivity(capturing: inputs.capturing, importState: inputs.importState),
        activity,
        reason: '$activity',
      );
    }
  });

  test('starting a video import is refused by every running feature, and offered again after', () {
    // The same call `VideoImportButton` makes (`lib/src/gui/video_import.dart`), with the capability
    // and regeneration inputs held at "nothing in the way" so the only thing under test is the
    // activity. This is the fourth feature's half of the rule; the other three are checked in
    // `report_import_button_test.dart` and `capture_toggle_reason_test.dart`.
    for (final activity in CaptureActivity.values) {
      final inputs = _inputsFor(activity);
      final blocker = resolveVideoImportBlocker(
        available: true,
        supported: true,
        controllerReady: true,
        // Resolved from the same two inputs the widget resolves it from, so this case cannot pass by
        // handing the gate an activity the card could never be in.
        activity: resolveCaptureActivity(capturing: inputs.capturing, importState: inputs.importState),
        regenerating: false,
      );
      if (activity == CaptureActivity.idle) {
        expect(blocker, isNull, reason: 'nothing is running, so the import must be offered');
      } else {
        expect(blocker, isNotNull, reason: '$activity must withdraw the import control');
      }
    }
  });

  test('the import control names the feature that is actually running, not another one', () {
    // The weakness the previous stage recorded and this one closes: the case above catches a gate
    // that stops refusing, and nothing caught a gate that refuses under the wrong name. Both halves
    // matter to the user in the same way -- a control that is inert for a reason it does not have
    // sends them to stop something that is not running.
    const named = <CaptureActivity, VideoImportBlocker?>{
      CaptureActivity.idle: null,
      CaptureActivity.capturing: VideoImportBlocker.capturing,
      CaptureActivity.pickingClip: VideoImportBlocker.picking,
      CaptureActivity.importing: VideoImportBlocker.importing,
    };
    expect(named.keys, containsAll(CaptureActivity.values), reason: 'every activity has to be named');
    for (final activity in CaptureActivity.values) {
      final inputs = _inputsFor(activity);
      expect(
        resolveVideoImportBlocker(
          available: true,
          supported: true,
          controllerReady: true,
          activity: resolveCaptureActivity(capturing: inputs.capturing, importState: inputs.importState),
          regenerating: false,
        ),
        named[activity],
        reason: '$activity',
      );
    }
  });

  test('only 動画取り込み may be operated while 動画取り込み is what is running', () {
    // Its running state is a cancel, exactly as the capture toggle's is a stop. The rule withdraws
    // the OTHER three features, never the one that owns the activity -- a rule that withdrew all
    // four would leave a running session with no way to end it.
    expect(
      resolveVideoImportBlocker(
        available: true,
        supported: true,
        controllerReady: true,
        // What the import's own pre-flight passes while its file dialog is open, for the reason
        // stated at `VideoImportButton._preflight`: its own state is left out of the activity,
        // because the import that is asking IS that activity and would otherwise refuse itself.
        activity: resolveCaptureActivity(capturing: false, importState: VideoImportState.idle),
        regenerating: false,
      ),
      isNull,
    );
    // And leaving its own state out must not blind it to anything else. The regeneration is the one
    // this second call exists for -- a batch can auto-start while the dialog is open -- so it is
    // asserted through the same exclusion rather than trusted to it.
    expect(
      resolveVideoImportBlocker(
        available: true,
        supported: true,
        controllerReady: true,
        activity: resolveCaptureActivity(capturing: false, importState: VideoImportState.idle),
        regenerating: true,
      ),
      VideoImportBlocker.regenerating,
    );
  });

  testWidgets('a report dialog covers the card, so no other feature can be reached behind it', (tester) async {
    // The measurement behind "structurally unreachable". Both report dialogs are `CardDialog`s, and
    // this is the layer every one of them is rendered by. The control behind is a real button
    // rather than a bare `GestureDetector` because a button is what is actually behind these
    // dialogs, and because only a button answers the keyboard half at all.
    var hitsBehind = 0;
    var hitsInDialog = 0;
    final behind = FocusNode(debugLabel: 'behind');
    final inDialog = FocusNode(debugLabel: 'in dialog');
    addTearDown(behind.dispose);
    addTearDown(inDialog.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DialogLayer(
            child: Scaffold(
              // Off-centre on purpose: the dialog is laid out centred, so a control in the middle
              // of the page would sit under the dialog itself and the pointer case could not tell
              // "the barrier stopped the tap" from "the dialog's own button took it".
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 400,
                  child: TextButton(focusNode: behind, onPressed: () => hitsBehind += 1, child: const Text('behind')),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // BASELINE, POINTER AND KEYBOARD. Both halves of the refusal below mean nothing unless the
    // same two gestures are shown to work with nothing in the way.
    await tester.tap(find.text('behind'));
    await tester.pump();
    expect(hitsBehind, 1, reason: 'without a dialog the control behind is reachable by pointer');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(behind.hasFocus, isTrue, reason: 'without a dialog Tab reaches the control behind');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(hitsBehind, 2, reason: 'without a dialog Enter fires the focused control behind');

    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => TextButton(focusNode: inDialog, onPressed: () => hitsInDialog += 1, child: const Text('in dialog')),
        );
    await tester.pump();

    // Showing the dialog has to take the focus off the page immediately: a focus ring left under
    // an opaque scrim is a keyboard user standing somewhere they cannot see.
    expect(behind.hasFocus, isFalse, reason: 'opening a dialog withdraws the focus the page held');

    // Enough presses to walk the whole traversal ring, not one: the point is that no amount of
    // tabbing leaves the dialog, and one press only shows where the very next stop is.
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(behind.hasFocus, isFalse, reason: 'Tab must not walk out of the dialog into the page behind it');
    }
    expect(inDialog.hasFocus, isTrue, reason: 'traversal stays inside the dialog rather than going nowhere');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(hitsBehind, 2, reason: 'Enter fires nothing behind the scrim');
    expect(hitsInDialog, 1, reason: 'Enter still reaches the dialog itself');

    // The pointer half comes last because this tap lands on a dismissible barrier and therefore
    // ends the dialog -- which is also what proves it landed on the barrier rather than in a gap.
    await tester.tap(find.text('behind'), warnIfMissed: false);
    await tester.pump();
    expect(hitsBehind, 2, reason: 'the dialog barrier swallowed the tap instead of letting it through');
    expect(container.read(dialogBuilderProvider), isNull, reason: 'the tap reached the barrier, which dismissed it');

    // And the withdrawal is only for as long as the dialog is up. A page that stayed unreachable
    // after the dialog closed would be the same defect facing the other way.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(behind.hasFocus, isTrue, reason: 'closing the dialog gives the page back to the keyboard');
  });

  test('a second report dialog replaces the first rather than joining it', () {
    // The other half of the structural claim: the two report dialogs cannot both be open, so
    // "キャプチャエラー報告 while 取り込みエラー報告 is open" is not a state to gate against.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final dialogs = container.read(dialogBuilderProvider.notifier);
    final first = dialogs.show((_) => const SizedBox.shrink());
    final second = dialogs.show((_) => const SizedBox.shrink());
    expect(second, isNot(first), reason: 'two different dialogs, so this is not the same one twice');
    expect(container.read(dialogBuilderProvider), isNotNull);
    dialogs.dismiss(first);
    expect(container.read(dialogBuilderProvider), isNotNull, reason: 'the first is gone; the second is what is up');
    dialogs.dismiss(second);
    expect(container.read(dialogBuilderProvider), isNull);
  });
}
