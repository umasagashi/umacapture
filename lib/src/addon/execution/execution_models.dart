import 'package:dart_mappable/dart_mappable.dart';

import '/src/addon/model/task_definition.dart';

part 'execution_models.mapper.dart';

/// Normalized event data handed to an action: template-variable name to value
/// (e.g. `{"event": "record_captured", "record_id": "abc"}`).
typedef PayloadMap = Map<String, String>;

final _payloadTokenPattern = RegExp(r'\{(\w+)\}');

/// Substitutes `{var}` tokens in [template] with values from [payload]. Unknown
/// tokens expand to the empty string. Shared by the external-program argument
/// expander and built-in actions that take a content template.
///
/// When [transform] is given it is applied to each substituted value (not the
/// literal template text) — e.g. [Uri.encodeQueryComponent] to safely inject
/// values into a URL while keeping its structure intact.
String substitutePayload(String template, PayloadMap payload, {String Function(String value)? transform}) {
  return template.replaceAllMapped(_payloadTokenPattern, (m) {
    final value = payload[m.group(1)] ?? '';
    return transform == null ? value : transform(value);
  });
}

/// Terminal (or in-flight) state of a single addon execution.
@MappableEnum()
enum ExecutionStatus { running, success, failure, cancelled, timeout }

/// A progress tick emitted by a running action. [value] is 0..1 for determinate
/// progress, or null when the action cannot report progress (e.g. external
/// programs), in which case the UI shows an indeterminate spinner.
class ExecutionProgress {
  final double? value;
  final String? message;

  const ExecutionProgress({this.value, this.message});

  static const indeterminate = ExecutionProgress();
}

/// The outcome of a finished action.
class ExecutionResult {
  final ExecutionStatus status;
  final int? exitCode;
  final String? stdout;
  final String? stderr;
  final String? error;
  final Duration duration;

  const ExecutionResult({
    required this.status,
    this.exitCode,
    this.stdout,
    this.stderr,
    this.error,
    this.duration = Duration.zero,
  });
}

/// A controllable handle over a started action: a progress stream, a terminal
/// result future, and a cancel hook. Returned by every [ActionRunner].
class ActionHandle {
  final Stream<ExecutionProgress> progress;
  final Future<ExecutionResult> result;
  final void Function() cancel;

  const ActionHandle({required this.progress, required this.result, required this.cancel});
}

/// A persisted record of a finished execution, shown in the history card.
@MappableClass(caseStyle: CaseStyle.snakeCase)
class HistoryEntry with HistoryEntryMappable {
  final String executionId;
  final String taskId;
  final String taskName;
  final TriggerEvent trigger;
  final ExecutionStatus status;
  final DateTime startedAt;
  final int durationMs;
  final int? exitCode;
  final String? error;

  const HistoryEntry({
    required this.executionId,
    required this.taskId,
    required this.taskName,
    required this.trigger,
    required this.status,
    required this.startedAt,
    required this.durationMs,
    this.exitCode,
    this.error,
  });
}
