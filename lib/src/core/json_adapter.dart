import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/material.dart';

import '/main.mapper.g.dart';

class MappingConverter<T, S> implements ICustomConverter<T> {
  final T Function(S map) _fromMap;
  final S Function(T obj) _toMap;

  MappingConverter({required T Function(S map) fromMap, required S Function(T obj) toMap})
      : _fromMap = fromMap,
        _toMap = toMap,
        super();

  @override
  T fromJSON(dynamic jsonValue, DeserializationContext context) {
    return _fromMap(jsonValue);
  }

  @override
  dynamic toJSON(T object, SerializationContext context) {
    return _toMap(object);
  }
}

extension on String {
  ThemeMode toThemeMode() {
    return ThemeMode.values.firstWhere((e) => e.name == this);
  }
}

final flutterTypesAdapter = JsonMapperAdapter(
  converters: {
    Size: MappingConverter<Size, Map>(
      fromMap: (map) => Size(map['width'].toDouble(), map['height'].toDouble()),
      toMap: (obj) => {'width': obj.width, 'height': obj.height},
    ),
    Offset: MappingConverter<Offset, Map>(
      fromMap: (map) => Offset(map['dx'].toDouble(), map['dy'].toDouble()),
      toMap: (obj) => {'dx': obj.dx, 'dy': obj.dy},
    ),
    ThemeMode: MappingConverter<ThemeMode, String>(
      fromMap: (map) => map.toThemeMode(),
      toMap: (obj) => obj.name,
    ),
  },
  valueDecorators: {},
);

void initializeJsonReflectable() {
  initializeJsonMapper(adapters: [flutterTypesAdapter]);
}
