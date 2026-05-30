import 'dart:async';
import 'dart:io';

import 'package:dart_json_mapper/dart_json_mapper.dart' hide kIsWeb;
import 'package:dio/dio.dart';
import 'package:dio/adapter.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '/const.dart';
import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/toast.dart';
import '/src/preference/privacy_setting.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

@jsonSerializable
class SentryRateLimit {
  final bool available;
  final int rateLimitPerMonth;

  SentryRateLimit(this.available, this.rateLimitPerMonth);

  static Future<SentryRateLimit?> download() async {
    initializeJsonReflectable();
    const options = DeserializationOptions(caseStyle: CaseStyle.snake);
    try {
      return await createDiagnosticDio(operation: "download_sentry_rate_limit_config")
          .get(Const.sentryRateLimitConfigUrl)
          .then((response) => JsonMapper.deserialize<SentryRateLimit>(response.toString(), options));
    } catch (exception, stackTrace) {
      logger.e("Failed to download sentry rate limit config.", exception, stackTrace);
      return null;
    }
  }
}

int getSentryReportCount() {
  final box = StorageBox(StorageBoxKey.settings);
  final month = box.entry<DateTime>(SettingsEntryKey.sentryReportLastMonth.name);
  final count = box.entry<int>(SettingsEntryKey.sentryReportTotalCount.name);
  if (month.pull()?.isSameMonth(DateTime.now()) != true) {
    month.push(DateTime.now());
    count.push(0);
  }
  return count.pull() ?? 0;
}

void incrementSentryReportCount() {
  final box = StorageBox(StorageBoxKey.settings);
  final month = box.entry<DateTime>(SettingsEntryKey.sentryReportLastMonth.name);
  final count = box.entry<int>(SettingsEntryKey.sentryReportTotalCount.name);
  month.push(DateTime.now());
  count.push((count.pull() ?? 0) + 1);
}

class ScreenshotResult {
  final FilePath path;
  final String result;

  ScreenshotResult(this.path, this.result);

  bool get hasError => result.isNotEmpty;
}

final latestScreenshotProvider = StateProvider<ScreenshotResult?>((ref) {
  return null;
});

void takeScreenshot(RefBase ref) {
  ref.read(latestScreenshotProvider.notifier).update((_) => null);
  final path = ref.read(pathInfoProvider).tempDir.filePath("screenshot.png");
  path.deleteSync(emptyOk: true);
  ref.read(platformControllerProvider)!.takeScreenshot(path);
}

bool isSentryAvailable() {
  return HubAdapter().isEnabled;
}

FutureOr<void> captureException(exception, stackTrace) {
  if (isSentryAvailable()) {
    Sentry.captureException(exception, stackTrace: stackTrace);
  }
}

FutureOr<void> captureExceptionWithScope(
  exception,
  stackTrace, {
  Map<String, String>? tags,
  Map<String, dynamic>? contexts,
}) {
  if (isSentryAvailable()) {
    Sentry.captureException(
      exception,
      stackTrace: stackTrace,
      withScope: (Scope scope) async {
        for (final entry in tags?.entries ?? const <MapEntry<String, String>>[]) {
          await scope.setTag(entry.key, entry.value);
        }
        for (final entry in contexts?.entries ?? const <MapEntry<String, dynamic>>[]) {
          await scope.setContexts(entry.key, entry.value);
        }
      },
    );
  }
}

FutureOr<void> captureMessageWithScope(
  String message, {
  SentryLevel level = SentryLevel.info,
  Map<String, String>? tags,
  Map<String, dynamic>? contexts,
}) {
  if (isSentryAvailable()) {
    Sentry.captureMessage(
      message,
      level: level,
      withScope: (Scope scope) async {
        for (final entry in tags?.entries ?? const <MapEntry<String, String>>[]) {
          await scope.setTag(entry.key, entry.value);
        }
        for (final entry in contexts?.entries ?? const <MapEntry<String, dynamic>>[]) {
          await scope.setContexts(entry.key, entry.value);
        }
      },
    );
  }
}

FutureOr<void> captureError(String message) {
  if (isSentryAvailable()) {
    Sentry.captureMessage(message, level: SentryLevel.error);
  }
}

const _requestStartedAtKey = "diagnostic_request_started_at";

Map<String, dynamic> _proxyConfigSummary(Uri uri) {
  final proxyConfig = HttpClient.findProxyFromEnvironment(uri);
  final entries = proxyConfig
      .split(";")
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final proxyEntries = entries.where((e) => e.toUpperCase() != "DIRECT").toList();
  return {
    "environment_proxy_present": proxyEntries.isNotEmpty,
    "environment_proxy_entry_count": proxyEntries.length,
    "environment_proxy_direct": proxyEntries.isEmpty && entries.any((e) => e.toUpperCase() == "DIRECT"),
    "environment_proxy_schemes": proxyEntries
        .map((e) => e.split(RegExp(r"\s+")).first.toUpperCase())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(),
  };
}

Map<String, dynamic> _certificateContext(X509Certificate certificate, String host, int port) {
  return {
    "host": host,
    "port": port,
    "subject": certificate.subject,
    "issuer": certificate.issuer,
    "start_validity": certificate.startValidity.toIso8601String(),
    "end_validity": certificate.endValidity.toIso8601String(),
  };
}

// Actively reproduces a TLS handshake against the failing host so that we can
// capture the certificate chain and OS-level error details that Dio's
// badCertificateCallback never sees when BoringSSL fails during chain build
// (e.g. CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate).
Future<Map<String, dynamic>> probeTlsConnection(Uri uri) async {
  final host = uri.host;
  if (host.isEmpty || uri.scheme != "https") {
    return {"probe_outcome": "skipped", "probe_scheme": uri.scheme};
  }
  final port = uri.hasPort ? uri.port : 443;
  final stopwatch = Stopwatch()..start();
  X509Certificate? capturedCert;
  try {
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
      onBadCertificate: (cert) {
        capturedCert = cert;
        return false;
      },
    );
    final peerCert = socket.peerCertificate;
    socket.destroy();
    stopwatch.stop();
    return {
      "probe_outcome": "ok",
      "probe_elapsed_ms": stopwatch.elapsedMilliseconds,
      if (peerCert != null) "probe_certificate": _certificateContext(peerCert, host, port),
    };
  } catch (probeError) {
    stopwatch.stop();
    final result = <String, dynamic>{
      "probe_outcome": capturedCert != null ? "bad_certificate" : "error",
      "probe_elapsed_ms": stopwatch.elapsedMilliseconds,
      "probe_error_type": probeError.runtimeType.toString(),
      "probe_error_message": probeError.toString(),
    };
    if (probeError is HandshakeException) {
      final os = probeError.osError;
      if (os != null) {
        result["probe_os_error_code"] = os.errorCode;
        result["probe_os_error_message"] = os.message;
      }
    } else if (probeError is SocketException) {
      final os = probeError.osError;
      if (os != null) {
        result["probe_os_error_code"] = os.errorCode;
        result["probe_os_error_message"] = os.message;
      }
    }
    if (capturedCert != null) {
      result["probe_certificate"] = _certificateContext(capturedCert!, host, port);
    }
    return result;
  }
}

Dio createDiagnosticDio({String? operation}) {
  final dio = Dio();
  final adapter = dio.httpClientAdapter;
  if (!kIsWeb && adapter is DefaultHttpClientAdapter) {
    adapter.onHttpClientCreate = (client) {
      client.badCertificateCallback = (certificate, host, port) {
        final context = _certificateContext(certificate, host, port);
        logger.e("Bad certificate rejected. operation=$operation, context=$context");
        captureMessageWithScope(
          "Bad certificate rejected.",
          level: SentryLevel.error,
          tags: {
            if (operation != null) "network.operation": operation,
            "network.host": host,
            "network.bad_certificate": "true",
          },
          contexts: {
            "bad_certificate": context,
          },
        );
        return false;
      };
      return client;
    };
  }

  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      options.extra[_requestStartedAtKey] = DateTime.now().millisecondsSinceEpoch;
      logger.d(
        "Network request started. operation=$operation"
        ", method=${options.method}"
        ", url=${options.uri}"
        ", proxy=${_proxyConfigSummary(options.uri)}",
      );
      handler.next(options);
    },
    onResponse: (response, handler) {
      final startedAt = response.requestOptions.extra[_requestStartedAtKey] as int?;
      final elapsed = startedAt == null ? null : DateTime.now().millisecondsSinceEpoch - startedAt;
      logger.d(
        "Network request completed. operation=$operation"
        ", method=${response.requestOptions.method}"
        ", url=${response.requestOptions.uri}"
        ", status=${response.statusCode}"
        ", elapsed_ms=$elapsed",
      );
      handler.next(response);
    },
    onError: (error, handler) {
      final startedAt = error.requestOptions.extra[_requestStartedAtKey] as int?;
      final elapsed = startedAt == null ? null : DateTime.now().millisecondsSinceEpoch - startedAt;
      logger.e(
        "Network request error. operation=$operation"
        ", method=${error.requestOptions.method}"
        ", url=${error.requestOptions.uri}"
        ", type=${error.type}"
        ", status=${error.response?.statusCode}"
        ", elapsed_ms=$elapsed"
        ", proxy=${_proxyConfigSummary(error.requestOptions.uri)}",
        error,
        error.stackTrace,
      );
      handler.next(error);
    },
  ));

  return dio;
}

List<FilePath> getCharaDetailRecordFiles(DirectoryPath directory) {
  final candidates = [
    "skill.png",
    "skill.jpg",
    "skill.json",
    "factor.png",
    "factor.jpg",
    "factor.json",
    "campaign.png",
    "campaign.jpg",
    "campaign.json",
    "record.json",
    "prediction.json",
  ];
  return candidates.map((name) => directory.filePath(name)).where((path) => path.existsSync()).toList();
}

FutureOr<void> captureCharaDetailRecord(String message, DirectoryPath directory) {
  if (isSentryAvailable()) {
    Sentry.captureMessage(
      message,
      level: SentryLevel.info,
      hint: CustomHint(useUniqueFingerprint: true, titlePrefix: "Record"),
      withScope: (Scope scope) {
        getCharaDetailRecordFiles(directory).forEach((path) => scope.addFile(path));
      },
    ).then((_) {
      incrementSentryReportCount();
      Toaster.show(ToastData.success(description: "toast.report_record".tr()));
    });
  }
}

FutureOr<void> captureScreen(String message, FilePath path) {
  if (isSentryAvailable()) {
    Sentry.captureMessage(
      message,
      level: SentryLevel.info,
      hint: CustomHint(useUniqueFingerprint: true, titlePrefix: "Screen"),
      withScope: (Scope scope) {
        scope.addFile(path);
      },
    ).then((_) {
      path.deleteSync(emptyOk: true);
      incrementSentryReportCount();
      Toaster.show(ToastData.success(description: "toast.report_screen".tr()));
    });
  }
}

OnFeedbackCallback _sendToSentry({
  Hub? hub,
  String? name,
  String? email,
}) {
  final realHub = hub ?? HubAdapter();

  return (UserFeedback feedback) async {
    final id = await realHub.captureMessage(
      feedback.text,
      hint: CustomHint(useUniqueFingerprint: true, titlePrefix: "Feedback"),
      withScope: (scope) {
        scope.addAttachment(SentryAttachment.fromUint8List(
          feedback.screenshot,
          'screenshot.png',
          contentType: 'image/png',
        ));
      },
    );
    await realHub.captureUserFeedback(SentryUserFeedback(
      eventId: id,
      email: email,
      name: name,
      comments: '${feedback.text}\n${feedback.extra.toString()}',
    ));
  };
}

OnFeedbackCallback captureFeedback() {
  final send = _sendToSentry();
  return (UserFeedback feedback) async {
    await send(feedback);
    Toaster.show(ToastData.success(description: "toast.feedback".tr()));
  };
}

extension ScopeExtension on Scope {
  FutureOr<void> addFile(FilePath path) {
    try {
      if (path.existsSync()) {
        addAttachment(SentryAttachment.fromLoader(
          loader: () => path.readAsBytes(),
          filename: path.name,
          contentType: path.contentType,
        ));
      }
    } catch (exception, stackTrace) {
      logger.e("Failed to add file attachment. file=${path.path}", exception, stackTrace);
      captureException(exception, stackTrace);
    }
  }
}

class CustomHint {
  final bool useUniqueFingerprint;
  final String? titlePrefix;

  CustomHint({
    this.useUniqueFingerprint = false,
    this.titlePrefix,
  });

  static CustomHint from(dynamic src) {
    if (src == null) {
      return CustomHint();
    }
    if (src is CustomHint) {
      return src;
    }
    throw UnsupportedError(src.toString());
  }
}

Future<void> _runWithSentry(AppRunner runner) async {
  final appVersion = await loadLocalAppVersion();
  await SentryFlutter.init(
    (SentryFlutterOptions options) {
      if (kDebugMode) {
        options.dsn = "https://6ccc0a047e5c42c788f907599f0d4e97@o1367286.ingest.sentry.io/6668087";
      } else {
        options.dsn = "https://6f9ab436b1ad46e2b1be72d8f44f03e0@o1367286.ingest.sentry.io/6670477";
      }
      options.release = appVersion.toString() + (kDebugMode ? "-debug" : "");
      options.enablePrintBreadcrumbs = false;
      options.beforeSend = (SentryEvent event, {dynamic hint}) async {
        final customHint = CustomHint.from(hint);
        if (customHint.useUniqueFingerprint) {
          event = event.copyWith(fingerprint: [event.eventId.toString()]);
        }
        if (customHint.titlePrefix != null) {
          final formatted = "[${customHint.titlePrefix}] ${event.message?.formatted}";
          event = event.copyWith(message: event.message?.copyWith(formatted: formatted));
        }
        return event;
      };
    },
    appRunner: runner,
  );
}

Future<void> runWithSentry(AppRunner runner) async {
  if (allowPostUserData() == PostUserData.deny) {
    logger.i("Error logging is disabled.");
    runner();
  } else {
    logger.i("Error logging is enabled.");
    _runWithSentry(runner);
  }
}
