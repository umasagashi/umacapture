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
