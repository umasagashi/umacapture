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
        await descriptor.run(ref, payload, action.argument);
        exec.finish((elapsed) => ExecutionResult(status: ExecutionStatus.success, duration: elapsed));
      } catch (e, s) {
        logger.w("Builtin action '${action.actionKey}' failed: $e\n$s");
        exec.finish(
          (elapsed) => ExecutionResult(status: ExecutionStatus.failure, error: e.toString(), duration: elapsed),
        );
      }
    }

    run();

    // Built-ins are not cancellable in the MVP (they are short, fire-and-forget).
    return exec.handle(() {});
  }
}
