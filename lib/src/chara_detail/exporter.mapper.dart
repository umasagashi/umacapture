// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'exporter.dart';

class JsonExportDataMapper extends ClassMapperBase<JsonExportData> {
  JsonExportDataMapper._();

  static JsonExportDataMapper? _instance;
  static JsonExportDataMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = JsonExportDataMapper._());
      CharaDetailRecordMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'JsonExportData';

  static List<CharaDetailRecord> _$charaDetail(JsonExportData v) =>
      v.charaDetail;
  static const Field<JsonExportData, List<CharaDetailRecord>> _f$charaDetail =
      Field('charaDetail', _$charaDetail, key: r'chara_detail');
  static Map<String, List<String>> _$labels(JsonExportData v) => v.labels;
  static const Field<JsonExportData, Map<String, List<String>>> _f$labels =
      Field('labels', _$labels);

  @override
  final MappableFields<JsonExportData> fields = const {
    #charaDetail: _f$charaDetail,
    #labels: _f$labels,
  };

  static JsonExportData _instantiate(DecodingData data) {
    return JsonExportData(data.dec(_f$charaDetail), data.dec(_f$labels));
  }

  @override
  final Function instantiate = _instantiate;

  static JsonExportData fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<JsonExportData>(map);
  }

  static JsonExportData fromJson(String json) {
    return ensureInitialized().decodeJson<JsonExportData>(json);
  }
}

mixin JsonExportDataMappable {
  String toJson() {
    return JsonExportDataMapper.ensureInitialized().encodeJson<JsonExportData>(
      this as JsonExportData,
    );
  }

  Map<String, dynamic> toMap() {
    return JsonExportDataMapper.ensureInitialized().encodeMap<JsonExportData>(
      this as JsonExportData,
    );
  }
}

