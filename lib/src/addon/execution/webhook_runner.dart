import 'dart:convert';

import 'package:dio/dio.dart';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';

/// Runs a [WebhookAction] by sending an HTTP request via the shared diagnostic
/// [Dio] client, substituting payload placeholders into the URL and body.
class WebhookRunner implements ActionRunner {
  final WebhookAction action;

  const WebhookRunner(this.action);

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    final exec = ActionExecution();
    final cancelToken = CancelToken();
    var cancelled = false;

    // Percent-encode substituted values so spaces / & / # inside a placeholder
    // value can't break the URL structure or inject extra query parameters.
    // encodeComponent (%20 for space) is valid in both path and query segments,
    // unlike encodeQueryComponent's '+', since a placeholder may appear anywhere in the URL.
    final url = substitutePayload(action.url, payload, transform: (_, value) => Uri.encodeComponent(value));
    // Escape substituted values for the body's content type so a placeholder value
    // containing a quote/newline (JSON) or '&'/'=' (form) cannot corrupt the body
    // or inject extra fields. The literal template text is left untouched, and
    // keys in the spec's rawKeys set bypass the escaper (record_json embeds as a
    // JSON value, not a string fragment).
    final spec = _specFor(action.contentType);
    final escaper = spec.escaper;
    final body = substitutePayload(
      action.bodyTemplate,
      payload,
      // A rawKeys value (record_json) is inserted unescaped so a whole JSON
      // document can embed as a JSON value. Guard it: only insert raw when it is
      // actually well-formed JSON, otherwise fall back to escaping it so a
      // corrupt/hand-edited record.json can never produce an invalid request body.
      transform: escaper == null
          ? null
          : (key, value) => (spec.rawKeys.contains(key) && _isValidJson(value)) ? value : escaper(value),
    );
    final options = Options(
      method: action.method,
      contentType: spec.header,
      // Do not follow redirects (Dio defaults to following up to 5). This is a
      // fire-and-forget notification: a 3xx becomes a non-2xx failure result
      // below. Auto-following would re-send the request -- including the body,
      // which may embed record data, and a secret carried in the URL path -- to
      // a redirect target, so an open redirect or a compromised endpoint could
      // exfiltrate them. Keeping redirects off matches the URL redaction above.
      followRedirects: false,
      // Treat any HTTP status as a completed response so non-2xx becomes a
      // failure result rather than a thrown DioException.
      validateStatus: (_) => true,
    );
    // Always bound the request: an explicit timeout when set, otherwise the
    // default. connectTimeout is essential: send/receive timeouts do NOT bound
    // the TCP connect phase, so a host that blackholes packets would otherwise
    // hang the request forever, never finishing this execution and permanently
    // consuming one of the bounded concurrent-execution slots.
    final duration = Duration(seconds: resolveWebhookTimeoutSeconds(action.timeoutSeconds));
    options.connectTimeout = duration;
    options.sendTimeout = duration;
    options.receiveTimeout = duration;

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
              // The response body is intentionally not persisted: it can echo a
              // secret (token, signed URL) or record data, and persisting it to
              // the on-disk history would undo the URL redaction applied above.
              // The HTTP status (exitCode / "HTTP $code") is enough to diagnose.
              error: ok ? null : "HTTP $code",
              duration: elapsed,
            ),
          );
        })
        .catchError((Object e) {
          // Log the action's summary (method + host), not the substituted URL,
          // which may carry a webhook secret and record data.
          logger.w("Webhook request failed: target=${action.describe()}, error=$e");
          exec.finish(
            (elapsed) => ExecutionResult(
              status: webhookErrorStatus(e, cancelled: cancelled),
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

  /// Whether [value] parses as a JSON document, so it is safe to embed raw as a
  /// JSON value in the request body.
  static bool _isValidJson(String value) {
    try {
      jsonDecode(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The header and body escaper for [contentType], defaulting to JSON for an
  /// unknown value (matching the form shown in the edit dialog).
  static _ContentTypeSpec _specFor(String contentType) => _contentTypeSpecs[contentType] ?? _contentTypeSpecs["json"]!;
}

/// The timeout (seconds) actually enforced for [configured], applying
/// [WebhookAction.defaultTimeoutSeconds] when it is null or non-positive. Always
/// positive, so a webhook can never hang unbounded and hold an execution slot.
int resolveWebhookTimeoutSeconds(int? configured) =>
    (configured == null || configured <= 0) ? WebhookAction.defaultTimeoutSeconds : configured;

/// Maps a failed webhook request to a terminal [ExecutionStatus].
///
/// A cancel (the [cancelled] flag, set by the handle's cancel hook, or a Dio
/// [DioExceptionType.cancel]) is [ExecutionStatus.cancelled]; a connect/send/
/// receive timeout is [ExecutionStatus.timeout] (distinct from a generic failure,
/// matching the external-program runner); anything else is
/// [ExecutionStatus.failure].
ExecutionStatus webhookErrorStatus(Object error, {required bool cancelled}) {
  if (cancelled || (error is DioException && error.type == DioExceptionType.cancel)) {
    return ExecutionStatus.cancelled;
  }
  if (error is DioException &&
      (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout)) {
    return ExecutionStatus.timeout;
  }
  return ExecutionStatus.failure;
}

/// Pairs a content-type header with the escaper applied to each substituted
/// placeholder value in the body, so the two can never drift apart for a given
/// content type.
class _ContentTypeSpec {
  final String header;

  /// Escaper for each substituted value, or null to send values verbatim.
  final String Function(String value)? escaper;

  /// Placeholder keys whose values bypass [escaper] and are inserted raw.
  final Set<String> rawKeys;

  const _ContentTypeSpec(this.header, this.escaper, {this.rawKeys = const {}});
}

/// Content-type registry keyed by [WebhookAction.contentType]. `json` is also the
/// fallback for any unrecognized value (see [WebhookRunner._specFor]).
const _contentTypeSpecs = <String, _ContentTypeSpec>{
  // Each value is a single application/x-www-form-urlencoded field value.
  "form": _ContentTypeSpec("application/x-www-form-urlencoded", Uri.encodeQueryComponent),
  // Plain text is sent verbatim.
  "text": _ContentTypeSpec("text/plain", null),
  // Escape as a JSON string fragment so quotes/backslashes/newlines in a value
  // keep the body valid JSON. record_json is the documented exception: it is an
  // entire JSON document, so escaping would make it impossible to embed as a
  // JSON value — it is inserted raw (used unquoted, e.g. {"record": {record_json}}).
  "json": _ContentTypeSpec("application/json", jsonStringFragment, rawKeys: {"record_json"}),
};
