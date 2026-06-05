// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'factor.dart';

class FactorSetLogicModeMapper extends EnumMapper<FactorSetLogicMode> {
  FactorSetLogicModeMapper._();

  static FactorSetLogicModeMapper? _instance;
  static FactorSetLogicModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorSetLogicModeMapper._());
    }
    return _instance!;
  }

  static FactorSetLogicMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  FactorSetLogicMode decode(dynamic value) {
    switch (value) {
      case r'anyOf':
        return FactorSetLogicMode.anyOf;
      case r'allOf':
        return FactorSetLogicMode.allOf;
      case r'mixed':
        return FactorSetLogicMode.mixed;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(FactorSetLogicMode self) {
    switch (self) {
      case FactorSetLogicMode.anyOf:
        return r'anyOf';
      case FactorSetLogicMode.allOf:
        return r'allOf';
      case FactorSetLogicMode.mixed:
        return r'mixed';
    }
  }
}

extension FactorSetLogicModeMapperExtension on FactorSetLogicMode {
  String toValue() {
    FactorSetLogicModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<FactorSetLogicMode>(this) as String;
  }
}

class FactorSearchSubjectModeMapper
    extends EnumMapper<FactorSearchSubjectMode> {
  FactorSearchSubjectModeMapper._();

  static FactorSearchSubjectModeMapper? _instance;
  static FactorSearchSubjectModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = FactorSearchSubjectModeMapper._(),
      );
    }
    return _instance!;
  }

  static FactorSearchSubjectMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  FactorSearchSubjectMode decode(dynamic value) {
    switch (value) {
      case r'trainee':
        return FactorSearchSubjectMode.trainee;
      case r'family':
        return FactorSearchSubjectMode.family;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(FactorSearchSubjectMode self) {
    switch (self) {
      case FactorSearchSubjectMode.trainee:
        return r'trainee';
      case FactorSearchSubjectMode.family:
        return r'family';
    }
  }
}

extension FactorSearchSubjectModeMapperExtension on FactorSearchSubjectMode {
  String toValue() {
    FactorSearchSubjectModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<FactorSearchSubjectMode>(this)
        as String;
  }
}

class FactorSearchElementModeMapper
    extends EnumMapper<FactorSearchElementMode> {
  FactorSearchElementModeMapper._();

  static FactorSearchElementModeMapper? _instance;
  static FactorSearchElementModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = FactorSearchElementModeMapper._(),
      );
    }
    return _instance!;
  }

  static FactorSearchElementMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  FactorSearchElementMode decode(dynamic value) {
    switch (value) {
      case r'starOnly':
        return FactorSearchElementMode.starOnly;
      case r'starAndCount':
        return FactorSearchElementMode.starAndCount;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(FactorSearchElementMode self) {
    switch (self) {
      case FactorSearchElementMode.starOnly:
        return r'starOnly';
      case FactorSearchElementMode.starAndCount:
        return r'starAndCount';
    }
  }
}

extension FactorSearchElementModeMapperExtension on FactorSearchElementMode {
  String toValue() {
    FactorSearchElementModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<FactorSearchElementMode>(this)
        as String;
  }
}

class FactorNotationModeMapper extends EnumMapper<FactorNotationMode> {
  FactorNotationModeMapper._();

  static FactorNotationModeMapper? _instance;
  static FactorNotationModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorNotationModeMapper._());
    }
    return _instance!;
  }

  static FactorNotationMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  FactorNotationMode decode(dynamic value) {
    switch (value) {
      case r'sumOnly':
        return FactorNotationMode.sumOnly;
      case r'traineeAndParents':
        return FactorNotationMode.traineeAndParents;
      case r'each':
        return FactorNotationMode.each;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(FactorNotationMode self) {
    switch (self) {
      case FactorNotationMode.sumOnly:
        return r'sumOnly';
      case FactorNotationMode.traineeAndParents:
        return r'traineeAndParents';
      case FactorNotationMode.each:
        return r'each';
    }
  }
}

extension FactorNotationModeMapperExtension on FactorNotationMode {
  String toValue() {
    FactorNotationModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<FactorNotationMode>(this) as String;
  }
}

class FactorDialogElementsMapper extends EnumMapper<FactorDialogElements> {
  FactorDialogElementsMapper._();

  static FactorDialogElementsMapper? _instance;
  static FactorDialogElementsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorDialogElementsMapper._());
    }
    return _instance!;
  }

  static FactorDialogElements fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  FactorDialogElements decode(dynamic value) {
    switch (value) {
      case r'selectionTags':
        return FactorDialogElements.selectionTags;
      case r'modeLogic':
        return FactorDialogElements.modeLogic;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(FactorDialogElements self) {
    switch (self) {
      case FactorDialogElements.selectionTags:
        return r'selectionTags';
      case FactorDialogElements.modeLogic:
        return r'modeLogic';
    }
  }
}

extension FactorDialogElementsMapperExtension on FactorDialogElements {
  String toValue() {
    FactorDialogElementsMapper.ensureInitialized();
    return MapperContainer.globals.toValue<FactorDialogElements>(this)
        as String;
  }
}

class FactorSearchElementMapper extends ClassMapperBase<FactorSearchElement> {
  FactorSearchElementMapper._();

  static FactorSearchElementMapper? _instance;
  static FactorSearchElementMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorSearchElementMapper._());
      FactorSearchElementModeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FactorSearchElement';

  static FactorSearchElementMode _$mode(FactorSearchElement v) => v.mode;
  static const Field<FactorSearchElement, FactorSearchElementMode> _f$mode =
      Field('mode', _$mode);
  static int _$star(FactorSearchElement v) => v.star;
  static const Field<FactorSearchElement, int> _f$star = Field('star', _$star);
  static int _$count(FactorSearchElement v) => v.count;
  static const Field<FactorSearchElement, int> _f$count = Field(
    'count',
    _$count,
  );

  @override
  final MappableFields<FactorSearchElement> fields = const {
    #mode: _f$mode,
    #star: _f$star,
    #count: _f$count,
  };

  static FactorSearchElement _instantiate(DecodingData data) {
    return FactorSearchElement(
      mode: data.dec(_f$mode),
      star: data.dec(_f$star),
      count: data.dec(_f$count),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static FactorSearchElement fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FactorSearchElement>(map);
  }

  static FactorSearchElement fromJson(String json) {
    return ensureInitialized().decodeJson<FactorSearchElement>(json);
  }
}

mixin FactorSearchElementMappable {
  String toJson() {
    return FactorSearchElementMapper.ensureInitialized()
        .encodeJson<FactorSearchElement>(this as FactorSearchElement);
  }

  Map<String, dynamic> toMap() {
    return FactorSearchElementMapper.ensureInitialized()
        .encodeMap<FactorSearchElement>(this as FactorSearchElement);
  }
}

class FactorNotationMapper extends ClassMapperBase<FactorNotation> {
  FactorNotationMapper._();

  static FactorNotationMapper? _instance;
  static FactorNotationMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorNotationMapper._());
      FactorNotationModeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FactorNotation';

  static FactorNotationMode _$mode(FactorNotation v) => v.mode;
  static const Field<FactorNotation, FactorNotationMode> _f$mode = Field(
    'mode',
    _$mode,
  );
  static int _$max(FactorNotation v) => v.max;
  static const Field<FactorNotation, int> _f$max = Field('max', _$max);

  @override
  final MappableFields<FactorNotation> fields = const {
    #mode: _f$mode,
    #max: _f$max,
  };

  static FactorNotation _instantiate(DecodingData data) {
    return FactorNotation(mode: data.dec(_f$mode), max: data.dec(_f$max));
  }

  @override
  final Function instantiate = _instantiate;

  static FactorNotation fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FactorNotation>(map);
  }

  static FactorNotation fromJson(String json) {
    return ensureInitialized().decodeJson<FactorNotation>(json);
  }
}

mixin FactorNotationMappable {
  String toJson() {
    return FactorNotationMapper.ensureInitialized().encodeJson<FactorNotation>(
      this as FactorNotation,
    );
  }

  Map<String, dynamic> toMap() {
    return FactorNotationMapper.ensureInitialized().encodeMap<FactorNotation>(
      this as FactorNotation,
    );
  }
}

class AggregateFactorSetPredicateMapper
    extends ClassMapperBase<AggregateFactorSetPredicate> {
  AggregateFactorSetPredicateMapper._();

  static AggregateFactorSetPredicateMapper? _instance;
  static AggregateFactorSetPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = AggregateFactorSetPredicateMapper._(),
      );
      FactorSetLogicModeMapper.ensureInitialized();
      FactorSearchSubjectModeMapper.ensureInitialized();
      FactorSearchElementMapper.ensureInitialized();
      FactorNotationMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'AggregateFactorSetPredicate';

  static Set<int> _$query(AggregateFactorSetPredicate v) => v.query;
  static const Field<AggregateFactorSetPredicate, Set<int>> _f$query = Field(
    'query',
    _$query,
    opt: true,
    def: const {},
  );
  static FactorSetLogicMode _$logic(AggregateFactorSetPredicate v) => v.logic;
  static const Field<AggregateFactorSetPredicate, FactorSetLogicMode> _f$logic =
      Field('logic', _$logic, opt: true, def: FactorSetLogicMode.anyOf);
  static FactorSearchSubjectMode _$subject(AggregateFactorSetPredicate v) =>
      v.subject;
  static const Field<AggregateFactorSetPredicate, FactorSearchSubjectMode>
  _f$subject = Field(
    'subject',
    _$subject,
    opt: true,
    def: FactorSearchSubjectMode.family,
  );
  static FactorSearchElement _$element(AggregateFactorSetPredicate v) =>
      v.element;
  static const Field<AggregateFactorSetPredicate, FactorSearchElement>
  _f$element = Field('element', _$element);
  static FactorNotation _$notation(AggregateFactorSetPredicate v) => v.notation;
  static const Field<AggregateFactorSetPredicate, FactorNotation> _f$notation =
      Field('notation', _$notation);
  static Set<String> _$factorTags(AggregateFactorSetPredicate v) =>
      v.factorTags;
  static const Field<AggregateFactorSetPredicate, Set<String>> _f$factorTags =
      Field('factorTags', _$factorTags, opt: true, def: const {});
  static Set<String> _$skillTags(AggregateFactorSetPredicate v) => v.skillTags;
  static const Field<AggregateFactorSetPredicate, Set<String>> _f$skillTags =
      Field('skillTags', _$skillTags, opt: true, def: const {});

  @override
  final MappableFields<AggregateFactorSetPredicate> fields = const {
    #query: _f$query,
    #logic: _f$logic,
    #subject: _f$subject,
    #element: _f$element,
    #notation: _f$notation,
    #factorTags: _f$factorTags,
    #skillTags: _f$skillTags,
  };

  static AggregateFactorSetPredicate _instantiate(DecodingData data) {
    return AggregateFactorSetPredicate(
      query: data.dec(_f$query),
      logic: data.dec(_f$logic),
      subject: data.dec(_f$subject),
      element: data.dec(_f$element),
      notation: data.dec(_f$notation),
      factorTags: data.dec(_f$factorTags),
      skillTags: data.dec(_f$skillTags),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static AggregateFactorSetPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<AggregateFactorSetPredicate>(map);
  }

  static AggregateFactorSetPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<AggregateFactorSetPredicate>(json);
  }
}

mixin AggregateFactorSetPredicateMappable {
  String toJson() {
    return AggregateFactorSetPredicateMapper.ensureInitialized()
        .encodeJson<AggregateFactorSetPredicate>(
          this as AggregateFactorSetPredicate,
        );
  }

  Map<String, dynamic> toMap() {
    return AggregateFactorSetPredicateMapper.ensureInitialized()
        .encodeMap<AggregateFactorSetPredicate>(
          this as AggregateFactorSetPredicate,
        );
  }
}

class FactorColumnSpecMapper extends SubClassMapperBase<FactorColumnSpec> {
  FactorColumnSpecMapper._();

  static FactorColumnSpecMapper? _instance;
  static FactorColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      AggregateFactorSetPredicateMapper.ensureInitialized();
      FactorDialogElementsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FactorColumnSpec';

  static String _$id(FactorColumnSpec v) => v.id;
  static const Field<FactorColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(FactorColumnSpec v) => v.title;
  static const Field<FactorColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(FactorColumnSpec v) => v.parser;
  static const Field<FactorColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static AggregateFactorSetPredicate _$predicate(FactorColumnSpec v) =>
      v.predicate;
  static const Field<FactorColumnSpec, AggregateFactorSetPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static bool _$showAllWhenQueryIsEmpty(FactorColumnSpec v) =>
      v.showAllWhenQueryIsEmpty;
  static const Field<FactorColumnSpec, bool> _f$showAllWhenQueryIsEmpty = Field(
    'showAllWhenQueryIsEmpty',
    _$showAllWhenQueryIsEmpty,
    opt: true,
    def: true,
  );
  static bool _$showAvailableOnly(FactorColumnSpec v) => v.showAvailableOnly;
  static const Field<FactorColumnSpec, bool> _f$showAvailableOnly = Field(
    'showAvailableOnly',
    _$showAvailableOnly,
    opt: true,
    def: true,
  );
  static Set<FactorDialogElements> _$hiddenElements(FactorColumnSpec v) =>
      v.hiddenElements;
  static const Field<FactorColumnSpec, Set<FactorDialogElements>>
  _f$hiddenElements = Field(
    'hiddenElements',
    _$hiddenElements,
    opt: true,
    def: const {},
  );
  static String _$labelKey(FactorColumnSpec v) => v.labelKey;
  static const Field<FactorColumnSpec, String> _f$labelKey = Field(
    'labelKey',
    _$labelKey,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<FactorColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #predicate: _f$predicate,
    #showAllWhenQueryIsEmpty: _f$showAllWhenQueryIsEmpty,
    #showAvailableOnly: _f$showAvailableOnly,
    #hiddenElements: _f$hiddenElements,
    #labelKey: _f$labelKey,
  };

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'FactorColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static FactorColumnSpec _instantiate(DecodingData data) {
    return FactorColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      predicate: data.dec(_f$predicate),
      showAllWhenQueryIsEmpty: data.dec(_f$showAllWhenQueryIsEmpty),
      showAvailableOnly: data.dec(_f$showAvailableOnly),
      hiddenElements: data.dec(_f$hiddenElements),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static FactorColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FactorColumnSpec>(map);
  }

  static FactorColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<FactorColumnSpec>(json);
  }
}

mixin FactorColumnSpecMappable {
  String toJson() {
    return FactorColumnSpecMapper.ensureInitialized()
        .encodeJson<FactorColumnSpec>(this as FactorColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return FactorColumnSpecMapper.ensureInitialized()
        .encodeMap<FactorColumnSpec>(this as FactorColumnSpec);
  }
}

