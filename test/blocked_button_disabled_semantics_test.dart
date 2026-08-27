// A WITHDRAWN BUTTON HAS TO ANNOUNCE ITSELF AS WITHDRAWN -- to the semantics tree, not only to the
// eye and the pointer.
// Run: .fvm/flutter_sdk/bin/flutter test test/blocked_button_disabled_semantics_test.dart
//
// `Disabled` greys a control, refuses its pointer events and takes it out of focus traversal, and
// its own doc asks callers to "still hand their button a null callback where they can -- that is
// what makes it announce itself as disabled". Two buttons did not:
//
//   1. `ReportImportDialog`'s Send kept `onPressed: _submit` under `Disabled`, so a screen reader
//      read out an available button that nothing could reach. Its sibling `ReportScreenDialog`
//      already nulls the callback on the same expression, with a comment saying the pointer-only
//      fix was "harmless for the pointer and not for the keyboard".
//   2. `RegenerateRecordDialog`'s destructive OK was not wrapped in `Disabled` at all. It blanked
//      `onLongPress` and left `onPressed: () {}`, and `ButtonStyleButton` counts itself enabled
//      while EITHER callback is non-null -- so a red filled button in its normal colours sat there
//      taking focus, taking Enter, and doing nothing, with the reason available only on hover.
//
// Measured through `SemanticsNode` flags rather than through `Disabled.disabled`: the flag is the
// input to the fix, and asserting on it would pass for an implementation that sets it and changes
// nothing a user (or an assistive technology) can observe.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/chara_detail/regenerate_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/report_import_dialog.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/records.dart';
import 'support/settling.dart';

const _common = 'pages.chara_detail.report_common.dialog';
const _regenerate = 'pages.chara_detail.regenerate_record.dialog';

late Directory _tempDir;

/// A decodable image, so the report preview's real decode has something to read.
final Uint8List _pngBytes = img.encodePng(img.Image(width: 1, height: 1));

const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

/// A clip whose every grab lands, so the "offered" half of the report case is reachable.
class _FakeClip implements ClipFrameSource {
  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async => _timeline;

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    File(destination.path).writeAsBytesSync(_pngBytes);
    return GrabbedVideoFrame(
      png: destination,
      requestedMs: timeMs,
      mediaTsMs: timeMs,
      seekBackoffMs: 0,
      decodedFrames: 3,
    );
  }
}

/// Active storage holding exactly the one record the regenerate dialog is opened on.
class _OneRecordStorage extends CharaDetailRecordStorage {
  _OneRecordStorage(this.record);

  final CharaDetailRecord record;

  @override
  Future<List<CharaDetailRecord>> build() async => [record];
}

Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

/// A container pointed at a scratch directory, optionally with [storage] standing in for the
/// active record store. Written as a named seam rather than an `Override` list because riverpod
/// does not export the `Override` type, so it cannot be passed through a typed parameter.
ProviderContainer _container({CharaDetailRecordStorage Function()? storage}) {
  final dir = DirectoryPath(_tempDir.path);
  final pathInfo = pathInfoProvider.overrideWithValue(
    PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir),
  );
  final container = ProviderContainer(
    // riverpod 3 retries a failed build by default, which turns any setup mistake below into a
    // thirty-second timeout instead of a failure that names itself.
    retry: (_, _) => null,
    overrides: storage == null ? [pathInfo] : [pathInfo, charaDetailRecordStorageLoaderProvider.overrideWith(storage)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Whether the button carrying [label] is announced as an enabled control.
///
/// `hasEnabledState` is asserted alongside it: a node with neither flag is not "disabled", it is a
/// node that never claimed to be a control at all, and reading only `isEnabled` would call that a
/// pass.
({bool hasEnabledState, bool isEnabled}) _announced(WidgetTester tester, String label) {
  // `getSemantics` walks up to the nearest enclosing node, which for a Material button is the
  // merged one carrying both the label and the enabled state -- i.e. the node a screen reader reads.
  final node = tester.getSemantics(find.text(label));
  return (
    hasEnabledState: node.hasFlag(SemanticsFlag.hasEnabledState),
    isEnabled: node.hasFlag(SemanticsFlag.isEnabled),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);
  useStorageBoxForTest();

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('umacapture_blocked_button_test');
    Directory('${_tempDir.path}/temp').createSync(recursive: true);
  });
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('the import report Send is announced as disabled while it is blocked, and enabled once it is not', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    // Tall enough for the whole card once a clip adds the slider and the step buttons; the Send row
    // otherwise lands outside the card's clip.
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final container = _container();
    // The real `DialogLayer`, driven through the real `dialogBuilderProvider`: the gate under test
    // is `Disabled`, which the dialog mounts itself, but the dialog is only ever reached through
    // this layer and a case that mounted the bare widget would be asserting about a tree the app
    // never builds.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: appTestLocale,
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => ReportImportDialog(
            onSubmit: (_) {},
            rateLimitLoader: _readyRateLimit,
            grabAvailable: true,
            picker: () async => _FakeClip(),
          ),
        );
    await tester.pump();
    await tester.pump();

    final sendLabel = appSentenceAt('$_common.ok_button.label');
    // Blocked: no clip has been chosen, so there is nothing to send.
    final blocked = _announced(tester, sendLabel);
    expect(blocked.hasEnabledState, isTrue, reason: 'Send is a control, and has to be read out as one');
    expect(blocked.isEnabled, isFalse, reason: 'nothing has been chosen to send');

    // Offered: a clip was chosen and a frame landed.
    await tester.tap(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.pick_button.label')));
    // Send is offered only once `_startGrab` has awaited `RecordImage.preload` -- a real file read
    // plus a PNG decode, neither of which runs on this isolate. Waiting for the announcement itself
    // rather than for a fixed number of milliseconds is what keeps a busy host slow instead of red.
    await settleUntil(
      tester,
      () => _announced(tester, sendLabel).isEnabled,
      describe: "the picked clip's first frame to be decoded, so Send is announced as enabled",
    );
    final offered = _announced(tester, sendLabel);
    expect(offered.hasEnabledState, isTrue);
    expect(offered.isEnabled, isTrue, reason: 'a fix that never re-enables the button is not a fix');
    // In the body, not in a tearDown: `flutter_test` checks for a live handle before tearDowns run.
    handle.dispose();
  });

  testWidgets('the regenerate OK is announced as disabled while a video import owns the pipeline', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final record = makeRecord(id: 'record-under-test', card: 1);
    final container = _container(storage: () => _OneRecordStorage(record));
    // The dialog reads the record synchronously off the notifier, which requires a settled value.
    await container.read(charaDetailRecordStorageLoaderProvider.future);

    final importing = ValueNotifier<VideoImportState>(const VideoImportState(phase: VideoImportPhase.importing));
    addTearDown(importing.dispose);

    // Mounted through `DialogLayer` and `dialogBuilderProvider` for the same reason as above: the
    // `Disabled` under test is inside the dialog, but `CardDialog` is what lays the button row out,
    // and a bare mount would not have it.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: appTestLocale,
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container
        .read(dialogBuilderProvider.notifier)
        .show((_) => RegenerateRecordDialog(recordId: record.id, debugImportState: importing));
    await tester.pump();
    await tester.pump();

    final okLabel = appSentenceAt('$_regenerate.ok_button.label');
    final blocked = _announced(tester, okLabel);
    expect(blocked.hasEnabledState, isTrue, reason: 'the destructive button is a control');
    expect(blocked.isEnabled, isFalse, reason: 'the worker refuses every record while an import owns the loop');
    // And the withdrawal is the app's own primitive, so the grey, the pointer refusal and the focus
    // exclusion come with it rather than being reinvented here.
    expect(
      tester.widget<Disabled>(find.ancestor(of: find.text(okLabel), matching: find.byType(Disabled)).first).disabled,
      isTrue,
    );

    // Idle: the same dialog, walked on rather than re-opened, because the button has to come back.
    importing.value = VideoImportState.idle;
    await tester.pump();
    final offered = _announced(tester, okLabel);
    expect(offered.hasEnabledState, isTrue);
    expect(offered.isEnabled, isTrue, reason: 'with no import running the batch is offered again');
    handle.dispose();
  });
}
