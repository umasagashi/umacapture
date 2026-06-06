// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
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
      case r'skill_plain':
        return CharaDetailRecordImageMode.skillPlain;
      case r'factor_plain':
        return CharaDetailRecordImageMode.factorPlain;
      case r'campaign_plain':
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
        return r'skill_plain';
      case CharaDetailRecordImageMode.factorPlain:
        return r'factor_plain';
      case CharaDetailRecordImageMode.campaignPlain:
        return r'campaign_plain';
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

