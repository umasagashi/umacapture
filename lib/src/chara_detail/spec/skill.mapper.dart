// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'skill.dart';

class SkillSetLogicModeMapper extends EnumMapper<SkillSetLogicMode> {
  SkillSetLogicModeMapper._();

  static SkillSetLogicModeMapper? _instance;
  static SkillSetLogicModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillSetLogicModeMapper._());
    }
    return _instance!;
  }

  static SkillSetLogicMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  SkillSetLogicMode decode(dynamic value) {
    switch (value) {
      case r'anyOf':
        return SkillSetLogicMode.anyOf;
      case r'allOf':
        return SkillSetLogicMode.allOf;
      case r'sumOf':
        return SkillSetLogicMode.sumOf;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(SkillSetLogicMode self) {
    switch (self) {
      case SkillSetLogicMode.anyOf:
        return r'anyOf';
      case SkillSetLogicMode.allOf:
        return r'allOf';
      case SkillSetLogicMode.sumOf:
        return r'sumOf';
    }
  }
}

extension SkillSetLogicModeMapperExtension on SkillSetLogicMode {
  String toValue() {
    SkillSetLogicModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<SkillSetLogicMode>(this) as String;
  }
}

class SkillNotationModeMapper extends EnumMapper<SkillNotationMode> {
  SkillNotationModeMapper._();

  static SkillNotationModeMapper? _instance;
  static SkillNotationModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillNotationModeMapper._());
    }
    return _instance!;
  }

  static SkillNotationMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  SkillNotationMode decode(dynamic value) {
    switch (value) {
      case r'names':
        return SkillNotationMode.names;
      case r'count':
        return SkillNotationMode.count;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(SkillNotationMode self) {
    switch (self) {
      case SkillNotationMode.names:
        return r'names';
      case SkillNotationMode.count:
        return r'count';
    }
  }
}

extension SkillNotationModeMapperExtension on SkillNotationMode {
  String toValue() {
    SkillNotationModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<SkillNotationMode>(this) as String;
  }
}

class SkillDialogElementsMapper extends EnumMapper<SkillDialogElements> {
  SkillDialogElementsMapper._();

  static SkillDialogElementsMapper? _instance;
  static SkillDialogElementsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillDialogElementsMapper._());
    }
    return _instance!;
  }

  static SkillDialogElements fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  SkillDialogElements decode(dynamic value) {
    switch (value) {
      case r'selection':
        return SkillDialogElements.selection;
      case r'selectionList':
        return SkillDialogElements.selectionList;
      case r'selectionTags':
        return SkillDialogElements.selectionTags;
      case r'mode':
        return SkillDialogElements.mode;
      case r'notationMax':
        return SkillDialogElements.notationMax;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(SkillDialogElements self) {
    switch (self) {
      case SkillDialogElements.selection:
        return r'selection';
      case SkillDialogElements.selectionList:
        return r'selectionList';
      case SkillDialogElements.selectionTags:
        return r'selectionTags';
      case SkillDialogElements.mode:
        return r'mode';
      case SkillDialogElements.notationMax:
        return r'notationMax';
    }
  }
}

extension SkillDialogElementsMapperExtension on SkillDialogElements {
  String toValue() {
    SkillDialogElementsMapper.ensureInitialized();
    return MapperContainer.globals.toValue<SkillDialogElements>(this) as String;
  }
}

class SkillNotationMapper extends ClassMapperBase<SkillNotation> {
  SkillNotationMapper._();

  static SkillNotationMapper? _instance;
  static SkillNotationMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillNotationMapper._());
      SkillNotationModeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'SkillNotation';

  static SkillNotationMode _$mode(SkillNotation v) => v.mode;
  static const Field<SkillNotation, SkillNotationMode> _f$mode = Field(
    'mode',
    _$mode,
    opt: true,
    def: SkillNotationMode.names,
  );
  static int _$max(SkillNotation v) => v.max;
  static const Field<SkillNotation, int> _f$max = Field(
    'max',
    _$max,
    opt: true,
    def: 3,
  );

  @override
  final MappableFields<SkillNotation> fields = const {
    #mode: _f$mode,
    #max: _f$max,
  };

  static SkillNotation _instantiate(DecodingData data) {
    return SkillNotation(mode: data.dec(_f$mode), max: data.dec(_f$max));
  }

  @override
  final Function instantiate = _instantiate;

  static SkillNotation fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SkillNotation>(map);
  }

  static SkillNotation fromJson(String json) {
    return ensureInitialized().decodeJson<SkillNotation>(json);
  }
}

mixin SkillNotationMappable {
  String toJson() {
    return SkillNotationMapper.ensureInitialized().encodeJson<SkillNotation>(
      this as SkillNotation,
    );
  }

  Map<String, dynamic> toMap() {
    return SkillNotationMapper.ensureInitialized().encodeMap<SkillNotation>(
      this as SkillNotation,
    );
  }
}

class AggregateSkillPredicateMapper
    extends ClassMapperBase<AggregateSkillPredicate> {
  AggregateSkillPredicateMapper._();

  static AggregateSkillPredicateMapper? _instance;
  static AggregateSkillPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = AggregateSkillPredicateMapper._(),
      );
      SkillSetLogicModeMapper.ensureInitialized();
      SkillNotationMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'AggregateSkillPredicate';

  static Set<int> _$query(AggregateSkillPredicate v) => v.query;
  static const Field<AggregateSkillPredicate, Set<int>> _f$query = Field(
    'query',
    _$query,
    opt: true,
    def: const {},
  );
  static SkillSetLogicMode _$logic(AggregateSkillPredicate v) => v.logic;
  static const Field<AggregateSkillPredicate, SkillSetLogicMode> _f$logic =
      Field('logic', _$logic, opt: true, def: SkillSetLogicMode.anyOf);
  static int _$min(AggregateSkillPredicate v) => v.min;
  static const Field<AggregateSkillPredicate, int> _f$min = Field(
    'min',
    _$min,
    opt: true,
    def: 1,
  );
  static SkillNotation _$notation(AggregateSkillPredicate v) => v.notation;
  static const Field<AggregateSkillPredicate, SkillNotation> _f$notation =
      Field('notation', _$notation);
  static Set<String> _$tags(AggregateSkillPredicate v) => v.tags;
  static const Field<AggregateSkillPredicate, Set<String>> _f$tags = Field(
    'tags',
    _$tags,
    opt: true,
    def: const {},
  );

  @override
  final MappableFields<AggregateSkillPredicate> fields = const {
    #query: _f$query,
    #logic: _f$logic,
    #min: _f$min,
    #notation: _f$notation,
    #tags: _f$tags,
  };

  static AggregateSkillPredicate _instantiate(DecodingData data) {
    return AggregateSkillPredicate(
      query: data.dec(_f$query),
      logic: data.dec(_f$logic),
      min: data.dec(_f$min),
      notation: data.dec(_f$notation),
      tags: data.dec(_f$tags),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static AggregateSkillPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<AggregateSkillPredicate>(map);
  }

  static AggregateSkillPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<AggregateSkillPredicate>(json);
  }
}

mixin AggregateSkillPredicateMappable {
  String toJson() {
    return AggregateSkillPredicateMapper.ensureInitialized()
        .encodeJson<AggregateSkillPredicate>(this as AggregateSkillPredicate);
  }

  Map<String, dynamic> toMap() {
    return AggregateSkillPredicateMapper.ensureInitialized()
        .encodeMap<AggregateSkillPredicate>(this as AggregateSkillPredicate);
  }
}

class SkillColumnSpecMapper extends SubClassMapperBase<SkillColumnSpec> {
  SkillColumnSpecMapper._();

  static SkillColumnSpecMapper? _instance;
  static SkillColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      AggregateSkillPredicateMapper.ensureInitialized();
      SkillDialogElementsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'SkillColumnSpec';

  static String _$id(SkillColumnSpec v) => v.id;
  static const Field<SkillColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(SkillColumnSpec v) => v.title;
  static const Field<SkillColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(SkillColumnSpec v) => v.parser;
  static const Field<SkillColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static AggregateSkillPredicate _$predicate(SkillColumnSpec v) => v.predicate;
  static const Field<SkillColumnSpec, AggregateSkillPredicate> _f$predicate =
      Field('predicate', _$predicate);
  static bool _$showAllWhenQueryIsEmpty(SkillColumnSpec v) =>
      v.showAllWhenQueryIsEmpty;
  static const Field<SkillColumnSpec, bool> _f$showAllWhenQueryIsEmpty = Field(
    'showAllWhenQueryIsEmpty',
    _$showAllWhenQueryIsEmpty,
    opt: true,
    def: true,
  );
  static bool _$showAvailableOnly(SkillColumnSpec v) => v.showAvailableOnly;
  static const Field<SkillColumnSpec, bool> _f$showAvailableOnly = Field(
    'showAvailableOnly',
    _$showAvailableOnly,
    opt: true,
    def: true,
  );
  static Set<SkillDialogElements> _$hiddenElements(SkillColumnSpec v) =>
      v.hiddenElements;
  static const Field<SkillColumnSpec, Set<SkillDialogElements>>
  _f$hiddenElements = Field(
    'hiddenElements',
    _$hiddenElements,
    opt: true,
    def: const {},
  );
  static bool _$selectByTag(SkillColumnSpec v) => v.selectByTag;
  static const Field<SkillColumnSpec, bool> _f$selectByTag = Field(
    'selectByTag',
    _$selectByTag,
    opt: true,
    def: false,
  );
  static bool _$hidden(SkillColumnSpec v) => v.hidden;
  static const Field<SkillColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(SkillColumnSpec v) => v.description;
  static const Field<SkillColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static double? _$width(SkillColumnSpec v) => v.width;
  static const Field<SkillColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );
  static String? _$builderId(SkillColumnSpec v) => v.builderId;
  static const Field<SkillColumnSpec, String> _f$builderId = Field(
    'builderId',
    _$builderId,
    opt: true,
  );
  static String _$labelKey(SkillColumnSpec v) => v.labelKey;
  static const Field<SkillColumnSpec, String> _f$labelKey = Field(
    'labelKey',
    _$labelKey,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<SkillColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #predicate: _f$predicate,
    #showAllWhenQueryIsEmpty: _f$showAllWhenQueryIsEmpty,
    #showAvailableOnly: _f$showAvailableOnly,
    #hiddenElements: _f$hiddenElements,
    #selectByTag: _f$selectByTag,
    #hidden: _f$hidden,
    #description: _f$description,
    #width: _f$width,
    #builderId: _f$builderId,
    #labelKey: _f$labelKey,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'SkillColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static SkillColumnSpec _instantiate(DecodingData data) {
    return SkillColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      predicate: data.dec(_f$predicate),
      showAllWhenQueryIsEmpty: data.dec(_f$showAllWhenQueryIsEmpty),
      showAvailableOnly: data.dec(_f$showAvailableOnly),
      hiddenElements: data.dec(_f$hiddenElements),
      selectByTag: data.dec(_f$selectByTag),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
      width: data.dec(_f$width),
      builderId: data.dec(_f$builderId),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static SkillColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SkillColumnSpec>(map);
  }

  static SkillColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<SkillColumnSpec>(json);
  }
}

mixin SkillColumnSpecMappable {
  String toJson() {
    return SkillColumnSpecMapper.ensureInitialized()
        .encodeJson<SkillColumnSpec>(this as SkillColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return SkillColumnSpecMapper.ensureInitialized().encodeMap<SkillColumnSpec>(
      this as SkillColumnSpec,
    );
  }
}

