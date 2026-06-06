// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'preview_dialog.dart';

class AnchorMapper extends ClassMapperBase<Anchor> {
  AnchorMapper._();

  static AnchorMapper? _instance;
  static AnchorMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AnchorMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Anchor';

  static String _$h(Anchor v) => v.h;
  static const Field<Anchor, String> _f$h = Field('h', _$h);
  static String _$v(Anchor v) => v.v;
  static const Field<Anchor, String> _f$v = Field('v', _$v);

  @override
  final MappableFields<Anchor> fields = const {#h: _f$h, #v: _f$v};

  static Anchor _instantiate(DecodingData data) {
    return Anchor(data.dec(_f$h), data.dec(_f$v));
  }

  @override
  final Function instantiate = _instantiate;

  static Anchor fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Anchor>(map);
  }

  static Anchor fromJson(String json) {
    return ensureInitialized().decodeJson<Anchor>(json);
  }
}

mixin AnchorMappable {
  String toJson() {
    return AnchorMapper.ensureInitialized().encodeJson<Anchor>(this as Anchor);
  }

  Map<String, dynamic> toMap() {
    return AnchorMapper.ensureInitialized().encodeMap<Anchor>(this as Anchor);
  }
}

class PointMapper extends ClassMapperBase<Point> {
  PointMapper._();

  static PointMapper? _instance;
  static PointMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PointMapper._());
      AnchorMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'Point';

  static int _$x(Point v) => v.x;
  static const Field<Point, int> _f$x = Field('x', _$x);
  static int _$y(Point v) => v.y;
  static const Field<Point, int> _f$y = Field('y', _$y);
  static Anchor _$anchor(Point v) => v.anchor;
  static const Field<Point, Anchor> _f$anchor = Field('anchor', _$anchor);

  @override
  final MappableFields<Point> fields = const {
    #x: _f$x,
    #y: _f$y,
    #anchor: _f$anchor,
  };

  static Point _instantiate(DecodingData data) {
    return Point(data.dec(_f$x), data.dec(_f$y), data.dec(_f$anchor));
  }

  @override
  final Function instantiate = _instantiate;

  static Point fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Point>(map);
  }

  static Point fromJson(String json) {
    return ensureInitialized().decodeJson<Point>(json);
  }
}

mixin PointMappable {
  String toJson() {
    return PointMapper.ensureInitialized().encodeJson<Point>(this as Point);
  }

  Map<String, dynamic> toMap() {
    return PointMapper.ensureInitialized().encodeMap<Point>(this as Point);
  }
}

class RectMapper extends ClassMapperBase<Rect> {
  RectMapper._();

  static RectMapper? _instance;
  static RectMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RectMapper._());
      PointMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'Rect';

  static Point _$topLeft(Rect v) => v.topLeft;
  static const Field<Rect, Point> _f$topLeft = Field(
    'topLeft',
    _$topLeft,
    key: r'top_left',
  );
  static Point _$bottomRight(Rect v) => v.bottomRight;
  static const Field<Rect, Point> _f$bottomRight = Field(
    'bottomRight',
    _$bottomRight,
    key: r'bottom_right',
  );

  @override
  final MappableFields<Rect> fields = const {
    #topLeft: _f$topLeft,
    #bottomRight: _f$bottomRight,
  };

  static Rect _instantiate(DecodingData data) {
    return Rect(data.dec(_f$topLeft), data.dec(_f$bottomRight));
  }

  @override
  final Function instantiate = _instantiate;

  static Rect fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Rect>(map);
  }

  static Rect fromJson(String json) {
    return ensureInitialized().decodeJson<Rect>(json);
  }
}

mixin RectMappable {
  String toJson() {
    return RectMapper.ensureInitialized().encodeJson<Rect>(this as Rect);
  }

  Map<String, dynamic> toMap() {
    return RectMapper.ensureInitialized().encodeMap<Rect>(this as Rect);
  }
}

class PredictionMapper extends ClassMapperBase<Prediction> {
  PredictionMapper._();

  static PredictionMapper? _instance;
  static PredictionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PredictionMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Prediction';

  static double _$confidence(Prediction v) => v.confidence;
  static const Field<Prediction, double> _f$confidence = Field(
    'confidence',
    _$confidence,
  );
  static dynamic _$label(Prediction v) => v.label;
  static const Field<Prediction, dynamic> _f$label = Field('label', _$label);

  @override
  final MappableFields<Prediction> fields = const {
    #confidence: _f$confidence,
    #label: _f$label,
  };

  static Prediction _instantiate(DecodingData data) {
    return Prediction(data.dec(_f$confidence), data.dec(_f$label));
  }

  @override
  final Function instantiate = _instantiate;

  static Prediction fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Prediction>(map);
  }

  static Prediction fromJson(String json) {
    return ensureInitialized().decodeJson<Prediction>(json);
  }
}

mixin PredictionMappable {
  String toJson() {
    return PredictionMapper.ensureInitialized().encodeJson<Prediction>(
      this as Prediction,
    );
  }

  Map<String, dynamic> toMap() {
    return PredictionMapper.ensureInitialized().encodeMap<Prediction>(
      this as Prediction,
    );
  }
}

class PredictionDataMapper extends ClassMapperBase<PredictionData> {
  PredictionDataMapper._();

  static PredictionDataMapper? _instance;
  static PredictionDataMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PredictionDataMapper._());
      RectMapper.ensureInitialized();
      PredictionMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'PredictionData';

  static String _$model(PredictionData v) => v.model;
  static const Field<PredictionData, String> _f$model = Field('model', _$model);
  static Rect _$rect(PredictionData v) => v.rect;
  static const Field<PredictionData, Rect> _f$rect = Field('rect', _$rect);
  static Prediction _$prediction(PredictionData v) => v.prediction;
  static const Field<PredictionData, Prediction> _f$prediction = Field(
    'prediction',
    _$prediction,
  );

  @override
  final MappableFields<PredictionData> fields = const {
    #model: _f$model,
    #rect: _f$rect,
    #prediction: _f$prediction,
  };

  static PredictionData _instantiate(DecodingData data) {
    return PredictionData(
      data.dec(_f$model),
      data.dec(_f$rect),
      data.dec(_f$prediction),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static PredictionData fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<PredictionData>(map);
  }

  static PredictionData fromJson(String json) {
    return ensureInitialized().decodeJson<PredictionData>(json);
  }
}

mixin PredictionDataMappable {
  String toJson() {
    return PredictionDataMapper.ensureInitialized().encodeJson<PredictionData>(
      this as PredictionData,
    );
  }

  Map<String, dynamic> toMap() {
    return PredictionDataMapper.ensureInitialized().encodeMap<PredictionData>(
      this as PredictionData,
    );
  }
}

class PredictionContainerMapper extends ClassMapperBase<PredictionContainer> {
  PredictionContainerMapper._();

  static PredictionContainerMapper? _instance;
  static PredictionContainerMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PredictionContainerMapper._());
      PredictionDataMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'PredictionContainer';

  static List<PredictionData> _$statusHeader(PredictionContainer v) =>
      v.statusHeader;
  static const Field<PredictionContainer, List<PredictionData>>
  _f$statusHeader = Field(
    'statusHeader',
    _$statusHeader,
    key: r'status_header',
  );
  static List<PredictionData> _$skillTab(PredictionContainer v) => v.skillTab;
  static const Field<PredictionContainer, List<PredictionData>> _f$skillTab =
      Field('skillTab', _$skillTab, key: r'skill_tab');
  static List<PredictionData> _$factorTab(PredictionContainer v) => v.factorTab;
  static const Field<PredictionContainer, List<PredictionData>> _f$factorTab =
      Field('factorTab', _$factorTab, key: r'factor_tab');
  static List<PredictionData> _$campaignTab(PredictionContainer v) =>
      v.campaignTab;
  static const Field<PredictionContainer, List<PredictionData>> _f$campaignTab =
      Field('campaignTab', _$campaignTab, key: r'campaign_tab');

  @override
  final MappableFields<PredictionContainer> fields = const {
    #statusHeader: _f$statusHeader,
    #skillTab: _f$skillTab,
    #factorTab: _f$factorTab,
    #campaignTab: _f$campaignTab,
  };

  static PredictionContainer _instantiate(DecodingData data) {
    return PredictionContainer(
      data.dec(_f$statusHeader),
      data.dec(_f$skillTab),
      data.dec(_f$factorTab),
      data.dec(_f$campaignTab),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static PredictionContainer fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<PredictionContainer>(map);
  }

  static PredictionContainer fromJson(String json) {
    return ensureInitialized().decodeJson<PredictionContainer>(json);
  }
}

mixin PredictionContainerMappable {
  String toJson() {
    return PredictionContainerMapper.ensureInitialized()
        .encodeJson<PredictionContainer>(this as PredictionContainer);
  }

  Map<String, dynamic> toMap() {
    return PredictionContainerMapper.ensureInitialized()
        .encodeMap<PredictionContainer>(this as PredictionContainer);
  }
}

class ImageSizeInfoMapper extends ClassMapperBase<ImageSizeInfo> {
  ImageSizeInfoMapper._();

  static ImageSizeInfoMapper? _instance;
  static ImageSizeInfoMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ImageSizeInfoMapper._());
      RectMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ImageSizeInfo';

  static Rect _$intersection(ImageSizeInfo v) => v.intersection;
  static const Field<ImageSizeInfo, Rect> _f$intersection = Field(
    'intersection',
    _$intersection,
  );

  @override
  final MappableFields<ImageSizeInfo> fields = const {
    #intersection: _f$intersection,
  };

  static ImageSizeInfo _instantiate(DecodingData data) {
    return ImageSizeInfo(data.dec(_f$intersection));
  }

  @override
  final Function instantiate = _instantiate;

  static ImageSizeInfo fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ImageSizeInfo>(map);
  }

  static ImageSizeInfo fromJson(String json) {
    return ensureInitialized().decodeJson<ImageSizeInfo>(json);
  }
}

mixin ImageSizeInfoMappable {
  String toJson() {
    return ImageSizeInfoMapper.ensureInitialized().encodeJson<ImageSizeInfo>(
      this as ImageSizeInfo,
    );
  }

  Map<String, dynamic> toMap() {
    return ImageSizeInfoMapper.ensureInitialized().encodeMap<ImageSizeInfo>(
      this as ImageSizeInfo,
    );
  }
}

