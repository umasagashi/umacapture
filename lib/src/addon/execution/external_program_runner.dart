import 'dart:async';
import 'dart:io';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/utils.dart';

/// Captured stdout/stderr is truncated to this many characters to keep history
/// entries and dialogs bounded.
const _maxCaptureChars = 8192;

/// Runs an [ExternalProgramAction] via [Process.start], substituting payload
/// variables into the argument template and capturing output.
class ExternalProgramRunner implements ActionRunner {
  final ExternalProgramAction action;

  const ExternalProgramRunner(this.action);

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    final progress = StreamController<ExecutionProgress>.broadcast();
    final completer = Completer<ExecutionResult>();
    final stopwatch = Stopwatch()..start();
    Process? process;
    Timer? timeoutTimer;
    var cancelled = false;
    var timedOut = false;

    void finish(ExecutionResult Function(Duration elapsed) build) {
      if (completer.isCompleted) return;
      timeoutTimer?.cancel();
      stopwatch.stop();
      final result = build(stopwatch.elapsed);
      if (!progress.isClosed) progress.close();
      completer.complete(result);
    }

    final args = expandArgumentTemplate(action.argumentTemplate, payload);
    final workingDir = action.workingDirectory?.trim();

    progress.add(ExecutionProgress.indeterminate);
    Process.start(
          action.programPath,
          args,
          runInShell: action.runInShell,
          workingDirectory: workingDir == null || workingDir.isEmpty ? null : workingDir,
        )
        .then((started) {
          process = started;
          // Decode with the system encoding: JP Windows console tools emit CP932,
          // which utf8 would mangle.
          final out = StringBuffer();
          final err = StringBuffer();
          started.stdout.transform(systemEncoding.decoder).listen((s) => _append(out, s));
          started.stderr.transform(systemEncoding.decoder).listen((s) => _append(err, s));

          final timeout = action.timeoutSeconds;
          if (timeout != null && timeout > 0) {
            timeoutTimer = Timer(Duration(seconds: timeout), () {
              timedOut = true;
              started.kill();
            });
          }

          started.exitCode.then((code) {
            final status = cancelled
                ? ExecutionStatus.cancelled
                : timedOut
                ? ExecutionStatus.timeout
                : (code == 0 ? ExecutionStatus.success : ExecutionStatus.failure);
            finish(
              (elapsed) => ExecutionResult(
                status: status,
                exitCode: code,
                stdout: out.toString(),
                stderr: err.toString(),
                duration: elapsed,
              ),
            );
          });
        })
        .catchError((Object e, StackTrace s) {
          logger.w("Failed to launch external program: ${action.programPath}, error=$e");
          finish((elapsed) => ExecutionResult(status: ExecutionStatus.failure, error: e.toString(), duration: elapsed));
        });

    return ActionHandle(
      progress: progress.stream,
      result: completer.future,
      cancel: () {
        cancelled = true;
        process?.kill();
      },
    );
  }

  static void _append(StringBuffer buffer, String chunk) {
    if (buffer.length >= _maxCaptureChars) return;
    final remaining = _maxCaptureChars - buffer.length;
    buffer.write(chunk.length > remaining ? chunk.substring(0, remaining) : chunk);
  }
}

/// Splits [template] into individual arguments (honoring double quotes), then
/// substitutes `{var}` tokens from [payload] within each argument. Substituting
/// after the split keeps a value containing spaces as a single argument. Unknown
/// tokens expand to the empty string.
///
/// This is safe for the default argv path ([ExternalProgramAction.runInShell]
/// false): each argument is passed to the OS verbatim, so token values cannot
/// break out of their argument. With `runInShell: true` the arguments are handed
/// to the system shell, which interprets metacharacters (`&`, `|`, `%VAR%`, …) in
/// substituted token values **unescaped** — only enable it for trusted templates.
List<String> expandArgumentTemplate(String template, PayloadMap payload) {
  final tokens = _tokenize(template);
  return tokens.map((t) => substitutePayload(t, payload)).toList();
}

List<String> _tokenize(String template) {
  final result = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var hasContent = false;
  for (var i = 0; i < template.length; i++) {
    final ch = template[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
      hasContent = true;
    } else if (ch == ' ' && !inQuotes) {
      if (hasContent) {
        result.add(current.toString());
        current.clear();
        hasContent = false;
      }
    } else {
      current.write(ch);
      hasContent = true;
    }
  }
  if (hasContent) result.add(current.toString());
  return result;
}
