// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'item_display.dart';

class UnmetRowsMapper extends EnumMapper<UnmetRows> {
  UnmetRowsMapper._();

  static UnmetRowsMapper? _instance;
  static UnmetRowsMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = UnmetRowsMapper._());
    }
    return _instance!;
  }

  static UnmetRows fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  UnmetRows decode(dynamic value) {
    switch (value) {
      case r'filterOut':
        return UnmetRows.filterOut;
      case r'markMissing':
        return UnmetRows.markMissing;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(UnmetRows self) {
    switch (self) {
      case UnmetRows.filterOut:
        return r'filterOut';
      case UnmetRows.markMissing:
        return r'markMissing';
    }
  }
}

extension UnmetRowsMapperExtension on UnmetRows {
  String toValue() {
    UnmetRowsMapper.ensureInitialized();
    return MapperContainer.globals.toValue<UnmetRows>(this) as String;
  }
}

