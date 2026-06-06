// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'loader.dart';

class RatingDataMapper extends ClassMapperBase<RatingData> {
  RatingDataMapper._();

  static RatingDataMapper? _instance;
  static RatingDataMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RatingDataMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'RatingData';

  static String _$title(RatingData v) => v.title;
  static const Field<RatingData, String> _f$title = Field('title', _$title);
  static Map<String, double> _$data(RatingData v) => v.data;
  static const Field<RatingData, Map<String, double>> _f$data = Field(
    'data',
    _$data,
  );

  @override
  final MappableFields<RatingData> fields = const {
    #title: _f$title,
    #data: _f$data,
  };

  static RatingData _instantiate(DecodingData data) {
    return RatingData(title: data.dec(_f$title), data: data.dec(_f$data));
  }

  @override
  final Function instantiate = _instantiate;

  static RatingData fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RatingData>(map);
  }

  static RatingData fromJson(String json) {
    return ensureInitialized().decodeJson<RatingData>(json);
  }
}

mixin RatingDataMappable {
  String toJson() {
    return RatingDataMapper.ensureInitialized().encodeJson<RatingData>(
      this as RatingData,
    );
  }

  Map<String, dynamic> toMap() {
    return RatingDataMapper.ensureInitialized().encodeMap<RatingData>(
      this as RatingData,
    );
  }
}

class MemoDataMapper extends ClassMapperBase<MemoData> {
  MemoDataMapper._();

  static MemoDataMapper? _instance;
  static MemoDataMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MemoDataMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'MemoData';

  static String _$title(MemoData v) => v.title;
  static const Field<MemoData, String> _f$title = Field('title', _$title);
  static Map<String, String> _$data(MemoData v) => v.data;
  static const Field<MemoData, Map<String, String>> _f$data = Field(
    'data',
    _$data,
  );

  @override
  final MappableFields<MemoData> fields = const {
    #title: _f$title,
    #data: _f$data,
  };

  static MemoData _instantiate(DecodingData data) {
    return MemoData(title: data.dec(_f$title), data: data.dec(_f$data));
  }

  @override
  final Function instantiate = _instantiate;

  static MemoData fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MemoData>(map);
  }

  static MemoData fromJson(String json) {
    return ensureInitialized().decodeJson<MemoData>(json);
  }
}

mixin MemoDataMappable {
  String toJson() {
    return MemoDataMapper.ensureInitialized().encodeJson<MemoData>(
      this as MemoData,
    );
  }

  Map<String, dynamic> toMap() {
    return MemoDataMapper.ensureInitialized().encodeMap<MemoData>(
      this as MemoData,
    );
  }
}

