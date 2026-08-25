// Verifies how web live-capture failures cross the shared PlatformController boundary.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_web_error_test.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_channel_web_ops.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
  });

  (ProviderContainer, PlatformController) build() {
    final container = ProviderContainer.test();
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    return (container, controller);
  }

  test('web start failures emit error toasts without becoming persistent capture state', () async {
    final (container, controller) = build();
    final toasts = <ToastData>[];
    final errors = <int>[];
    final toastSubscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    final errorSubscription = container.listen<AsyncValue<int>>(
      errorEventProvider,
      (_, current) => current.whenData(errors.add),
    );
    addTearDown(toastSubscription.close);
    addTearDown(errorSubscription.close);

    const expected = <String, String>{
      'screen_share_denied': '画面共有がキャンセルまたは拒否されました。',
      'screen_share_no_video': '映像トラックを取得できませんでした。',
      'live_capture_start_failed': 'ライブキャプチャを開始できませんでした。',
    };
    for (final entry in expected.entries) {
      controller.handleNativeMessage(jsonEncode({'type': 'onError', 'message': entry.key}));
      expect(container.read(charaDetailCaptureStateProvider).error, isNull);
    }
    await pumpEventQueue();

    expect(toasts.map((toast) => toast.type), everyElement(ToastType.error));
    expect(toasts.map((toast) => toast.description), expected.values);
    expect(errors, hasLength(expected.length));
  });

  test('a confirmed loss of captured records is told to the user, not only to the log', () async {
    // The defect this pins: `_persistHarvestToOpfs` logged each record it could not store
    // and said nothing to the person who captured them. The message has to survive the
    // `onCaptureStopped` the same stop relays moments later, which is why the code must be
    // routed to a toast -- as capture state it would be reset before it could be read.
    final (container, controller) = build();
    final toasts = <ToastData>[];
    final subscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);

    controller.handleNativeMessage(jsonEncode({'type': 'onError', 'message': liveRecordsNotStoredErrorCode}));
    controller.handleNativeMessage(jsonEncode({'type': 'onCaptureStopped'}));
    await pumpEventQueue();

    expect(container.read(charaDetailCaptureStateProvider).error, isNull);
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
    // Says what happened (the records are not saved) and what to do about it.
    expect(toasts.single.description, contains('保存領域に書き込めませんでした'));
    expect(toasts.single.description, contains('もう一度キャプチャ'));
  });

  testWidgets('the share-picker guidance warns about whole-monitor selection', (tester) async {
    // Firefox ignores `monitorTypeSurfaces: exclude` / `displaySurface: window`, so its picker
    // still offers whole monitors -- which recognition cannot use. Shown unconditionally.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: WebCaptureTutorialDialog())));

    expect(find.textContaining('画面全体'), findsOneWidget);
    expect(find.textContaining('ウィンドウを選択'), findsOneWidget);
  });
}

final _refProvider = Provider<Ref>((ref) => ref);
