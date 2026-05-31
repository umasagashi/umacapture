// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'utils.dart';

class RangeMapper extends ClassMapperBase<Range> {
  RangeMapper._();

  static RangeMapper? _instance;
  static RangeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RangeMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Range';
  @override
  Function get typeFactory =>
      <T extends dynamic>(f) => f<Range<T>>();

  static dynamic _$min(Range v) => v.min;
  static dynamic _arg$min<T extends dynamic>(f) => f<T>();
  static const Field<Range, dynamic> _f$min = Field(
    'min',
    _$min,
    arg: _arg$min,
  );
  static dynamic _$max(Range v) => v.max;
  static dynamic _arg$max<T extends dynamic>(f) => f<T>();
  static const Field<Range, dynamic> _f$max = Field(
    'max',
    _$max,
    arg: _arg$max,
  );

  @override
  final MappableFields<Range> fields = const {#min: _f$min, #max: _f$max};

  static Range<T> _instantiate<T extends dynamic>(DecodingData data) {
    return Range(min: data.dec(_f$min), max: data.dec(_f$max));
  }

  @override
  final Function instantiate = _instantiate;

  static Range<T> fromMap<T extends dynamic>(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Range<T>>(map);
  }

  static Range<T> fromJson<T extends dynamic>(String json) {
    return ensureInitialized().decodeJson<Range<T>>(json);
  }
}

mixin RangeMappable<T extends dynamic> {
  String toJson() {
    return RangeMapper.ensureInitialized().encodeJson<Range<T>>(
      this as Range<T>,
    );
  }

  Map<String, dynamic> toMap() {
    return RangeMapper.ensureInitialized().encodeMap<Range<T>>(
      this as Range<T>,
    );
  }
}

