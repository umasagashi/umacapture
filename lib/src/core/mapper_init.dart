import 'package:dart_mappable/dart_mappable.dart';

import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/addon/model/task_definition.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/chara_rank.dart';
import '/src/chara_detail/spec/character.dart';
import '/src/chara_detail/spec/datetime.dart';
import '/src/chara_detail/spec/factor.dart';
import '/src/chara_detail/spec/family_registration.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/logic.dart';
import '/src/chara_detail/spec/memo.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/preset.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/spec/ranged_label.dart';
import '/src/chara_detail/spec/rating.dart';
import '/src/chara_detail/spec/script.dart';
import '/src/chara_detail/spec/simple_label.dart';
import '/src/chara_detail/spec/skill.dart';
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

  // Custom mappers for dart:core / dart:ui / material types.
  MapperContainer.globals.useAll(const [SizeMapper(), OffsetMapper(), ThemeModeMapper(), RegExpMapper()]);

  // Polymorphic roots (discriminator bases). ensureInitialized() cascades to field
  // types and to subclasses declared in the SAME library, but NOT to subclasses in
  // other files. Parser keeps all of its subclasses in parser.dart, so its cascade is
  // complete. The ColumnSpec subclasses each live in their own file, so they are not
  // auto-discovered and must be registered explicitly here; otherwise decoding a saved
  // ColumnSpec fails with MapperException.missingConstructor('ColumnSpec').
  ColumnSpecMapper.ensureInitialized();
  RangedIntegerColumnSpecMapper.ensureInitialized();
  RangedLabelColumnSpecMapper.ensureInitialized();
  CharaRankColumnSpecMapper.ensureInitialized();
  SimpleLabelColumnSpecMapper.ensureInitialized();
  FamilyRegistrationColumnSpecMapper.ensureInitialized();
  SkillColumnSpecMapper.ensureInitialized();
  FactorColumnSpecMapper.ensureInitialized();
  CharacterCardColumnSpecMapper.ensureInitialized();
  DateTimeColumnSpecMapper.ensureInitialized();
  RatingColumnSpecMapper.ensureInitialized();
  MemoColumnSpecMapper.ensureInitialized();
  ScriptColumnSpecMapper.ensureInitialized();
  LogicColumnSpecMapper.ensureInitialized();
  ParserMapper.ensureInitialized();
  CharaDetailRecordMapper.ensureInitialized();

  // Addon feature. AddonAction subclasses are co-located in addon_action.dart, so
  // the cascade from AddonActionMapper covers ExternalProgramAction/WebhookAction/BuiltinAction.
  TaskDefinitionMapper.ensureInitialized();
  AddonActionMapper.ensureInitialized();
  HistoryEntryMapper.ensureInitialized();

  // Types that are (de)serialized on their own.
  SkillInfoMapper.ensureInitialized();
  FactorInfoMapper.ensureInitialized();
  CharaCardInfoMapper.ensureInitialized();
  TagMapper.ensureInitialized();
  RatingDataMapper.ensureInitialized();
  MemoDataMapper.ensureInitialized();
  ColumnPresetIndexMapper.ensureInitialized();
  ColumnPresetEntryMapper.ensureInitialized();
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
  RowHeightModeMapper.ensureInitialized();
}
