import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/builtin_actions.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/utils.dart';

/// Backstop timeout for one builtin run. Builtins are expected to finish in
/// well under a second, but several await platform channels (clipboard, sound)
/// that can stall; without a bound, one stuck await would hold an execution
/// slot forever. A provider so tests can override it.
final builtinTimeoutProvider = Provider<Duration>((_) => const Duration(seconds: 30));

/// Runs a [BuiltinAction] by looking up its function in [builtinActionRegistry].
class BuiltinRunner implements ActionRunner {
  final BuiltinAction action;

  const BuiltinRunner(this.action);

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    final exec = ActionExecution();

    Future<void> run() async {
      final descriptor = builtinActionRegistry[action.actionKey];
      if (descriptor == null) {
        exec.finish(
          (elapsed) => ExecutionResult(
            status: ExecutionStatus.failure,
            error: "Unknown builtin action: ${action.actionKey}",
            duration: elapsed,
          ),
        );
        return;
      }
      try {
        await descriptor
            .run(ref, payload, action.argument, action.secondaryArgument)
            .timeout(ref.read(builtinTimeoutProvider));
        exec.finish((elapsed) => ExecutionResult(status: ExecutionStatus.success, duration: elapsed));
      } on TimeoutException {
        logger.w("Builtin action '${action.actionKey}' timed out.");
        exec.finish(
          (elapsed) => ExecutionResult(
            status: ExecutionStatus.timeout,
            error: "Builtin action '${action.actionKey}' did not finish in time.",
            duration: elapsed,
          ),
        );
      } catch (e, s) {
        logger.w("Builtin action '${action.actionKey}' failed: $e\n$s");
        exec.finish(
          (elapsed) => ExecutionResult(status: ExecutionStatus.failure, error: e.toString(), duration: elapsed),
        );
      }
    }

    run();

    // Cancel is best-effort: it releases the execution slot immediately (finish
    // is idempotent, so the builtin completing later is a no-op), but the
    // in-flight builtin itself runs to completion in the background.
    return exec.handle(
      () => exec.finish((elapsed) => ExecutionResult(status: ExecutionStatus.cancelled, duration: elapsed)),
    );
  }
}
