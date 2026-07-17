import 'dart:async';
import 'dart:io';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:uuid/uuid.dart';

import '/const.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/toast.dart';
import '/src/preference/privacy_setting.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

part 'sentry_util.mapper.dart';

@MappableClass(caseStyle: CaseStyle.snakeCase)
class SentryRateLimit with SentryRateLimitMappable {
  final bool available;
  final int rateLimitPerMonth;

  SentryRateLimit(this.available, this.rateLimitPerMonth);

  static Future<SentryRateLimit?> download() async {
    initializeMappers();
    try {
      return await createDiagnosticDio(
        operation: "download_sentry_rate_limit_config",
      ).get(Const.sentryRateLimitConfigUrl).then((response) => SentryRateLimitMapper.fromJson(response.toString()));
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

/// The ID gets its own box rather than sitting next to the consent flag in `settings`:
/// that box is the [SettingsEntryKey]-keyed preference store, whereas an opaque
/// generated ID with a lifetime of its own belongs beside [trainerIdProvider]'s
/// `trainer_id`, whose box this mirrors.
StorageEntry<String> _getTelemetryIdEntry() {
  return StorageBox(StorageBoxKey.telemetryId).entry<String>("telemetry_id");
}

/// Returns the anonymous telemetry ID, generating and persisting one on first call.
///
/// Registered as the Sentry user, this ends up as the `distinct_id` on sentry-native's
/// session — the identity behind Release Health's `count_unique(user)` and each issue's
/// user count.
///
/// Left alone, sentry-native fills that field with its own installation ID instead. That
/// ID is scoped to the DSN (a DSN change silently restarts the user count from zero) and
/// only arrived in 0.14.1, which a patch-level dependency bump switched on without a code
/// change here. Owning the ID keeps the metric from shifting under a `pub upgrade`.
/// [trainerIdProvider]'s ID is unsuitable for the opposite reason: it is game data written
/// into records, with its own lifetime and deletion rules.
///
/// It carries no personal data and is never logged: diagnostic logs ship inside bug
/// reports, and printing the ID there would tie a report to every other report from
/// the same installation.
String getTelemetryId() {
  final entry = _getTelemetryIdEntry();
  final stored = entry.pull();
  if (stored != null) {
    return stored;
  }
  final generated = const Uuid().v4();
  entry.push(generated);
  return generated;
}

/// Drops the stored telemetry ID. Idempotent, and safe to call when none exists.
///
/// Called on opt-out, so a later opt-in mints a fresh ID instead of resurrecting the old
/// one, which intentionally leaves the two stretches of use unlinkable.
///
/// Only the persisted ID is cleared. [runWithSentry]'s consent gate is evaluated once at
/// startup, so opting out mid-session stops neither the reporting already under way nor
/// the ID on the live scope; both last until restart. Unsetting the scope user would not
/// close that gap either, since sentry-native then falls back to its own installation ID.
void deleteTelemetryId() {
  _getTelemetryIdEntry().delete();
}

class ScreenshotResult {
  final FilePath path;
  final String result;

  ScreenshotResult(this.path, this.result);

  bool get hasError => result.isNotEmpty;
}

final latestScreenshotProvider = settableNotifierProvider<ScreenshotResult?>(null);

void takeScreenshot(RefBase ref) {
  ref.read(latestScreenshotProvider.notifier).set(null);
  final path = ref.read(pathInfoProvider).tempDir.filePath("screenshot.png");
  path.deleteSync(emptyOk: true);
  ref.read(platformControllerProvider)!.takeScreenshot(path);
}

bool isSentryAvailable() {
  return HubAdapter().isEnabled;
}

FutureOr<void> captureException(dynamic exception, dynamic stackTrace) {
  if (isSentryAvailable()) {
    Sentry.captureException(exception, stackTrace: stackTrace);
  }
}

FutureOr<void> captureExceptionWithScope(
  dynamic exception,
  dynamic stackTrace, {
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
  final entries = proxyConfig.split(";").map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
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

/// Creates a [Dio] with request/response/error diagnostics and certificate
/// logging tied to [operation].
///
/// When [redactUrl] is true, only `scheme://host` is logged instead of the full
/// URI. Use it for requests whose path/query carry secrets or user data — e.g.
/// addon webhooks, where the URL may hold a Discord/Slack token in the path and
/// record-derived values in the query — so they don't land in the diagnostic log.
Dio createDiagnosticDio({String? operation, bool redactUrl = false}) {
  String urlText(Uri uri) => redactUrl ? "${uri.scheme}://${uri.host}" : uri.toString();
  final dio = Dio();
  final adapter = dio.httpClientAdapter;
  if (!kIsWeb && adapter is IOHttpClientAdapter) {
    adapter.createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = (certificate, host, port) {
        final context = _certificateContext(certificate, host, port);
        logger.e("Bad certificate rejected. operation=$operation, context=$context");
        captureMessageWithScope(
          "Bad certificate rejected.",
          level: SentryLevel.error,
          tags: {"network.operation": ?operation, "network.host": host, "network.bad_certificate": "true"},
          contexts: {"bad_certificate": context},
        );
        return false;
      };
      return client;
    };
  }

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        options.extra[_requestStartedAtKey] = DateTime.now().millisecondsSinceEpoch;
        logger.d(
          "Network request started. operation=$operation"
          ", method=${options.method}"
          ", url=${urlText(options.uri)}"
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
          ", url=${urlText(response.requestOptions.uri)}"
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
          ", url=${urlText(error.requestOptions.uri)}"
          ", type=${error.type}"
          ", status=${error.response?.statusCode}"
          ", elapsed_ms=$elapsed"
          ", proxy=${_proxyConfigSummary(error.requestOptions.uri)}",
          error,
          error.stackTrace,
        );
        handler.next(error);
      },
    ),
  );

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
      hint: CustomHint(useUniqueFingerprint: true, titlePrefix: "Record").toHint(),
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
      hint: CustomHint(useUniqueFingerprint: true, titlePrefix: "Screen").toHint(),
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

OnFeedbackCallback _sendToSentry({Hub? hub, String? name, String? email}) {
  final realHub = hub ?? HubAdapter();

  return (UserFeedback feedback) async {
    final id = await realHub.captureMessage(
      feedback.text,
      hint: CustomHint(useUniqueFingerprint: true, titlePrefix: "Feedback").toHint(),
      withScope: (scope) {
        scope.addAttachment(
          SentryAttachment.fromUint8List(feedback.screenshot, 'screenshot.png', contentType: 'image/png'),
        );
      },
    );
    // sentry9 replaced Hub.captureUserFeedback/SentryUserFeedback with
    // captureFeedback/SentryFeedback. The feedback is linked to the message
    // event above via associatedEventId.
    await realHub.captureFeedback(
      SentryFeedback(
        message: '${feedback.text}\n${feedback.extra.toString()}',
        contactEmail: email,
        name: name,
        associatedEventId: id,
      ),
    );
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
        addAttachment(
          SentryAttachment.fromLoader(
            loader: () => path.readAsBytes(),
            filename: path.name,
            contentType: path.contentType,
          ),
        );
      }
    } catch (exception, stackTrace) {
      logger.e("Failed to add file attachment. file=${path.path}", exception, stackTrace);
      captureException(exception, stackTrace);
    }
  }
}

class CustomHint {
  static const _useUniqueFingerprintKey = "custom_hint_use_unique_fingerprint";
  static const _titlePrefixKey = "custom_hint_title_prefix";

  final bool useUniqueFingerprint;
  final String? titlePrefix;

  CustomHint({this.useUniqueFingerprint = false, this.titlePrefix});

  // sentry9 no longer accepts arbitrary hint objects; the `hint` parameter is a
  // typed [Hint] whose key/value storage is the only way to pass custom data
  // through to [SentryOptions.beforeSend]. We serialize our fields into it and
  // read them back in [_runWithSentry].
  Hint toHint() {
    final hint = Hint();
    hint.set(_useUniqueFingerprintKey, useUniqueFingerprint);
    if (titlePrefix != null) {
      hint.set(_titlePrefixKey, titlePrefix);
    }
    return hint;
  }

  static CustomHint from(Hint hint) {
    final titlePrefix = hint.get(_titlePrefixKey);
    return CustomHint(
      useUniqueFingerprint: hint.get(_useUniqueFingerprintKey) == true,
      titlePrefix: titlePrefix is String ? titlePrefix : null,
    );
  }
}

Future<void> _runWithSentry(AppRunner runner) async {
  // Guard so the app is started exactly once: SentryFlutter.init invokes
  // appRunner internally, but if any pre-init step (loadLocalAppVersion,
  // getApplicationSupportDirectory) or init itself throws, appRunner may never
  // be called. Falling back here guarantees runApp() always runs, otherwise a
  // startup failure leaves a blank white window with no error UI.
  var appStarted = false;
  void startAppOnce() {
    if (appStarted) {
      return;
    }
    appStarted = true;
    runner();
  }

  try {
    final appVersion = await loadLocalAppVersion();
    // The sentry-native (crashpad) database defaults to `.sentry-native` in the current
    // working directory. For a Program Files install without admin rights that directory
    // is not writable, so native crash capture would silently fail. Pin it to a
    // user-writable, persistent location under the app support directory (the same base
    // PathInfo uses), as recommended by the Sentry docs for production deployments.
    final supportDir = await getApplicationSupportDirectory();
    final nativeDatabasePath = p.join(supportDir.path, "sentry-native");
    // sentry-native does not create missing parent directories, so the crash DB
    // (and thus native crash capture) is silently dropped unless we create it.
    await Directory(nativeDatabasePath).create(recursive: true);
    await SentryFlutter.init((SentryFlutterOptions options) {
      options.nativeDatabasePath = nativeDatabasePath;
      // Debug builds never reach here (see runWithSentry), so only the release
      // project DSN remains.
      options.dsn = "https://6f9ab436b1ad46e2b1be72d8f44f03e0@o1367286.ingest.sentry.io/6670477";
      options.release = appVersion.toString();
      options.enablePrintBreadcrumbs = false;
      options.beforeSend = (SentryEvent event, Hint hint) async {
        final customHint = CustomHint.from(hint);
        if (customHint.useUniqueFingerprint) {
          // SentryEvent.copyWith is deprecated; assign fields directly.
          event.fingerprint = [event.eventId.toString()];
        }
        if (customHint.titlePrefix != null) {
          final message = event.message;
          if (message != null) {
            message.formatted = "[${customHint.titlePrefix}] ${message.formatted}";
          }
        }
        return event;
      };
    }, appRunner: startAppOnce);
    // Attach the anonymous telemetry ID so the session's distinct_id is one we own
    // rather than sentry-native's DSN-scoped installation ID. NativeScopeObserver
    // forwards this to sentry_set_user, which back-fills the session already started
    // by init (verified on a release build: the session envelope carries this ID).
    //
    // Placement matters, keep it here: inside runWithSentry's gates the ID is never
    // even generated when the user has opted out (or in debug), and inside this try a
    // failure still lands in the catch below, which starts the app anyway. Wrapping
    // appRunner instead would put failable work in front of the runApp guarantee.
    await Sentry.configureScope((scope) => scope.setUser(SentryUser(id: getTelemetryId())));
  } catch (exception, stackTrace) {
    // Never let a Sentry/startup-prep failure prevent the app from launching.
    logger.e("Failed to initialize Sentry; starting app without it.", exception, stackTrace);
    startAppOnce();
  }
}

Future<void> runWithSentry(AppRunner runner) async {
  // Never initialize Sentry in debug builds: developer-side errors must not be
  // reported. Skipping init leaves HubAdapter disabled, so every captureXxx
  // helper and the log breadcrumbs become no-ops.
  if (kDebugMode || allowPostUserData() == PostUserData.deny) {
    logger.i("Error logging is disabled.");
    runner();
  } else {
    logger.i("Error logging is enabled.");
    _runWithSentry(runner);
  }
}
