import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Grace period to wait for stdout/stderr to flush after the process has exited
/// before finishing the execution anyway. A detached grandchild that inherited
/// the pipe keeps it open past the direct process's exit, so an unbounded wait
/// would hang [ExternalProgramRunner.start] forever and leak an execution slot.
const _drainGrace = Duration(seconds: 5);

/// Upper bound on raw bytes buffered per output stream before decoding. Four
/// bytes per char guarantees at least [maxCaptureChars] decoded characters even
/// for multi-byte encodings while keeping memory bounded.
const _maxCaptureBytes = 4 * maxCaptureChars;

/// Accumulates raw output bytes and decodes them in one shot at snapshot time.
/// Public so tests can pin the chunk-boundary behavior with an injected
/// [encoding] independent of the machine code page.
///
/// Decoding per pipe chunk would corrupt multi-byte characters split across a
/// chunk boundary: on Windows, [systemEncoding]'s decoder sink converts each
/// chunk independently (no cross-chunk state), so a CP932 lead byte at a chunk
/// edge becomes mojibake. Buffering the bytes and decoding once avoids that;
/// only a character cut by the byte cap itself can decode as garbage.
class CaptureBuffer {
  CaptureBuffer([this.encoding = systemEncoding]);

  final Encoding encoding;
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> chunk) {
    if (_bytes.length >= _maxCaptureBytes) return;
    final remaining = _maxCaptureBytes - _bytes.length;
    _bytes.add(chunk.length > remaining ? chunk.sublist(0, remaining) : chunk);
  }

  /// Decodes everything buffered so far, truncated to [maxCaptureChars].
  /// Repeatable: the buffered bytes are kept, so an early (drain-grace) snapshot
  /// simply reflects what has arrived by then.
  String snapshot() {
    try {
      return truncateCapture(encoding.decode(_bytes.toBytes()));
    } catch (e) {
      logger.w("Failed to decode external program output: $e");
      return "";
    }
  }
}

/// Forcefully terminates [process] and, on Windows, its whole child tree.
///
/// [Process.kill] only terminates the direct child: with
/// [ExternalProgramAction.runInShell] (or a launcher such as a `.bat` wrapper)
/// that kills cmd.exe while the actual program keeps running, despite the
/// timeout/cancel promising forced termination. `taskkill /T` removes the whole
/// tree; [Process.kill] remains the fallback (non-Windows, taskkill unavailable,
/// or the process already gone).
Future<void> _killProcessTree(Process process) async {
  if (Platform.isWindows) {
    try {
      final result = await Process.run("taskkill", ["/pid", "${process.pid}", "/T", "/F"]);
      if (result.exitCode == 0) return;
    } catch (e) {
      logger.w("taskkill failed; falling back to Process.kill: $e");
    }
  }
  process.kill();
}

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
          if (cancelled) unawaited(_killProcessTree(started));
          // Buffer raw bytes and decode once at snapshot time (system encoding:
          // JP Windows console tools emit CP932, which utf8 would mangle) — see
          // CaptureBuffer for why per-chunk decoding is wrong.
          final out = CaptureBuffer();
          final err = CaptureBuffer();
          final outDone = _drain(started.stdout, out);
          final errDone = _drain(started.stderr, err);

          // Always bound the run: an explicit timeout when set, otherwise the
          // backstop for legacy tasks. A never-exiting process must not hold an
          // execution slot indefinitely.
          final timeout = resolveExternalTimeoutSeconds(action.timeoutSeconds);
          if (timeout > 0) {
            timeoutTimer = Timer(Duration(seconds: timeout), () {
              timedOut = true;
              unawaited(_killProcessTree(started));
            });
          }

          started.exitCode.then((code) async {
            // The process has exited: a timer firing from here on (e.g. during
            // the drain wait below) must not flip the run to a timeout.
            timeoutTimer?.cancel();
            // Wait for stdout/stderr to fully flush before snapshotting: exitCode
            // can complete before the pipes have delivered their last bytes. Bound
            // the wait: a detached grandchild that inherited the pipe keeps it open
            // after the direct process exits, which would otherwise hang here
            // forever and permanently hold an execution slot. After the grace
            // period, snapshot whatever has been captured so far and finish.
            await Future.wait([outDone, errDone]).timeout(_drainGrace, onTimeout: () => const <void>[]);
            final status = cancelled
                ? ExecutionStatus.cancelled
                : timedOut
                ? ExecutionStatus.timeout
                : (code == 0 ? ExecutionStatus.success : ExecutionStatus.failure);
            exec.finish(
              (elapsed) => ExecutionResult(
                status: status,
                exitCode: code,
                stdout: out.snapshot(),
                stderr: err.snapshot(),
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
      final p = process;
      if (p != null) unawaited(_killProcessTree(p));
    });
  }

  /// Feeds [stream]'s raw bytes into [capture] and returns a future that
  /// completes when the stream is exhausted or errors.
  static Future<void> _drain(Stream<List<int>> stream, CaptureBuffer capture) {
    final done = Completer<void>();
    stream.listen(
      capture.add,
      onError: (Object e) => logger.w("Failed to read external program output: $e"),
      onDone: done.complete,
      cancelOnError: false,
    );
    return done.future;
  }
}

/// Splits [template] into individual arguments (honoring double quotes), then
/// substitutes `{var}` placeholders from [payload] within each argument.
/// Substituting after the split keeps a value containing spaces as a single
/// argument. Unknown placeholders expand to the empty string.
///
/// This is safe for the default argv path ([ExternalProgramAction.runInShell]
/// false): each argument is passed to the OS verbatim, so placeholder values
/// cannot break out of their argument. With `runInShell: true` the arguments are
/// handed to the system shell, which interprets metacharacters (`&`, `|`,
/// `%VAR%`, …) in substituted placeholder values **unescaped** — only enable it
/// for trusted templates.
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
