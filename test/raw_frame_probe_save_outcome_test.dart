// The raw-frame probe must not announce a save it did not make.
//
// `FilePicker.saveFile` answers a path on Windows and `null` on web whatever
// happened, and on Windows its `saveBytesToFile` opens with
// `if (path == null || bytes == null || bytes.isEmpty) return;` -- so a returned
// path is not a written file either. `deliverRawFrameBundle` therefore reads the
// outcome through `saveDialogReportsPathProvider`'s capability rather than
// treating "returned without throwing" as success.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/raw_frame_probe_save_outcome_test.dart
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/raw_frame_probe.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/gui/raw_frame_probe_view.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';

/// Collects the toasts published while a case runs.
///
/// `Toaster.show` publishes into a module-level broadcast stream, so a container
/// that is not the one under test still sees them -- which is what makes "no
/// toast was shown" an assertion rather than a hope.
class _ToastObserver {
  _ToastObserver() {
    _container = ProviderContainer(retry: (_, _) => null);
    _container.listen(plainToastEventProvider, (_, next) => next.whenData(seen.add));
    addTearDown(_container.dispose);
  }

  late final ProviderContainer _container;
  final List<ToastData> seen = [];

  Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 20));
}

final _bundle = RawFrameBundle(fileName: 'rawframe-20260901.zip', bytes: Uint8List.fromList([1, 2, 3, 4]));

String _tr(String leaf) => 'pages.settings.raw_frame_probe.save.$leaf'.tr();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  /// A save seam that answers [answer] and records what it was handed.
  ({StorageSaveFile seam, List<Uint8List> offered}) seam(String? answer) {
    final offered = <Uint8List>[];
    return (
      seam: ({required String dialogTitle, required String fileName, required Uint8List bytes}) async {
        offered.add(bytes);
        return answer;
      },
      offered: offered,
    );
  }

  test('a dismissed save dialog is not announced as a save', () async {
    // The case the old code got wrong: on a build whose dialog reports a path, a
    // `null` is the user closing it, and nothing was written.
    final toasts = _ToastObserver();
    final save = seam(null);

    await deliverRawFrameBundle(_bundle, saveFile: save.seam, reportsPath: true);
    await toasts.drain();

    expect(save.offered, hasLength(1), reason: 'the dialog really was opened with the bundle');
    expect(toasts.seen, isEmpty, reason: 'a cancellation is not a failure and not a success');
  });

  test('a chosen path is announced as a save', () async {
    // The positive control for the case above: without it, never announcing
    // anything would pass.
    final toasts = _ToastObserver();
    final save = seam(r'C:\Users\someone\Downloads\rawframe.zip');

    await deliverRawFrameBundle(_bundle, saveFile: save.seam, reportsPath: true);
    await toasts.drain();

    expect(toasts.seen.map((toast) => toast.type), [ToastType.success]);
    expect(toasts.seen.single.description, _tr('success'));
  });

  test('a browser download is announced even though it reports no path', () async {
    // The other half of the capability: on web the `null` carries no information,
    // so reading it as a cancellation would silence every successful download.
    final toasts = _ToastObserver();
    final save = seam(null);

    await deliverRawFrameBundle(_bundle, saveFile: save.seam, reportsPath: false);
    await toasts.drain();

    expect(toasts.seen.map((toast) => toast.type), [ToastType.success]);
    expect(save.offered.single, _bundle.bytes);
  });

  test('an empty bundle is refused before the dialog rather than announced as saved', () async {
    // Neither save route writes a zero-byte file; the Windows one still answers
    // the chosen path, which is what would otherwise become a false success.
    final toasts = _ToastObserver();
    final save = seam(r'C:\Users\someone\Downloads\rawframe.zip');

    await deliverRawFrameBundle(
      RawFrameBundle(fileName: 'rawframe.zip', bytes: Uint8List(0)),
      saveFile: save.seam,
      reportsPath: true,
    );
    await toasts.drain();

    expect(save.offered, isEmpty, reason: 'nothing is offered that the platform would refuse to write');
    expect(toasts.seen.map((toast) => toast.type), [ToastType.error]);
    expect(toasts.seen.single.description, _tr('failure'));
  });

  test('a grab that produced nothing keeps its own calm message', () async {
    // Negative control for the three above: the null-bundle branch predates this
    // fix and must not have been folded into the new ones.
    final toasts = _ToastObserver();
    final save = seam(null);

    await deliverRawFrameBundle(null, saveFile: save.seam, reportsPath: true);
    await toasts.drain();

    expect(save.offered, isEmpty);
    expect(toasts.seen.map((toast) => toast.type), [ToastType.warning]);
    expect(toasts.seen.single.description, _tr('unavailable'));
  });
}
