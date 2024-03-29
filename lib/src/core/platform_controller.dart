import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

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
  return ref.watch(captureTriggeredEventProvider).when(
      data: (data) => data,
      loading: () => false,
      error: (error, stack) {
        logger.e("error: $error, $stack");
        return false;
      });
});

final capturingFrameSizeProvider = StateProvider<Size?>((ref) {
  return null;
});

final capturingFrameRateProvider = StateProvider<double?>((ref) {
  return null;
});

StreamController<String> _errorEventController = StreamController();
final errorEventProvider = StreamProvider<String>((ref) {
  if (_errorEventController.hasListener) {
    _errorEventController = StreamController();
  }
  return _errorEventController.stream;
});

StreamController<bool> _captureTriggeredEventController = StreamController();
final captureTriggeredEventProvider = StreamProvider<bool>((ref) {
  if (_captureTriggeredEventController.hasListener) {
    _captureTriggeredEventController = StreamController();
  }
  return _captureTriggeredEventController.stream;
});

StreamController<int> _scrollReadyEventController = StreamController();
final scrollReadyEventProvider = StreamProvider<int>((ref) {
  if (_scrollReadyEventController.hasListener) {
    _scrollReadyEventController = StreamController();
  }
  return _scrollReadyEventController.stream;
});

StreamController<int> _pageReadyEventController = StreamController();
final pageReadyEventProvider = StreamProvider<int>((ref) {
  if (_pageReadyEventController.hasListener) {
    _pageReadyEventController = StreamController();
  }
  return _pageReadyEventController.stream;
});

StreamController<String> _charaDetailRecordCapturedEventController = StreamController();
final charaDetailRecordCapturedEventProvider = StreamProvider<String>((ref) {
  if (_charaDetailRecordCapturedEventController.hasListener) {
    _charaDetailRecordCapturedEventController = StreamController();
  }
  return _charaDetailRecordCapturedEventController.stream;
});

class CharaDetailLink {
  String id;

  CharaDetailLink({required this.id});
}

class CharaDetailCaptureState {
  bool isCapturing;

  double skillTabProgress;

  double factorTabProgress;

  double campaignTabProgress;

  CharaDetailLink? link;
  String? error;

  CharaDetailCaptureState({
    this.isCapturing = false,
    this.skillTabProgress = 0,
    this.factorTabProgress = 0,
    this.campaignTabProgress = 0,
    this.link,
    this.error,
  });

  CharaDetailCaptureState clone() {
    return CharaDetailCaptureState(
      isCapturing: isCapturing,
      skillTabProgress: skillTabProgress,
      factorTabProgress: factorTabProgress,
      campaignTabProgress: campaignTabProgress,
      link: link,
      error: error,
    );
  }

  CharaDetailCaptureState reset() {
    return CharaDetailCaptureState();
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
}

final charaDetailCaptureStateProvider = StateProvider<CharaDetailCaptureState>((ref) {
  return CharaDetailCaptureState();
});

final trainerIdProvider = Provider<String>((ref) {
  final entry = StorageBox(StorageBoxKey.trainerId).entry<String>("trainer_id");
  var id = entry.pull();
  if (id == null) {
    id = const Uuid().v4();
    entry.push(id);
    logger.i("Trainer ID generated: $id");
  } else {
    logger.i("Trainer ID loaded: $id");
  }
  return id;
});

final forceResizeModeStateProvider = BooleanNotifierProvider((ref) {
  final box = ref.watch(storageBoxProvider);
  return BooleanNotifier(
    entry: StorageEntry(box: box, key: SettingsEntryKey.forceResizeMode.name),
    defaultValue: false,
  );
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

  PlatformController(Ref ref, Map<String, dynamic> config)
      : _ref = ref,
        nativeConfig = config,
        _platformChannel = PlatformChannel() {
    _platformChannel.setCallback((message) => _handleMessage(message));
    _platformChannel.setConfig(jsonEncode(config));

    // This is not required, but we will need storage later anyway, so start it up.
    ref.read(charaDetailRecordStorageLoader);
  }

  void _handleMessage(String message) {
    final data = jsonDecode(message) as Map;
    final dataType = data['type'].toString();
    final captureState = _ref.read(charaDetailCaptureStateProvider.notifier);
    switch (dataType) {
      case 'onError':
        _errorEventController.sink.add(data['message']);
        captureState.update((state) => state.fail(message: data['message']));
        break;
      case 'onCaptureStarted':
        _captureTriggeredEventController.sink.add(true);
        captureState.update((state) => state.reset());
        break;
      case 'onCaptureStopped':
        _captureTriggeredEventController.sink.add(false);
        captureState.update((state) => state.reset());
        _ref.read(capturingFrameSizeProvider.notifier).state = null;
        _ref.read(capturingFrameRateProvider.notifier).state = null;
        break;
      case 'onScrollReady':
        _scrollReadyEventController.sink.add(data['index']);
        break;
      case 'onScrollUpdated':
        captureState.update((state) => state.progress(data['index'], data['progress']));
        break;
      case 'onPageReady':
        _pageReadyEventController.sink.add(data['index']);
        captureState.update((state) => state.progress(data['index'], 1));
        break;
      case 'onCharaDetailStarted':
        captureState.update((state) => state.reset());
        break;
      case 'onCharaDetailFinished':
        if (data['success']) {
          _charaDetailRecordCapturedEventController.sink.add(data['id']);
          captureState.update((state) => state.success(id: data['id']));
        }
        break;
      case 'onCharaDetailUpdated':
        _ref.read(charaDetailRecordRegenerationControllerProvider.notifier).updated(data['id']);
        break;
      case 'onFrameRateReported':
        _ref.read(capturingFrameRateProvider.notifier).update((_) => data['fps'].toDouble());
        break;
      case 'onScreenshotTaken':
        logger.i("path=${data['path']}, result='${data['result']}'");
        _ref
            .read(latestScreenshotProvider.notifier)
            .update((_) => ScreenshotResult(FilePath(data['path']), data['result']));
        break;
      case 'onFrameSizeReported':
        final size = Size(data['size']['width'].toDouble(), data['size']['height'].toDouble());
        _ref.read(capturingFrameSizeProvider.notifier).update((_) => size);
        break;
      default:
        throw UnimplementedError(dataType);
    }
  }

  Future<void> startCapture() => _platformChannel.startCapture();

  Future<void> stopCapture() => _platformChannel.stopCapture();

  Future<void> updateRecord(String id) => _platformChannel.updateRecord(id);

  Future<void> copyToClipboardFromFile(FilePath path) => _platformChannel.copyToClipboardFromFile(path);

  Future<void> takeScreenshot(FilePath path) => _platformChannel.takeScreenshot(path);

  Future<void> setForceResizeMode(bool enable) {
    final config = {
      "window_recorder": {
        "force_resize": enable,
      }
    };
    return _platformChannel.setPlatformConfig(jsonEncode(config));
  }
}
