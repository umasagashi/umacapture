// Unit tests for the addon runner I/O paths and editor validation that the
// previous batch deferred: the webhook HTTP path (against a local server), the
// external-program process path (against cmd.exe on Windows), the output cap,
// and the task-dialog validation helpers.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/addon_runner_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/addon/execution/execution_models.dart';
import 'package:umacapture/src/addon/execution/external_program_runner.dart';
import 'package:umacapture/src/addon/execution/webhook_runner.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/addon.dart' show formatHistoryTimestamp;
import 'package:umacapture/src/gui/addon/task_dialog.dart';

/// Exposes a [RefBase] so the runners (which take one) can be called in tests.
/// Both runners ignore it for these cases, but the signature requires it.
final _refBaseProvider = Provider<RefBase>((ref) => ref.base);

void main() {
  group('WebhookRunner.start', () {
    late HttpServer server;
    late int port;
    late Future<void> Function(HttpRequest request) handler;
    late ProviderContainer container;
    late RefBase ref;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((request) => handler(request));
      container = ProviderContainer.test();
      ref = container.read(_refBaseProvider);
    });

    tearDown(() async {
      await server.close(force: true);
      container.dispose();
    });

    String url(String path) => 'http://127.0.0.1:$port$path';

    test('a 2xx response is a success carrying the status code, and the body is not persisted', () async {
      handler = (request) async {
        request.response.statusCode = 200;
        request.response.write('pong');
        await request.response.close();
      };

      final result = await WebhookRunner(WebhookAction(url: url('/ok'), method: 'GET')).start(ref, const {}).result;

      expect(result.status, ExecutionStatus.success);
      expect(result.exitCode, 200);
      // The response body is intentionally not captured into the result/history,
      // so a secret or record data echoed back cannot leak to disk.
      expect(result.stdout, isNull);
    });

    test('a non-2xx response is a failure (validateStatus keeps it from throwing)', () async {
      handler = (request) async {
        request.response.statusCode = 500;
        await request.response.close();
      };

      final result = await WebhookRunner(WebhookAction(url: url('/boom'), method: 'GET')).start(ref, const {}).result;

      expect(result.status, ExecutionStatus.failure);
      expect(result.exitCode, 500);
      expect(result.error, 'HTTP 500');
    });

    test('a response slower than the timeout is reported as a timeout', () async {
      handler = (request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        request.response.statusCode = 200;
        await request.response.close();
      };

      final result = await WebhookRunner(
        WebhookAction(url: url('/slow'), method: 'GET', timeoutSeconds: 1),
      ).start(ref, const {}).result;

      expect(result.status, ExecutionStatus.timeout);
    });

    test('cancelling an in-flight request is reported as cancelled', () async {
      handler = (request) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        request.response.statusCode = 200;
        await request.response.close();
      };

      final handle = WebhookRunner(
        WebhookAction(url: url('/slow'), method: 'GET', timeoutSeconds: 30),
      ).start(ref, const {});
      handle.cancel();

      expect((await handle.result).status, ExecutionStatus.cancelled);
    });

    test('a JSON POST escapes substituted values and sets the content type', () async {
      String? receivedBody;
      String? receivedContentType;
      handler = (request) async {
        receivedBody = await utf8.decodeStream(request);
        receivedContentType = request.headers.contentType?.mimeType;
        request.response.statusCode = 200;
        await request.response.close();
      };

      await WebhookRunner(
        WebhookAction(url: url('/post'), method: 'POST', contentType: 'json', bodyTemplate: '{"v":"{record_id}"}'),
      ).start(ref, const {'record_id': 'Special "Week"'}).result;

      expect(receivedContentType, 'application/json');
      // The quote inside the value is escaped, so the body stays valid JSON and
      // decodes back to the original value (jsonStringFragment, end-to-end).
      expect(jsonDecode(receivedBody!), {'v': 'Special "Week"'});
    });

    test('a JSON POST embeds {record_json} raw as a JSON value while escaping other keys', () async {
      String? receivedBody;
      handler = (request) async {
        receivedBody = await utf8.decodeStream(request);
        request.response.statusCode = 200;
        await request.response.close();
      };

      const recordJson = '{"a":"x \\"y\\"","n":1}';
      await WebhookRunner(
        WebhookAction(
          url: url('/post'),
          method: 'POST',
          contentType: 'json',
          bodyTemplate: '{"record": {record_json}, "v":"{record_id}"}',
        ),
      ).start(ref, const {'record_json': recordJson, 'record_id': 'Special "Week"'}).result;

      // The record document arrives as a nested JSON object (not a double-encoded
      // string), and the ordinary placeholder is still escaped.
      expect(jsonDecode(receivedBody!), {
        'record': {'a': 'x "y"', 'n': 1},
        'v': 'Special "Week"',
      });
    });

    test('an invalid {record_json} is escaped instead of inserted raw, keeping the body valid JSON', () async {
      String? receivedBody;
      handler = (request) async {
        receivedBody = await utf8.decodeStream(request);
        request.response.statusCode = 200;
        await request.response.close();
      };

      // A corrupt/hand-edited record.json that is not well-formed JSON.
      const brokenJson = '{"a": not json';
      await WebhookRunner(
        WebhookAction(
          url: url('/post'),
          method: 'POST',
          contentType: 'json',
          bodyTemplate: '{"record": "{record_json}"}',
        ),
      ).start(ref, const {'record_json': brokenJson}).result;

      // The broken value is escaped as a JSON string fragment, so the body stays
      // valid JSON and round-trips back to the original text.
      expect(jsonDecode(receivedBody!), {'record': brokenJson});
    });

    test('a GET sends no request body even when a body template is set', () async {
      String? receivedBody;
      handler = (request) async {
        receivedBody = await utf8.decodeStream(request);
        request.response.statusCode = 200;
        await request.response.close();
      };

      await WebhookRunner(
        WebhookAction(url: url('/get'), method: 'GET', bodyTemplate: '{"x":1}'),
      ).start(ref, const {}).result;

      expect(receivedBody, isEmpty);
    });
  });

  group('ExternalProgramRunner.start', () {
    final comspec = Platform.environment['COMSPEC'] ?? 'cmd.exe';
    late ProviderContainer container;
    late RefBase ref;

    setUp(() {
      container = ProviderContainer.test();
      ref = container.read(_refBaseProvider);
    });
    tearDown(() => container.dispose());

    Future<ExecutionResult> run(String args, {int? timeoutSeconds, PayloadMap payload = const {}}) {
      final action = ExternalProgramAction(
        programPath: comspec,
        argumentTemplate: args,
        timeoutSeconds: timeoutSeconds,
      );
      return ExternalProgramRunner(action).start(ref, payload).result;
    }

    test('captures stdout and maps exit 0 to success', () async {
      final result = await run('/c echo hello');
      expect(result.status, ExecutionStatus.success);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('hello'));
    });

    test('substitutes placeholders into the real argv', () async {
      final result = await run('/c echo {event}', payload: const {'event': 'manual'});
      expect(result.stdout, contains('manual'));
    });

    test('maps a non-zero exit code to failure', () async {
      final result = await run('/c exit 3');
      expect(result.status, ExecutionStatus.failure);
      expect(result.exitCode, 3);
    });

    test('kills a run that exceeds its timeout and reports timeout', () async {
      // ping -n 5 keeps the process alive ~4s; a 1s timeout must kill it.
      final result = await run('/c ping 127.0.0.1 -n 5', timeoutSeconds: 1);
      expect(result.status, ExecutionStatus.timeout);
    });

    test('cancel kills the process and reports cancelled', () async {
      final action = ExternalProgramAction(
        programPath: comspec,
        argumentTemplate: '/c ping 127.0.0.1 -n 30',
        timeoutSeconds: 60,
      );
      final handle = ExternalProgramRunner(action).start(ref, const {});
      handle.cancel();
      expect((await handle.result).status, ExecutionStatus.cancelled);
    });
  }, skip: !Platform.isWindows ? 'Windows-only (drives cmd.exe)' : null);

  group('truncateCapture', () {
    test('truncates to maxCaptureChars and leaves shorter strings intact', () {
      expect(truncateCapture('x' * (maxCaptureChars + 808)).length, maxCaptureChars);
      expect(truncateCapture('short'), 'short');
    });
  });

  group('CaptureBuffer', () {
    test('decodes a multi-byte character split across chunks intact', () {
      // Per-chunk decoding would turn each half into garbage; the buffer must
      // defer decoding until snapshot so the split character survives. utf8 is
      // injected so the test does not depend on the machine code page.
      final bytes = utf8.encode('日');
      final buffer = CaptureBuffer(utf8)
        ..add(bytes.sublist(0, 1))
        ..add(bytes.sublist(1));
      expect(buffer.snapshot(), '日');
    });

    test('caps the buffered bytes and truncates the decoded snapshot', () {
      final buffer = CaptureBuffer(utf8);
      // Feed far more than the cap in moderate chunks.
      for (var i = 0; i < 10; i++) {
        buffer.add(List.filled(maxCaptureChars, 0x61));
      }
      final snapshot = buffer.snapshot();
      expect(snapshot.length, maxCaptureChars);
      expect(snapshot, startsWith('aaa'));
    });

    test('snapshot is repeatable and reflects later additions', () {
      final buffer = CaptureBuffer(utf8)..add(utf8.encode('one'));
      expect(buffer.snapshot(), 'one');
      buffer.add(utf8.encode(' two'));
      expect(buffer.snapshot(), 'one two');
    });
  });

  group('task_dialog validation helpers', () {
    test('timeoutErrorKey enforces a positive integer, required-aware', () {
      expect(timeoutErrorKey('', required: true), '$tr_addon.dialog.timeout_required');
      expect(timeoutErrorKey(''), isNull);
      expect(timeoutErrorKey('0'), '$tr_addon.dialog.timeout_invalid');
      expect(timeoutErrorKey('abc'), '$tr_addon.dialog.timeout_invalid');
      expect(timeoutErrorKey('5'), isNull);
    });

    test('urlErrorKey accepts templated http/https URLs and rejects bad ones', () {
      expect(urlErrorKey(''), isNull);
      // Placeholders are stripped via the runtime substituter before parsing.
      expect(urlErrorKey('http://host/{record_id}'), isNull);
      expect(urlErrorKey('https://host'), isNull);
      expect(urlErrorKey('ftp://host'), '$tr_addon.dialog.webhook.url_invalid');
      expect(urlErrorKey('not a url'), '$tr_addon.dialog.webhook.url_invalid');
    });

    test('builtinNeedsUnavailableRecord blocks record-only builtins on record-less triggers', () {
      expect(builtinNeedsUnavailableRecord('copy_image_to_clipboard', TriggerEvent.manual), isTrue);
      expect(builtinNeedsUnavailableRecord('copy_image_to_clipboard', TriggerEvent.recordCaptured), isFalse);
      expect(builtinNeedsUnavailableRecord('show_toast', TriggerEvent.manual), isFalse);
    });

    test('clampToOptions keeps a known value and falls back to the first option', () {
      expect(clampToOptions('GET', ['POST', 'GET']), 'GET');
      // A value persisted by another app version must not crash the dropdown.
      expect(clampToOptions('connect', ['POST', 'GET']), 'POST');
    });
  });

  group('formatHistoryTimestamp', () {
    test('renders in local time without sub-second noise', () {
      final utc = DateTime.utc(2026, 6, 1, 12, 0, 0, 123);
      // Persisted entries decode as UTC; the display must match what a fresh
      // local-time entry would show.
      expect(formatHistoryTimestamp(utc), utc.toLocal().toString().split('.').first);
      expect(formatHistoryTimestamp(utc), isNot(contains('.')));
    });
  });
}
