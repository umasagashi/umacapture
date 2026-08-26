import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/const.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/platform_controller.dart';
import '/src/core/sound_player.dart';
import '/src/core/video_import.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/chara_detail/export_button.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_toast = "toast";

/// The "open the containing folder" callback of the export-completed toast, or
/// null when that affordance must not be offered.
///
/// Null for a web download ([ExportResult.downloadRequested] carries no path)
/// and null wherever there is no OS file manager: `PathEntity.launch()` is a
/// no-op there, so a tappable toast would do nothing at all. Same capability
/// gate as every other reveal site (`CurrentPlatform.canRevealInFileManager`).
VoidCallback? revealExportedFileCallback(ExportResult result) {
  final path = result.path;
  if (path == null || !CurrentPlatform.canRevealInFileManager()) {
    return null;
  }
  return () => path.parent.launch();
}

class NotificationLayer extends ConsumerStatefulWidget {
  const NotificationLayer({super.key, this.debugVideoImportState, this.debugPlaySound});

  /// Test-only: stands in for the import state [videoImportState] reports.
  ///
  /// `video_import.dart` resolves to the desktop stub on the VM, whose notifier is a constant idle by
  /// construction, so without this seam the import mute below could only be exercised in a browser.
  /// Same seam, same reason, as `PlatformController.debugVideoImportState`.
  @visibleForTesting
  final ValueListenable<VideoImportState>? debugVideoImportState;

  /// Test-only: the sink [_NotificationLayerState._playSound] hands each chime to.
  ///
  /// Overriding [soundEffectProvider] cannot substitute: it is a cached `FutureProvider`, so an
  /// override observes the FIRST request for a given [SoundType] and no later one — and how many
  /// chimes fire is the entire property under test here.
  @visibleForTesting
  final void Function(SoundType type)? debugPlaySound;

  static Widget asSibling({required Widget child}) {
    return Column(
      children: [
        Expanded(child: child),
        const NotificationLayer(),
      ],
    );
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotificationLayerState();
}

class _NotificationLayerState extends ConsumerState<NotificationLayer> {
  final Toaster _toaster = Toaster(); // Do not use Toaster.show in this class.

  /// Whether a video import owns the recognition pipeline right now.
  ///
  /// **The sound gate lives here rather than in the event dispatch**, for two reasons. The events
  /// have to keep flowing regardless — the progress rings, the status line and the record harvest all
  /// read them, and an import is expected to drive every one of those. And the four chimes do not
  /// share a dispatch: three come from `platform_controller.dart`, but
  /// [duplicatedCharaEventProvider] is emitted by the record store, so a gate placed in the
  /// controller's `switch` would silence three of the four and leave the duplicate cue playing.
  ///
  /// Derived from the import front end's own state instead of a mute flag this class raises and
  /// lowers: every ending an import can have (completion, cancellation, refusal, failure, a worker
  /// teardown that settles the outcome) leaves [VideoImportState.isRunning], so there is no mute to
  /// get stuck and silence live capture afterwards.
  ///
  /// **Defence in depth, and deliberately kept after the origin marker landed.** A record now
  /// carries whether an import produced it (`harvestOriginVideoImport`), and that marker is what
  /// covers the merges this gate cannot see — the ones that run after the state has settled, on
  /// either platform. This gate covers the opposite half: cues that are not attached to a record at
  /// all (standby, and the two error sources), which no per-record marker can reach. Neither
  /// subsumes the other, so removing either one leaves a real hole.
  bool get _videoImportRunning => (widget.debugVideoImportState ?? videoImportState).value.isRunning;

  void _playSound(SoundType type) {
    if (_videoImportRunning) {
      // An import is a bulk, unattended pass over a clip: it can cross dozens of characters in a
      // minute, and chiming for each one says "come and look" about something nobody is watching.
      return;
    }
    final debugPlaySound = widget.debugPlaySound;
    if (debugPlaySound != null) {
      debugPlaySound(type);
      return;
    }
    ref.read(soundEffectProvider(type).future).playSafely();
  }

  void _listenForPlaySound(StreamProvider provider, SoundType soundType) {
    ref.listen<AsyncValue<void>>(provider, (_, current) {
      current.whenData((_) => _playSound(soundType));
    });
  }

  void _listenForToast<T>(StreamProvider<T> provider, String message, [VoidCallback? Function(T)? onTap]) {
    ref.listen<AsyncValue<T>>(provider, (_, current) {
      current.whenData((T data) {
        _toaster.showToast(context, ToastData.success(description: message, onTap: onTap?.call(data)));
      });
    });
  }

  void _listenForToastData<T>(StreamProvider<ToastData> provider) {
    ref.listen<AsyncValue<ToastData>>(provider, (_, current) {
      current.whenData((ToastData data) => _toaster.showToast(context, data));
    });
  }

  @override
  Widget build(BuildContext context) {
    _listenForPlaySound(scrollReadyEventProvider, SoundType.standby);
    _listenForPlaySound(pageReadyEventProvider, SoundType.success);
    _listenForPlaySound(errorEventProvider, SoundType.error);
    _listenForPlaySound(duplicatedCharaEventProvider, SoundType.error);

    _listenForToastData(plainToastEventProvider);
    _listenForToast<ExportResult>(
      recordExportEventProvider,
      "$tr_toast.record_export".tr(),
      revealExportedFileCallback,
    );

    return Container();
  }
}
