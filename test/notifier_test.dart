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
    expect(container.read(charaDetailCaptureStateProvider).skillTabProgress, 0.0);

    // started() begins the attempt the core announced; outcomes are applied only to it.
    notifier.started('rec-1');
    expect(container.read(charaDetailCaptureStateProvider).attemptId, 'rec-1');

    // progress() records per-tab progress.
    notifier.progress(0, 0.5);
    var state = container.read(charaDetailCaptureStateProvider);
    expect(state.skillTabProgress, 0.5);

    notifier.progress(1, 1.0);
    expect(container.read(charaDetailCaptureStateProvider).factorTabProgress, 1.0);

    // success() of another attempt changes nothing.
    expect(notifier.success('rec-0'), isFalse);
    expect(container.read(charaDetailCaptureStateProvider).link, isNull);

    // success() exposes the new link and pins every tab at 100% (the completed rings stay visible).
    expect(notifier.success('rec-1'), isTrue);
    state = container.read(charaDetailCaptureStateProvider);
    expect(state.link?.id, 'rec-1');
    expect(state.skillTabProgress, 1.0);

    // fail() keeps the current state but records the error message.
    notifier.fail('boom');
    expect(container.read(charaDetailCaptureStateProvider).error, 'boom');

    // reset() returns to a clean state, and keeps the attempt it was about.
    notifier.reset();
    final reset = container.read(charaDetailCaptureStateProvider);
    expect(reset.error, isNull);
    expect(reset.link, isNull);
    expect(reset.attemptId, 'rec-1');
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
