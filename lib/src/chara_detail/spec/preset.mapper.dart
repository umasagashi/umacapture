// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'preset.dart';

class ColumnPresetEntryMapper extends ClassMapperBase<ColumnPresetEntry> {
  ColumnPresetEntryMapper._();

  static ColumnPresetEntryMapper? _instance;
  static ColumnPresetEntryMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ColumnPresetEntryMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ColumnPresetEntry';

  static String _$key(ColumnPresetEntry v) => v.key;
  static const Field<ColumnPresetEntry, String> _f$key = Field('key', _$key);
  static String _$title(ColumnPresetEntry v) => v.title;
  static const Field<ColumnPresetEntry, String> _f$title = Field(
    'title',
    _$title,
  );

  @override
  final MappableFields<ColumnPresetEntry> fields = const {
    #key: _f$key,
    #title: _f$title,
  };

  static ColumnPresetEntry _instantiate(DecodingData data) {
    return ColumnPresetEntry(key: data.dec(_f$key), title: data.dec(_f$title));
  }

  @override
  final Function instantiate = _instantiate;

  static ColumnPresetEntry fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ColumnPresetEntry>(map);
  }

  static ColumnPresetEntry fromJson(String json) {
    return ensureInitialized().decodeJson<ColumnPresetEntry>(json);
  }
}

mixin ColumnPresetEntryMappable {
  String toJson() {
    return ColumnPresetEntryMapper.ensureInitialized()
        .encodeJson<ColumnPresetEntry>(this as ColumnPresetEntry);
  }

  Map<String, dynamic> toMap() {
    return ColumnPresetEntryMapper.ensureInitialized()
        .encodeMap<ColumnPresetEntry>(this as ColumnPresetEntry);
  }
}

class ColumnPresetIndexMapper extends ClassMapperBase<ColumnPresetIndex> {
  ColumnPresetIndexMapper._();

  static ColumnPresetIndexMapper? _instance;
  static ColumnPresetIndexMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ColumnPresetIndexMapper._());
      ColumnPresetEntryMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ColumnPresetIndex';

  static List<ColumnPresetEntry> _$presets(ColumnPresetIndex v) => v.presets;
  static const Field<ColumnPresetIndex, List<ColumnPresetEntry>> _f$presets =
      Field('presets', _$presets);
  static String _$selectedKey(ColumnPresetIndex v) => v.selectedKey;
  static const Field<ColumnPresetIndex, String> _f$selectedKey = Field(
    'selectedKey',
    _$selectedKey,
  );

  @override
  final MappableFields<ColumnPresetIndex> fields = const {
    #presets: _f$presets,
    #selectedKey: _f$selectedKey,
  };

  static ColumnPresetIndex _instantiate(DecodingData data) {
    return ColumnPresetIndex(
      presets: data.dec(_f$presets),
      selectedKey: data.dec(_f$selectedKey),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ColumnPresetIndex fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ColumnPresetIndex>(map);
  }

  static ColumnPresetIndex fromJson(String json) {
    return ensureInitialized().decodeJson<ColumnPresetIndex>(json);
  }
}

mixin ColumnPresetIndexMappable {
  String toJson() {
    return ColumnPresetIndexMapper.ensureInitialized()
        .encodeJson<ColumnPresetIndex>(this as ColumnPresetIndex);
  }

  Map<String, dynamic> toMap() {
    return ColumnPresetIndexMapper.ensureInitialized()
        .encodeMap<ColumnPresetIndex>(this as ColumnPresetIndex);
  }
}

