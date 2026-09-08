// A DISABLED CONTROL MUST NOT ACT AS A HOLE IN THE ROW IT SITS ON.
//
// The addon task list draws each task as a `ListTile` whose whole surface opens the edit dialog and
// whose trailing ▶ starts a manual run. While the task is already running the ▶ is handed a null
// callback, which greys it and takes it out of the gesture arena -- so the press fell straight
// through to the row's own `onTap` and opened the edit dialog. The user aimed at a control that
// announces itself as unavailable and got a different screen.
//
// The claim these cases pin down: **a press that lands on the trailing control is answered by that
// control, whether or not it is available -- it never becomes a press on the row.** Its negative
// halves matter as much: an available ▶ still runs the task (the fix must not swallow real
// presses), the row itself still opens the dialog (the fix must not deaden the row), and the greyed
// ▶ still announces itself as a disabled control and still carries its tooltip (the fix must not be
// "remove it from hit testing", which is how the defect is *made*, not how it is cured).
//
// Run: .fvm/flutter_sdk/bin/flutter test test/addon_task_row_gate_test.dart
import 'dart:async';
// `Tristate` is declared in dart:ui and `package:flutter/semantics.dart` only imports it, so it has
// to be named from here.
import 'dart:ui' show Tristate;

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/addon/execution/action_runner.dart';
import 'package:umacapture/src/addon/execution/execution_controller.dart';
import 'package:umacapture/src/addon/execution/execution_models.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/addon/task_definitions.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/addon.dart';
import 'package:umacapture/src/gui/addon/task_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';

/// A runner that starts and then never finishes, so the task it was handed stays in `active` for as
/// long as the test needs the ▶ to be unavailable.
class _NeverFinishingRunner implements ActionRunner {
  final _progress = StreamController<ExecutionProgress>.broadcast();
  final _result = Completer<ExecutionResult>();
  var started = 0;

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    started++;
    return ActionHandle(progress: _progress.stream, result: _result.future, cancel: () {});
  }

  void dispose() {
    if (!_progress.isClosed) _progress.close();
  }
}

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

const _taskName = 'Nightly export';

TaskDefinition _task() {
  return const TaskDefinition(
    id: 'task-1',
    name: _taskName,
    trigger: TriggerEvent.manual,
    action: BuiltinAction(actionKey: 'show_toast', argument: '{event}'),
  );
}

/// The task row's trailing run control.
///
/// Found by its icon rather than by position: the running-tasks card below carries an `IconButton`
/// too (its cancel ✕), and a positional finder would silently start reading that one the day the
/// layout changes.
final _runButton = find.widgetWithIcon(IconButton, Symbols.play_arrow_rounded);

/// How the run control announces its own availability.
///
/// A [Tristate] rather than a boolean because [Tristate.none] -- a node that never claimed to be a
/// control with an enabled state at all -- is a *failing* outcome here, and a boolean would report
/// it as "not enabled" and call that a pass. That distinction is the whole point: the cure must
/// leave the button's own semantics intact and must not lay a second, tappable node over the top of
/// it, which would be a node announcing a tap with no enabled state to go with it.
Tristate _runEnablement(WidgetTester tester) => tester.getSemantics(_runButton).flagsCollection.isEnabled;

void main() {
  setUpAll(loadAppTranslations);

  group('the addon task row', () {
    useHiveForTest(['addon']);

    setUp(() => Hive.box('addon').clear());

    /// Mounts the real [AddonPage] under a [DialogLayer], which is the host that actually renders
    /// what `CardDialog.show` pushes. Without that host the edit dialog could never appear and
    /// every "no dialog opened" assertion below would pass for the wrong reason.
    Future<({ProviderContainer container, _NeverFinishingRunner runner})> pumpPage(
      WidgetTester tester, {
      required bool running,
    }) async {
      final runner = _NeverFinishingRunner();
      addTearDown(runner.dispose);
      final container = ProviderContainer.test(
        overrides: [actionRunnerFactoryProvider.overrideWithValue((action) => runner)],
      );
      container.read(taskDefinitionsProvider.notifier).addOrUpdate(_task());
      if (running) {
        container.read(addonExecutionControllerProvider.notifier).run(_task(), const {'event': 'manual'});
      }
      await pumpWithContainer(
        tester,
        container,
        MaterialApp(
          theme: _theme(),
          home: const DialogLayer(child: Scaffold(body: AddonPage())),
        ),
      );
      await tester.pump();
      return (container: container, runner: runner);
    }

    testWidgets('opens the edit dialog when the row itself is pressed', (tester) async {
      await pumpPage(tester, running: false);

      await tester.tap(find.text(_taskName));
      await tester.pump();

      // The positive control for every "no dialog" assertion below: this harness can open the
      // dialog, so a later `findsNothing` reports a press that was answered elsewhere rather than a
      // dialog that was never reachable.
      expect(find.byType(TaskEditDialog), findsOneWidget);
    });

    testWidgets('runs the task, and opens nothing, when an available run control is pressed', (tester) async {
      final h = await pumpPage(tester, running: false);
      expect(_runEnablement(tester), Tristate.isTrue);

      await tester.tap(_runButton);
      await tester.pump();

      // The press reached the button, not the row: the run started and the row's dialog did not.
      expect(h.runner.started, 1);
      expect(find.byType(TaskEditDialog), findsNothing);
    });

    testWidgets('opens no edit dialog when the unavailable run control is pressed', (tester) async {
      final h = await pumpPage(tester, running: true);
      expect(_runEnablement(tester), Tristate.isFalse);

      await tester.tap(_runButton, warnIfMissed: false);
      await tester.pump();

      // The defect: this press fell through the greyed ▶ onto the row and opened the edit dialog.
      expect(find.byType(TaskEditDialog), findsNothing);
      // And it did not start a second run either -- the button really is inert, not merely silent.
      expect(h.runner.started, 1);
    });

    testWidgets('still names the unavailable run control on hover', (tester) async {
      await pumpPage(tester, running: true);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(_runButton));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      // Read off the rendered tooltip, not off the parameter: the cure must not be one that kills
      // hover (an `AbsorbPointer` would), and only the drawn text can tell those apart. The literal
      // comes from the shipped `ja.json`, so `key.tr()` cannot compare equal to itself here.
      expect(find.text(appSentenceAt('pages.addon.task.run')), findsOneWidget);
    });
  });
}
