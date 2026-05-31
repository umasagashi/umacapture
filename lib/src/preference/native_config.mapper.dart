// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'native_config.dart';

class WindowTargetMapper extends ClassMapperBase<WindowTarget> {
  WindowTargetMapper._();

  static WindowTargetMapper? _instance;
  static WindowTargetMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = WindowTargetMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'WindowTarget';

  static String? _$windowClass(WindowTarget v) => v.windowClass;
  static const Field<WindowTarget, String> _f$windowClass = Field(
    'windowClass',
    _$windowClass,
    opt: true,
  );
  static String? _$windowTitle(WindowTarget v) => v.windowTitle;
  static const Field<WindowTarget, String> _f$windowTitle = Field(
    'windowTitle',
    _$windowTitle,
    opt: true,
  );

  @override
  final MappableFields<WindowTarget> fields = const {
    #windowClass: _f$windowClass,
    #windowTitle: _f$windowTitle,
  };

  static WindowTarget _instantiate(DecodingData data) {
    return WindowTarget(
      windowClass: data.dec(_f$windowClass),
      windowTitle: data.dec(_f$windowTitle),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static WindowTarget fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<WindowTarget>(map);
  }

  static WindowTarget fromJson(String json) {
    return ensureInitialized().decodeJson<WindowTarget>(json);
  }
}

mixin WindowTargetMappable {
  String toJson() {
    return WindowTargetMapper.ensureInitialized().encodeJson<WindowTarget>(
      this as WindowTarget,
    );
  }

  Map<String, dynamic> toMap() {
    return WindowTargetMapper.ensureInitialized().encodeMap<WindowTarget>(
      this as WindowTarget,
    );
  }
}

class AspectRatioRangeMapper extends ClassMapperBase<AspectRatioRange> {
  AspectRatioRangeMapper._();

  static AspectRatioRangeMapper? _instance;
  static AspectRatioRangeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AspectRatioRangeMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'AspectRatioRange';

  static double? _$min(AspectRatioRange v) => v.min;
  static const Field<AspectRatioRange, double> _f$min = Field(
    'min',
    _$min,
    opt: true,
  );
  static double? _$max(AspectRatioRange v) => v.max;
  static const Field<AspectRatioRange, double> _f$max = Field(
    'max',
    _$max,
    opt: true,
  );

  @override
  final MappableFields<AspectRatioRange> fields = const {
    #min: _f$min,
    #max: _f$max,
  };

  static AspectRatioRange _instantiate(DecodingData data) {
    return AspectRatioRange(min: data.dec(_f$min), max: data.dec(_f$max));
  }

  @override
  final Function instantiate = _instantiate;

  static AspectRatioRange fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<AspectRatioRange>(map);
  }

  static AspectRatioRange fromJson(String json) {
    return ensureInitialized().decodeJson<AspectRatioRange>(json);
  }
}

mixin AspectRatioRangeMappable {
  String toJson() {
    return AspectRatioRangeMapper.ensureInitialized()
        .encodeJson<AspectRatioRange>(this as AspectRatioRange);
  }

  Map<String, dynamic> toMap() {
    return AspectRatioRangeMapper.ensureInitialized()
        .encodeMap<AspectRatioRange>(this as AspectRatioRange);
  }
}

class CropProfileMapper extends ClassMapperBase<CropProfile> {
  CropProfileMapper._();

  static CropProfileMapper? _instance;
  static CropProfileMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CropProfileMapper._());
      AspectRatioRangeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'CropProfile';

  static AspectRatioRange? _$windowAspectRatio(CropProfile v) =>
      v.windowAspectRatio;
  static const Field<CropProfile, AspectRatioRange> _f$windowAspectRatio =
      Field('windowAspectRatio', _$windowAspectRatio, opt: true);
  static Size? _$clientAspectRatio(CropProfile v) => v.clientAspectRatio;
  static const Field<CropProfile, Size> _f$clientAspectRatio = Field(
    'clientAspectRatio',
    _$clientAspectRatio,
    opt: true,
  );

  @override
  final MappableFields<CropProfile> fields = const {
    #windowAspectRatio: _f$windowAspectRatio,
    #clientAspectRatio: _f$clientAspectRatio,
  };

  static CropProfile _instantiate(DecodingData data) {
    return CropProfile(
      windowAspectRatio: data.dec(_f$windowAspectRatio),
      clientAspectRatio: data.dec(_f$clientAspectRatio),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CropProfile fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CropProfile>(map);
  }

  static CropProfile fromJson(String json) {
    return ensureInitialized().decodeJson<CropProfile>(json);
  }
}

mixin CropProfileMappable {
  String toJson() {
    return CropProfileMapper.ensureInitialized().encodeJson<CropProfile>(
      this as CropProfile,
    );
  }

  Map<String, dynamic> toMap() {
    return CropProfileMapper.ensureInitialized().encodeMap<CropProfile>(
      this as CropProfile,
    );
  }
}

class RecorderConfigMapper extends ClassMapperBase<RecorderConfig> {
  RecorderConfigMapper._();

  static RecorderConfigMapper? _instance;
  static RecorderConfigMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RecorderConfigMapper._());
      WindowTargetMapper.ensureInitialized();
      CropProfileMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RecorderConfig';

  static List<WindowTarget>? _$windowTargets(RecorderConfig v) =>
      v.windowTargets;
  static const Field<RecorderConfig, List<WindowTarget>> _f$windowTargets =
      Field('windowTargets', _$windowTargets, opt: true);
  static List<CropProfile>? _$cropProfiles(RecorderConfig v) => v.cropProfiles;
  static const Field<RecorderConfig, List<CropProfile>> _f$cropProfiles = Field(
    'cropProfiles',
    _$cropProfiles,
    opt: true,
  );
  static int? _$recordingFps(RecorderConfig v) => v.recordingFps;
  static const Field<RecorderConfig, int> _f$recordingFps = Field(
    'recordingFps',
    _$recordingFps,
    opt: true,
  );
  static Size? _$minimumSize(RecorderConfig v) => v.minimumSize;
  static const Field<RecorderConfig, Size> _f$minimumSize = Field(
    'minimumSize',
    _$minimumSize,
    opt: true,
  );

  @override
  final MappableFields<RecorderConfig> fields = const {
    #windowTargets: _f$windowTargets,
    #cropProfiles: _f$cropProfiles,
    #recordingFps: _f$recordingFps,
    #minimumSize: _f$minimumSize,
  };

  static RecorderConfig _instantiate(DecodingData data) {
    return RecorderConfig(
      windowTargets: data.dec(_f$windowTargets),
      cropProfiles: data.dec(_f$cropProfiles),
      recordingFps: data.dec(_f$recordingFps),
      minimumSize: data.dec(_f$minimumSize),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RecorderConfig fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RecorderConfig>(map);
  }

  static RecorderConfig fromJson(String json) {
    return ensureInitialized().decodeJson<RecorderConfig>(json);
  }
}

mixin RecorderConfigMappable {
  String toJson() {
    return RecorderConfigMapper.ensureInitialized().encodeJson<RecorderConfig>(
      this as RecorderConfig,
    );
  }

  Map<String, dynamic> toMap() {
    return RecorderConfigMapper.ensureInitialized().encodeMap<RecorderConfig>(
      this as RecorderConfig,
    );
  }
}

class WindowsConfigMapper extends ClassMapperBase<WindowsConfig> {
  WindowsConfigMapper._();

  static WindowsConfigMapper? _instance;
  static WindowsConfigMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = WindowsConfigMapper._());
      RecorderConfigMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'WindowsConfig';

  static RecorderConfig? _$windowRecorder(WindowsConfig v) => v.windowRecorder;
  static const Field<WindowsConfig, RecorderConfig> _f$windowRecorder = Field(
    'windowRecorder',
    _$windowRecorder,
    opt: true,
  );

  @override
  final MappableFields<WindowsConfig> fields = const {
    #windowRecorder: _f$windowRecorder,
  };

  static WindowsConfig _instantiate(DecodingData data) {
    return WindowsConfig(windowRecorder: data.dec(_f$windowRecorder));
  }

  @override
  final Function instantiate = _instantiate;

  static WindowsConfig fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<WindowsConfig>(map);
  }

  static WindowsConfig fromJson(String json) {
    return ensureInitialized().decodeJson<WindowsConfig>(json);
  }
}

mixin WindowsConfigMappable {
  String toJson() {
    return WindowsConfigMapper.ensureInitialized().encodeJson<WindowsConfig>(
      this as WindowsConfig,
    );
  }

  Map<String, dynamic> toMap() {
    return WindowsConfigMapper.ensureInitialized().encodeMap<WindowsConfig>(
      this as WindowsConfig,
    );
  }
}

class NativeConfigMapper extends ClassMapperBase<NativeConfig> {
  NativeConfigMapper._();

  static NativeConfigMapper? _instance;
  static NativeConfigMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = NativeConfigMapper._());
      WindowsConfigMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'NativeConfig';

  static WindowsConfig? _$windows(NativeConfig v) => v.windows;
  static const Field<NativeConfig, WindowsConfig> _f$windows = Field(
    'windows',
    _$windows,
    opt: true,
  );
  static String? _$directory(NativeConfig v) => v.directory;
  static const Field<NativeConfig, String> _f$directory = Field(
    'directory',
    _$directory,
    opt: true,
  );

  @override
  final MappableFields<NativeConfig> fields = const {
    #windows: _f$windows,
    #directory: _f$directory,
  };

  static NativeConfig _instantiate(DecodingData data) {
    return NativeConfig(
      windows: data.dec(_f$windows),
      directory: data.dec(_f$directory),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static NativeConfig fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<NativeConfig>(map);
  }

  static NativeConfig fromJson(String json) {
    return ensureInitialized().decodeJson<NativeConfig>(json);
  }
}

mixin NativeConfigMappable {
  String toJson() {
    return NativeConfigMapper.ensureInitialized().encodeJson<NativeConfig>(
      this as NativeConfig,
    );
  }

  Map<String, dynamic> toMap() {
    return NativeConfigMapper.ensureInitialized().encodeMap<NativeConfig>(
      this as NativeConfig,
    );
  }
}

