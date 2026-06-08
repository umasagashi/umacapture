import 'dart:async';

import '/src/addon/execution/builtin_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/execution/external_program_runner.dart';
import '/src/addon/execution/webhook_runner.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/utils.dart';

/// Executes one kind of [AddonAction]. Adding a new action kind means adding a
/// runner and one arm to [runnerFor] — no other layer changes.
abstract class ActionRunner {
  /// Starts the action and returns a controllable [ActionHandle].
  ActionHandle start(RefBase ref, PayloadMap payload);
}

/// Shared scaffolding every [ActionRunner] needs: a broadcast progress stream
/// (seeded with an indeterminate tick), a single-completion result, and a
/// stopwatch. Centralizes the close/guard logic that previously drifted between
/// runners (e.g. one used `whenComplete` with no double-complete guard).
class ActionExecution {
  final _progress = StreamController<ExecutionProgress>.broadcast();
  final _completer = Completer<ExecutionResult>();
  final _stopwatch = Stopwatch()..start();

  ActionExecution() {
    _progress.add(ExecutionProgress.indeterminate);
  }

  /// Elapsed time since the action started; valid both before and after [finish].
  Duration get elapsed => _stopwatch.elapsed;

  /// Completes the result exactly once, stopping the clock and closing progress.
  /// Calls after the first are no-ops, so racing timeout/cancel/exit paths are safe.
  void finish(ExecutionResult Function(Duration elapsed) build) {
    if (_completer.isCompleted) return;
    _stopwatch.stop();
    if (!_progress.isClosed) _progress.close();
    _completer.complete(build(_stopwatch.elapsed));
  }

  /// Builds the handle a runner returns, wiring its [cancel] hook.
  ActionHandle handle(void Function() cancel) {
    return ActionHandle(progress: _progress.stream, result: _completer.future, cancel: cancel);
  }
}

/// Resolves the runner for [action].
ActionRunner runnerFor(AddonAction action) {
  return switch (action) {
    ExternalProgramAction a => ExternalProgramRunner(a),
    WebhookAction a => WebhookRunner(a),
    BuiltinAction a => BuiltinRunner(a),
    _ => throw UnimplementedError("No runner for action: ${action.runtimeType}"),
  };
}
