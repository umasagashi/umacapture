import '/src/addon/execution/builtin_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/execution/external_program_runner.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/utils.dart';

/// Executes one kind of [AddonAction]. Adding a new action kind means adding a
/// runner and one arm to [runnerFor] — no other layer changes.
abstract class ActionRunner {
  /// Starts the action and returns a controllable [ActionHandle].
  ActionHandle start(RefBase ref, PayloadMap payload);
}

/// Resolves the runner for [action].
ActionRunner runnerFor(AddonAction action) {
  return switch (action) {
    ExternalProgramAction a => ExternalProgramRunner(a),
    BuiltinAction a => BuiltinRunner(a),
    _ => throw UnimplementedError("No runner for action: ${action.runtimeType}"),
  };
}
