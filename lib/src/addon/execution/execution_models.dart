import 'dart:convert';

import 'package:dart_mappable/dart_mappable.dart';

import '/src/addon/model/task_definition.dart';

part 'execution_models.mapper.dart';

/// Normalized event data handed to an action: template-variable name to value
/// (e.g. `{"event": "record_captured", "record_id": "abc"}`).
typedef PayloadMap = Map<String, String>;

final _payloadPlaceholderPattern = RegExp(r'\{(\w+)\}');

/// Substitutes `{var}` placeholders in [template] with values from [payload].
/// Unknown placeholders expand to the empty string. Shared by the
/// external-program argument expander and built-in actions that take a content
/// template.
///
/// When [transform] is given it is applied to each substituted value (not the
/// literal template text) — e.g. percent-encoding to safely inject values into
/// a URL while keeping its structure intact. It receives the placeholder key so
/// a caller can exempt specific keys (the webhook JSON path inserts
/// `record_json` raw, as a JSON value rather than a string fragment).
///
/// Substitution is a single pass ([String.replaceAllMapped] never rescans a
/// replacement), so brace sequences inside a substituted value are left as-is.
///
/// Keys starting with `_` are an internal namespace (chain bookkeeping such as
/// `_chain_visited`, the `_enriched` marker) and are NEVER substituted — a
/// `{_chain_visited}` placeholder expands to empty so internal control state
/// cannot leak into command args, URLs, or webhook bodies.
String substitutePayload(String template, PayloadMap payload, {String Function(String key, String value)? transform}) {
  return template.replaceAllMapped(_payloadPlaceholderPattern, (m) {
    final key = m.group(1)!;
    final value = key.startsWith('_') ? '' : (payload[key] ?? '');
    return transform == null ? value : transform(key, value);
  });
}

/// Captured stdout/stderr/response bodies are truncated to this many characters
/// to keep history entries and dialogs bounded. Shared by every runner.
const maxCaptureChars = 8192;

/// Truncates [s] to [maxCaptureChars], used when a whole captured string is
/// available at once (the streaming external-program path bounds its buffer
/// incrementally instead).
String truncateCapture(String s) => s.length > maxCaptureChars ? s.substring(0, maxCaptureChars) : s;

/// Escapes [value] as the inner content of a JSON string (without the wrapping
/// quotes), so a placeholder value containing `"`, `\`, or a newline can be
/// substituted into a JSON body template while keeping it valid JSON.
String jsonStringFragment(String value) {
  final encoded = jsonEncode(value);
  return encoded.substring(1, encoded.length - 1);
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

  /// Captured stdout (external program) or response body (webhook), truncated to
  /// [maxCaptureChars]. Nullable so legacy entries without this key decode fine.
  final String? output;

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
    this.output,
  });
}
