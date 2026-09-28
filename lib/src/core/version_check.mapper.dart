// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'version_check.dart';

class ModuleVersionRawDataMapper extends ClassMapperBase<ModuleVersionRawData> {
  ModuleVersionRawDataMapper._();

  static ModuleVersionRawDataMapper? _instance;
  static ModuleVersionRawDataMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ModuleVersionRawDataMapper._());
      ModuleArchiveRefMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ModuleVersionRawData';

  static String _$formatVersion(ModuleVersionRawData v) => v.formatVersion;
  static const Field<ModuleVersionRawData, String> _f$formatVersion = Field(
    'formatVersion',
    _$formatVersion,
    key: r'format_version',
  );
  static String _$region(ModuleVersionRawData v) => v.region;
  static const Field<ModuleVersionRawData, String> _f$region = Field(
    'region',
    _$region,
  );
  static String _$recognizerVersion(ModuleVersionRawData v) =>
      v.recognizerVersion;
  static const Field<ModuleVersionRawData, String> _f$recognizerVersion = Field(
    'recognizerVersion',
    _$recognizerVersion,
    key: r'recognizer_version',
  );
  static String _$minimumVersion(ModuleVersionRawData v) => v.minimumVersion;
  static const Field<ModuleVersionRawData, String> _f$minimumVersion = Field(
    'minimumVersion',
    _$minimumVersion,
    key: r'minimum_version',
    opt: true,
    def: "2021-02-24T00:00:00+0900",
  );
  static String _$applicationVersion(ModuleVersionRawData v) =>
      v.applicationVersion;
  static const Field<ModuleVersionRawData, String> _f$applicationVersion =
      Field(
        'applicationVersion',
        _$applicationVersion,
        key: r'application_version',
        opt: true,
        def: "0.0.0",
      );
  static bool _$pinVersion(ModuleVersionRawData v) => v.pinVersion;
  static const Field<ModuleVersionRawData, bool> _f$pinVersion = Field(
    'pinVersion',
    _$pinVersion,
    key: r'pin_version',
    opt: true,
    def: false,
  );
  static ModuleArchiveRef? _$moduleArchive(ModuleVersionRawData v) =>
      v.moduleArchive;
  static const Field<ModuleVersionRawData, ModuleArchiveRef> _f$moduleArchive =
      Field(
        'moduleArchive',
        _$moduleArchive,
        key: r'module_archive',
        opt: true,
      );

  @override
  final MappableFields<ModuleVersionRawData> fields = const {
    #formatVersion: _f$formatVersion,
    #region: _f$region,
    #recognizerVersion: _f$recognizerVersion,
    #minimumVersion: _f$minimumVersion,
    #applicationVersion: _f$applicationVersion,
    #pinVersion: _f$pinVersion,
    #moduleArchive: _f$moduleArchive,
  };

  static ModuleVersionRawData _instantiate(DecodingData data) {
    return ModuleVersionRawData(
      data.dec(_f$formatVersion),
      data.dec(_f$region),
      data.dec(_f$recognizerVersion),
      data.dec(_f$minimumVersion),
      data.dec(_f$applicationVersion),
      data.dec(_f$pinVersion),
      data.dec(_f$moduleArchive),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ModuleVersionRawData fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ModuleVersionRawData>(map);
  }

  static ModuleVersionRawData fromJson(String json) {
    return ensureInitialized().decodeJson<ModuleVersionRawData>(json);
  }
}

mixin ModuleVersionRawDataMappable {
  String toJson() {
    return ModuleVersionRawDataMapper.ensureInitialized()
        .encodeJson<ModuleVersionRawData>(this as ModuleVersionRawData);
  }

  Map<String, dynamic> toMap() {
    return ModuleVersionRawDataMapper.ensureInitialized()
        .encodeMap<ModuleVersionRawData>(this as ModuleVersionRawData);
  }
}

class ModuleArchiveRefMapper extends ClassMapperBase<ModuleArchiveRef> {
  ModuleArchiveRefMapper._();

  static ModuleArchiveRefMapper? _instance;
  static ModuleArchiveRefMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ModuleArchiveRefMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ModuleArchiveRef';

  static String _$path(ModuleArchiveRef v) => v.path;
  static const Field<ModuleArchiveRef, String> _f$path = Field('path', _$path);
  static String _$sha256(ModuleArchiveRef v) => v.sha256;
  static const Field<ModuleArchiveRef, String> _f$sha256 = Field(
    'sha256',
    _$sha256,
  );
  static int _$size(ModuleArchiveRef v) => v.size;
  static const Field<ModuleArchiveRef, int> _f$size = Field('size', _$size);

  @override
  final MappableFields<ModuleArchiveRef> fields = const {
    #path: _f$path,
    #sha256: _f$sha256,
    #size: _f$size,
  };

  static ModuleArchiveRef _instantiate(DecodingData data) {
    return ModuleArchiveRef(
      data.dec(_f$path),
      data.dec(_f$sha256),
      data.dec(_f$size),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ModuleArchiveRef fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ModuleArchiveRef>(map);
  }

  static ModuleArchiveRef fromJson(String json) {
    return ensureInitialized().decodeJson<ModuleArchiveRef>(json);
  }
}

mixin ModuleArchiveRefMappable {
  String toJson() {
    return ModuleArchiveRefMapper.ensureInitialized()
        .encodeJson<ModuleArchiveRef>(this as ModuleArchiveRef);
  }

  Map<String, dynamic> toMap() {
    return ModuleArchiveRefMapper.ensureInitialized()
        .encodeMap<ModuleArchiveRef>(this as ModuleArchiveRef);
  }
}

