import 'dart:async';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/builtin_actions.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/utils.dart';

/// Runs a [BuiltinAction] by looking up its function in [builtinActionRegistry].
class BuiltinRunner implements ActionRunner {
  final BuiltinAction action;

  const BuiltinRunner(this.action);

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    final progress = StreamController<ExecutionProgress>.broadcast();
    final stopwatch = Stopwatch()..start();
    progress.add(ExecutionProgress.indeterminate);

    Future<ExecutionResult> run() async {
      final descriptor = builtinActionRegistry[action.actionKey];
      if (descriptor == null) {
        return ExecutionResult(
          status: ExecutionStatus.failure,
          error: "Unknown builtin action: ${action.actionKey}",
          duration: stopwatch.elapsed,
        );
      }
      try {
        await descriptor.run(ref, payload, action.argument);
        return ExecutionResult(status: ExecutionStatus.success, duration: stopwatch.elapsed);
      } catch (e, s) {
        logger.w("Builtin action '${action.actionKey}' failed: $e\n$s");
        return ExecutionResult(status: ExecutionStatus.failure, error: e.toString(), duration: stopwatch.elapsed);
      }
    }

    final result = run().whenComplete(() {
      stopwatch.stop();
      if (!progress.isClosed) progress.close();
    });

    // Built-ins are not cancellable in the MVP (they are short, fire-and-forget).
    return ActionHandle(progress: progress.stream, result: result, cancel: () {});
  }
}
