import 'dart:async';

import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:dio/dio.dart';
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
      return await Dio()
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

FutureOr<void> captureError(String message) {
  if (isSentryAvailable()) {
    Sentry.captureMessage(message, level: SentryLevel.error);
  }
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
  if (kDebugMode || allowPostUserData() == PostUserData.deny) {
    logger.i("Error logging is disabled.");
    runner();
  } else {
    logger.i("Error logging is enabled.");
    _runWithSentry(runner);
  }
}
