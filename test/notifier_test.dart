// Provider tests for the riverpod 3 migration. These cover Notifiers whose
// state is self-contained (no Hive / filesystem), exercising the hand-written
// build()/method shape introduced when the legacy State* APIs were removed.
// Run: .fvm/flutter_sdk/bin/flutter test test/notifier_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/core/platform_controller.dart';

void main() {
  test('CharaDetailCaptureStateNotifier transitions through capture lifecycle', () {
    final container = ProviderContainer.test();
    final notifier = container.read(charaDetailCaptureStateProvider.notifier);

    // Initial state.
    expect(container.read(charaDetailCaptureStateProvider).isCapturing, isFalse);

    // progress() flips isCapturing and records per-tab progress.
    notifier.progress(0, 0.5);
    var state = container.read(charaDetailCaptureStateProvider);
    expect(state.isCapturing, isTrue);
    expect(state.skillTabProgress, 0.5);

    notifier.progress(1, 1.0);
    expect(container.read(charaDetailCaptureStateProvider).factorTabProgress, 1.0);

    // success() resets progress and exposes the new link.
    notifier.success('rec-1');
    state = container.read(charaDetailCaptureStateProvider);
    expect(state.link?.id, 'rec-1');
    expect(state.isCapturing, isFalse);
    expect(state.skillTabProgress, 0.0);

    // fail() keeps the current state but records the error message.
    notifier.fail('boom');
    expect(container.read(charaDetailCaptureStateProvider).error, 'boom');

    // reset() returns to a clean state.
    notifier.reset();
    final reset = container.read(charaDetailCaptureStateProvider);
    expect(reset.isCapturing, isFalse);
    expect(reset.error, isNull);
    expect(reset.link, isNull);
  });

  test('each read of charaDetailCaptureStateProvider sees a NEW instance on mutation', () {
    final container = ProviderContainer.test();
    final notifier = container.read(charaDetailCaptureStateProvider.notifier);

    final before = container.read(charaDetailCaptureStateProvider);
    notifier.progress(0, 0.25);
    final after = container.read(charaDetailCaptureStateProvider);

    // A new instance must be assigned so riverpod's ==-based filtering rebuilds.
    expect(identical(before, after), isFalse);
  });

  test('Exporting notifier exposes a simple boolean setter', () {
    final container = ProviderContainer.test();
    expect(container.read(exportingStateProvider), isFalse);

    container.read(exportingStateProvider.notifier).set(true);
    expect(container.read(exportingStateProvider), isTrue);

    container.read(exportingStateProvider.notifier).set(false);
    expect(container.read(exportingStateProvider), isFalse);
  });
}
