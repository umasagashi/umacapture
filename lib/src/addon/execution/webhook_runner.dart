import 'dart:async';

import 'package:dio/dio.dart';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';

/// Captured response body is truncated to this many characters to keep history
/// entries and dialogs bounded.
const _maxCaptureChars = 8192;

/// Runs a [WebhookAction] by sending an HTTP request via the shared diagnostic
/// [Dio] client, substituting payload tokens into the URL and body.
class WebhookRunner implements ActionRunner {
  final WebhookAction action;

  const WebhookRunner(this.action);

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    final progress = StreamController<ExecutionProgress>.broadcast();
    final completer = Completer<ExecutionResult>();
    final stopwatch = Stopwatch()..start();
    final cancelToken = CancelToken();
    var cancelled = false;

    void finish(ExecutionResult Function(Duration elapsed) build) {
      if (completer.isCompleted) return;
      stopwatch.stop();
      if (!progress.isClosed) progress.close();
      completer.complete(build(stopwatch.elapsed));
    }

    final url = substitutePayload(action.url, payload);
    final body = substitutePayload(action.bodyTemplate, payload);
    final options = Options(
      method: action.method,
      contentType: _contentTypeHeader(action.contentType),
      // Treat any HTTP status as a completed response so non-2xx becomes a
      // failure result rather than a thrown DioException.
      validateStatus: (_) => true,
    );
    final timeout = action.timeoutSeconds;
    if (timeout != null && timeout > 0) {
      options.sendTimeout = Duration(seconds: timeout);
      options.receiveTimeout = Duration(seconds: timeout);
    }

    progress.add(ExecutionProgress.indeterminate);
    createDiagnosticDio(operation: "addon_webhook")
        .request(
          url,
          data: _hasBody(action.method) && body.isNotEmpty ? body : null,
          options: options,
          cancelToken: cancelToken,
        )
        .then((response) {
          final code = response.statusCode ?? 0;
          final ok = code >= 200 && code < 300;
          finish(
            (elapsed) => ExecutionResult(
              status: ok ? ExecutionStatus.success : ExecutionStatus.failure,
              exitCode: code,
              stdout: _truncate(response.data?.toString() ?? ""),
              error: ok ? null : "HTTP $code",
              duration: elapsed,
            ),
          );
        })
        .catchError((Object e) {
          final isCancel = cancelled || (e is DioException && e.type == DioExceptionType.cancel);
          logger.w("Webhook request failed: url=$url, error=$e");
          finish(
            (elapsed) => ExecutionResult(
              status: isCancel ? ExecutionStatus.cancelled : ExecutionStatus.failure,
              error: e.toString(),
              duration: elapsed,
            ),
          );
        });

    return ActionHandle(
      progress: progress.stream,
      result: completer.future,
      cancel: () {
        cancelled = true;
        cancelToken.cancel();
      },
    );
  }

  static bool _hasBody(String method) => method.toUpperCase() != "GET" && method.toUpperCase() != "HEAD";

  static String _contentTypeHeader(String contentType) {
    return switch (contentType) {
      "form" => "application/x-www-form-urlencoded",
      "text" => "text/plain",
      _ => "application/json",
    };
  }

  static String _truncate(String s) => s.length > _maxCaptureChars ? s.substring(0, _maxCaptureChars) : s;
}
