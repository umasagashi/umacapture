// Shared Riverpod test helpers.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/utils.dart';

/// Exposes a [RefBase] from a container so functions and runners that take a
/// [RefBase] (rather than a [ProviderContainer]) can be exercised in tests:
/// `container.read(refBaseProvider)`.
final refBaseProvider = Provider<RefBase>((ref) => ref.base);

/// Pumps [child] with [container] in scope, tying the container's lifetime to
/// the widget tree.
///
/// Use this instead of a bare [UncontrolledProviderScope] whenever a widget test
/// owns its container. `flutter_test` unmounts the tree at the end of the test
/// body and then asserts that no timer is left pending — and it does so *before*
/// any `addTearDown` runs, so `addTearDown(container.dispose)` is always too
/// late. A container that outlives the tree keeps its provider elements alive
/// across that check, together with whatever timers they own — and riverpod arms
/// one on every build that fails with a retryable error: the 200 ms retry
/// `Timer` scheduled from `ProviderElement.triggerRetry`. The test then fails
/// with "A Timer is still pending even after the widget tree was disposed",
/// naming a provider the test never meant to keep. Whether that timer is still
/// there at the check depends on whether the element was auto-disposed first,
/// which is not something a test should be left to win.
///
/// Note that a container-level `retry` (the app's `retry: (_, __) => null` in
/// `lib/main.dart`) does *not* close this: riverpod consults `origin.retry`
/// first, so any provider declaring its own policy — `retryUnlessStoreOutage`,
/// for instance — bypasses the container's. Owning the lifetime does close it,
/// for every provider and every timer.
///
/// The container is disposed when this scope unmounts, so pumping a different
/// tree ends its life: pump the whole page under one call.
Future<void> pumpWithContainer(WidgetTester tester, ProviderContainer container, Widget child) {
  return tester.pumpWidget(_ContainerLifetimeScope(container: container, child: child));
}

/// Mounts [container] and disposes it when it leaves the tree.
class _ContainerLifetimeScope extends StatefulWidget {
  const _ContainerLifetimeScope({required this.container, required this.child});

  final ProviderContainer container;
  final Widget child;

  @override
  State<_ContainerLifetimeScope> createState() => _ContainerLifetimeScopeState();
}

class _ContainerLifetimeScopeState extends State<_ContainerLifetimeScope> {
  @override
  void dispose() {
    // The framework unmounts deepest-first, so the scope below has already let go
    // of the container by now. Disposing is idempotent, so a test that also
    // registers `addTearDown(container.dispose)` as a never-pumped fallback stays
    // correct.
    widget.container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(container: widget.container, child: widget.child);
  }
}
