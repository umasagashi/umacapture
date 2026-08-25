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
// `withoutSecrets` only: `logger` keeps arriving through `utils.dart`'s re-export, which is what the
// rest of this file already uses. Named the same way `wasm_worker_client.dart` names it.
import '/src/core/app_logger.dart' show withoutSecrets, withoutUserPaths;
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

/// Removes a transient bug-report image, logging instead of throwing.
///
/// The file is a full frame of the user's screen, so no abandon path may leave
/// it behind: on desktop the startup temp sweep is a backstop, but on web that
/// sweep cannot run before the tab is reloaded, and OPFS is a quota the user
/// never sees.
///
/// **The rule, which is what callers have to satisfy: such a file has exactly
/// one owner at any moment, ownership passes at the instant it is handed to a
/// send, and whoever holds it calls this on every outcome including the ones
/// that send nothing.** Stated as a rule and not as a roster of the dialogs and
/// senders that hold one: this comment used to name them, and it went out of
/// date the first time a third producer was added without anyone thinking to
/// come back and extend the list.
Future<void> deleteTransientScreenshot(FilePath path) async {
  try {
    await path.delete(emptyOk: true);
  } catch (error, stackTrace) {
    // Deleting scratch is never worth failing a report over, and the callers are
    // all fire-and-forget, so an unhandled rejection here would escape the zone.
    logger.w("Failed to delete the transient screenshot.", error, stackTrace);
  }
}

/// Requests a bug-report screenshot and returns the path it will be written to.
///
/// The path is chosen here, synchronously, before the capture is even started, so
/// the caller can take ownership of the file up front instead of having to wait
/// for [latestScreenshotProvider] to tell it what it asked for. That also makes
/// the path the request's identity: it is unique per call and both platforms echo
/// it back in `onScreenshotTaken`, so a caller can tell its own shot from a
/// concurrent attempt's without any extra bookkeeping.
///
/// The capture itself is asynchronous and fire-and-forget: when this returns, the
/// file usually does not exist yet.
FilePath takeScreenshot(RefBase ref) {
  ref.read(latestScreenshotProvider.notifier).set(null);
  // A per-call unique name avoids the pre-write `deleteSync` (which evaluates `existsSync`
  // and throws UnsupportedError on web's fs backend, killing the whole report flow before
  // the web `takeScreenshot` runs). It also sidesteps stale previews: RecordImage's web LRU
  // and the desktop ImageCache are both keyed by path, so a fresh name is always a fresh
  // image. The file is transient because its owner deletes it -- see
  // [deleteTransientScreenshot]; the startup temp sweep only reclaims what an abnormal
  // termination left behind.
  final path = ref.read(pathInfoProvider).tempDir.filePath("screenshot_${DateTime.now().microsecondsSinceEpoch}.png");
  ref.read(platformControllerProvider)!.takeScreenshot(path);
  return path;
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
  // The web build has no HttpClient/environment proxy notion, and
  // findProxyFromEnvironment throws there. This helper feeds diagnostic logs
  // that also run on web (createDiagnosticDio powers the dashboard news load),
  // so report "not applicable" instead of touching the io API.
  if (kIsWeb) {
    return {"environment_proxy_present": false, "environment_proxy_not_applicable": true};
  }
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

/// What a certificate says about a failing handshake, **minus the certificate's names**.
///
/// Same rule as [_proxyConfigSummary] directly above, which deliberately reports the proxy's shape
/// (how many, which schemes) and never its host: the shape of the user's network is a diagnostic,
/// its identity is not. A subject/issuer DN is exactly that identity — the case this context is
/// built for is a TLS-intercepting middlebox, whose internal CA carries the user's employer or
/// school in its `CN`/`O` and names the security product doing the interception. The user enabled
/// error reporting; they were never asked about that and have no way to notice it leaving.
/// [scrubUserPathsFromEvent] cannot catch it either — it states that it removes filesystem paths
/// and nothing else.
///
/// [selfIssuedKey] is derived from both names and reproduces neither, which is what the diagnosis
/// actually turns on: together with the OS error already in the probe result, a chain that failed
/// to build while the leaf is *not* self-issued is the signature of re-issuance by a private CA,
/// and the validity window separates that from a plainly expired certificate.
Map<String, dynamic> _certificateContext(X509Certificate certificate, String host, int port) {
  return {
    "host": host,
    "port": port,
    selfIssuedKey: certificate.subject == certificate.issuer,
    "start_validity": certificate.startValidity.toIso8601String(),
    "end_validity": certificate.endValidity.toIso8601String(),
  };
}

/// The one key of [_certificateContext] that is computed from the certificate's names.
///
/// Named rather than spelled twice so the test that asserts no name survives can state which key it
/// expects to be a boolean, instead of re-typing a literal that could drift away from the producer.
@visibleForTesting
const selfIssuedKey = "self_issued";

/// Runs [_certificateContext] for a test. The context itself stays private: nothing outside this
/// file builds one, and the point of the check is what the file publishes, not a second entry point.
@visibleForTesting
Map<String, dynamic> debugCertificateContext(X509Certificate certificate, String host, int port) =>
    _certificateContext(certificate, host, port);

// Actively reproduces a TLS handshake against the failing host so that we can
// capture the certificate chain and OS-level error details that Dio's
// badCertificateCallback never sees when BoringSSL fails during chain build
// (e.g. CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate).
Future<Map<String, dynamic>> probeTlsConnection(Uri uri) async {
  // SecureSocket is a dart:io API that throws on web; the browser performs its
  // own TLS handshake and never surfaces the certificate chain, so there is
  // nothing to probe. Skip rather than crash the diagnostic path.
  if (kIsWeb) {
    return {"probe_outcome": "skipped", "probe_reason": "web"};
  }
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
  // The type test alone decides this: web's BrowserHttpClientAdapter is not an
  // IOHttpClientAdapter, so the branch is already unreachable there. A platform
  // term next to it would be a second mechanism for one decision.
  if (adapter is IOHttpClientAdapter) {
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

/// Returns the record's attachment files that actually exist on disk.
///
/// Async because the web (OPFS) fs backend throws on synchronous existence
/// checks; `exists()` is the web-safe path and behaves identically on desktop.
Future<List<FilePath>> getCharaDetailRecordFiles(DirectoryPath directory) async {
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
  final paths = candidates.map((name) => directory.filePath(name)).toList();
  final existence = await Future.wait(paths.map((path) => path.exists()));
  return [
    for (var i = 0; i < paths.length; i++)
      if (existence[i]) paths[i],
  ];
}

/// Why a user-initiated report never became a Sentry event.
///
/// Two states rather than a catalogue of causes, because the split is the one the **user** can act
/// on: one of them can be retried and the other cannot, and nothing else about the failure is
/// theirs to do anything with. A list of causes would also be exactly the kind of table that goes
/// stale the first time the SDK grows a new way to drop an event — every such way already arrives
/// here as [notDelivered] with no code to remember.
///
/// The switch in [_reportFailureToastLeaf] is exhaustive, so a third state cannot be added without
/// a message being written for it.
enum ReportFailure {
  /// No enabled hub, so nothing was even attempted: the privacy opt-out, a debug build, or a
  /// `SentryFlutter.init` that failed at startup and let the app run without it (see
  /// [runWithSentry]). Retrying changes nothing, which is why this is not folded into the other.
  reportingDisabled,

  /// A hub accepted the report and it still did not become an event: the SDK dropped it
  /// (`beforeSend`, sampling, an event processor), the handoff to the platform SDK threw, the
  /// scope could not be assembled, or — where the Dart HTTP transport is in play — the request
  /// failed or was refused. Retrying later may work.
  notDelivered,
}

/// Translation namespaces carrying one failure sentence per [ReportFailure] value.
///
/// Two of them rather than one because the app's own vocabulary distinguishes the subjects: the
/// three evidence reports say 報告 and their success toasts do too, while the feedback sheet says
/// フィードバック everywhere — drawer tooltip, submit button, success toast. A failure notice that
/// changed nouns halfway through the conversation reads as being about something else.
///
/// A namespace and **not** a per-feature key table: which of the two sentences is shown stays the
/// exhaustive switch in [_reportFailureToastLeaf], so a third [ReportFailure] state still cannot be
/// added without a message being written for it — in both vocabularies at once, because the leaf is
/// what the switch produces.
const _reportFailureToastPrefix = "toast.report_failure";
const _feedbackFailureToastPrefix = "toast.feedback_failure";

String _reportFailureToastLeaf(ReportFailure failure) => switch (failure) {
  ReportFailure.reportingDisabled => "disabled",
  ReportFailure.notDelivered => "not_delivered",
};

/// Tells the user their report did not go, in the same voice the success toast uses.
///
/// A toast and not a dialog deliberately: the send starts as the report dialog closes, so there is
/// no surface left to put the answer on, and the successful outcome has always been a toast. Two
/// shapes for one answer is how they drift.
///
/// The key is assembled from [toastPrefix] and the leaf, so a namespace that is missing a leaf
/// degrades to `.tr()` echoing the key instead of failing loudly. That is the cost of the two
/// vocabularies, and it is paid for by a case that resolves every prefix against every
/// [ReportFailure] value and asserts none of them echoes.
void _notifyReportFailure(String toastPrefix, ReportFailure failure) {
  Toaster.show(ToastData.error(description: "$toastPrefix.${_reportFailureToastLeaf(failure)}".tr()));
}

/// Performs one user-initiated send and **tells the user what happened on every outcome**.
///
/// Every report surface in the app answers through here — the three evidence reports
/// ([captureScreen], [captureCharaDetailRecord], [captureImportError]) and the feedback sheet
/// ([captureFeedback]) — so "the user pressed Send and was told nothing" cannot come back through
/// one of them forgetting a branch: there is no failure branch for a caller to write, only a [send]
/// to perform and a [successToast] to name.
///
/// **What counts as sent is the [SentryId], not the future completing.** [Hub.captureMessage] and
/// [Hub.captureFeedback] both catch everything their client throws and answer `SentryId.empty()`
/// instead (sentry 9.23.0, `hub.dart:206-293`), and both transports answer the same for an event
/// the SDK dropped or could not hand over. So a `.then` that assumes success runs for failures too
/// — which is what the success toasts used to do — and an `onError` beside it is very nearly dead
/// code.
///
/// **What "sent" can and cannot mean.** On desktop and web alike the transport is a handoff to the
/// platform SDK (`FileSystemTransport` / `JavascriptTransport`, sentry_flutter 9.23.0), and both
/// answer with the envelope's own id the moment they have accepted the bytes. A non-empty id
/// therefore means the report left this code, not that it reached sentry.io; a browser request
/// dropped by a content blocker is still invisible here (see the UNMEASURED note in
/// [runWithSentry]). This notice under-reports failure and never over-reports it.
///
/// [send] answers with the id that stands for the whole report. A surface that files more than one
/// event decides there what a partial outcome means and answers `SentryId.empty()` when the report
/// as a whole did not land — see [_sendFeedbackPair]. Keeping that decision in the surface and the
/// *announcement* here is deliberate: "which events make up this report" is per-surface, "was the
/// user told" must not be.
///
/// [release] is the hand-back for a report that owns a transient file. It runs on every outcome,
/// before the user is told, so the file's owner does not depend on which way the send went.
///
/// [spendsQuota] has no default. The monthly counter is the *evidence report* budget, and whether a
/// new surface belongs inside it is a decision about the user's allowance, not something to inherit
/// from whichever value happened to be written here first.
///
/// [hub] is a test seam: a suite must never file real issues, and leaving that to "the hub happens
/// to be disabled under `flutter test`" makes the suite's safety a property of the environment.
Future<void> _deliverUserReport({
  required String titlePrefix,
  required Future<SentryId> Function(Hub hub) send,
  required String successToast,
  required String failureToastPrefix,
  required bool spendsQuota,
  Future<void> Function()? release,
  Hub? hub,
}) async {
  final target = hub ?? HubAdapter();
  if (!target.isEnabled) {
    // No hub to attach anything to, so nothing will ever read a released file again.
    await release?.call();
    logger.w("Reporting is disabled; the $titlePrefix report was not sent.");
    _notifyReportFailure(failureToastPrefix, ReportFailure.reportingDisabled);
    return;
  }
  SentryId eventId;
  try {
    eventId = await send(target);
  } catch (error, stackTrace) {
    // Reachable even though the hub swallows its client's errors: it awaits the withScope callback
    // *outside* that try (sentry 9.23.0, `hub.dart:220-226` and `hub.dart:268-276`), so a scope
    // builder that throws — listing a record directory, for instance — rejects the future.
    logger.e("Failed to send the $titlePrefix report.", error, stackTrace);
    await release?.call();
    _notifyReportFailure(failureToastPrefix, ReportFailure.notDelivered);
    return;
  }
  // Async release for the reason [deleteTransientScreenshot] states: deleteSync evaluates
  // existsSync, which throws UnsupportedError on web's fs backend.
  await release?.call();
  if (eventId == const SentryId.empty()) {
    logger.e("The $titlePrefix report produced no event id, so it was not sent.");
    _notifyReportFailure(failureToastPrefix, ReportFailure.notDelivered);
    return;
  }
  if (spendsQuota) {
    // Only a report that became an event spends quota. A dropped one costs the developer nothing to
    // receive, and charging for it would retire the user's monthly allowance for reports nobody got.
    incrementSentryReportCount();
  }
  Toaster.show(ToastData.success(description: successToast.tr()));
}

/// The single-event shape the three evidence reports share: one `captureMessage` whose scope
/// carries the attachments, spending one of the month's allowance when it lands.
Future<void> _sendUserReport({
  required String message,
  required String titlePrefix,
  required ScopeCallback buildScope,
  required String successToast,
  Future<void> Function()? release,
  Hub? hub,
}) {
  return _deliverUserReport(
    titlePrefix: titlePrefix,
    successToast: successToast,
    failureToastPrefix: _reportFailureToastPrefix,
    spendsQuota: true,
    release: release,
    hub: hub,
    send: (target) => target.captureMessage(
      message,
      level: SentryLevel.info,
      hint: CustomHint(useUniqueFingerprint: true, titlePrefix: titlePrefix).toHint(),
      withScope: buildScope,
    ),
  );
}

FutureOr<void> captureCharaDetailRecord(String message, DirectoryPath directory, {@visibleForTesting Hub? hub}) {
  return _sendUserReport(
    message: message,
    titlePrefix: "Record",
    hub: hub,
    successToast: "toast.report_record",
    buildScope: (Scope scope) async {
      final files = await getCharaDetailRecordFiles(directory);
      for (final path in files) {
        await scope.addFile(path);
      }
    },
  );
}

/// Sends the bug-report screenshot at [path] and takes ownership of the file.
///
/// The report dialog stops tracking the screenshot the moment it hands it over,
/// so this is the last owner: it deletes the file on every outcome, including
/// the ones that send nothing (Sentry disabled) or fail to send. Which outcome it
/// was, and what the user is told about it, are [_sendUserReport]'s to decide.
FutureOr<void> captureScreen(String message, FilePath path, {@visibleForTesting Hub? hub}) {
  return _sendUserReport(
    message: message,
    titlePrefix: "Screen",
    hub: hub,
    successToast: "toast.report_screen",
    buildScope: (Scope scope) async {
      await scope.addFile(path);
    },
    release: () => deleteTransientScreenshot(path),
  );
}

/// Sends a video-import error report — one PNG frame the user chose out of a clip, their note as
/// the message, and [contexts] / [tags] describing the clip, the frame and (when it could be tied
/// to one) the import — and **takes ownership of [png]**.
///
/// The same shape as [captureScreen], deliberately, down to the ownership rule: the dialog stops
/// tracking the frame the moment it hands it over, so this is the last owner and deletes the file on
/// every outcome, including the ones that send nothing (Sentry disabled) or fail to send. What is
/// added is the scope: a screen report is a picture of the moment it was taken and needs nothing
/// beside it, while an import report is about a *file* and a *time in that file*, neither of which
/// is visible in the pixels.
///
/// The counter and its monthly window are the shared ones ([getSentryReportCount] /
/// [incrementSentryReportCount]): a second budget would let one report type exhaust nothing while
/// the other is refused, for one user sending one kind of evidence about one app.
FutureOr<void> captureImportError(
  String message,
  FilePath png, {
  required Map<String, dynamic> contexts,
  required Map<String, String> tags,
  @visibleForTesting Hub? hub,
}) {
  return _sendUserReport(
    message: message,
    titlePrefix: "Import",
    hub: hub,
    successToast: "toast.report_import",
    buildScope: (Scope scope) async {
      for (final entry in tags.entries) {
        await scope.setTag(entry.key, entry.value);
      }
      for (final entry in contexts.entries) {
        await scope.setContexts(entry.key, entry.value);
      }
      await scope.addFile(png);
    },
    release: () => deleteTransientScreenshot(png),
  );
}

/// Files the two events one piece of feedback is made of, and answers with the id that stands for
/// the pair.
///
/// **The two are halves of one report, not two tries at the same thing**, which is why the answer
/// is `SentryId.empty()` unless *both* landed. Read out of sentry 9.23.0 rather than assumed:
///
/// * the first call is an ordinary message event, and the screenshot is attached to *its* scope, so
///   an empty id there means the picture is gone;
/// * the second is `SentryEvent(type: 'feedback', contexts: Contexts(feedback: …))`
///   (`sentry_client.dart:491-511`) — a separate event carrying the note plus `extra`, the contact
///   details, and the back-link, and it is the only one that reaches Sentry's User Feedback view.
///
/// Neither half is what the user was shown when they pressed 送信, so calling a half a success
/// would be the same lie the unconditional toast used to tell, only smaller. The direction of the
/// remaining error is the safe one: a partial outcome is announced as a failure although the
/// developer did receive something. The price is a duplicate event if the user retries — every
/// report carries `useUniqueFingerprint`, so the retry opens its own issue rather than merging —
/// and a duplicate is strictly better than a report the user believes was filed and was not.
///
/// **No short circuit between the two calls.** The second is issued even when the first produced no
/// id, because *what gets sent* is not this change's business: dropping it would take the note away
/// from the developer as well. Only the verdict is new.
Future<SentryId> _sendFeedbackPair(Hub target, UserFeedback feedback, {String? name, String? email}) async {
  // `UserFeedback.extra` is only populated by a custom BetterFeedback.feedbackBuilder;
  // the default builder leaves it null, so interpolating it unconditionally appended a
  // literal "null" line to every report. Append it only when it actually carries data.
  final extra = feedback.extra;
  final message = extra == null || extra.isEmpty ? feedback.text : '${feedback.text}\n$extra';
  final eventId = await target.captureMessage(
    feedback.text,
    hint: CustomHint(useUniqueFingerprint: true, titlePrefix: "Feedback").toHint(),
    withScope: (scope) {
      scope.addAttachment(
        SentryAttachment.fromUint8List(feedback.screenshot, 'screenshot.png', contentType: 'image/png'),
      );
    },
  );
  const empty = SentryId.empty();
  // sentry9 replaced Hub.captureUserFeedback/SentryUserFeedback with
  // captureFeedback/SentryFeedback. The feedback is linked to the message
  // event above via associatedEventId.
  //
  // Null rather than the id when the first half was dropped: `SentryFeedback.toJson` emits
  // `associated_event_id` whenever the field is non-null (`protocol/sentry_feedback.dart:47-58`), so
  // passing the all-zeros id would file a User Feedback entry whose "view event" link points at an
  // event that does not exist. Developer-facing only — the user is told the same thing either way —
  // but a dead link is worse than an absent one, because it costs a click to find out.
  final feedbackId = await target.captureFeedback(
    SentryFeedback(
      message: message,
      contactEmail: email,
      name: name,
      associatedEventId: eventId == empty ? null : eventId,
    ),
  );
  if (eventId == empty || feedbackId == empty) {
    logger.w(
      "One half of the feedback did not become an event."
      " message_event=${eventId != empty}, feedback_event=${feedbackId != empty}",
    );
    return empty;
  }
  // The message event's id: it is the issue a developer opens, and the one the feedback event
  // points back at.
  return eventId;
}

/// The feedback sheet's submit handler, answering on every outcome like the three report dialogs do.
///
/// Outside the monthly quota deliberately, and that is unchanged: the counter
/// ([getSentryReportCount]) is the evidence-report allowance, spent by reports that carry the
/// user's screen or their records, and this entry point is instead gated by `isFeedbackAvailable`
/// (`lib/src/preference/privacy_setting.dart:50`). Folding feedback into the counter would silently
/// shrink the allowance the three report dialogs show the user.
///
/// That same gate is why [ReportFailure.reportingDisabled] is not reachable from here in the app —
/// the drawer and the title-bar menu do not render the button when Sentry is off. The branch is
/// still taken by the shared sender rather than special-cased away: a gate on the widget and a
/// verdict on the send are two mechanisms, and the day one of them moves is not the day to discover
/// the other was leaning on it.
OnFeedbackCallback captureFeedback({@visibleForTesting Hub? hub, String? name, String? email}) {
  return (UserFeedback feedback) => _deliverUserReport(
    titlePrefix: "Feedback",
    successToast: "toast.feedback",
    failureToastPrefix: _feedbackFailureToastPrefix,
    spendsQuota: false,
    hub: hub,
    send: (target) => _sendFeedbackPair(target, feedback, name: name, email: email),
  );
}

/// A failure to attach a file to a report, carrying text that has already been redacted.
///
/// The original exception is deliberately **not** what gets reported. On desktop it is a
/// [FileSystemException], whose `toString` quotes the absolute path it failed on — and every file
/// this app attaches lives inside the user's own profile, either under the temp directory
/// (`C:\Users\<person>\AppData\Local\Temp\…`) or under the record store. Reporting it names the user,
/// on the one code path that runs *because* a report is being sent.
///
/// The cost, stated: Sentry groups by exception type, so these stop being grouped as
/// `FileSystemException` and become one issue of their own. That is the intended shape — "an
/// attachment could not be read" is one problem, and the reason survives in the message.
class AttachmentException implements Exception {
  final String message;

  AttachmentException(this.message);

  @override
  String toString() => "AttachmentException: $message";
}

extension ScopeExtension on Scope {
  Future<void> addFile(FilePath path) async {
    try {
      if (await path.exists()) {
        addAttachment(
          SentryAttachment.fromLoader(
            loader: () => path.readAsBytes(),
            filename: path.name,
            contentType: path.contentType,
          ),
        );
      }
    } catch (exception, stackTrace) {
      // NOTHING HERE MAY NAME THE USER, by three separate routes that all end at Sentry: this line is
      // a breadcrumb (`app_logger.dart` turns every level above trace into one), the `error` argument
      // of that breadcrumb is serialised into its data, and [captureException] is an event outright.
      // The attachment's own *leaf* is safe — this app chose it (`screenshot_<micros>.png`,
      // `video_frame_<micros>.png`, `record.json`) — but the directory in front of it is the user's
      // profile, so the leaf is logged and the absolute path is not.
      //
      // The exception's text goes through `withoutSecrets` rather than being trusted: `path.path` is
      // the string a `FileSystemException` quotes, and the structural pass takes out any other
      // absolute directory the platform may have put in there.
      final detail = withoutSecrets("$exception", [path.path]);
      // The exception object itself is dropped from the breadcrumb (its `toString` is the leak) and
      // replaced by the redacted sentence, which says the same thing.
      logger.e("Failed to add file attachment. file=${path.name}, detail=$detail", null, stackTrace);
      captureException(AttachmentException(detail), stackTrace);
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

/// The single release-project DSN, shared by the desktop and web init paths. It is
/// a public client value (safe to embed) and points at the same Sentry project;
/// desktop and web events are told apart by the `environment` tag.
const _sentryDsn = "https://6f9ab436b1ad46e2b1be72d8f44f03e0@o1367286.ingest.sentry.io/6670477";

/// Shared `beforeSend` for both platforms: applies the [CustomHint] fingerprint
/// and title-prefix carried through the event hint, and takes the user's Windows
/// account name out of every path the event carries.
///
/// **A failure anywhere in here drops the event.** The whole body is guarded, and the guard
/// returns null rather than the event, because the SDK's own guard does the opposite: when the
/// callback throws, `_runBeforeSend` logs and keeps the event it pre-seeded
/// (`sentry-9.23.0/lib/src/sentry_client.dart:532-578`), so an unguarded throw here would send the
/// event **as assembled** — unredacted. Between losing one report and publishing the account name
/// of a user who will never know, the report is the cheaper loss: it can be reproduced, and a send
/// cannot be taken back.
///
/// The residual risk that ruling creates, named rather than implied: a redaction that fails for
/// *every* event silently costs every report. What detects it is the console line below (the
/// developer running the app sees the failure the event no longer carries) and the negative control
/// in `test/sentry_scrub_event_test.dart`, which fails the moment an ordinary event stops coming
/// back from here.
///
/// Public only so that ruling can be tested; nothing outside this library calls it.
@visibleForTesting
Future<SentryEvent?> sentryBeforeSend(SentryEvent event, Hint hint) async {
  try {
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
    return scrubUserPathsFromEvent(event);
  } catch (exception, stackTrace) {
    // Not `captureException`: reporting a failure of the redaction *through* the thing being
    // redacted would recurse. The console line is the only report of this, and it is enough --
    // it reaches the one machine where the failing input exists.
    logger.e('Redacting the event failed; it is dropped rather than sent unredacted.', exception, stackTrace);
    return null;
  }
}

/// [value] with [withoutUserPaths] applied to every string it carries, at any depth, and with the
/// **same instance returned when nothing changed**.
///
/// A sweep rather than a list of the context keys that are known to carry a path today. The defect
/// being repaired is a path reaching Sentry unredacted, and a per-key table is the shape that lets
/// the next key leak: `network_failure.inner_error` is the one that does it today, `tls_probe`'s
/// message fields and `bad_certificate` are the same shape, and the three
/// `wasm_worker_client.dart` scopes publish contexts nobody here has read.
///
/// **The identity rule is load bearing, not an optimisation.** [Contexts] is a map whose default
/// keys hold *typed* SDK objects — `device`, `os`, `runtime` (a `List<SentryRuntime>`) — and its
/// `toJson` reads them back through typed getters. Writing a plain list or map over one of those
/// keys would make the event fail to serialise. Returning the original instance whenever no string
/// underneath it changed means those keys are never written at all, without this having to know
/// their names.
dynamic _withoutUserPathsInValue(dynamic value) {
  if (value is String) {
    return withoutUserPaths(value);
  }
  if (value is Map) {
    Map<dynamic, dynamic>? scrubbed;
    for (final entry in value.entries) {
      final item = _withoutUserPathsInValue(entry.value);
      if (identical(item, entry.value)) continue;
      // Keys are the vocabulary this app chose (`inner_error`, `probe_outcome`), never user text,
      // so they are left as they are: rewriting one would rename a field a reader searches by.
      (scrubbed ??= Map<dynamic, dynamic>.of(value))[entry.key] = item;
    }
    return scrubbed ?? value;
  }
  if (value is List) {
    List<dynamic>? scrubbed;
    for (var index = 0; index < value.length; index++) {
      final item = _withoutUserPathsInValue(value[index]);
      if (identical(item, value[index])) continue;
      (scrubbed ??= List<dynamic>.of(value))[index] = item;
    }
    return scrubbed ?? value;
  }
  return value;
}

/// Puts every frame of [trace] through [withoutUserPaths].
///
/// A release build's frames name `package:` / `dart:` URIs and match nothing; a source-relative
/// build, a plugin's own frame, or a future symbolication step can name a real file. Shared by
/// [SentryException] and [SentryThread], which carry the same [SentryStackTrace].
void _scrubStackTrace(SentryStackTrace? trace) {
  for (final frame in trace?.frames ?? const <SentryStackFrame>[]) {
    final absPath = frame.absPath;
    if (absPath != null) {
      frame.absPath = withoutUserPaths(absPath);
    }
    final fileName = frame.fileName;
    if (fileName != null) {
      frame.fileName = withoutUserPaths(fileName);
    }
  }
}

/// Writes [_withoutUserPathsInValue] back over every entry of [map], in place.
void _scrubMapInPlace(Map<String, dynamic> map) {
  for (final key in map.keys.toList()) {
    final value = map[key];
    final scrubbed = _withoutUserPathsInValue(value);
    if (!identical(scrubbed, value)) {
      map[key] = scrubbed;
    }
  }
}

/// Replaces the user's own directories in everything [event] carries as text, and returns it.
///
/// **The event counterpart of `AppLogger._addBreadcrumb`.** A breadcrumb is scrubbed where it is
/// assembled; an event's text is not assembled by this app at all — the SDK builds
/// `exceptions[].value` from `exception.toString()` — so the only place both `Sentry.captureException`
/// and every uncaught error pass through is here. That is what covers the call sites that hand a raw
/// filesystem exception straight to [captureException] (record load and quarantine, spec grid build,
/// the memo title write, and both module-zip installers) **without editing one of them**, and covers
/// the ones written after this. A `FileSystemException`'s `toString` quotes the path it failed on,
/// so those events named `C:\Users\<account>\` before this existed.
///
/// The **type** is left alone, deliberately: rewriting the value keeps Sentry's grouping on
/// `FileSystemException` rather than collapsing these into one synthetic class, which is the cost the
/// alternative — wrapping the throwable at [captureException] — would have charged. `event.throwable`
/// is likewise untouched; it is not serialised (the SDK's exception factory has already read it into
/// [SentryEvent.exceptions] by the time `beforeSend` runs, `sentry_client.dart:145,174`).
///
/// Breadcrumbs **are** walked here, although every breadcrumb this app produces was already scrubbed
/// at `AppLogger._addBreadcrumb` and the SDK's own (navigation, HTTP) carry route names and URLs.
/// [withoutUserPaths] is idempotent, so the second pass over an app breadcrumb costs a comparison
/// and buys the rule below its "every field" — which is the whole difference between a redaction
/// that holds and one that holds for the fields somebody thought of.
///
/// `debugMeta` **is** walked, and only its path-shaped fields are: `code_file`, `debug_file` and
/// `name` lose their directory and keep their leaf, while `debug_id`, `code_id`, `uuid`, `type`,
/// `arch` and the addresses are left byte-for-byte alone. This is not hypothetical — the loaded-image
/// list sentry-native attaches to a Windows minidump event enumerates *every* module mapped into the
/// process, including third-party DLLs that live under `C:\Users\<account>\AppData\…`, and two
/// production 0.2.1 events did carry one. Symbolication matches on `debug_id` plus the *file name*,
/// both of which survive: this cuts the directory only.
///
/// **What is deliberately not walked, and why**, since the rest is swept rather than listed:
/// `throwable` is not serialised (the SDK's exception factory has already read it into
/// [SentryEvent.exceptions] by the time this runs, `sentry_client.dart:145,174`); and
/// `SentryRequest.data` has no setter in the SDK, so it cannot be rewritten in place — nothing in
/// this app builds a `request` at all. Everything else that could hold a path is walked, including
/// the parts nothing populates today (`threads`, `user.data`, `unknown`): "the SDK does not fill
/// this" is a statement about a version, and a version is not a guarantee.
///
/// That list is **not** the whole exclusion set. `test/sentry_scrub_event_test.dart` enumerates
/// `SentryEvent`'s fields out of the SDK's own source and requires each to be swept here or named on
/// a list **it** owns, which is larger than the four above; the reason for each of the others is
/// stated there, next to the name. Do not read this paragraph as the inventory of what goes
/// unscrubbed.
///
/// **Throws rather than degrading.** This is the opposite of the earlier ruling, and deliberately:
/// swallowing the failure here sent the event as assembled, i.e. unredacted, which is the one
/// outcome that cannot be undone. [sentryBeforeSend] owns the send-or-drop decision and drops.
@visibleForTesting
SentryEvent scrubUserPathsFromEvent(SentryEvent event) {
  final message = event.message;
  if (message != null) {
    message.formatted = withoutUserPaths(message.formatted);
    final template = message.template;
    if (template != null) {
      message.template = withoutUserPaths(template);
    }
    // Coerced to strings by Sentry anyway, so the scrub reads them the same way.
    message.params = message.params?.map((e) => e is String ? withoutUserPaths(e) : e).toList();
  }
  for (final exception in event.exceptions ?? const <SentryException>[]) {
    final value = exception.value;
    if (value != null) {
      exception.value = withoutUserPaths(value);
    }
    _scrubStackTrace(exception.stackTrace);
  }
  // Never populated by the Dart SDK *today*. Walked anyway, because a thread carries the same
  // `SentryStackTrace` an exception does: the day the SDK starts filling it — or a native event is
  // round-tripped through `fromJson` — the frames arrive by a route no comment can hold shut.
  for (final thread in event.threads ?? const <SentryThread>[]) {
    _scrubStackTrace(thread.stacktrace);
    final threadName = thread.name;
    if (threadName != null) {
      thread.name = withoutUserPaths(threadName);
    }
  }
  for (final breadcrumb in event.breadcrumbs ?? const <Breadcrumb>[]) {
    final crumbMessage = breadcrumb.message;
    if (crumbMessage != null) {
      breadcrumb.message = withoutUserPaths(crumbMessage);
    }
    final data = breadcrumb.data;
    if (data != null) {
      _scrubMapInPlace(data);
    }
  }
  _scrubMapInPlace(event.contexts);
  // ignore: deprecated_member_use
  final extra = event.extra;
  if (extra != null) {
    _scrubMapInPlace(extra);
  }
  final tags = event.tags;
  if (tags != null) {
    // Values only: a tag's key is a filter name this app chose, and renaming one would silently
    // move an issue out of the filter a reader is watching.
    event.tags = tags.map((key, value) => MapEntry(key, withoutUserPaths(value)));
  }
  final request = event.request;
  if (request != null) {
    final url = request.url;
    if (url != null) {
      request.url = withoutUserPaths(url);
    }
    final queryString = request.queryString;
    if (queryString != null) {
      request.queryString = withoutUserPaths(queryString);
    }
    final cookies = request.cookies;
    if (cookies != null) {
      request.cookies = withoutUserPaths(cookies);
    }
    final fragment = request.fragment;
    if (fragment != null) {
      request.fragment = withoutUserPaths(fragment);
    }
    request.headers = request.headers.map((key, value) => MapEntry(key, withoutUserPaths(value)));
  }
  final culprit = event.culprit;
  if (culprit != null) {
    event.culprit = withoutUserPaths(culprit);
  }
  final transaction = event.transaction;
  if (transaction != null) {
    event.transaction = withoutUserPaths(transaction);
  }
  // Grouping keys. This app writes the event id, but the field is free text and a caller that
  // fingerprinted on the failing file would publish it. `withoutUserPaths` is identity on a UUID,
  // so today's grouping is unchanged byte for byte.
  final fingerprint = event.fingerprint;
  if (fingerprint != null) {
    event.fingerprint = fingerprint.map(withoutUserPaths).toList();
  }
  // The id is this app's opaque telemetry UUID and stays untouched, as do `username` / `email` /
  // `ipAddress` / `geo`: those are identity, and this function redacts **paths**, not PII in general
  // — widening it would leave nobody able to say what it guarantees. `data` and `extras` are the two
  // untyped maps of a user, so they are the two that can hold a path. Assigned rather than mutated:
  // a caller may have handed in an unmodifiable map, and dropping the whole report is a worse
  // outcome than a copy.
  final user = event.user;
  if (user != null) {
    user.data = user.data?.map((key, value) => MapEntry(key, _withoutUserPathsInValue(value)));
    // ignore: deprecated_member_use
    user.extras = user.extras?.map((key, value) => MapEntry(key, _withoutUserPathsInValue(value)));
  }
  // The SDK's passthrough for JSON keys its model has no field for. Empty on an event assembled
  // in-process, non-empty on one that came back through `fromJson`, and unbounded by construction —
  // which is exactly why it cannot be excluded on a promise about today's shape.
  // ignore: invalid_use_of_internal_member
  final unknown = event.unknown;
  if (unknown != null) {
    _scrubMapInPlace(unknown);
  }
  // `images` hands back an unmodifiable *list*, but each `DebugImage` is mutable, so the entries are
  // rewritten in place rather than the list rebuilt. Only the path-shaped fields are touched — see
  // the doc comment for which identifiers this must not disturb. `unknown` is the SDK's passthrough
  // for keys it did not recognise (`AccessAwareMap.notAccessed`, a plain growable map), so it is
  // swept as a map: it is the one part of an image whose contents this code cannot enumerate, and a
  // future sentry-native key naming a file would otherwise arrive unscrubbed.
  for (final image in event.debugMeta?.images ?? const <DebugImage>[]) {
    final codeFile = image.codeFile;
    if (codeFile != null) {
      image.codeFile = withoutUserPaths(codeFile);
    }
    final debugFile = image.debugFile;
    if (debugFile != null) {
      image.debugFile = withoutUserPaths(debugFile);
    }
    final name = image.name;
    if (name != null) {
      image.name = withoutUserPaths(name);
    }
    // `@internal` in the SDK, but it is the only handle on the keys the model has no field for, and
    // leaving it unswept is the enumeration hole this whole change is closing.
    // ignore: invalid_use_of_internal_member
    final unknown = image.unknown;
    if (unknown != null) {
      _scrubMapInPlace(unknown);
    }
  }
  return event;
}

/// Attaches the anonymous telemetry ID as the Sentry user so the session's
/// distinct_id is one we own rather than the SDK's own fallback. Shared by both
/// init paths (see the placement note at each call site).
Future<void> _attachTelemetryUser() async {
  await Sentry.configureScope((scope) => scope.setUser(SentryUser(id: getTelemetryId())));
}

/// Web init path: runs [SentryFlutter.init] without any of the desktop-only setup
/// (`nativeDatabasePath`, `getApplicationSupportDirectory`, crash-DB creation, or
/// any other `dart:io` call), so it is safe to reach on web. Error reporting is
/// otherwise the same as desktop — the SDK auto-hooks `FlutterError.onError` and
/// `PlatformDispatcher.onError`, and shares the DSN, release tag, `beforeSend`, and
/// telemetry user. Web events are marked `environment = 'web'`.
Future<void> _runWithSentryWeb(AppRunner runner) async {
  // Same start-exactly-once guarantee as the desktop path: SentryFlutter.init calls
  // appRunner internally, but a pre-init throw (loadLocalAppVersion) or an init
  // failure would otherwise leave runApp() uncalled and the page blank.
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
    await SentryFlutter.init((SentryFlutterOptions options) {
      // Debug builds never reach here (see runWithSentry), so only the release
      // project DSN remains.
      options.dsn = _sentryDsn;
      options.environment = "web";
      options.release = appVersion.toString();
      options.enablePrintBreadcrumbs = false;
      options.beforeSend = sentryBeforeSend;
    }, appRunner: startAppOnce);
    // Web uses the same telemetry-owned distinct_id as desktop; getTelemetryId is
    // web-safe (StorageBox is Hive/IndexedDB on web). Kept inside this try so a
    // failure still starts the app via the catch below.
    await _attachTelemetryUser();
  } catch (exception, stackTrace) {
    logger.e("Failed to initialize Sentry; starting app without it.", exception, stackTrace);
    startAppOnce();
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
      options.dsn = _sentryDsn;
      options.environment = "desktop";
      options.release = appVersion.toString();
      options.enablePrintBreadcrumbs = false;
      options.beforeSend = sentryBeforeSend;
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
    await _attachTelemetryUser();
  } catch (exception, stackTrace) {
    // Never let a Sentry/startup-prep failure prevent the app from launching.
    logger.e("Failed to initialize Sentry; starting app without it.", exception, stackTrace);
    startAppOnce();
  }
}

Future<void> runWithSentry(AppRunner runner) async {
  // Never initialize Sentry in debug builds: developer-side errors must not be
  // reported. Skipping init leaves HubAdapter disabled, so every captureXxx
  // helper and the log breadcrumbs become no-ops. The privacy opt-out gate
  // (allowPostUserData == deny) is honored on every platform the same way.
  if (kDebugMode || allowPostUserData() == PostUserData.deny) {
    logger.i("Error logging is disabled.");
    runner();
    return;
  }
  // Web takes a separate init path that omits the desktop-only crash-DB setup
  // (getApplicationSupportDirectory / nativeDatabasePath, both dart:io) which has
  // no web counterpart; error reporting is otherwise equivalent (see
  // _runWithSentryWeb). Desktop keeps its native crash-DB init unchanged.
  //
  // UNMEASURED: web deliverability has never been measured. The browser sends
  // envelopes to the Sentry ingest host from page script, so a content blocker
  // or an extension filter list can drop them before they leave the tab, and the
  // SDK reports that as an ordinary network failure with no user-visible sign.
  // Nothing here detects it, and there is no first-party tunnel endpoint that
  // would move ingest under this app's own origin.
  //
  // Consequence, and the reason this note exists rather than a code change: do
  // NOT treat the absence of web events as evidence that web is healthy, and do
  // not build a decision (release gating, regression checks, "is anyone hitting
  // this?") on web telemetry until delivery has actually been measured from a
  // real browser with a blocker enabled. Desktop telemetry carries no such
  // caveat. Measuring first is deliberate: adding a tunnel is delivery
  // infrastructure, and it is not worth building against an unquantified loss.
  if (kIsWeb) {
    logger.i("Error logging is enabled (web).");
    _runWithSentryWeb(runner);
  } else {
    logger.i("Error logging is enabled.");
    _runWithSentry(runner);
  }
}
