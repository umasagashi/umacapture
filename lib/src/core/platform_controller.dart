import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_channel.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/capture.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

final capturingStateProvider = Provider<bool>((ref) {
  return ref
      .watch(captureTriggeredEventProvider)
      .when(
        data: (data) => data,
        loading: () => false,
        error: (error, stack) {
          logger.e("error: $error, $stack");
          return false;
        },
      );
});

final capturingFrameSizeProvider = settableNotifierProvider<Size?>(null);

final capturingFrameRateProvider = settableNotifierProvider<double?>(null);

// Monotonic id so every sound-trigger event yields a distinct StreamProvider value. The sound
// listeners use ref.listen(), which skips equal consecutive AsyncData; without a changing payload a
// repeated event (same scroll index, same error message) would be deduplicated and play no sound
// (e.g. retrying a capture quickly, or opening/closing the same tab repeatedly).
int _soundEventSequence = 0;

final _errorEvent = EventStreamProvider<int>();
final errorEventProvider = _errorEvent.provider;

final _captureTriggeredEvent = EventStreamProvider<bool>();
final captureTriggeredEventProvider = _captureTriggeredEvent.provider;

final _scrollReadyEvent = EventStreamProvider<int>();
final scrollReadyEventProvider = _scrollReadyEvent.provider;

final _pageReadyEvent = EventStreamProvider<int>();
final pageReadyEventProvider = _pageReadyEvent.provider;

final _charaDetailRecordCapturedEvent = EventStreamProvider<String>();
final charaDetailRecordCapturedEventProvider = _charaDetailRecordCapturedEvent.provider;

class CharaDetailLink {
  String id;

  CharaDetailLink({required this.id});
}

/// A single, mutually exclusive capture status derived from [CharaDetailCaptureState].
///
/// The capture tab presents each status on two axes -- what is happening now and what the user
/// should do next -- so the UI must map every state to exactly one of these. Deriving them in one
/// place (rather than each widget re-deciding from the raw fields) keeps the shown messages from
/// contradicting one another.
enum CharaDetailCaptureStatus {
  /// Capturing, but no detail screen has been detected yet.
  waitingForDetail,

  /// Detail screen detected, nothing captured yet (safe to start or to switch characters).
  detailReady,

  /// Scroll capture in progress on at least one tab (not safe to switch until complete).
  capturing,

  /// Every tab captured; the record was saved.
  succeeded,

  /// The early duplicate probe suggests this character is likely already captured (a hint, not an error).
  duplicateHint,

  /// A completed capture was rejected because the character is already stored.
  alreadyCaptured,

  /// The capture failed (e.g. the detail screen was lost before completion).
  failed,
}

class CharaDetailCaptureState {
  /// Native tab index for the factor tab (skill=0, factor=1, campaign=2).
  static const int factorTabIndex = 1;

  bool isCapturing;

  double skillTabProgress;

  double factorTabProgress;

  double campaignTabProgress;

  /// Whether a chara-detail screen is currently open (set from the native started/restarted events).
  bool detailOpened;

  CharaDetailLink? link;
  String? error;

  /// The id of the existing record this capture duplicates, when a duplicate was detected
  /// (duplicated_character_probe / duplicated_character). Lets the UI focus that record in the table.
  String? duplicateRecordId;

  /// The tab currently displayed (skill=0, factor=1, campaign=2), from the native scroll-position event.
  int currentTab;

  /// Whether the current tab is at its scroll-top, from the native scroll-position event.
  ///
  /// This is the single authoritative scroll-position fact. Native reports it directly rather than the
  /// UI inferring it from capture-progress deltas, so "capturing" (scrolled) and "safe to switch" (factor
  /// tab at top) are both derived from it and can never disagree. A non-scrollable tab counts as at top.
  bool atTop;

  CharaDetailCaptureState({
    this.isCapturing = false,
    this.skillTabProgress = 0,
    this.factorTabProgress = 0,
    this.campaignTabProgress = 0,
    this.detailOpened = false,
    this.link,
    this.error,
    this.duplicateRecordId,
    this.currentTab = 0,
    this.atTop = true,
  });

  CharaDetailCaptureState clone() {
    return CharaDetailCaptureState(
      isCapturing: isCapturing,
      skillTabProgress: skillTabProgress,
      factorTabProgress: factorTabProgress,
      campaignTabProgress: campaignTabProgress,
      detailOpened: detailOpened,
      link: link,
      error: error,
      duplicateRecordId: duplicateRecordId,
      currentTab: currentTab,
      atTop: atTop,
    );
  }

  CharaDetailCaptureState reset() {
    return CharaDetailCaptureState();
  }

  CharaDetailCaptureState started() {
    final state = reset();
    state.detailOpened = true;
    return state;
  }

  CharaDetailCaptureState progress(int index, double progress) {
    final state = clone();
    state.isCapturing = true;
    // Progress is purely the ring value (how much of the tab has been captured). Scroll position -- whether
    // the tab is at its top -- is a separate fact reported by the native scroll-position event, so it is not
    // inferred from progress deltas here.
    switch (index) {
      case 0:
        state.skillTabProgress = progress;
        break;
      case 1:
        state.factorTabProgress = progress;
        break;
      case 2:
        state.campaignTabProgress = progress;
        break;
    }
    return state;
  }

  /// Records the current tab and whether it is at its scroll-top, from the native scroll-position event.
  CharaDetailCaptureState scrollPosition(int index, bool atTop) {
    final state = clone();
    state.currentTab = index;
    state.atTop = atTop;
    return state;
  }

  CharaDetailCaptureState success({required String id}) {
    final state = reset();
    // Keep every tab pinned at 100% instead of clearing it, so the completed progress rings (and the
    // "safe to switch" indicator alongside them) stay visible until the next character is opened.
    state.skillTabProgress = 1;
    state.factorTabProgress = 1;
    state.campaignTabProgress = 1;
    state.link = CharaDetailLink(id: id);
    return state;
  }

  CharaDetailCaptureState fail({required String message, String? duplicateRecordId}) {
    final state = clone();
    state.error = message;
    state.duplicateRecordId = duplicateRecordId;
    return state;
  }

  /// The single capture status this state represents.
  ///
  /// This is the one place that classifies the raw fields, so every message on the capture tab is
  /// derived from the same decision instead of each widget re-deciding independently.
  CharaDetailCaptureStatus get status {
    final currentError = error;
    // Confirmed duplicate and hard failures are terminal, regardless of progress.
    if (currentError == "duplicated_character") {
      return CharaDetailCaptureStatus.alreadyCaptured;
    }
    if (currentError != null && currentError != "duplicated_character_probe") {
      return CharaDetailCaptureStatus.failed;
    }
    // Past here the only possible error is the non-fatal duplicate probe hint (or none).
    if (link != null) {
      return CharaDetailCaptureStatus.succeeded;
    }
    if (!detailOpened) {
      return CharaDetailCaptureStatus.waitingForDetail;
    }
    // The probe hint only stands while the factor tab is still at its top (where the hint fired). Once the
    // user scrolls or navigates to another tab, factorAtTop is false and the stale hint degrades to the
    // ordinary phase below.
    if (currentError == "duplicated_character_probe" && factorAtTop) {
      return CharaDetailCaptureStatus.duplicateHint;
    }
    // Two states only: the current tab is either at its top (detailReady, and switchable when it is the
    // factor tab) or scrolled (capturing). There is no intermediate, because both derive from the same
    // atTop fact rather than from two independent heuristics.
    if (!atTop) {
      return CharaDetailCaptureStatus.capturing;
    }
    return CharaDetailCaptureStatus.detailReady;
  }

  /// Whether the factor tab is currently displayed at its scroll-top -- the one point mid-capture where a
  /// character switch is detectable (Rule 3). Derived from the single (currentTab, atTop) fact.
  bool get factorAtTop => atTop && currentTab == factorTabIndex;

  /// Whether it is safe to navigate to an adjacent character without closing the detail screen.
  ///
  /// Native can only detect and re-capture a switch when the factor tab is at its top (Rule 3) or
  /// every tab is complete (Rule 2); switching anywhere else loses the new character's first frame.
  /// So a switch is safe only at [factorAtTop] (during capture) or after success. Returns null when
  /// there is no meaningful guidance (no detail session, or a hard error surfaced separately).
  bool? get switchSafety => switch (status) {
    // succeeded and alreadyCaptured both mean every tab was captured, so a switch is detectable (Rule 2).
    CharaDetailCaptureStatus.succeeded ||
    CharaDetailCaptureStatus.alreadyCaptured ||
    CharaDetailCaptureStatus.duplicateHint => true,
    CharaDetailCaptureStatus.detailReady || CharaDetailCaptureStatus.capturing => factorAtTop,
    _ => null,
  };
}

class CharaDetailCaptureStateNotifier extends Notifier<CharaDetailCaptureState> {
  @override
  CharaDetailCaptureState build() => CharaDetailCaptureState();

  void reset() => state = state.reset();

  void started() => state = state.started();

  void progress(int index, double progress) => state = state.progress(index, progress);

  void scrollPosition(int index, bool atTop) => state = state.scrollPosition(index, atTop);

  void success(String id) => state = state.success(id: id);

  void fail(String message, {String? duplicateRecordId}) =>
      state = state.fail(message: message, duplicateRecordId: duplicateRecordId);
}

final charaDetailCaptureStateProvider = NotifierProvider<CharaDetailCaptureStateNotifier, CharaDetailCaptureState>(
  CharaDetailCaptureStateNotifier.new,
);

final trainerIdProvider = Provider<String>((ref) {
  final entry = StorageBox(StorageBoxKey.trainerId).entry<String>("trainer_id");
  var id = entry.pull();
  // Logs are included in bug reports, so we should not casually print the trainer ID.
  if (id == null) {
    id = const Uuid().v4();
    entry.push(id);
    if (kDebugMode) {
      logger.i("Trainer ID generated: $id");
    }
  } else {
    if (kDebugMode) {
      logger.i("Trainer ID loaded: $id");
    }
  }
  return id;
});

final forceResizeModeStateProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.forceResizeMode.name, defaultValue: false);
});

typedef JsonMap = Map<String, dynamic>;

final platformConfigLoader = FutureProvider<JsonMap>((ref) async {
  JsonMap config = {
    "chara_detail": {},
    "directory": {},
    "video_mode": false,
    "trainer_id": ref.watch(trainerIdProvider),
  };

  await Future.wait([
    ref.watch(pathInfoLoader.future).then((directory) {
      config["directory"]["temp_dir"] = directory.tempDir.path;
      config["directory"]["storage_dir"] = directory.storageDir.path;
      config["directory"]["modules_dir"] = directory.modulesDir.path;
    }),
    rootBundle
        .loadString('assets/config/chara_detail/scene_context.json')
        .then((text) => config["chara_detail"]["scene_context"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/scene_scraper.json')
        .then((text) => config["chara_detail"]["scene_scraper"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/scene_stitcher.json')
        .then((text) => config["chara_detail"]["scene_stitcher"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/recognizer.json')
        .then((text) => config["chara_detail"]["recognizer"] = jsonDecode(text)),
    rootBundle.loadString('assets/config/platform.json').then((text) => config["platform"] = jsonDecode(text)),
  ]);

  return config;
});

final platformControllerLoader = FutureProvider<PlatformController?>((ref) async {
  if ((await ref.watch(moduleVersionLoader.future)) == null) {
    return null;
  }
  return ref.watch(platformConfigLoader.future).then((config) {
    final forceResizeMode = ref.read(forceResizeModeStateProvider);
    config["platform"]["windows"]["window_recorder"]["force_resize"] = forceResizeMode;

    final controller = PlatformController(ref, config);
    ref.listen<bool>(forceResizeModeStateProvider, (_, enable) {
      controller.setForceResizeMode(enable);
    });

    if (ref.read(autoStartCaptureStateProvider)) {
      controller.startCapture();
    }
    return controller;
  });
});

final platformControllerProvider = Provider<PlatformController?>((ref) {
  return ref.watch(platformControllerLoader).value;
});

class PlatformController {
  final Ref _ref;

  final PlatformChannel _platformChannel;

  final Map<String, dynamic> nativeConfig;

  // The self-factors from the most recent factor probe. Native re-probes whenever the factor-tab content
  // changes (a character switch), but may emit the same probe more than once; comparing against this key
  // suppresses a redundant duplicate check (and its error cue) for an unchanged character.
  List<Factor>? _lastProbeKey;

  PlatformController(Ref ref, Map<String, dynamic> config)
    : _ref = ref,
      nativeConfig = config,
      _platformChannel = PlatformChannel() {
    _platformChannel.setCallback((message) => _handleMessage(message));
    _platformChannel.setConfig(jsonEncode(config));

    // This is not required, but we will need storage later anyway, so start it up.
    ref.read(charaDetailRecordStorageLoaderProvider);
  }

  // Order-sensitive equality of two probe keys (factors are compared by value; their order is stable).
  bool _sameFactorKey(List<Factor> a, List<Factor>? b) {
    if (b == null || a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  void _handleMessage(String message) {
    // Native payloads are untyped and cross the platform channel, where neither
    // the field set nor the Dart runtime types are guaranteed. Wrap the whole
    // dispatch so a malformed message is logged and dropped instead of throwing
    // out of the method-channel callback (where the error would be hard to trace
    // and the event silently lost anyway).
    try {
      final data = jsonDecode(message) as Map;
      final dataType = data['type'].toString();
      final captureState = _ref.read(charaDetailCaptureStateProvider.notifier);
      switch (dataType) {
        case 'onError':
          _errorEvent.add(_soundEventSequence++);
          captureState.fail(data['message']);
          break;
        case 'onCaptureStarted':
          _captureTriggeredEvent.add(true);
          captureState.reset();
          break;
        case 'onCaptureStopped':
          _captureTriggeredEvent.add(false);
          captureState.reset();
          _lastProbeKey = null;
          _ref.read(capturingFrameSizeProvider.notifier).set(null);
          _ref.read(capturingFrameRateProvider.notifier).set(null);
          break;
        case 'onScrollReady':
          _scrollReadyEvent.add(_soundEventSequence++);
          break;
        case 'onFactorProbe':
          {
            // Native deferred the factor-tab scroll-ready cue and instead sent the self-factors
            // visible before scrolling. Run the early duplicate check: only emit the scroll-ready
            // cue when it is not a duplicate; otherwise the storage layer raises the duplicate error.
            final factorsRaw = data['factors'];
            if (factorsRaw is! List) {
              break;
            }
            final probeSelf = factorsRaw
                .whereType<Map>()
                .map((e) => FactorMapper.fromMap(Map<String, dynamic>.from(e)))
                .toList();
            // The probe only fires at the factor tab's top, so it marks the one safe point to switch
            // characters mid-capture. Reassert the factor-at-top position before the dedup break, so even
            // a re-emitted probe (e.g. a settling frame after briefly leaving and returning) -- and any
            // ordering ahead of the scroll-position event -- restores the "safe" state.
            captureState.scrollPosition(CharaDetailCaptureState.factorTabIndex, true);
            // Native may re-emit the probe for the same character (e.g. a settling frame after a switch).
            // Skip an unchanged key so the duplicate check and its error cue fire at most once per character.
            if (_sameFactorKey(probeSelf, _lastProbeKey)) {
              break;
            }
            _lastProbeKey = probeSelf;
            // The threshold depends on the capture's record type; -1 (or any out-of-range value)
            // from native maps to null, which falls back to the default (non-friend-standard) threshold.
            final recordTypeRaw = data['record_type'];
            final recordType = (recordTypeRaw is int && recordTypeRaw >= 0 && recordTypeRaw < RecordType.values.length)
                ? RecordType.values[recordTypeRaw]
                : null;
            final isDuplicate = _ref
                .read(charaDetailRecordStorageLoaderProvider.notifier)
                .reportDuplicateFromFactorProbe(probeSelf, recordType);
            if (!isDuplicate) {
              _scrollReadyEvent.add(_soundEventSequence++);
            }
          }
          break;
        case 'onScrollUpdated':
          {
            final index = data['index'] as int?;
            final progress = (data['progress'] as num?)?.toDouble();
            if (index != null && progress != null) {
              captureState.progress(index, progress);
            }
          }
          break;
        case 'onScrollPosition':
          {
            final index = data['index'] as int?;
            final atTop = data['at_top'] as bool?;
            if (index != null && atTop != null) {
              captureState.scrollPosition(index, atTop);
            }
          }
          break;
        case 'onPageReady':
          {
            _pageReadyEvent.add(_soundEventSequence++);
            final index = data['index'] as int?;
            if (index != null) {
              captureState.progress(index, 1);
            }
          }
          break;
        case 'onCharaDetailStarted':
        case 'onCharaDetailRestarted':
          // A restart is a mid-scene reset (native inferred a character switch and rebuilt the session
          // without the detail screen closing). The UI resets its capture progress exactly as on a fresh
          // open, and the probe key is cleared so the new character's early duplicate check runs.
          captureState.started();
          _lastProbeKey = null;
          break;
        case 'onCharaDetailFinished':
          if (data['success'] == true) {
            _charaDetailRecordCapturedEvent.add(data['id']);
            captureState.success(data['id']);
          }
          break;
        case 'onCharaDetailClosed':
          // The detail screen was closed. Drop the retained progress (a completed capture keeps its rings
          // on screen until now) and return to waiting. For an incomplete close, the closed_before_completed
          // error arrives right after this and re-establishes the failure state.
          captureState.reset();
          _lastProbeKey = null;
          break;
        case 'onCharaDetailUpdated':
          _ref.read(charaDetailRecordRegenerationControllerProvider.notifier).updated(data['id']);
          break;
        case 'onFrameRateReported':
          {
            final fps = (data['fps'] as num?)?.toDouble();
            if (fps != null) {
              _ref.read(capturingFrameRateProvider.notifier).set(fps);
            }
          }
          break;
        case 'onScreenshotTaken':
          logger.i("path=${data['path']}, result='${data['result']}'");
          _ref.read(latestScreenshotProvider.notifier).set(ScreenshotResult(FilePath(data['path']), data['result']));
          break;
        case 'onFrameSizeReported':
          {
            final width = (data['size']?['width'] as num?)?.toDouble();
            final height = (data['size']?['height'] as num?)?.toDouble();
            if (width != null && height != null) {
              _ref.read(capturingFrameSizeProvider.notifier).set(Size(width, height));
            }
          }
          break;
        default:
          throw UnimplementedError(dataType);
      }
    } catch (e, st) {
      logger.w("Failed to handle native message: $message", e, st);
    }
  }

  Future<void> startCapture() => _platformChannel.startCapture();

  Future<void> stopCapture() => _platformChannel.stopCapture();

  Future<void> updateRecord(String id) => _platformChannel.updateRecord(id);

  Future<void> copyToClipboardFromFile(FilePath path) => _platformChannel.copyToClipboardFromFile(path);

  Future<void> takeScreenshot(FilePath path) => _platformChannel.takeScreenshot(path);

  Future<void> setForceResizeMode(bool enable) {
    final config = {
      "window_recorder": {"force_resize": enable},
    };
    return _platformChannel.setPlatformConfig(jsonEncode(config));
  }
}
