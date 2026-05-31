import 'package:dart_mappable/dart_mappable.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/json_adapter.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/chara_detail/preview_dialog.dart';
import '/src/preference/native_config.dart';

bool _initialized = false;

/// Registers all dart_mappable mappers into the (current isolate's) global container.
/// Replacement for the old dart_json_mapper `initializeJsonReflectable()`.
/// Must also be called inside each `compute` (separate isolate).
void initializeMappers() {
  if (_initialized) {
    return;
  }
  _initialized = true;

  // Custom mappers for dart:ui / material types.
  MapperContainer.globals.useAll(const [
    SizeMapper(),
    OffsetMapper(),
    ThemeModeMapper(),
  ]);

  // Polymorphic roots (discriminator bases). ensureInitialized cascades to field types and subclasses.
  ColumnSpecMapper.ensureInitialized();
  ParserMapper.ensureInitialized();
  CharaDetailRecordMapper.ensureInitialized();

  // Types that are (de)serialized on their own.
  SkillInfoMapper.ensureInitialized();
  FactorInfoMapper.ensureInitialized();
  CharaCardInfoMapper.ensureInitialized();
  TagMapper.ensureInitialized();
  RatingDataMapper.ensureInitialized();
  MemoDataMapper.ensureInitialized();
  ModuleVersionRawDataMapper.ensureInitialized();
  SentryRateLimitMapper.ensureInitialized();
  JsonExportDataMapper.ensureInitialized();
  NativeConfigMapper.ensureInitialized();
  PredictionContainerMapper.ensureInitialized();
  ImageSizeInfoMapper.ensureInitialized();
  RangeMapper.ensureInitialized();

  // Enums stored on their own in Hive.
  CharaDetailRecordImageModeMapper.ensureInitialized();
  ClipboardPasteImageModeMapper.ensureInitialized();
}
