// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'storage.dart';

class CharaDetailRecordImageModeMapper
    extends EnumMapper<CharaDetailRecordImageMode> {
  CharaDetailRecordImageModeMapper._();

  static CharaDetailRecordImageModeMapper? _instance;
  static CharaDetailRecordImageModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = CharaDetailRecordImageModeMapper._(),
      );
    }
    return _instance!;
  }

  static CharaDetailRecordImageMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  CharaDetailRecordImageMode decode(dynamic value) {
    switch (value) {
      case r'none':
        return CharaDetailRecordImageMode.none;
      case r'skillPlain':
        return CharaDetailRecordImageMode.skillPlain;
      case r'factorPlain':
        return CharaDetailRecordImageMode.factorPlain;
      case r'campaignPlain':
        return CharaDetailRecordImageMode.campaignPlain;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(CharaDetailRecordImageMode self) {
    switch (self) {
      case CharaDetailRecordImageMode.none:
        return r'none';
      case CharaDetailRecordImageMode.skillPlain:
        return r'skillPlain';
      case CharaDetailRecordImageMode.factorPlain:
        return r'factorPlain';
      case CharaDetailRecordImageMode.campaignPlain:
        return r'campaignPlain';
    }
  }
}

extension CharaDetailRecordImageModeMapperExtension
    on CharaDetailRecordImageMode {
  String toValue() {
    CharaDetailRecordImageModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<CharaDetailRecordImageMode>(this)
        as String;
  }
}

