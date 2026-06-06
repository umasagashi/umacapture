import 'package:dart_mappable/dart_mappable.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

/// Custom dart_mappable mappers.
/// Used to serialize dart:core / dart:ui / material types (RegExp / Size / Offset / ThemeMode).
/// Replaces the old dart_json_mapper MappingConverter / flutterTypesAdapter.

class SizeMapper extends SimpleMapper<Size> {
  const SizeMapper();

  @override
  Size decode(dynamic value) {
    final map = value as Map;
    return Size(map['width'].toDouble(), map['height'].toDouble());
  }

  @override
  dynamic encode(Size self) {
    return {'width': self.width, 'height': self.height};
  }
}

class OffsetMapper extends SimpleMapper<Offset> {
  const OffsetMapper();

  @override
  Offset decode(dynamic value) {
    final map = value as Map;
    return Offset(map['dx'].toDouble(), map['dy'].toDouble());
  }

  @override
  dynamic encode(Offset self) {
    return {'dx': self.dx, 'dy': self.dy};
  }
}

class RegExpMapper extends SimpleMapper<RegExp> {
  const RegExpMapper();

  @override
  RegExp decode(dynamic value) {
    return RegExp(value as String);
  }

  @override
  dynamic encode(RegExp self) {
    return self.pattern;
  }
}

class ThemeModeMapper extends SimpleMapper<ThemeMode> {
  const ThemeModeMapper();

  @override
  ThemeMode decode(dynamic value) {
    return ThemeMode.values.firstWhere((e) => e.name == value);
  }

  @override
  dynamic encode(ThemeMode self) {
    return self.name;
  }
}

/// Base class for all models. dart_mappable does not generate equals/stringify
/// (see build.yaml); equality is left to Equatable as before
/// (props-based == and identity-based hashCode).
abstract class JsonEquatable extends Equatable {
  const JsonEquatable();

  @override
  bool get stringify => true;

  @override
  // ignore: hash_and_equals
  int get hashCode => runtimeType.hashCode ^ identityHashCode(this);

  @override
  List<Object?> get props => properties();

  List<Object?> properties();
}
