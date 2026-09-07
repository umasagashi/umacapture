import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/platform_controller.dart';
import '/src/core/raw_frame_probe.dart';
import '/src/core/storage/file_download.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_raw_frame = "pages.settings.raw_frame_probe";

/// Settings entry for the diagnostic raw-frame probe.
///
/// Mounted by [SettingsPage] only when the app was launched with `?rawframe=1`
/// (`rawFrameProbeEnabled`), so an ordinary session never shows it. The probe collects
/// material for the frame-shaping review: one screen-share still that has been through no
/// crop, resize, or title-bar trim, plus the metadata needed to read its geometry.
class RawFrameProbeGroup extends ConsumerWidget {
  const RawFrameProbeGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_raw_frame.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        ListTile(
          title: Text("$tr_raw_frame.save.title".tr()),
          subtitle: Text("$tr_raw_frame.save.description".tr()),
          trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.bug_report_rounded)),
          onTap: () => saveRawFrameBundle(ref),
        ),
      ],
    );
  }
}

/// Grabs one raw frame and hands the resulting bundle to the platform's save route.
///
/// Deliberately not `async`: `getDisplayMedia` spends the tap's transient user activation, so
/// the call into the platform channel has to happen before this returns to the event loop.
/// Everything after the picker resolves is done in the continuation.
///
/// The save seam and the capability it is read with are both taken from
/// [storageSaveFileProvider] / [saveDialogReportsPathProvider], and both are read *here* rather
/// than in the continuation: the settings tile that triggered this is free to go away while the
/// screen-share picker is open, and reading a disposed [WidgetRef] throws.
void saveRawFrameBundle(WidgetRef ref) {
  final controller = ref.read(platformControllerProvider);
  if (controller == null) {
    Toaster.show(ToastData.error(description: "$tr_raw_frame.save.failure".tr()));
    return;
  }
  final saveFile = ref.read(storageSaveFileProvider);
  final reportsPath = ref.read(saveDialogReportsPathProvider);
  controller
      .buildRawFrameBundle()
      .then((bundle) => deliverRawFrameBundle(bundle, saveFile: saveFile, reportsPath: reportsPath))
      .catchError((Object error, StackTrace stackTrace) {
        logger.e("Failed to save a raw frame bundle", error, stackTrace);
        Toaster.show(ToastData.error(description: "$tr_raw_frame.save.failure".tr()));
      });
}

/// Offers [bundle] to the platform's save route and announces what happened.
///
/// Split out of [saveRawFrameBundle] so the four outcomes below are reachable without a platform
/// channel: the grab itself is an OS screen-share picker that no test can drive, and folding the
/// two together is what let "saved" be announced for a dialog the user had dismissed.
@visibleForTesting
Future<void> deliverRawFrameBundle(
  RawFrameBundle? bundle, {
  required StorageSaveFile saveFile,
  required bool reportsPath,
}) async {
  if (bundle == null) {
    // Cancelled picker, denied permission, or a frame that could not be grabbed. All three
    // are ordinary outcomes of a user-driven diagnostic, so they share one calm message.
    Toaster.show(ToastData.warning(description: "$tr_raw_frame.save.unavailable".tr()));
    return;
  }
  if (bundle.bytes.isEmpty) {
    // Neither save route writes a zero-byte file, and the two fail differently: the web leg
    // throws `ArgumentError` before reaching the browser, while the Windows leg's
    // `saveBytesToFile` opens with `if (path == null || bytes == null || bytes.isEmpty)
    // return;` and *still answers the chosen path*. Refusing here is what stops that second
    // case from being announced as a save that never happened. It is `failure` and not
    // `unavailable`: a bundle that arrived with no bytes in it is a fault in the probe, not
    // an outcome the user chose. (`downloadStorageFile` refuses the same input for the same
    // reason.)
    logger.e("Raw frame bundle arrived with no bytes: ${bundle.fileName}");
    Toaster.show(ToastData.error(description: "$tr_raw_frame.save.failure".tr()));
    return;
  }
  final savedPath = await saveFile(
    dialogTitle: "$tr_raw_frame.save.dialog_title".tr(),
    fileName: bundle.fileName,
    bytes: bundle.bytes,
  );
  if (!reportsPath) {
    // The browser has the bytes. `file_picker`'s web leg starts an anchor download and then
    // returns null unconditionally, so the null carries no information and is not consulted;
    // arriving here without an exception is the whole of what "it went out" can mean.
    Toaster.show(ToastData.success(description: "$tr_raw_frame.save.success".tr()));
    return;
  }
  if (savedPath == null) {
    // A build whose dialog reports a path answers null only when the user dismissed it.
    // Nothing was written, the user is the one who decided so, and saying anything here
    // would be reporting their own choice back at them as an event.
    return;
  }
  Toaster.show(ToastData.success(description: "$tr_raw_frame.save.success".tr()));
}
