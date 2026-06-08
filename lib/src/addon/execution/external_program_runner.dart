import 'dart:async';
import 'dart:io';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/utils.dart';

/// The timeout (seconds) actually enforced for [configured], applying
/// [ExternalProgramAction.defaultTimeoutSeconds] when it is null or non-positive.
/// Always positive, so an external program can never run unbounded and hold an
/// execution slot forever.
int resolveExternalTimeoutSeconds(int? configured) =>
    (configured == null || configured <= 0) ? ExternalProgramAction.defaultTimeoutSeconds : configured;

/// Runs an [ExternalProgramAction] via [Process.start], substituting payload
/// variables into the argument template and capturing output.
class ExternalProgramRunner implements ActionRunner {
  final ExternalProgramAction action;

  const ExternalProgramRunner(this.action);

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    final exec = ActionExecution();
    Process? process;
    Timer? timeoutTimer;
    var cancelled = false;
    var timedOut = false;

    final args = expandArgumentTemplate(action.argumentTemplate, payload);
    final workingDir = action.workingDirectory?.trim();

    Process.start(
          action.programPath,
          args,
          runInShell: action.runInShell,
          workingDirectory: workingDir == null || workingDir.isEmpty ? null : workingDir,
        )
        .then((started) {
          process = started;
          // A cancel issued while Process.start was still resolving could not kill
          // a null process; honor it now that the process exists. Fall through so
          // the exit handler still runs and completes the result (as cancelled).
          if (cancelled) started.kill();
          // Decode with the system encoding: JP Windows console tools emit CP932,
          // which utf8 would mangle. onError keeps an undecodable byte sequence
          // from surfacing as an uncaught async error.
          final out = StringBuffer();
          final err = StringBuffer();
          final outDone = _drain(started.stdout, out);
          final errDone = _drain(started.stderr, err);

          // Always bound the run: an explicit timeout when set, otherwise the
          // backstop for legacy tasks. A never-exiting process must not hold an
          // execution slot indefinitely.
          final timeout = resolveExternalTimeoutSeconds(action.timeoutSeconds);
          if (timeout > 0) {
            timeoutTimer = Timer(Duration(seconds: timeout), () {
              timedOut = true;
              started.kill();
            });
          }

          started.exitCode.then((code) async {
            // Wait for stdout/stderr to fully flush before snapshotting: exitCode
            // can complete before the pipes have delivered their last bytes.
            await Future.wait([outDone, errDone]);
            timeoutTimer?.cancel();
            final status = cancelled
                ? ExecutionStatus.cancelled
                : timedOut
                ? ExecutionStatus.timeout
                : (code == 0 ? ExecutionStatus.success : ExecutionStatus.failure);
            exec.finish(
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
          timeoutTimer?.cancel();
          exec.finish(
            (elapsed) => ExecutionResult(status: ExecutionStatus.failure, error: e.toString(), duration: elapsed),
          );
        });

    return exec.handle(() {
      cancelled = true;
      process?.kill();
    });
  }

  /// Decodes [stream] into [buffer] (bounded to [maxCaptureChars]) and returns a
  /// future that completes when the stream is exhausted or errors.
  static Future<void> _drain(Stream<List<int>> stream, StringBuffer buffer) {
    final done = Completer<void>();
    stream
        .transform(systemEncoding.decoder)
        .listen(
          (s) => _append(buffer, s),
          onError: (Object e) => logger.w("Failed to decode external program output: $e"),
          onDone: done.complete,
          cancelOnError: false,
        );
    return done.future;
  }

  static void _append(StringBuffer buffer, String chunk) {
    if (buffer.length >= maxCaptureChars) return;
    final remaining = maxCaptureChars - buffer.length;
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
