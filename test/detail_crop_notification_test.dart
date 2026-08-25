// Tests the `native -> Dart` receive path for `onDetailCropReported`: the real wire payload, through the
// real dispatch in [PlatformController.handleNativeMessage], into [detailCropReportProvider].
//
// Constructing a [DetailCropReport] by hand proves nothing about this seam. The payload's key names are a
// contract with `messages::detailCropReported` in native/src/core/native_api_messages.h (pinned on the other
// side by test_native_api_messages.cpp), and an unhandled type falls into `handleNativeMessage`'s
// `UnimplementedError` default — which is caught and downgraded to a log line, so a missing case would take
// the whole feature down silently.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/detail_crop_notification_test.dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';

/// The exact payload `messages::detailCropReported` emits (flat left/top/width/height per rect).
String _payload({required List<int> defaultRect, required List<int> corrected, required bool latched}) {
  Map<String, int> rect(List<int> v) => {'left': v[0], 'top': v[1], 'width': v[2], 'height': v[3]};
  return jsonEncode({
    'type': 'onDetailCropReported',
    'default': rect(defaultRect),
    'corrected': rect(corrected),
    'latched': latched,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The controller pushes its initial config over the method channel from its constructor; answer it so
    // the fire-and-forget call does not surface as a failure toast.
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

  /// A controller wired to [container], plus the container itself.
  (ProviderContainer, PlatformController) build() {
    final container = ProviderContainer.test();
    // The Ref the controller needs is the one the real provider hands it; a container read of any provider
    // gives the same element-scoped behaviour for the notifier reads this test exercises.
    final controller = PlatformController(container.read(_refProvider), const {});
    return (container, controller);
  }

  test('a report populates the provider from the wire payload', () {
    final (container, controller) = build();
    expect(container.read(detailCropReportProvider), isNull);

    controller.handleNativeMessage(
      _payload(defaultRect: [0, 0, 1280, 720], corrected: [2, 1, 1276, 718], latched: true),
    );

    final report = container.read(detailCropReportProvider);
    expect(report, isNotNull);
    expect(report!.defaultRect, const DetailCropRect(left: 0, top: 0, width: 1280, height: 720));
    expect(report.correctedRect, const DetailCropRect(left: 2, top: 1, width: 1276, height: 718));
    expect(report.latched, isTrue);
  });

  test('an unlatched report is stored as unlatched', () {
    final (container, controller) = build();

    controller.handleNativeMessage(
      _payload(defaultRect: [4, 8, 640, 360], corrected: [4, 8, 640, 360], latched: false),
    );

    final report = container.read(detailCropReportProvider)!;
    expect(report.latched, isFalse);
  });

  test('a later report replaces the earlier one', () {
    final (container, controller) = build();
    controller.handleNativeMessage(
      _payload(defaultRect: [0, 0, 1280, 720], corrected: [1, 0, 1279, 720], latched: false),
    );

    controller.handleNativeMessage(
      _payload(defaultRect: [0, 0, 1280, 720], corrected: [2, 1, 1276, 718], latched: true),
    );

    final report = container.read(detailCropReportProvider)!;
    expect(report.correctedRect, const DetailCropRect(left: 2, top: 1, width: 1276, height: 718));
    expect(report.latched, isTrue);
  });

  test('a malformed report is ignored rather than half-applied', () {
    // The dispatch swallows and logs; what matters is that a previously good value survives instead of
    // being replaced by a rect that was never measured.
    final (container, controller) = build();
    controller.handleNativeMessage(
      _payload(defaultRect: [0, 0, 1280, 720], corrected: [2, 1, 1276, 718], latched: true),
    );

    controller.handleNativeMessage(jsonEncode({'type': 'onDetailCropReported', 'default': {}, 'latched': true}));

    expect(container.read(detailCropReportProvider)!.correctedRect.left, 2);
  });
}

/// Exposes a plain [Ref] from the container, so a [PlatformController] can be built against it exactly as
/// `platformControllerLoader` builds the real one.
final _refProvider = Provider<Ref>((ref) => ref);
