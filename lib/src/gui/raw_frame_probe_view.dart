import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/platform_controller.dart';
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

/// Grabs one raw frame and hands the resulting bundle to the browser as a download.
///
/// Deliberately not `async`: `getDisplayMedia` spends the tap's transient user activation, so
/// the call into the platform channel has to happen before this returns to the event loop.
/// Everything after the picker resolves is done in the continuation.
void saveRawFrameBundle(WidgetRef ref) {
  final controller = ref.read(platformControllerProvider);
  if (controller == null) {
    Toaster.show(ToastData.error(description: "$tr_raw_frame.save.failure".tr()));
    return;
  }
  controller
      .buildRawFrameBundle()
      .then((bundle) async {
        if (bundle == null) {
          // Cancelled picker, denied permission, or a frame that could not be grabbed. All three
          // are ordinary outcomes of a user-driven diagnostic, so they share one calm message.
          Toaster.show(ToastData.warning(description: "$tr_raw_frame.save.unavailable".tr()));
          return;
        }
        // Web has no writable OS path and no native save dialog, so the completed bytes are
        // handed to the browser as a download -- the same route the record exporter takes.
        await FilePicker.saveFile(
          dialogTitle: "$tr_raw_frame.save.dialog_title".tr(),
          fileName: bundle.fileName,
          bytes: bundle.bytes,
        );
        // Success is "returned without throwing", not "returned a path": the web implementation
        // hands the bytes to the browser as a download and then returns null unconditionally,
        // because web has no save path to report. The user-cancelled case is already handled
        // above -- the picker runs before any bytes exist, so a cancel arrives as a null bundle.
        Toaster.show(ToastData.success(description: "$tr_raw_frame.save.success".tr()));
      })
      .catchError((Object error, StackTrace stackTrace) {
        logger.e("Failed to save a raw frame bundle", error, stackTrace);
        Toaster.show(ToastData.error(description: "$tr_raw_frame.save.failure".tr()));
      });
}
