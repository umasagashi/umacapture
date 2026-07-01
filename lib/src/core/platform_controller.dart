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

class CharaDetailCaptureState {
  bool isCapturing;

  double skillTabProgress;

  double factorTabProgress;

  double campaignTabProgress;

  RecordType? recordType;

  CharaDetailLink? link;
  String? error;

  CharaDetailCaptureState({
    this.isCapturing = false,
    this.skillTabProgress = 0,
    this.factorTabProgress = 0,
    this.campaignTabProgress = 0,
    this.recordType,
    this.link,
    this.error,
  });

  CharaDetailCaptureState clone() {
    return CharaDetailCaptureState(
      isCapturing: isCapturing,
      skillTabProgress: skillTabProgress,
      factorTabProgress: factorTabProgress,
      campaignTabProgress: campaignTabProgress,
      recordType: recordType,
      link: link,
      error: error,
    );
  }

  CharaDetailCaptureState reset() {
    return CharaDetailCaptureState();
  }

  CharaDetailCaptureState started(RecordType recordType) {
    final state = reset();
    state.recordType = recordType;
    return state;
  }

  CharaDetailCaptureState progress(int index, double progress) {
    final state = clone();
    state.isCapturing = true;
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

  CharaDetailCaptureState success({required String id}) {
    final state = reset();
    state.link = CharaDetailLink(id: id);
    return state;
  }

  CharaDetailCaptureState fail({required String message}) {
    final state = clone();
    state.error = message;
    return state;
  }

  /// Whether it is safe to navigate to an adjacent character without closing the detail screen.
  ///
  /// A switch is only reliably handled at three points: nothing captured yet, every tab captured,
  /// or the early duplicate check flagged the character. Returns null when no detail session is
  /// active, so the UI shows no guidance.
  bool? get switchSafety {
    if (error != null) {
      // The duplicate-probe hint is a safe switch point; any other error is a failure, not guidance.
      return error == "duplicated_character_probe" ? true : null;
    }
    if (link != null) {
      return true; // All tabs captured (success).
    }
    if (recordType == null) {
      return null; // Detail screen not open.
    }
    // Freshly opened detail screen with nothing captured yet.
    return skillTabProgress == 0 && factorTabProgress == 0 && campaignTabProgress == 0;
  }
}

class CharaDetailCaptureStateNotifier extends Notifier<CharaDetailCaptureState> {
  @override
  CharaDetailCaptureState build() => CharaDetailCaptureState();

  void reset() => state = state.reset();

  void started(RecordType recordType) => state = state.started(recordType);

  void progress(int index, double progress) => state = state.progress(index, progress);

  void success(String id) => state = state.success(id: id);

  void fail(String message) => state = state.fail(message: message);
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
          final recordType = data['record_type'] as int;
          if (recordType < 0 || recordType >= RecordType.values.length) {
            throw RangeError.value(recordType, 'record_type');
          }
          captureState.started(RecordType.values[recordType]);
          _lastProbeKey = null;
          break;
        case 'onCharaDetailFinished':
          if (data['success'] == true) {
            _charaDetailRecordCapturedEvent.add(data['id']);
            captureState.success(data['id']);
          }
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
