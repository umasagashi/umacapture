// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'item_display.dart';

class ItemDisplayModeMapper extends EnumMapper<ItemDisplayMode> {
  ItemDisplayModeMapper._();

  static ItemDisplayModeMapper? _instance;
  static ItemDisplayModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ItemDisplayModeMapper._());
    }
    return _instance!;
  }

  static ItemDisplayMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  ItemDisplayMode decode(dynamic value) {
    switch (value) {
      case r'normal':
        return ItemDisplayMode.normal;
      case r'absence':
        return ItemDisplayMode.absence;
      case r'difference':
        return ItemDisplayMode.difference;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(ItemDisplayMode self) {
    switch (self) {
      case ItemDisplayMode.normal:
        return r'normal';
      case ItemDisplayMode.absence:
        return r'absence';
      case ItemDisplayMode.difference:
        return r'difference';
    }
  }
}

extension ItemDisplayModeMapperExtension on ItemDisplayMode {
  String toValue() {
    ItemDisplayModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<ItemDisplayMode>(this) as String;
  }
}

