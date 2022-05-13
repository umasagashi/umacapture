import 'dart:ui';

import 'package:dart_json_mapper/dart_json_mapper.dart';

@jsonSerializable
class WindowProfile {
  final String? windowClass;
  final String? windowTitle;
  final bool? fixedAspectRatio;

  const WindowProfile({
    this.windowClass,
    this.windowTitle,
    this.fixedAspectRatio,
  });
}

@jsonSerializable
class RecorderConfig {
  final WindowProfile? windowProfile;
  final int? recordingFps;
  final Size? minimumSize;

  const RecorderConfig({
    this.windowProfile,
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
class PlatformConfig {
  final WindowsConfig? windowsConfig;
  final String? directory;

  const PlatformConfig({
    this.windowsConfig,
    this.directory,
  });

  PlatformConfig copyWith({
    windowsConfig,
    directory,
  }) {
    return PlatformConfig(
      windowsConfig: windowsConfig ?? this.windowsConfig,
      directory: directory ?? this.directory,
    );
  }
}
