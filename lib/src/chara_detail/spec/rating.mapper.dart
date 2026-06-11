// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'rating.dart';

class IsInRangeRatingPredicateMapper
    extends ClassMapperBase<IsInRangeRatingPredicate> {
  IsInRangeRatingPredicateMapper._();

  static IsInRangeRatingPredicateMapper? _instance;
  static IsInRangeRatingPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = IsInRangeRatingPredicateMapper._(),
      );
    }
    return _instance!;
  }

  @override
  final String id = 'IsInRangeRatingPredicate';

  static double? _$min(IsInRangeRatingPredicate v) => v.min;
  static const Field<IsInRangeRatingPredicate, double> _f$min = Field(
    'min',
    _$min,
    opt: true,
  );
  static double? _$max(IsInRangeRatingPredicate v) => v.max;
  static const Field<IsInRangeRatingPredicate, double> _f$max = Field(
    'max',
    _$max,
    opt: true,
  );

  @override
  final MappableFields<IsInRangeRatingPredicate> fields = const {
    #min: _f$min,
    #max: _f$max,
  };

  static IsInRangeRatingPredicate _instantiate(DecodingData data) {
    return IsInRangeRatingPredicate(
      min: data.dec(_f$min),
      max: data.dec(_f$max),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static IsInRangeRatingPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<IsInRangeRatingPredicate>(map);
  }

  static IsInRangeRatingPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<IsInRangeRatingPredicate>(json);
  }
}

mixin IsInRangeRatingPredicateMappable {
  String toJson() {
    return IsInRangeRatingPredicateMapper.ensureInitialized()
        .encodeJson<IsInRangeRatingPredicate>(this as IsInRangeRatingPredicate);
  }

  Map<String, dynamic> toMap() {
    return IsInRangeRatingPredicateMapper.ensureInitialized()
        .encodeMap<IsInRangeRatingPredicate>(this as IsInRangeRatingPredicate);
  }
}

class RatingColumnSpecMapper extends SubClassMapperBase<RatingColumnSpec> {
  RatingColumnSpecMapper._();

  static RatingColumnSpecMapper? _instance;
  static RatingColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RatingColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      IsInRangeRatingPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RatingColumnSpec';

  static String _$id(RatingColumnSpec v) => v.id;
  static const Field<RatingColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(RatingColumnSpec v) => v.title;
  static const Field<RatingColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(RatingColumnSpec v) => v.parser;
  static const Field<RatingColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static IsInRangeRatingPredicate _$predicate(RatingColumnSpec v) =>
      v.predicate;
  static const Field<RatingColumnSpec, IsInRangeRatingPredicate> _f$predicate =
      Field('predicate', _$predicate);
  static String _$storageKey(RatingColumnSpec v) => v.storageKey;
  static const Field<RatingColumnSpec, String> _f$storageKey = Field(
    'storageKey',
    _$storageKey,
  );
  static String? _$description(RatingColumnSpec v) => v.description;
  static const Field<RatingColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static bool _$hidden(RatingColumnSpec v) => v.hidden;
  static const Field<RatingColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static Range<double> _$range(RatingColumnSpec v) => v.range;
  static const Field<RatingColumnSpec, Range<double>> _f$range = Field(
    'range',
    _$range,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<RatingColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #predicate: _f$predicate,
    #storageKey: _f$storageKey,
    #description: _f$description,
    #hidden: _f$hidden,
    #range: _f$range,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RatingColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RatingColumnSpec _instantiate(DecodingData data) {
    return RatingColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      predicate: data.dec(_f$predicate),
      storageKey: data.dec(_f$storageKey),
      description: data.dec(_f$description),
      hidden: data.dec(_f$hidden),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RatingColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RatingColumnSpec>(map);
  }

  static RatingColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<RatingColumnSpec>(json);
  }
}

mixin RatingColumnSpecMappable {
  String toJson() {
    return RatingColumnSpecMapper.ensureInitialized()
        .encodeJson<RatingColumnSpec>(this as RatingColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return RatingColumnSpecMapper.ensureInitialized()
        .encodeMap<RatingColumnSpec>(this as RatingColumnSpec);
  }
}

