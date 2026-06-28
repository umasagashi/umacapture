// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'base.dart';

class RowHeightModeMapper extends EnumMapper<RowHeightMode> {
  RowHeightModeMapper._();

  static RowHeightModeMapper? _instance;
  static RowHeightModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RowHeightModeMapper._());
    }
    return _instance!;
  }

  static RowHeightMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  RowHeightMode decode(dynamic value) {
    switch (value) {
      case r'wrap':
        return RowHeightMode.wrap;
      case r'auto_per_row':
        return RowHeightMode.autoPerRow;
      case r'auto_uniform':
        return RowHeightMode.autoUniform;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(RowHeightMode self) {
    switch (self) {
      case RowHeightMode.wrap:
        return r'wrap';
      case RowHeightMode.autoPerRow:
        return r'auto_per_row';
      case RowHeightMode.autoUniform:
        return r'auto_uniform';
    }
  }
}

extension RowHeightModeMapperExtension on RowHeightMode {
  String toValue() {
    RowHeightModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<RowHeightMode>(this) as String;
  }
}

class ColumnSpecCellActionMapper extends EnumMapper<ColumnSpecCellAction> {
  ColumnSpecCellActionMapper._();

  static ColumnSpecCellActionMapper? _instance;
  static ColumnSpecCellActionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ColumnSpecCellActionMapper._());
    }
    return _instance!;
  }

  static ColumnSpecCellAction fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  ColumnSpecCellAction decode(dynamic value) {
    switch (value) {
      case r'openSkillPreview':
        return ColumnSpecCellAction.openSkillPreview;
      case r'openFactorPreview':
        return ColumnSpecCellAction.openFactorPreview;
      case r'openCampaignPreview':
        return ColumnSpecCellAction.openCampaignPreview;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(ColumnSpecCellAction self) {
    switch (self) {
      case ColumnSpecCellAction.openSkillPreview:
        return r'openSkillPreview';
      case ColumnSpecCellAction.openFactorPreview:
        return r'openFactorPreview';
      case ColumnSpecCellAction.openCampaignPreview:
        return r'openCampaignPreview';
    }
  }
}

extension ColumnSpecCellActionMapperExtension on ColumnSpecCellAction {
  String toValue() {
    ColumnSpecCellActionMapper.ensureInitialized();
    return MapperContainer.globals.toValue<ColumnSpecCellAction>(this)
        as String;
  }
}

class TagMapper extends ClassMapperBase<Tag> {
  TagMapper._();

  static TagMapper? _instance;
  static TagMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TagMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Tag';

  static String _$id(Tag v) => v.id;
  static const Field<Tag, String> _f$id = Field('id', _$id);
  static String _$name(Tag v) => v.name;
  static const Field<Tag, String> _f$name = Field('name', _$name);

  @override
  final MappableFields<Tag> fields = const {#id: _f$id, #name: _f$name};

  static Tag _instantiate(DecodingData data) {
    return Tag(data.dec(_f$id), data.dec(_f$name));
  }

  @override
  final Function instantiate = _instantiate;

  static Tag fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Tag>(map);
  }

  static Tag fromJson(String json) {
    return ensureInitialized().decodeJson<Tag>(json);
  }
}

mixin TagMappable {
  String toJson() {
    return TagMapper.ensureInitialized().encodeJson<Tag>(this as Tag);
  }

  Map<String, dynamic> toMap() {
    return TagMapper.ensureInitialized().encodeMap<Tag>(this as Tag);
  }
}

class SkillInfoMapper extends ClassMapperBase<SkillInfo> {
  SkillInfoMapper._();

  static SkillInfoMapper? _instance;
  static SkillInfoMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillInfoMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'SkillInfo';

  static int _$sid(SkillInfo v) => v.sid;
  static const Field<SkillInfo, int> _f$sid = Field('sid', _$sid);
  static int _$sortKey(SkillInfo v) => v.sortKey;
  static const Field<SkillInfo, int> _f$sortKey = Field(
    'sortKey',
    _$sortKey,
    key: r'sort_key',
  );
  static List<String> _$names(SkillInfo v) => v.names;
  static const Field<SkillInfo, List<String>> _f$names = Field(
    'names',
    _$names,
  );
  static List<String> _$descriptions(SkillInfo v) => v.descriptions;
  static const Field<SkillInfo, List<String>> _f$descriptions = Field(
    'descriptions',
    _$descriptions,
  );
  static Set<String> _$tags(SkillInfo v) => v.tags;
  static const Field<SkillInfo, Set<String>> _f$tags = Field('tags', _$tags);

  @override
  final MappableFields<SkillInfo> fields = const {
    #sid: _f$sid,
    #sortKey: _f$sortKey,
    #names: _f$names,
    #descriptions: _f$descriptions,
    #tags: _f$tags,
  };

  static SkillInfo _instantiate(DecodingData data) {
    return SkillInfo(
      data.dec(_f$sid),
      data.dec(_f$sortKey),
      data.dec(_f$names),
      data.dec(_f$descriptions),
      data.dec(_f$tags),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static SkillInfo fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SkillInfo>(map);
  }

  static SkillInfo fromJson(String json) {
    return ensureInitialized().decodeJson<SkillInfo>(json);
  }
}

mixin SkillInfoMappable {
  String toJson() {
    return SkillInfoMapper.ensureInitialized().encodeJson<SkillInfo>(
      this as SkillInfo,
    );
  }

  Map<String, dynamic> toMap() {
    return SkillInfoMapper.ensureInitialized().encodeMap<SkillInfo>(
      this as SkillInfo,
    );
  }
}

class FactorInfoMapper extends ClassMapperBase<FactorInfo> {
  FactorInfoMapper._();

  static FactorInfoMapper? _instance;
  static FactorInfoMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorInfoMapper._());
      SkillInfoMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FactorInfo';

  static int _$sid(FactorInfo v) => v.sid;
  static const Field<FactorInfo, int> _f$sid = Field('sid', _$sid);
  static int _$sortKey(FactorInfo v) => v.sortKey;
  static const Field<FactorInfo, int> _f$sortKey = Field(
    'sortKey',
    _$sortKey,
    key: r'sort_key',
  );
  static List<String> _$names(FactorInfo v) => v.names;
  static const Field<FactorInfo, List<String>> _f$names = Field(
    'names',
    _$names,
  );
  static List<String> _$descriptions(FactorInfo v) => v.descriptions;
  static const Field<FactorInfo, List<String>> _f$descriptions = Field(
    'descriptions',
    _$descriptions,
  );
  static Set<String> _$tags(FactorInfo v) => v.tags;
  static const Field<FactorInfo, Set<String>> _f$tags = Field('tags', _$tags);
  static int? _$skillSid(FactorInfo v) => v.skillSid;
  static const Field<FactorInfo, int> _f$skillSid = Field(
    'skillSid',
    _$skillSid,
    key: r'skill_sid',
    opt: true,
  );
  static SkillInfo? _$skillInfo(FactorInfo v) => v.skillInfo;
  static const Field<FactorInfo, SkillInfo> _f$skillInfo = Field(
    'skillInfo',
    _$skillInfo,
    key: r'skill_info',
    opt: true,
  );

  @override
  final MappableFields<FactorInfo> fields = const {
    #sid: _f$sid,
    #sortKey: _f$sortKey,
    #names: _f$names,
    #descriptions: _f$descriptions,
    #tags: _f$tags,
    #skillSid: _f$skillSid,
    #skillInfo: _f$skillInfo,
  };

  static FactorInfo _instantiate(DecodingData data) {
    return FactorInfo(
      sid: data.dec(_f$sid),
      sortKey: data.dec(_f$sortKey),
      names: data.dec(_f$names),
      descriptions: data.dec(_f$descriptions),
      tags: data.dec(_f$tags),
      skillSid: data.dec(_f$skillSid),
      skillInfo: data.dec(_f$skillInfo),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static FactorInfo fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FactorInfo>(map);
  }

  static FactorInfo fromJson(String json) {
    return ensureInitialized().decodeJson<FactorInfo>(json);
  }
}

mixin FactorInfoMappable {
  String toJson() {
    return FactorInfoMapper.ensureInitialized().encodeJson<FactorInfo>(
      this as FactorInfo,
    );
  }

  Map<String, dynamic> toMap() {
    return FactorInfoMapper.ensureInitialized().encodeMap<FactorInfo>(
      this as FactorInfo,
    );
  }
}

class CharaCardInfoMapper extends ClassMapperBase<CharaCardInfo> {
  CharaCardInfoMapper._();

  static CharaCardInfoMapper? _instance;
  static CharaCardInfoMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CharaCardInfoMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'CharaCardInfo';

  static int _$sid(CharaCardInfo v) => v.sid;
  static const Field<CharaCardInfo, int> _f$sid = Field('sid', _$sid);
  static int _$sortKey(CharaCardInfo v) => v.sortKey;
  static const Field<CharaCardInfo, int> _f$sortKey = Field(
    'sortKey',
    _$sortKey,
    key: r'sort_key',
  );
  static List<String> _$names(CharaCardInfo v) => v.names;
  static const Field<CharaCardInfo, List<String>> _f$names = Field(
    'names',
    _$names,
  );

  @override
  final MappableFields<CharaCardInfo> fields = const {
    #sid: _f$sid,
    #sortKey: _f$sortKey,
    #names: _f$names,
  };

  static CharaCardInfo _instantiate(DecodingData data) {
    return CharaCardInfo(
      data.dec(_f$sid),
      data.dec(_f$sortKey),
      data.dec(_f$names),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CharaCardInfo fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CharaCardInfo>(map);
  }

  static CharaCardInfo fromJson(String json) {
    return ensureInitialized().decodeJson<CharaCardInfo>(json);
  }
}

mixin CharaCardInfoMappable {
  String toJson() {
    return CharaCardInfoMapper.ensureInitialized().encodeJson<CharaCardInfo>(
      this as CharaCardInfo,
    );
  }

  Map<String, dynamic> toMap() {
    return CharaCardInfoMapper.ensureInitialized().encodeMap<CharaCardInfo>(
      this as CharaCardInfo,
    );
  }
}

class RaceTitleInfoMapper extends ClassMapperBase<RaceTitleInfo> {
  RaceTitleInfoMapper._();

  static RaceTitleInfoMapper? _instance;
  static RaceTitleInfoMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RaceTitleInfoMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'RaceTitleInfo';

  static int _$sid(RaceTitleInfo v) => v.sid;
  static const Field<RaceTitleInfo, int> _f$sid = Field('sid', _$sid);
  static int _$sortKey(RaceTitleInfo v) => v.sortKey;
  static const Field<RaceTitleInfo, int> _f$sortKey = Field(
    'sortKey',
    _$sortKey,
    key: r'sort_key',
  );
  static List<String> _$names(RaceTitleInfo v) => v.names;
  static const Field<RaceTitleInfo, List<String>> _f$names = Field(
    'names',
    _$names,
  );
  static List<String> _$descriptions(RaceTitleInfo v) => v.descriptions;
  static const Field<RaceTitleInfo, List<String>> _f$descriptions = Field(
    'descriptions',
    _$descriptions,
  );
  static Set<String> _$tags(RaceTitleInfo v) => v.tags;
  static const Field<RaceTitleInfo, Set<String>> _f$tags = Field(
    'tags',
    _$tags,
  );

  @override
  final MappableFields<RaceTitleInfo> fields = const {
    #sid: _f$sid,
    #sortKey: _f$sortKey,
    #names: _f$names,
    #descriptions: _f$descriptions,
    #tags: _f$tags,
  };

  static RaceTitleInfo _instantiate(DecodingData data) {
    return RaceTitleInfo(
      data.dec(_f$sid),
      data.dec(_f$sortKey),
      data.dec(_f$names),
      data.dec(_f$descriptions),
      data.dec(_f$tags),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RaceTitleInfo fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RaceTitleInfo>(map);
  }

  static RaceTitleInfo fromJson(String json) {
    return ensureInitialized().decodeJson<RaceTitleInfo>(json);
  }
}

mixin RaceTitleInfoMappable {
  String toJson() {
    return RaceTitleInfoMapper.ensureInitialized().encodeJson<RaceTitleInfo>(
      this as RaceTitleInfo,
    );
  }

  Map<String, dynamic> toMap() {
    return RaceTitleInfoMapper.ensureInitialized().encodeMap<RaceTitleInfo>(
      this as RaceTitleInfo,
    );
  }
}

class ColumnSpecMapper extends ClassMapperBase<ColumnSpec> {
  ColumnSpecMapper._();

  static ColumnSpecMapper? _instance;
  static ColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ColumnSpecMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ColumnSpec';
  @override
  Function get typeFactory =>
      <T>(f) => f<ColumnSpec<T>>();

  @override
  final MappableFields<ColumnSpec> fields = const {};

  static ColumnSpec<T> _instantiate<T>(DecodingData data) {
    throw MapperException.missingConstructor('ColumnSpec');
  }

  @override
  final Function instantiate = _instantiate;

  static ColumnSpec<T> fromMap<T>(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ColumnSpec<T>>(map);
  }

  static ColumnSpec<T> fromJson<T>(String json) {
    return ensureInitialized().decodeJson<ColumnSpec<T>>(json);
  }
}

mixin ColumnSpecMappable<T> {
  String toJson();
  Map<String, dynamic> toMap();
}

