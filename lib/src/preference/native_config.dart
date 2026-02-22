import 'dart:ui';

import 'package:dart_json_mapper/dart_json_mapper.dart';

@jsonSerializable
class WindowTarget {
  final String? windowClass;
  final String? windowTitle;

  const WindowTarget({
    this.windowClass,
    this.windowTitle,
  });
}

@jsonSerializable
class AspectRatioRange {
  final double? min;
  final double? max;

  const AspectRatioRange({
    this.min,
    this.max,
  });
}

@jsonSerializable
class CropProfile {
  final AspectRatioRange? windowAspectRatio;
  final Size? clientAspectRatio;

  const CropProfile({
    this.windowAspectRatio,
    this.clientAspectRatio,
  });
}

@jsonSerializable
class RecorderConfig {
  final List<WindowTarget>? windowTargets;
  final List<CropProfile>? cropProfiles;
  final int? recordingFps;
  final Size? minimumSize;

  const RecorderConfig({
    this.windowTargets,
    this.cropProfiles,
    this.recordingFps,
    this.minimumSize,
  });
}

@jsonSerializable
class WindowsConfig {
  final RecorderConfig? windowRecorder;

  const WindowsConfig({
    this.windowRecorder,
  });
}

@jsonSerializable
class NativeConfig {
  final WindowsConfig? windows;
  final String? directory;

  const NativeConfig({
    this.windows,
    this.directory,
  });

  NativeConfig copyWith({
    windows,
    directory,
  }) {
    return NativeConfig(
      windows: windows ?? this.windows,
      directory: directory ?? this.directory,
    );
  }
}
