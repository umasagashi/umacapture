// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'ranged_integer.dart';

class IsInRangeIntegerPredicateMapper
    extends ClassMapperBase<IsInRangeIntegerPredicate> {
  IsInRangeIntegerPredicateMapper._();

  static IsInRangeIntegerPredicateMapper? _instance;
  static IsInRangeIntegerPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = IsInRangeIntegerPredicateMapper._(),
      );
    }
    return _instance!;
  }

  @override
  final String id = 'IsInRangeIntegerPredicate';

  static int? _$min(IsInRangeIntegerPredicate v) => v.min;
  static const Field<IsInRangeIntegerPredicate, int> _f$min = Field(
    'min',
    _$min,
    opt: true,
  );
  static int? _$max(IsInRangeIntegerPredicate v) => v.max;
  static const Field<IsInRangeIntegerPredicate, int> _f$max = Field(
    'max',
    _$max,
    opt: true,
  );

  @override
  final MappableFields<IsInRangeIntegerPredicate> fields = const {
    #min: _f$min,
    #max: _f$max,
  };

  static IsInRangeIntegerPredicate _instantiate(DecodingData data) {
    return IsInRangeIntegerPredicate(
      min: data.dec(_f$min),
      max: data.dec(_f$max),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static IsInRangeIntegerPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<IsInRangeIntegerPredicate>(map);
  }

  static IsInRangeIntegerPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<IsInRangeIntegerPredicate>(json);
  }
}

mixin IsInRangeIntegerPredicateMappable {
  String toJson() {
    return IsInRangeIntegerPredicateMapper.ensureInitialized()
        .encodeJson<IsInRangeIntegerPredicate>(
          this as IsInRangeIntegerPredicate,
        );
  }

  Map<String, dynamic> toMap() {
    return IsInRangeIntegerPredicateMapper.ensureInitialized()
        .encodeMap<IsInRangeIntegerPredicate>(
          this as IsInRangeIntegerPredicate,
        );
  }
}

class RangedIntegerColumnSpecMapper
    extends SubClassMapperBase<RangedIntegerColumnSpec> {
  RangedIntegerColumnSpecMapper._();

  static RangedIntegerColumnSpecMapper? _instance;
  static RangedIntegerColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = RangedIntegerColumnSpecMapper._(),
      );
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      IsInRangeIntegerPredicateMapper.ensureInitialized();
      ColumnSpecCellActionMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RangedIntegerColumnSpec';

  static String _$id(RangedIntegerColumnSpec v) => v.id;
  static const Field<RangedIntegerColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(RangedIntegerColumnSpec v) => v.title;
  static const Field<RangedIntegerColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(RangedIntegerColumnSpec v) => v.parser;
  static const Field<RangedIntegerColumnSpec, Parser<dynamic>> _f$parser =
      Field('parser', _$parser);
  static IsInRangeIntegerPredicate _$predicate(RangedIntegerColumnSpec v) =>
      v.predicate;
  static const Field<RangedIntegerColumnSpec, IsInRangeIntegerPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static ColumnSpecCellAction _$cellAction(RangedIntegerColumnSpec v) =>
      v.cellAction;
  static const Field<RangedIntegerColumnSpec, ColumnSpecCellAction>
  _f$cellAction = Field('cellAction', _$cellAction, opt: true);
  static bool _$hidden(RangedIntegerColumnSpec v) => v.hidden;
  static const Field<RangedIntegerColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(RangedIntegerColumnSpec v) => v.description;
  static const Field<RangedIntegerColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );

  @override
  final MappableFields<RangedIntegerColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #predicate: _f$predicate,
    #cellAction: _f$cellAction,
    #hidden: _f$hidden,
    #description: _f$description,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RangedIntegerColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RangedIntegerColumnSpec _instantiate(DecodingData data) {
    return RangedIntegerColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      predicate: data.dec(_f$predicate),
      cellAction: data.dec(_f$cellAction),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RangedIntegerColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RangedIntegerColumnSpec>(map);
  }

  static RangedIntegerColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<RangedIntegerColumnSpec>(json);
  }
}

mixin RangedIntegerColumnSpecMappable {
  String toJson() {
    return RangedIntegerColumnSpecMapper.ensureInitialized()
        .encodeJson<RangedIntegerColumnSpec>(this as RangedIntegerColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return RangedIntegerColumnSpecMapper.ensureInitialized()
        .encodeMap<RangedIntegerColumnSpec>(this as RangedIntegerColumnSpec);
  }
}

