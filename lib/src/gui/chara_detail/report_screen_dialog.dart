import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/path_entity.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/report_common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_report_screen = "pages.chara_detail.report_screen";

class ReportScreenDialog extends ConsumerStatefulWidget {
  /// How the monthly report quota is fetched.
  ///
  /// Only overridden by tests: the real loader issues a Dio request, whose
  /// timeout timer a widget test reports as a pending timer even after the
  /// dialog is gone.
  @visibleForTesting
  final Future<SentryRateLimit?> Function() rateLimitLoader;

  /// How the screenshot this dialog owns is requested; returns the path the shot
  /// will be written to.
  ///
  /// Only overridden by tests: the real request goes through the platform
  /// controller, which no widget test has.
  @visibleForTesting
  final FilePath Function(RefBase ref) captureRequester;

  const ReportScreenDialog({
    super.key,
    this.rateLimitLoader = SentryRateLimit.download,
    this.captureRequester = takeScreenshot,
  });

  /// Opens the report dialog, which also requests the screenshot it shows.
  ///
  /// The capture is deliberately *not* started here: a screenshot must never
  /// exist without an owner already waiting for it, and only the mounted dialog
  /// is that owner (see [_ReportScreenDialogState.initState]).
  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const ReportScreenDialog());
  }

  @override
  ConsumerState<ReportScreenDialog> createState() => _ReportScreenDialogState();
}

class _ReportScreenDialogState extends ConsumerState<ReportScreenDialog> {
  final TextEditingController _noteController = TextEditingController();
  // Cached so a rebuild does not re-issue the rate-limit request (and reset the spinner).
  late final Future<SentryRateLimit?> _rateLimitFuture = widget.rateLimitLoader();

  /// The transient screenshot this dialog is responsible for.
  ///
  /// Known from the moment the capture is *requested* -- [takeScreenshot] picks
  /// the path and returns it synchronously -- so ownership never depends on
  /// having seen [latestScreenshotProvider] publish anything, and this dialog can
  /// only ever delete the file it asked for. Null only while no request has been
  /// made, which is also the only state with nothing to clean up.
  FilePath? _screenshotPath;

  /// Open while the capture that writes [_screenshotPath] is still running, null
  /// once it has settled (and before anything was requested).
  ///
  /// The request only *starts* the capture, so when the dialog closes the file
  /// usually does not exist yet and deleting it there would be a no-op the write
  /// then undoes. `onScreenshotTaken` -- published by both platforms on success
  /// and on failure alike, echoing back the requested path -- is the signal that
  /// the writer is done with the file.
  ProviderSubscription<ScreenshotResult?>? _capture;

  /// Set once *this dialog's own* shot has been handed to [captureScreen], which
  /// owns it from then on. Without it [dispose] would delete the file out from
  /// under the in-flight attachment upload.
  ///
  /// Only ever set for [_screenshotPath] (Send reads [_ownResult]), so it always
  /// means "my file has a later owner". Set it for someone else's shot and this
  /// dialog's own file would be leaked instead: the listener below would then
  /// skip its delete.
  bool _handedOver = false;

  /// The result of this dialog's own capture, latched the moment it lands.
  ///
  /// The dialog never previews or submits [latestScreenshotProvider] directly:
  /// that is one global slot, written for every `onScreenshotTaken` with no
  /// notion of which dialog asked, so a concurrent attempt -- an earlier dialog
  /// the user dismissed while its capture was still running -- publishes into it
  /// too. Reading the slot would show and upload another attempt's frame of the
  /// user's screen, on a path this dialog does not own and whose file that
  /// attempt is deleting as it lands; and once overwritten, the slot never
  /// carries this dialog's shot again, so even the preview could not recover.
  ///
  /// Latching the owned result instead makes the requested path the identity for
  /// display and submit as well -- the same test [dispose] and the capture
  /// listener already use -- and makes it immune to whatever lands afterwards.
  /// Null means "mine has not arrived", which is what a foreign result means too.
  ScreenshotResult? _ownResult;

  /// Set by [dispose]: this dialog no longer needs the shot, so a capture still
  /// running has to be cleaned up the moment it finishes.
  bool _abandoned = false;

  @override
  void initState() {
    super.initState();
    // Deferred by a frame because the request resets [latestScreenshotProvider],
    // and riverpod forbids writing to a provider from a widget life-cycle. The
    // mounted check is the point of ownership: a dialog that is already gone
    // never asks for a screenshot, so none can be produced unowned.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _requestScreenshot();
    });
  }

  /// Starts the capture and stays on the hook for the file it will write.
  ///
  /// The subscription is bound to the provider *container*, not to this widget:
  /// the capture outlives the dialog on every early-close path, and a
  /// widget-scoped listener (`ref.listen`/`listenManual`) would be closed exactly
  /// when it is needed. It is opened here rather than from [dispose] so that it
  /// is only ever taken out while the widget -- and therefore the container --
  /// is still alive.
  ///
  /// The requested path is the attempt's identity: it is unique per call and
  /// echoed back by both platforms, so a concurrent attempt's shot is passed over
  /// instead of being mistaken for this one's, and this one's own shot is still
  /// collected when it lands after that newer attempt opened.
  ///
  /// This is also where [_ownResult] is latched, so the one subscription that
  /// already knows which result belongs to this dialog is what feeds the preview
  /// and Send -- there is no second, weaker notion of ownership to drift from it.
  void _requestScreenshot() {
    final path = widget.captureRequester(ref.base);
    _screenshotPath = path;
    final container = ProviderScope.containerOf(context, listen: false);
    _capture = container.listen<ScreenshotResult?>(latestScreenshotProvider, (_, next) {
      final result = next;
      if (result == null || result.path.path != path.path) {
        return;
      }
      _capture?.close();
      _capture = null;
      if (_abandoned) {
        // dispose() sets _abandoned, so this is also the unmounted case: nothing
        // is left to show the result to, only a file to clean up.
        if (!_handedOver) {
          unawaited(deleteTransientScreenshot(path));
        }
        return;
      }
      setState(() => _ownResult = result);
    });
  }

  @override
  void dispose() {
    _noteController.dispose();
    // Every close path other than Send abandons the screenshot: the title-bar X,
    // a scrim tap, and the unavailable / limit-reached branches all just unmount
    // this dialog without running any of its callbacks. Nothing else would ever
    // remove the file on web, where the startup temp sweep cannot run until the
    // tab is reloaded -- so a full frame of the user's screen share would sit in
    // OPFS indefinitely.
    _abandoned = true;
    final path = _screenshotPath;
    // A capture still in flight is left to the listener above, which deletes as
    // soon as the file exists; only an already-settled one is removed from here.
    if (!_handedOver && path != null && _capture == null) {
      unawaited(deleteTransientScreenshot(path));
    }
    super.dispose();
  }

  /// The close-only states, both drawn by the shared [ReportDialogNotice].
  Widget notice(String message) {
    return ReportDialogNotice(dialogTitle: "$tr_report_screen.dialog.title".tr(), message: message);
  }

  Widget screenshot(BuildContext context, ScreenshotResult? data) {
    if (data == null) {
      return const CircularProgressIndicator();
    }
    if (data.hasError) {
      return Center(child: NoteCard(description: Text("$tr_report_screen.dialog.screenshot_error".tr())));
    }
    return Center(child: RecordImage(data.path));
  }

  Widget ready(BuildContext context, {required int count, required int limit}) {
    final data = _ownResult;
    // ONE EXPRESSION FOR BOTH HALVES. It used to be written twice -- `data == null || data.hasError`
    // greyed the wrapper while the callback re-checked only `path == null` -- and the two did not
    // cover the same set: [ScreenshotResult] carries a path even when it failed, so the failed case
    // was greyed but still pressable. That was harmless for the pointer and not for the keyboard.
    final sendBlocked = data == null || data.hasError;
    // AND THE SENTENCE COMES OFF THAT SAME LOCAL. Whether there is a reason to show is `sendBlocked`
    // itself, not a second condition written beside it: a re-tested condition can drift and start
    // explaining a state the button is no longer in. Only the choice *between* the two sentences
    // still reads `data`, and it is exhaustive over the two disjuncts `sendBlocked` is made of --
    // pending is the `data == null` half, failed is the other.
    final sendBlockedTooltip = !sendBlocked
        ? null
        : data == null
        ? "$tr_report_screen.dialog.send_blocked.pending".tr()
        : "$tr_report_screen.dialog.send_blocked.failed".tr();
    return CardDialog(
      dialogTitle: "$tr_report_screen.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_common.dialog.close_button.tooltip".tr(),
      content: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Above the description rather than beside the Send button: the description explains
            // what the image is, and the user has to know it is leaving the machine before they
            // start reading it, not after they have already decided to send.
            const ReportUploadWarning(),
            const SizedBox(height: 16),
            Text("$tr_report_screen.dialog.description".tr()),
            const SizedBox(height: 16),
            screenshot(context, data),
            const SizedBox(height: 16),
            Text("$tr_report_common.dialog.note".tr()),
            const SizedBox(height: 4),
            TextFormField(controller: _noteController),
            if (limit - count <= 10) ...[
              const SizedBox(height: 16),
              Text("${"$tr_report_common.dialog.available_count".tr()} (${limit - count} / $limit)"),
            ],
            // The buttons scroll with the content instead of sitting in a fixed
            // footer: reporters were submitting straight from the always-visible
            // footer without ever noticing the free-text note field below the
            // image. Reaching Send now means scrolling past it.
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Tooltip(
                  message: "$tr_report_common.dialog.cancel_button.tooltip".tr(),
                  child: OutlinedButton.icon(
                    icon: const Icon(Symbols.cancel_rounded),
                    label: Text("$tr_report_common.dialog.cancel_button.label".tr()),
                    // Cancelling only closes the dialog: dispose() removes the transient screenshot on
                    // every abandon path, so this one needs no cleanup of its own.
                    onPressed: () => CardDialog.dismiss(ref.base),
                  ),
                ),
                const SizedBox(width: 8),
                Disabled(
                  // Null covers both "this dialog's own shot has not landed yet" and "only a
                  // concurrent attempt's shot is in the slot"; either way there is nothing of
                  // ours to send. Also blocked while the screenshot failed: the preview above is
                  // showing the screenshot_error card, and its path holds no file, so sending
                  // would attach nothing (ScopeExtension.addFile skips a missing file) and report
                  // an image-less event.
                  disabled: sendBlocked,
                  // The reason, and not the generic "what this button does" line below it: the inner
                  // [Tooltip] sits under `Disabled`'s `IgnorePointer`, which refuses hover as well
                  // as taps, so it goes silent for exactly as long as Send is blocked. Pointing at a
                  // greyed Send used to produce nothing at all -- the explanation was withheld in
                  // the one state that needed explaining.
                  tooltip: sendBlockedTooltip,
                  child: Tooltip(
                    message: "$tr_report_common.dialog.ok_button.tooltip".tr(),
                    child: FilledButton.icon(
                      icon: const Icon(Symbols.check_circle_rounded),
                      label: Text("$tr_report_common.dialog.ok_button.label".tr()),
                      onPressed: sendBlocked
                          ? null
                          : () {
                              // Deliberately the latched [_ownResult] rather than the global slot:
                              // sending a concurrent attempt's shot would upload a foreign screen
                              // frame and, by setting _handedOver below, also strand this dialog's
                              // own file -- nothing would ever delete it. `sendBlocked` is a local
                              // holding `data == null || …`, so flow analysis promotes `data` here
                              // and the branch that used to re-check it by hand is gone.
                              //
                              // captureScreen owns the file from here on (it deletes it on every
                              // send outcome), so dispose() must not race its attachment upload.
                              _handedOver = true;
                              captureScreen(_noteController.text, data.path);
                              CardDialog.dismiss(ref.base);
                            },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Nothing here reads latestScreenshotProvider: the preview and Send use the
    // latched [_ownResult], and the path dispose() cleans up comes from the
    // request itself, so no build-time state feeds the cleanup.
    return FutureBuilder<SentryRateLimit?>(
      future: _rateLimitFuture,
      builder: (BuildContext context, AsyncSnapshot<SentryRateLimit?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const ReportDialogLoading();
        }
        final rateLimit = snapshot.data;
        if (rateLimit == null) {
          logger.e("Failed to retrieve rate limit config", snapshot.error, snapshot.stackTrace);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            CardDialog.dismiss(ref.base);
            Toaster.show(ToastData.error(description: "$tr_report_common.dialog.loading_error".tr()));
          });
          return Container();
        }
        final count = getSentryReportCount();
        logger.i("Rate Limit: available=${rateLimit.available}, limit=${rateLimit.rateLimitPerMonth}, count=$count");
        if (!rateLimit.available) {
          return notice("$tr_report_common.dialog.unavailable".tr());
        }
        if (count >= rateLimit.rateLimitPerMonth) {
          return notice("$tr_report_common.dialog.limit_reached".tr());
        }
        return ready(context, count: count, limit: rateLimit.rateLimitPerMonth);
      },
    );
  }
}
