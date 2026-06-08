import 'package:dio/dio.dart';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';

/// Runs a [WebhookAction] by sending an HTTP request via the shared diagnostic
/// [Dio] client, substituting payload tokens into the URL and body.
class WebhookRunner implements ActionRunner {
  final WebhookAction action;

  const WebhookRunner(this.action);

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    final exec = ActionExecution();
    final cancelToken = CancelToken();
    var cancelled = false;

    // Percent-encode substituted values so spaces / & / # inside a token value
    // can't break the URL structure or inject extra query parameters.
    // encodeComponent (%20 for space) is valid in both path and query segments,
    // unlike encodeQueryComponent's '+', since a token may appear anywhere in the URL.
    final url = substitutePayload(action.url, payload, transform: Uri.encodeComponent);
    // Escape substituted values for the body's content type so a token value
    // containing a quote/newline (JSON) or '&'/'=' (form) cannot corrupt the body
    // or inject extra fields. The literal template text is left untouched.
    final spec = _specFor(action.contentType);
    final body = substitutePayload(action.bodyTemplate, payload, transform: spec.escaper);
    final options = Options(
      method: action.method,
      contentType: spec.header,
      // Treat any HTTP status as a completed response so non-2xx becomes a
      // failure result rather than a thrown DioException.
      validateStatus: (_) => true,
    );
    final timeout = action.timeoutSeconds;
    if (timeout != null && timeout > 0) {
      final duration = Duration(seconds: timeout);
      // connectTimeout is essential: send/receive timeouts do NOT bound the TCP
      // connect phase, so a host that blackholes packets would otherwise hang the
      // request forever, never finishing this execution and permanently consuming
      // one of the bounded concurrent-execution slots.
      options.connectTimeout = duration;
      options.sendTimeout = duration;
      options.receiveTimeout = duration;
    }

    // A fresh client per fire (this runs once per matching event); close it once
    // the request settles so its keep-alive HttpClient doesn't leak connections
    // over a long session. redactUrl keeps the substituted URL (which may carry a
    // webhook secret in the path and record data in the query) out of the log.
    final dio = createDiagnosticDio(operation: "addon_webhook", redactUrl: true);
    dio
        .request(
          url,
          data: _hasBody(action.method) && body.isNotEmpty ? body : null,
          options: options,
          cancelToken: cancelToken,
        )
        .then((response) {
          final code = response.statusCode ?? 0;
          final ok = code >= 200 && code < 300;
          exec.finish(
            (elapsed) => ExecutionResult(
              status: ok ? ExecutionStatus.success : ExecutionStatus.failure,
              exitCode: code,
              stdout: truncateCapture(response.data?.toString() ?? ""),
              error: ok ? null : "HTTP $code",
              duration: elapsed,
            ),
          );
        })
        .catchError((Object e) {
          final isCancel = cancelled || (e is DioException && e.type == DioExceptionType.cancel);
          // Log the action's summary (method + host), not the substituted URL,
          // which may carry a webhook secret and record data.
          logger.w("Webhook request failed: target=${action.describe()}, error=$e");
          exec.finish(
            (elapsed) => ExecutionResult(
              status: isCancel ? ExecutionStatus.cancelled : ExecutionStatus.failure,
              error: e.toString(),
              duration: elapsed,
            ),
          );
        })
        .whenComplete(dio.close);

    return exec.handle(() {
      cancelled = true;
      cancelToken.cancel();
    });
  }

  static bool _hasBody(String method) => method.toUpperCase() != "GET" && method.toUpperCase() != "HEAD";

  /// The header and body escaper for [contentType], defaulting to JSON for an
  /// unknown value (matching the form shown in the edit dialog).
  static _ContentTypeSpec _specFor(String contentType) => _contentTypeSpecs[contentType] ?? _contentTypeSpecs["json"]!;
}

/// Pairs a content-type header with the escaper applied to each substituted token
/// value in the body, so the two can never drift apart for a given content type.
class _ContentTypeSpec {
  final String header;

  /// Escaper for each substituted value, or null to send values verbatim.
  final String Function(String value)? escaper;

  const _ContentTypeSpec(this.header, this.escaper);
}

/// Content-type registry keyed by [WebhookAction.contentType]. `json` is also the
/// fallback for any unrecognized value (see [WebhookRunner._specFor]).
const _contentTypeSpecs = <String, _ContentTypeSpec>{
  // Each value is a single application/x-www-form-urlencoded field value.
  "form": _ContentTypeSpec("application/x-www-form-urlencoded", Uri.encodeQueryComponent),
  // Plain text is sent verbatim.
  "text": _ContentTypeSpec("text/plain", null),
  // Escape as a JSON string fragment so quotes/backslashes/newlines in a value
  // keep the body valid JSON.
  "json": _ContentTypeSpec("application/json", jsonStringFragment),
};
