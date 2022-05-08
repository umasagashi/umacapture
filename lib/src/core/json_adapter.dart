import 'dart:ui';

import 'package:dart_json_mapper/dart_json_mapper.dart';

class MappingConverter<T> implements ICustomConverter<T> {
  final T Function(Map map) _fromMap;
  final Map Function(T obj) _toMap;

  MappingConverter({required fromMap, required toMap})
      : _fromMap = fromMap,
        _toMap = toMap,
        super();

  @override
  T fromJSON(dynamic jsonValue, DeserializationContext context) {
    if (jsonValue is Map) {
      return _fromMap(jsonValue);
    }
    return jsonValue;
  }

  @override
  dynamic toJSON(T object, SerializationContext context) {
    return _toMap(object);
  }
}

final flutterTypesAdapter = JsonMapperAdapter(
  converters: {
    Size: MappingConverter<Size>(
      fromMap: (map) => Size(map['width'], map['height']),
      toMap: (obj) => {'width': obj.width, 'height': obj.height},
    ),
    Offset: MappingConverter<Offset>(
      fromMap: (map) => Offset(map['dx'], map['dy']),
      toMap: (obj) => {'dx': obj.dx, 'dy': obj.dy},
    ),
  },
  valueDecorators: {},
);
