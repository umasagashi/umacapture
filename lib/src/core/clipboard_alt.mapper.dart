// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'clipboard_alt.dart';

class ClipboardPasteImageModeMapper
    extends EnumMapper<ClipboardPasteImageMode> {
  ClipboardPasteImageModeMapper._();

  static ClipboardPasteImageModeMapper? _instance;
  static ClipboardPasteImageModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = ClipboardPasteImageModeMapper._(),
      );
    }
    return _instance!;
  }

  static ClipboardPasteImageMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  ClipboardPasteImageMode decode(dynamic value) {
    switch (value) {
      case r'memory':
        return ClipboardPasteImageMode.memory;
      case r'file':
        return ClipboardPasteImageMode.file;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(ClipboardPasteImageMode self) {
    switch (self) {
      case ClipboardPasteImageMode.memory:
        return r'memory';
      case ClipboardPasteImageMode.file:
        return r'file';
    }
  }
}

extension ClipboardPasteImageModeMapperExtension on ClipboardPasteImageMode {
  String toValue() {
    ClipboardPasteImageModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<ClipboardPasteImageMode>(this)
        as String;
  }
}

