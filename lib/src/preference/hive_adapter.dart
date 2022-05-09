import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

class JsonAdapter<T> extends TypeAdapter<T?> {
  static const _serializationOptions = SerializationOptions(
    indent: null,
    caseStyle: CaseStyle.snake,
    ignoreNullMembers: true,
    ignoreDefaultMembers: true,
    ignoreUnknownTypes: false,
  );

  static const _deserializationOptions = DeserializationOptions(
    caseStyle: CaseStyle.snake,
  );

  JsonAdapter(this.typeId);

  @override
  final int typeId;

  @override
  T? read(BinaryReader reader) {
    return JsonMapper.deserialize<T>(reader.readString(), _deserializationOptions);
  }

  @override
  void write(BinaryWriter writer, T? obj) {
    writer.writeString(JsonMapper.serialize(obj, _serializationOptions));
  }
}

void registerHiveAdapters() {
  int index = 0;
  Hive.registerAdapter(JsonAdapter<Size>(index++));
  Hive.registerAdapter(JsonAdapter<Offset>(index++));
  Hive.registerAdapter(JsonAdapter<ThemeMode>(index++));
}
