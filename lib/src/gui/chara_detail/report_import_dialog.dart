import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/video_frame_grab.dart';
import '/src/core/video_frame_grab_ops.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/report_common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_report_import = "pages.chara_detail.report_import";

/// What the user assembled: **one PNG frame of a clip they chose, and their note.**
///
/// The dialog hands this to its caller and stops owning [png] at that moment, exactly as
/// [ReportScreenDialog] hands its screenshot to `captureScreen`. Whoever receives it owns the file
/// and must delete it on every outcome — the frame is a full picture of the user's game screen, and
/// on web nothing sweeps the temp directory until the tab is reloaded.
///
/// [frame] and [timeline] travel with it because a report that says "the frame at T" has to quote
/// [GrabbedVideoFrame.mediaTsMs] rather than the time that was requested: the two differ by up to
/// one frame interval by construction (see `video_frame_grab_ops.dart`). Reconstructing them at the
/// send site would mean grabbing the frame a second time.
@immutable
class ImportErrorReport {
  const ImportErrorReport({
    required this.png,
    required this.note,
    required this.clipName,
    required this.frame,
    required this.timeline,
  });

  /// The PNG the report attaches. **Owned by the receiver from the moment this is handed over.**
  final FilePath png;

  /// The user's free-text note. Empty when they wrote none.
  final String note;

  /// The chosen clip's file name — its *leaf*, never its directory, which is a path on the user's
  /// machine and not something a bug report needs.
  ///
  /// **Used to decide which import this report belongs to, and never sent.** It is the first check
  /// in `resolveImportReportCorrelation`, and what reaches Sentry in its place is the clip's
  /// container and measured attributes (`buildImportErrorReportScope`, `reportClipContainer`) —
  /// a file name is written by the user and can name a person, an employer or a case.
  final String clipName;

  /// Which frame this actually is, as the producer reported it.
  final GrabbedVideoFrame frame;

  /// The clip's time axis, as the probe reported it.
  final VideoFrameTimeline timeline;
}

/// One clip, and everything this dialog asks of it.
///
/// **An interface rather than the facade's `VideoFrameSource` plus its two free functions**, and the
/// reason is structural rather than stylistic. `video_frame_grab.dart` is a conditional export whose
/// `VideoFrameSource` is a *different class* on every leg — `forPath` on io, `forFile` on web,
/// `unsupported` on the default one — because what a clip IS differs by platform. The analyzer
/// resolves an unadorned import of that export to the default leg while `flutter test` runs the io
/// one, so a seam typed with that class can be analyzable or runnable from a test but not both
/// (measured: `VideoFrameSource.forPath` is `undefined_method` under `dart analyze` and the only
/// constructor that exists under `flutter test`). Bundling the operations behind the handle keeps
/// the platform type inside the leg that defines it, and lets a test supply a whole clip rather than
/// forge one.
abstract class ClipFrameSource {
  /// The clip's file name, for the dialog's own label and for deciding which import this report
  /// belongs to. Its *leaf*, never its directory — and it does not travel with the report itself
  /// (see [ImportErrorReport.clipName]).
  String get name;

  /// The clip's time axis. See [VideoFrameTimeline]; slow enough that it is asked once per clip.
  Future<VideoFrameTimeline> probe();

  /// Writes the frame displayed at [timeMs] to [destination] as a PNG.
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination});
}

/// Opens this front end's clip dialog, or returns null when the user dismissed it.
///
/// The same dialog and the same container list the video import opens, which is what keeps a clip
/// the import accepted from being one this report cannot re-open.
Future<ClipFrameSource?> pickClipFrameSource() async {
  final source = await pickVideoFrameSource();
  return source == null ? null : _PlatformClipFrameSource(source);
}

/// The real clip: the facade's handle, and its two operations bound to it.
class _PlatformClipFrameSource implements ClipFrameSource {
  const _PlatformClipFrameSource(this._source);

  final VideoFrameSource _source;

  @override
  String get name => _source.name;

  @override
  Future<VideoFrameTimeline> probe() => probeVideoFrames(_source);

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) =>
      grabVideoFrame(source: _source, timeMs: timeMs, destination: destination);
}

/// [timeMs] as a clock reading, `m:ss.mmm` (or `h:mm:ss.mmm` past an hour).
///
/// **A time, never a frame ordinal**, and that is measured rather than stylistic: a container's
/// frame count is not merely absent but *wrong* on this app's own recordings (426 reported against
/// 376 decoded), so a frame number shown here would be a number neither side can honour. See the
/// library comment in `video_frame_grab_ops.dart`.
String formatClipTimestamp(int timeMs) {
  final clamped = timeMs < 0 ? 0 : timeMs;
  final millis = clamped % 1000;
  final totalSeconds = clamped ~/ 1000;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  final tail = '${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  if (hours == 0) {
    return '$minutes:$tail';
  }
  return '$hours:${minutes.toString().padLeft(2, '0')}:$tail';
}

/// One press of a frame-step button: the neighbour of the frame currently previewed.
///
/// **Two members and nothing else, because there are exactly two neighbours** — and they are not
/// reached the same way (see `_ReportImportDialogState._stepAction`): the previous frame is
/// derived from the landed time, the next one is a fact the producer stated. Carrying the
/// translation key and the icon on the member keeps the pair from being re-enumerated at every
/// place a button is drawn, where the next member added would be forgotten.
enum _FrameStep {
  previous('previous_frame_button', Symbols.skip_previous_rounded),
  next('next_frame_button', Symbols.skip_next_rounded);

  const _FrameStep(this.buttonKey, this.icon);

  /// Both the localisation sub-key and the widget key, so a test names the same thing the user sees.
  final String buttonKey;
  final IconData icon;
}

/// What one press of a frame-step button would do — and, when it would do nothing, **why not**.
///
/// **A union rather than a nullable time, because "no target" had two causes and only one of them
/// was ever said out loud.** "This clip has no frame that way" and "there is no frame on screen to
/// step from at all" are both an absent target, so a button disabled by the first condition and
/// explained by a sentence chosen beside it told the user the clip had ended while the very first
/// grab was still running — a statement about a frame that was not on screen. Naming the two
/// refusals apart makes the cause a *value* rather than something the button has to re-derive, and
/// the switches over it are exhaustive, so a third reason added later cannot quietly borrow one of
/// these sentences.
sealed class _StepAction {
  const _StepAction();
}

/// There is a frame that way, and [timeMs] is the time to ask the producer for.
final class _StepTarget extends _StepAction {
  const _StepTarget(this.timeMs);

  final int timeMs;
}

/// **Nothing is on screen to step from**: no frame has been decoded yet, or the one that was showing
/// went away when a grab failed. Neither neighbour is defined here, and neither is any claim about
/// where the clip ends — the preview beside the buttons is the spinner or the failure card, and is
/// what says which of the two this is.
final class _StepNoFrame extends _StepAction {
  const _StepNoFrame();
}

/// A frame is on screen and this clip has none on that side of it: an end of the clip, as the
/// producer measured it rather than as a duration or a frame rate implies it.
final class _StepNoNeighbour extends _StepAction {
  const _StepNoNeighbour();
}

/// The video-import counterpart of [ReportScreenDialog]: **pick a clip, pick a time, write a note.**
///
/// It exists as its own dialog rather than as a mode of the screen report because of the one thing
/// that makes it more than a copy: with a live capture the user shows the screen they mean and
/// presses the button, and with a clip they cannot — so *choosing the frame* is the flow, and
/// everything else here is in service of it.
///
/// **The clip is always asked for.** There is no "the clip you just imported" default, so no video
/// handle or path has to be retained anywhere between an import and a report.
class ReportImportDialog extends ConsumerStatefulWidget {
  /// How the monthly report quota is fetched. Same seam, same reason as [ReportScreenDialog]'s: the
  /// real loader issues a Dio request whose timeout timer a widget test reports as a pending timer.
  @visibleForTesting
  final Future<SentryRateLimit?> Function() rateLimitLoader;

  /// Whether this front end can pull a frame out of a clip.
  ///
  /// Injectable for the reason `CaptureControlGroup.importAvailable` is: the real value resolves
  /// through a conditional export that answers `Platform.isWindows` under `flutter test`, so without
  /// this seam which branch a test sees would depend on the host running the suite.
  @visibleForTesting
  final bool? grabAvailable;

  /// How a clip is obtained. One seam rather than three, because the picker and the two operations
  /// are one collaborator: a test that replaced only the picker would still reach a real decoder
  /// with a path that does not exist. The real one opens a native modal dialog and waits for a
  /// human, so no test may drive the default.
  @visibleForTesting
  final Future<ClipFrameSource?> Function() picker;

  /// Where the finished report goes. The dialog owns the PNG until this is called and never
  /// afterwards — see [ImportErrorReport].
  final void Function(ImportErrorReport report) onSubmit;

  const ReportImportDialog({
    super.key,
    required this.onSubmit,
    this.rateLimitLoader = SentryRateLimit.download,
    this.grabAvailable,
    this.picker = pickClipFrameSource,
  });

  /// Opens the dialog. [onSubmit] receives the frame and the note the user settled on.
  static void show(RefBase ref, {required void Function(ImportErrorReport report) onSubmit}) {
    CardDialog.show(ref, (_) => ReportImportDialog(onSubmit: onSubmit));
  }

  @override
  ConsumerState<ReportImportDialog> createState() => _ReportImportDialogState();
}

class _ReportImportDialogState extends ConsumerState<ReportImportDialog> {
  /// How long the time selector waits after the last movement before it grabs.
  ///
  /// **A grab costs 60-450 ms** (measured on Windows, `video_frame_grabber.h`), so a control that
  /// issued one per slider position would spend a drag queueing work the user has already scrolled
  /// past. 250 ms is comfortably longer than the ~16 ms a dragging pointer emits at, so a continuous
  /// drag issues nothing at all, and short enough that letting go feels like it answered: the worst
  /// case a user waits is this plus one grab, under a second. It is deliberately *not* tied to the
  /// grab's own duration — the two are unrelated, and the in-flight guard below is what keeps a slow
  /// decoder from queueing.
  static const _debounce = Duration(milliseconds: 250);

  /// What one frame-step button occupies on the control line.
  ///
  /// The Material minimum tap target, which is what [IconButton]'s default constraints pin its box
  /// to, and it does **not** grow with the text scale (no text is in it). A number that was too
  /// small here would show up as an overflowing line rather than as a wrong-looking one, which is
  /// why `report_import_layout_test.dart` sweeps widths at two text scales instead of asserting
  /// this constant.
  static const _stepButtonExtent = kMinInteractiveDimension;

  /// How short the slider track may get before the line is split in two.
  ///
  /// Below roughly this the track is too short to aim a long clip with — a 12-minute clip on 100 px
  /// is 7 seconds per pixel — and the frame-step buttons, which need no width at all, are the
  /// control that still works there. So the slider is what the split gives the room to.
  static const _minSliderWidth = 120.0;

  final TextEditingController _noteController = TextEditingController();
  late final Future<SentryRateLimit?> _rateLimitFuture = widget.rateLimitLoader();

  Timer? _debounceTimer;

  /// The clip the user chose, and its axis. Null until they choose one; [_timeline] is null while
  /// the probe is still running.
  ClipFrameSource? _source;
  VideoFrameTimeline? _timeline;

  /// True while the file dialog or the probe is in flight, so neither can be started twice.
  bool _opening = false;

  /// The producer's own sentence for the failure that is currently on screen, or null.
  ///
  /// **English, and rendered as detail beside a localised line.** The statuses are defined in C++
  /// (`video::describe`) and in the worker, and a Dart-side translation table would be a second list
  /// that stops matching the first the next time a cause is added.
  String? _openError;
  String? _grabError;

  /// The time the selector is on. Always inside `[firstFrameMs, durationMs)`.
  int _selectedMs = 0;

  /// The frame currently previewed, and the PNG behind it. Null until the first grab lands.
  GrabbedVideoFrame? _grabbed;

  /// True while a grab is running, and the time asked for while one was.
  ///
  /// Only ever one grab in flight, with the *latest* requested time queued behind it: a dragged
  /// slider must not be able to put an unbounded number of decodes on the producer's single worker,
  /// and coalescing to the newest time is also what makes a stale reply impossible — there is never
  /// more than one reply outstanding, so what lands is always what was asked for last.
  bool _grabbing = false;
  int? _queuedMs;

  /// Frame-step presses waiting their turn, oldest first.
  ///
  /// **Counted rather than coalesced, and that is the difference between the two controls.** The
  /// slider keeps only its newest position because the older ones name places the user has already
  /// scrolled past. A step names no place at all until the previous step has landed — the time to
  /// ask for next is read off the reply that is still in flight ([GrabbedVideoFrame.nextMediaTsMs])
  /// — so collapsing presses the way [_queuedMs] does would silently perform one step for three
  /// presses. Three presses are three frames and three decodes, in the order they were pressed.
  final List<_FrameStep> _pendingSteps = <_FrameStep>[];

  /// Set once the report has been handed to [ReportImportDialog.onSubmit], which owns the PNG from
  /// then on. Without it [dispose] would delete the file out from under the send.
  bool _handedOver = false;

  bool get _available => widget.grabAvailable ?? videoFrameGrabAvailable;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _noteController.dispose();
    // Every close path other than Send abandons the frame: the title-bar X, a scrim tap and the
    // unavailable / limit-reached branches all just unmount this dialog without running any of its
    // callbacks. The file is a full picture of the user's game screen, and on web nothing sweeps
    // the temp directory until the tab is reloaded.
    final png = _grabbed?.png;
    if (!_handedOver && png != null) {
      unawaited(deleteTransientScreenshot(png));
    }
    super.dispose();
  }

  /// A fresh destination for every grab.
  ///
  /// Unique per call rather than one reused name, for the reason `takeScreenshot` states: both the
  /// desktop `ImageCache` and web's byte LRU are keyed by path, so reusing a name would show the
  /// previous frame for the new time — the "wrong frame" outcome, in the preview the user checks
  /// the frame with.
  FilePath _newDestination() {
    return ref.read(pathInfoProvider).tempDir.filePath("video_frame_${DateTime.now().microsecondsSinceEpoch}.png");
  }

  /// Opens the clip dialog, probes what the user chose, and previews its first frame.
  ///
  /// **One clip per dialog.** There is no control that swaps the clip once one is chosen, because
  /// closing this dialog and opening it again already asks for a file — and that path resets
  /// everything by construction, where a swap in place has to remember to drop the previewed frame,
  /// the probe, and both failure lines. The guard below is the rule itself rather than a
  /// consequence of which buttons happen to be mounted.
  Future<void> _pickClip() async {
    if (_opening || _source != null) {
      return;
    }
    setState(() => _opening = true);
    try {
      final source = await widget.picker();
      if (!mounted) {
        return;
      }
      if (source == null) {
        // Cancelled: no clip was chosen, so the dialog stays where it was — still offering to pick
        // one. This is the only way back to the picker, and the only one that needs to exist.
        setState(() => _opening = false);
        return;
      }
      setState(() => _source = source);
      final timeline = await source.probe();
      if (!mounted) {
        return;
      }
      setState(() {
        _timeline = timeline;
        _selectedMs = timeline.selectableStartMs;
        _opening = false;
      });
      if (timeline.hasMediaTimeline && timeline.lastSelectableMs != null) {
        // Straight away, without the debounce: nothing is being dragged, and a dialog that showed an
        // empty frame until the user touched the slider would read as one that failed to open it.
        unawaited(_startGrab(timeline.selectableStartMs));
      }
    } on VideoFrameGrabException catch (error) {
      if (mounted) {
        setState(() {
          _openError = error.message;
          _opening = false;
        });
      }
    } catch (error, stackTrace) {
      // The seams above are `Future`s returned into a callback, so an unforeseen error type would
      // otherwise become an unhandled zone error and the user would be shown nothing at all.
      logger.e('Unexpected failure while opening a clip for the import report', error, stackTrace);
      if (mounted) {
        setState(() {
          _openError = '$error';
          _opening = false;
        });
      }
    }
  }

  /// Drops the previewed frame and deletes its file. Called before every state that replaces it.
  void _discardFrame() {
    final png = _grabbed?.png;
    if (png != null && !_handedOver) {
      unawaited(deleteTransientScreenshot(png));
    }
    _grabbed = null;
  }

  /// The selector moved. Only the *last* position within [_debounce] is asked for.
  void _onTimeChanged(double value) {
    final timeline = _timeline;
    if (timeline == null) {
      return;
    }
    final timeMs = timeline.clampToSelectable(value.round());
    setState(() => _selectedMs = timeMs);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => unawaited(_requestGrab(timeMs)));
  }

  /// One press of [step]: the time it would grab, or the sentence that says why it would not.
  ///
  /// **This one expression decides the action, whether the button is offered at all, and what its
  /// tooltip says**, so what a press does, what its enabled state promises and how that state is
  /// explained cannot drift apart. Every input to it is something a producer measured: nothing here
  /// consults [VideoFrameTimeline.fps] or [VideoFrameTimeline.durationMs], which are an average and
  /// container metadata.
  _StepAction _stepAction(_FrameStep step) {
    final grabbed = _grabbed;
    final timeline = _timeline;
    if (grabbed == null || timeline == null) {
      // NO FRAME IS ON SCREEN, so neither neighbour is defined — and neither is any claim about the
      // ends of the clip. This is the state before the first grab lands and the state a failed grab
      // leaves behind, and in both of them "there is nothing beyond this" would be an assertion
      // about a frame the user cannot see. Which of the two it is, and why, is said by the preview
      // beside the buttons: the spinner or the failure card carrying the producer's own sentence.
      return const _StepNoFrame();
    }
    switch (step) {
      case _FrameStep.previous:
        // Exactly "the frame before the one on screen": on an integer-millisecond wire under the
        // `<=` contract, the last frame at or before `M - 1` is the last frame strictly before `M`.
        // A derivation, not an epsilon and not a frame interval — see the library comment in
        // `video_frame_grab_ops.dart`, which is also why no `prevMediaTsMs` exists to read instead.
        return grabbed.mediaTsMs > timeline.firstFrameMs
            ? _StepTarget(grabbed.mediaTsMs - 1)
            : const _StepNoNeighbour();
      case _FrameStep.next:
        // Stated by the producer or not at all. Null is "the pass that decoded this frame found no
        // frame after it", which is a measurement; the alternatives — `durationMs` and an fps model
        // — are the numbers this whole API refuses to identify frames by.
        //
        // BOTH front ends state it — `windows/runner/video_frame_grab_service.h` off the frame its
        // forward pass had already decoded, `web/worker.js` off the second sample mediabunny yields
        // — so this button is not a Windows-only capability and the disabled sentence means the same
        // thing on both.
        //
        // Not clamped to the selectable range: the range's upper end comes from `durationMs`, and a
        // decoded stamp that lies past it is evidence the container's duration is short, not
        // evidence the frame is absent. Clamping would aim the step back at the frame already on
        // screen, i.e. a button that visibly does nothing.
        final next = grabbed.nextMediaTsMs;
        return next == null ? const _StepNoNeighbour() : _StepTarget(next);
    }
  }

  /// A frame-step button was pressed.
  void _onStepPressed(_FrameStep step) {
    _pendingSteps.add(step);
    final timer = _debounceTimer;
    if (timer != null && timer.isActive) {
      // A slider position chosen just before the press is a newer intent than the frame on screen,
      // and the press is newer still. Flushing it now rather than cancelling it keeps the step
      // relative to the frame the user was aiming at, and keeps both actions.
      timer.cancel();
      unawaited(_requestGrab(_selectedMs));
      return;
    }
    if (!_grabbing) {
      unawaited(_drainSteps());
    }
  }

  /// Issues the oldest pending step. Called again from [_startGrab] once that one has landed.
  Future<void> _drainSteps() async {
    if (_pendingSteps.isEmpty) {
      return;
    }
    final action = _stepAction(_pendingSteps.removeAt(0));
    final target = switch (action) {
      _StepTarget(:final timeMs) => timeMs,
      _StepNoFrame() || _StepNoNeighbour() => null,
    };
    if (target == null) {
      // The clip ran out — or the grab failed — under presses that were made while there was still
      // somewhere to go. The rest are dropped rather than retried: they were aimed at neighbours of
      // a frame that is no longer on screen, and the buttons now carry, disabled, the sentence for
      // whichever of the two it was.
      _pendingSteps.clear();
      return;
    }
    await _startGrab(target);
  }

  Future<void> _requestGrab(int timeMs) async {
    if (_grabbing) {
      _queuedMs = timeMs; // Coalesced: the newest time wins, and the running grab finishes first.
      return;
    }
    await _startGrab(timeMs);
  }

  Future<void> _startGrab(int timeMs) async {
    final source = _source;
    if (source == null) {
      return;
    }
    _grabbing = true;
    setState(() => _grabError = null);
    final destination = _newDestination();
    try {
      final grabbed = await source.grab(timeMs: timeMs, destination: destination);
      if (!mounted) {
        // The dialog is gone and dispose() has already cleaned up whatever it knew about, so this
        // file has no other owner.
        unawaited(deleteTransientScreenshot(destination));
        return;
      }
      // Decoded BEFORE it is published, so the swap the user sees is one frame's worth of work:
      // publishing a path nothing has decoded yet makes `Image` drop the frame it is showing and
      // lay out at zero height until the read and decode land, which jumps everything under the
      // preview up by the whole height of the frame and back. The alternative — `gaplessPlayback`
      // — removes the jump by leaving the OLD pixels up, which is worse here than the jump: this
      // preview exists to be checked against the frame time printed directly beneath it, so a
      // stale image under a new time is the one failure it must not have. Waiting here keeps the
      // image and its caption changing in the same frame, and while the wait runs it is the
      // previous frame *and* the previous caption on screen, which agree with each other.
      await RecordImage.preload(grabbed.png, context);
      if (!mounted) {
        unawaited(deleteTransientScreenshot(destination));
        return;
      }
      _discardFrame();
      setState(() {
        _grabbed = grabbed;
        _followLandedFrame(grabbed);
      });
    } on VideoFrameGrabException catch (error) {
      unawaited(deleteTransientScreenshot(destination));
      if (mounted) {
        setState(() {
          _discardFrame();
          _grabError = error.message;
        });
      }
    } catch (error, stackTrace) {
      logger.e('Unexpected failure while grabbing a frame for the import report', error, stackTrace);
      unawaited(deleteTransientScreenshot(destination));
      if (mounted) {
        setState(() {
          _discardFrame();
          _grabError = '$error';
        });
      }
    } finally {
      _grabbing = false;
      final queued = _queuedMs;
      _queuedMs = null;
      if (queued != null && mounted) {
        // The slider's newest position first: it was chosen before the steps waiting behind it, and
        // a step means "one frame on from where I am", so it has to start from where the user aimed.
        unawaited(_startGrab(queued));
      } else if (mounted) {
        unawaited(_drainSteps());
      }
    }
  }

  /// Moves the time selector onto the frame that actually landed.
  ///
  /// **Without this the slider and the step buttons are two controls addressing different things**:
  /// a step moves the previewed frame without touching [_selectedMs], so the thumb would stay where
  /// the user last dragged it while the preview walked away from it, and the label above the slider
  /// would name a time no longer being looked at.
  ///
  /// Skipped while a newer position is already on its way, because there the user is the one moving
  /// the slider and pulling the thumb back onto a frame they have already scrolled past would fight
  /// their drag. Only [_selectedMs] is involved either way — the caption under the preview always
  /// quotes the landed frame, so nothing here can make the image and its caption disagree.
  void _followLandedFrame(GrabbedVideoFrame grabbed) {
    final timeline = _timeline;
    if (timeline == null) {
      return;
    }
    final timer = _debounceTimer;
    if (_queuedMs != null || (timer != null && timer.isActive)) {
      return;
    }
    _selectedMs = timeline.clampToSelectable(grabbed.mediaTsMs);
  }

  void _submit() {
    final grabbed = _grabbed;
    final source = _source;
    final timeline = _timeline;
    if (grabbed == null || source == null || timeline == null) {
      return;
    }
    // The receiver owns the PNG from here on, so dispose() must not race it.
    _handedOver = true;
    widget.onSubmit(
      ImportErrorReport(
        png: grabbed.png,
        note: _noteController.text,
        clipName: source.name,
        frame: grabbed,
        timeline: timeline,
      ),
    );
    CardDialog.dismiss(ref.base);
  }

  /// The close-only states, all drawn by the shared [ReportDialogNotice].
  Widget _notice(String message) {
    return ReportDialogNotice(dialogTitle: "$tr_report_import.dialog.title".tr(), message: message);
  }

  /// A localised sentence with the producer's own English one underneath it.
  ///
  /// The two lines are not interchangeable: the first is what the user can act on, the second is
  /// what the developer needs and is the only thing that names the actual cause. Neither is dropped,
  /// and the English one is visibly *detail* — a quieter scale, under a label — so it does not read
  /// as the app talking to the user in the wrong language.
  Widget _failure(BuildContext context, String message, String detail) {
    final theme = Theme.of(context);
    return NoteCard(
      color: theme.colorScheme.error,
      description: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          const SizedBox(height: 8),
          Text(
            "$tr_report_import.dialog.detail_label".tr(),
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          SelectableText(detail, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _clipRow(BuildContext context) {
    final source = _source;
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: source == null
              ? Text("$tr_report_import.dialog.no_clip".tr())
              : Tooltip(
                  message: source.name,
                  child: StartEllipsisText(source.name, style: theme.textTheme.bodyMedium),
                ),
        ),
        // Offered only while no clip has been chosen. Swapping the clip in place was removed: the
        // dialog asks for a file every time it opens, so closing and reopening is the way to report
        // on a different clip, and it is one the user already has.
        if (source == null) ...[
          const SizedBox(width: 8),
          Disabled(
            disabled: _opening,
            child: OutlinedButton.icon(
              icon: const Icon(Symbols.video_file_rounded, size: 20),
              label: Text("$tr_report_import.dialog.pick_button.label".tr()),
              onPressed: () => unawaited(_pickClip()),
            ),
          ),
        ],
      ],
    );
  }

  /// The time selector and the frame it selected — the half of this dialog that has no counterpart
  /// in the screen report.
  Widget _selector(BuildContext context, VideoFrameTimeline timeline) {
    final last = timeline.lastSelectableMs;
    if (!timeline.hasMediaTimeline) {
      // Refused rather than offered: a clip whose frames carry no advancing media time answers every
      // T with the same arbitrary frame, so a selector over it would look like it worked.
      return _failure(
        context,
        "$tr_report_import.dialog.no_timeline".tr(),
        'the clip carries no advancing media timeline',
      );
    }
    if (last == null) {
      // Indeterminate duration: the range has no upper end, so there is no honest slider to draw.
      return _failure(
        context,
        "$tr_report_import.dialog.no_duration".tr(),
        'the container states no duration, so the selectable range has no upper end',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _controls(context, timeline, last: last),
        const SizedBox(height: 8),
        _preview(context),
      ],
    );
  }

  /// The clip's whole time control: **slider, frame-step buttons, and the time on one line.**
  ///
  /// One group over one fact. The reading at the end is the time of the frame that actually landed
  /// ([GrabbedVideoFrame.mediaTsMs]) and it is now the **only** place this dialog prints a time: the
  /// slider's thumb and that caption named the same thing except while a grab was in flight, so a
  /// second printed copy could only ever be the one that was wrong. Where the user is aiming
  /// mid-drag is still shown — by the slider's own value indicator, which exists only while the
  /// pointer is down and disappears with it.
  Widget _controls(BuildContext context, VideoFrameTimeline timeline, {required int last}) {
    final theme = Theme.of(context);
    final start = timeline.selectableStartMs;
    final captionStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final grabbed = _grabbed;
    // THE TIME THAT IS ACTUALLY BEING REPORTED, which is at or before the one asked for: the frame
    // displayed at T is the last frame stamped at or before T, so the two differ by up to one frame
    // interval by construction. Stating the requested time here instead would put a number on
    // screen — and in the report — that names a frame nobody ever saw.
    final captionText = grabbed == null ? null : _frameTimeSentence(grabbed.mediaTsMs);
    // A one-frame clip has nothing to choose between, and Slider requires min < max.
    final slider = last > start
        ? Slider(
            key: const ValueKey("report_import_time_slider"),
            min: start.toDouble(),
            max: last.toDouble(),
            value: _selectedMs.toDouble().clamp(start.toDouble(), last.toDouble()),
            label: formatClipTimestamp(_selectedMs),
            onChanged: _onTimeChanged,
          )
        : null;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final caption = captionText == null ? null : Text(captionText, style: captionStyle);
        // The buttons and the reading are what a line has to carry before the slider gets anything;
        // measured rather than assumed for the reading, because it is the part that grows with the
        // text scale (the buttons are pinned to the Material tap target).
        final tail =
            _stepButtonExtent * _FrameStep.values.length +
            (captionText == null ? 0 : _captionWidth(context, timeline, captionText, captionStyle));
        final oneLine = slider == null || constraints.maxWidth - tail >= _minSliderWidth;
        final trailing = <Widget>[
          for (final step in _FrameStep.values) _stepButton(step),
          if (caption != null) Flexible(child: caption),
        ];
        if (oneLine) {
          return Row(
            children: [
              if (slider != null) Expanded(child: slider),
              ...trailing,
            ],
          );
        }
        // Too narrow (a small window, or a large text scale) for one line: the slider keeps the
        // full width and the buttons and the reading move under it, in the same left-to-right order
        // they have when they fit. Nothing is dropped and nothing is truncated.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            slider,
            Row(children: trailing),
          ],
        );
      },
    );
  }

  /// The one sentence this dialog uses to state a time.
  String _frameTimeSentence(int timeMs) =>
      "$tr_report_import.dialog.frame_time".tr(namedArgs: {'time': formatClipTimestamp(timeMs)});

  /// How wide the time reading can get on this clip, in the text scale in force.
  ///
  /// The widest of the reading currently shown and the one this clip's *end* produces, so that
  /// scrubbing past a minute or an hour boundary cannot re-wrap the line under the user's pointer:
  /// which layout is drawn is then a property of the clip and the text scale, not of where the
  /// thumb happens to be.
  double _captionWidth(BuildContext context, VideoFrameTimeline timeline, String shown, TextStyle? style) {
    final atEnd = _frameTimeSentence(timeline.lastSelectableMs ?? timeline.selectableStartMs);
    final scaler = MediaQuery.textScalerOf(context);
    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final shownWidth = widthOf(shown);
    final endWidth = widthOf(atEnd);
    return shownWidth > endWidth ? shownWidth : endWidth;
  }

  /// One frame-step button: **it moves by one frame, and it never says which one.**
  ///
  /// No ordinal is printed here or anywhere else in this dialog, and the reason is measured rather
  /// than stylistic: a container's frame count is not merely missing but *wrong* on this app's own
  /// recordings (426 stated against 376 decoded, 1344 against 1258), so a number counted from it
  /// would be one neither side can honour. The frame the user is on is stated as a time, on the
  /// same line as these buttons, by the producer that grabbed it.
  ///
  /// Disabled by [_stepAction] refusing — i.e. by what the decoder said about *this* frame, never by
  /// a frame-rate model — and when it is disabled the tooltip is the reason it is, not the name of
  /// an action that would not happen.
  ///
  /// **The sentence is read off the refusal itself** rather than chosen by a second condition here:
  /// the two causes of a refusal are two different sentences, and a `disabled_tooltip` picked merely
  /// because there was no target claimed the clip had ended in the state where nothing had been
  /// decoded yet.
  Widget _stepButton(_FrameStep step) {
    final action = _stepAction(step);
    // Which of THIS BUTTON's own two sentences applies — the step it would take, or the end of the
    // clip it has run into. Read off [action] like everything else here, never off a second look at
    // the dialog's state.
    final tooltip = action is _StepTarget ? 'tooltip' : 'disabled_tooltip';
    final message = switch (action) {
      // The third state belongs to no button: with nothing on screen to be a neighbour OF, both
      // sentences above would be describing a frame the user cannot see.
      _StepNoFrame() => "$tr_report_import.dialog.step_blocked.no_frame".tr(),
      _StepTarget() || _StepNoNeighbour() => "$tr_report_import.dialog.${step.buttonKey}.$tooltip".tr(),
    };
    return IconButton(
      key: ValueKey('report_import_${step.buttonKey}'),
      icon: Icon(step.icon),
      tooltip: message,
      // A real disabled button rather than an ignored one, so the theme dims it and a screen reader
      // reports it as unavailable. The press itself is never dropped when it is offered: see
      // [_pendingSteps].
      onPressed: switch (action) {
        _StepTarget() => () => _onStepPressed(step),
        _StepNoFrame() || _StepNoNeighbour() => null,
      },
    );
  }

  Widget _preview(BuildContext context) {
    final error = _grabError;
    if (error != null) {
      return _failure(context, "$tr_report_import.dialog.grab_error".tr(), error);
    }
    final grabbed = _grabbed;
    if (grabbed == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // `preloaded` because `_startGrab` awaited `RecordImage.preload` for exactly this path before
    // publishing it: it lets the web leg read the bytes it already holds synchronously, instead of
    // spending one more frame inside a FutureBuilder showing nothing.
    //
    // The frame's time is NOT printed here any more — it is stated once, on the control line above,
    // beside the two controls that move it. It still changes in the same pumped frame as this
    // image, because both are published by the one `setState` that follows the preload.
    return Center(child: RecordImage(grabbed.png, preloaded: true));
  }

  Widget _ready(BuildContext context, {required int count, required int limit}) {
    final timeline = _timeline;
    final openError = _openError;
    // ONE EXPRESSION FOR BOTH HALVES, as [ReportScreenDialog.ready] does: whether Send is withdrawn
    // and whether there is a reason to show are the same fact, so a second condition written beside
    // this one could drift and start explaining a state the button is no longer in.
    final sendBlocked = _grabbed == null;
    // The choice *between* the two sentences is the only thing that reads anything else, and it is
    // exhaustive over this dialog's two shapes of "no frame": before a clip has been chosen the
    // answer is a step the user can take, and after one has been the preview directly above is
    // already showing the spinner or the failure card that says which frame is missing and why.
    final sendBlockedTooltip = !sendBlocked
        ? null
        : _source == null
        ? "$tr_report_import.dialog.send_blocked.no_clip".tr()
        : "$tr_report_import.dialog.send_blocked.no_frame".tr();
    return CardDialog(
      dialogTitle: "$tr_report_import.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_common.dialog.close_button.tooltip".tr(),
      content: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // At the head of the dialog for the reason [ReportScreenDialog] states: the fact that
            // the chosen frame leaves the machine has to be met before the description, not after
            // the decision to send has already been made.
            const ReportUploadWarning(),
            const SizedBox(height: 16),
            Text("$tr_report_import.dialog.description".tr()),
            const SizedBox(height: 16),
            _clipRow(context),
            const SizedBox(height: 16),
            if (openError != null)
              _failure(context, "$tr_report_import.dialog.open_error".tr(), openError)
            else if (_opening)
              const Center(child: CircularProgressIndicator())
            else if (timeline != null)
              _selector(context, timeline),
            const SizedBox(height: 16),
            Text("$tr_report_common.dialog.note".tr()),
            const SizedBox(height: 4),
            TextFormField(controller: _noteController),
            if (limit - count <= 10) ...[
              const SizedBox(height: 16),
              Text("${"$tr_report_common.dialog.available_count".tr()} (${limit - count} / $limit)"),
            ],
            // The buttons scroll with the content rather than sitting in a fixed footer, for the
            // reason [ReportScreenDialog] states: reporters were submitting from an always-visible
            // footer without ever noticing the note field. Reaching Send means scrolling past it.
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
                    // Cancelling only closes the dialog: dispose() removes the frame on every
                    // abandon path, so this one needs no cleanup of its own.
                    label: Text("$tr_report_common.dialog.cancel_button.label".tr()),
                    onPressed: () => CardDialog.dismiss(ref.base),
                  ),
                ),
                const SizedBox(width: 8),
                Disabled(
                  // Null means no frame has landed: nothing has been chosen to send, and the preview
                  // above is either a spinner or the failure card.
                  disabled: sendBlocked,
                  // The reason, and not the generic "what this button does" line below it: the inner
                  // [Tooltip] sits under `Disabled`'s `IgnorePointer`, which refuses hover as well as
                  // taps, so it goes silent for exactly as long as Send is blocked. Pointing at a
                  // greyed Send used to produce nothing at all -- the explanation was withheld in the
                  // one state that needed explaining.
                  tooltip: sendBlockedTooltip,
                  child: Tooltip(
                    message: "$tr_report_common.dialog.ok_button.tooltip".tr(),
                    child: FilledButton.icon(
                      icon: const Icon(Symbols.check_circle_rounded),
                      label: Text("$tr_report_common.dialog.ok_button.label".tr()),
                      // Null on the same expression `Disabled` is given, as the sibling capture
                      // report does. `Disabled` already closes the pointer and the keyboard, so this
                      // is the semantics half: with a callback attached the button is still *read
                      // out* as available, and the one user who cannot see it greyed is the one told
                      // it can be pressed. The `_submit` guard below stays -- it is the invariant,
                      // not the affordance.
                      onPressed: sendBlocked ? null : _submit,
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
    if (!_available) {
      // Reached only by a caller that ignored [videoFrameGrabAvailable]; the capture card mounts no
      // button at all where there is no grabber. Stated rather than crashed, for the same reason
      // `video_frame_grab_io.dart`'s own guard exists.
      return _notice("$tr_report_import.dialog.unsupported".tr());
    }
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
        // The quota is checked BEFORE the clip is asked for, not at Send: the flow costs the user a
        // file dialog and several 60-450 ms grabs, and finding out afterwards that the month's
        // reports are used up would waste all of it.
        if (!rateLimit.available) {
          return _notice("$tr_report_common.dialog.unavailable".tr());
        }
        if (count >= rateLimit.rateLimitPerMonth) {
          return _notice("$tr_report_common.dialog.limit_reached".tr());
        }
        return _ready(context, count: count, limit: rateLimit.rateLimitPerMonth);
      },
    );
  }
}
