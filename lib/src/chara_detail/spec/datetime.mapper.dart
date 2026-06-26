// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'datetime.dart';

class IsInRangeDateTimePredicateMapper
    extends ClassMapperBase<IsInRangeDateTimePredicate> {
  IsInRangeDateTimePredicateMapper._();

  static IsInRangeDateTimePredicateMapper? _instance;
  static IsInRangeDateTimePredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = IsInRangeDateTimePredicateMapper._(),
      );
    }
    return _instance!;
  }

  @override
  final String id = 'IsInRangeDateTimePredicate';

  static DateTime? _$min(IsInRangeDateTimePredicate v) => v.min;
  static const Field<IsInRangeDateTimePredicate, DateTime> _f$min = Field(
    'min',
    _$min,
    opt: true,
  );
  static DateTime? _$max(IsInRangeDateTimePredicate v) => v.max;
  static const Field<IsInRangeDateTimePredicate, DateTime> _f$max = Field(
    'max',
    _$max,
    opt: true,
  );

  @override
  final MappableFields<IsInRangeDateTimePredicate> fields = const {
    #min: _f$min,
    #max: _f$max,
  };

  static IsInRangeDateTimePredicate _instantiate(DecodingData data) {
    return IsInRangeDateTimePredicate(
      min: data.dec(_f$min),
      max: data.dec(_f$max),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static IsInRangeDateTimePredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<IsInRangeDateTimePredicate>(map);
  }

  static IsInRangeDateTimePredicate fromJson(String json) {
    return ensureInitialized().decodeJson<IsInRangeDateTimePredicate>(json);
  }
}

mixin IsInRangeDateTimePredicateMappable {
  String toJson() {
    return IsInRangeDateTimePredicateMapper.ensureInitialized()
        .encodeJson<IsInRangeDateTimePredicate>(
          this as IsInRangeDateTimePredicate,
        );
  }

  Map<String, dynamic> toMap() {
    return IsInRangeDateTimePredicateMapper.ensureInitialized()
        .encodeMap<IsInRangeDateTimePredicate>(
          this as IsInRangeDateTimePredicate,
        );
  }
}

class DateTimeColumnSpecMapper extends SubClassMapperBase<DateTimeColumnSpec> {
  DateTimeColumnSpecMapper._();

  static DateTimeColumnSpecMapper? _instance;
  static DateTimeColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DateTimeColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      IsInRangeDateTimePredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'DateTimeColumnSpec';

  static String _$id(DateTimeColumnSpec v) => v.id;
  static const Field<DateTimeColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(DateTimeColumnSpec v) => v.title;
  static const Field<DateTimeColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(DateTimeColumnSpec v) => v.parser;
  static const Field<DateTimeColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static IsInRangeDateTimePredicate _$predicate(DateTimeColumnSpec v) =>
      v.predicate;
  static const Field<DateTimeColumnSpec, IsInRangeDateTimePredicate>
  _f$predicate = Field('predicate', _$predicate);
  static bool _$hidden(DateTimeColumnSpec v) => v.hidden;
  static const Field<DateTimeColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(DateTimeColumnSpec v) => v.description;
  static const Field<DateTimeColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static double? _$width(DateTimeColumnSpec v) => v.width;
  static const Field<DateTimeColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );

  @override
  final MappableFields<DateTimeColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #predicate: _f$predicate,
    #hidden: _f$hidden,
    #description: _f$description,
    #width: _f$width,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'DateTimeColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static DateTimeColumnSpec _instantiate(DecodingData data) {
    return DateTimeColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      predicate: data.dec(_f$predicate),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
      width: data.dec(_f$width),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static DateTimeColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<DateTimeColumnSpec>(map);
  }

  static DateTimeColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<DateTimeColumnSpec>(json);
  }
}

mixin DateTimeColumnSpecMappable {
  String toJson() {
    return DateTimeColumnSpecMapper.ensureInitialized()
        .encodeJson<DateTimeColumnSpec>(this as DateTimeColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return DateTimeColumnSpecMapper.ensureInitialized()
        .encodeMap<DateTimeColumnSpec>(this as DateTimeColumnSpec);
  }
}

