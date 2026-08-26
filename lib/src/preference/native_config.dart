import 'dart:ui';

import 'package:dart_mappable/dart_mappable.dart';

part 'native_config.mapper.dart';

@MappableClass()
class WindowTarget with WindowTargetMappable {
  final String? windowClass;
  final String? windowTitle;

  const WindowTarget({this.windowClass, this.windowTitle});
}

@MappableClass()
class RecorderConfig with RecorderConfigMappable {
  final List<WindowTarget>? windowTargets;
  final int? recordingFps;
  final Size? minimumSize;

  const RecorderConfig({this.windowTargets, this.recordingFps, this.minimumSize});
}

@MappableClass()
class WindowsConfig with WindowsConfigMappable {
  final RecorderConfig? windowRecorder;

  const WindowsConfig({this.windowRecorder});
}

@MappableClass()
class NativeConfig with NativeConfigMappable {
  final WindowsConfig? windows;
  final String? directory;

  const NativeConfig({this.windows, this.directory});

  NativeConfig copyWith({WindowsConfig? windows, String? directory}) {
    return NativeConfig(windows: windows ?? this.windows, directory: directory ?? this.directory);
  }
}
