import '/src/addon/execution/execution_models.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';

/// File name of a record's serialized JSON within its directory.
const recordJsonName = "record.json";

/// Internal payload marker set once a payload has been enriched. Lets a
/// `taskExecuted` chain hop — whose forwarded payload already carries the record
/// placeholders — skip re-resolving (and re-reading from disk) the same record on
/// every hop. `_`-prefixed, so it is never substituted into action templates.
const _enrichedMarker = "_enriched";

/// Expands a trigger [base] payload with rich placeholders so actions can
/// reference `{card_name}`, `{rank}`, `{record_json_path}`, `{modules_dir}` etc.
/// instead of just `{record_id}`.
///
/// Module-data path placeholders are install-constant and added for every
/// trigger. Record placeholders are added only when [base] carries a `record_id`
/// (the record-captured trigger, or a chain hop forwarding it). Best-effort: any
/// failure (record not found, module data not yet loaded) leaves the
/// corresponding placeholders absent, which the substituter then expands to the
/// empty string — consistent with the unknown-placeholder rule.
PayloadMap enrichPayload(RefBase ref, PayloadMap base) {
  // Already enriched upstream (e.g. a chain hop forwarding a record's
  // placeholders); re-resolving would repeat the disk read of resolveRecordById
  // for no gain.
  if (base.containsKey(_enrichedMarker)) return base;
  final enriched = {...base};
  // Install-constant paths to the downloaded master data (labels.json, *_info.json).
  // Added regardless of trigger so an action can decode a record's numeric IDs
  // into names, or read any other module file via {modules_dir}.
  _addModulePlaceholders(ref, enriched);
  final recordId = base["record_id"];
  if (recordId != null && recordId.isNotEmpty) {
    try {
      final record = resolveRecordById(ref, recordId);
      if (record != null) {
        _addRecordPlaceholders(ref, enriched, record);
        // Mark only once the (possibly disk-backed) record lookup has succeeded,
        // so a chain hop forwarding these placeholders skips repeating it. A
        // not-yet-resolvable record stays unmarked so a later hop can still
        // retry; the idempotent module placeholders are simply re-derived then.
        enriched[_enrichedMarker] = "1";
      }
    } catch (e, s) {
      logger.w("Failed to enrich addon payload for record $recordId: $e\n$s");
    }
  }
  return enriched;
}

/// Resolves the record by id, preferring the in-memory store but falling back to
/// reading `record.json` from disk. The fallback covers the race where a
/// listener runs before the storage notifier has folded in a freshly captured
/// record (both listen to the same capture event). It decodes directly rather
/// than via [CharaDetailRecord.load] to avoid that method's quarantine side
/// effect firing from an addon path.
///
/// Shared by [enrichPayload] and the built-in record actions so both resolve a
/// just-captured record the same way.
CharaDetailRecord? resolveRecordById(RefBase ref, String recordId) {
  try {
    final fromMemory = ref.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: recordId);
    if (fromMemory != null) return fromMemory;
  } catch (_) {
    // Storage not ready yet; fall through to the on-disk copy.
  }
  final file = (ref.read(pathInfoProvider).charaDetailActiveDir / recordId).filePath(recordJsonName);
  if (!file.existsSync()) return null;
  return CharaDetailRecordMapper.fromJson(file.readAsStringSync());
}

void _addRecordPlaceholders(RefBase ref, PayloadMap p, CharaDetailRecord r) {
  // Placeholders that need no downloaded module data.
  p["evaluation_value"] = "${r.evaluationValue}";
  p["fans"] = "${r.fans}";
  p["speed"] = "${r.status.speed}";
  p["stamina"] = "${r.status.stamina}";
  p["power"] = "${r.status.power}";
  p["guts"] = "${r.status.guts}";
  p["intelligence"] = "${r.status.intelligence}";
  p["trained_date"] = r.trainedDate;
  p["trainer_id"] = r.metadata.trainerId;

  final activeDir = _safe(() => ref.read(pathInfoProvider).charaDetailActiveDir);
  if (activeDir != null) {
    final recordDir = activeDir / r.id;
    p["record_dir"] = recordDir.path;
    p["record_json_path"] = recordDir.filePath(recordJsonName).path;
    // Reuse the record's own relative icon path so the "trainee.jpg" literal
    // lives only on CharaDetailRecord.traineeIconPath.
    p["trainee_icon_path"] = activeDir.filePath(r.traineeIconPath).path;
    // Reuse CharaDetailRecordImageMode.fileName so the capture-image filenames
    // are not duplicated here.
    p["skill_image_path"] = recordDir.filePath(CharaDetailRecordImageMode.skillPlain.fileName).path;
    p["factor_image_path"] = recordDir.filePath(CharaDetailRecordImageMode.factorPlain.fileName).path;
    p["campaign_image_path"] = recordDir.filePath(CharaDetailRecordImageMode.campaignPlain.fileName).path;
  }

  // Module-data-dependent placeholders (labels / card names / rank). Each is
  // best-effort so a missing module simply omits that placeholder.
  final labels = _safe(() => ref.read(labelMapProvider));
  if (labels != null) {
    final scenarios = labels[LabelKeys.campaignScenario];
    if (scenarios != null && r.scenario.id >= 0 && r.scenario.id < scenarios.length) {
      p["scenario"] = scenarios[r.scenario.id];
    }
    final rankLabels = labels[LabelKeys.charaRank];
    final border = _safe(() => ref.read(charaRankBorderProvider));
    if (rankLabels != null && border != null) {
      final found = border.indexWhere((b) => b > r.evaluationValue);
      final rankIndex = found < 0 ? border.length : found;
      if (rankIndex >= 0 && rankIndex < rankLabels.length) p["rank"] = rankLabels[rankIndex];
    }
  }

  final cards = _safe(() => ref.read(charaCardInfoProvider));
  if (cards != null && r.trainee.card >= 0 && r.trainee.card < cards.length) {
    p["card_name"] = cards[r.trainee.card].names.first;
  }
}

/// Adds the install-constant module-data path placeholders. Just the directory
/// plus the most useful decode tables — any other module file is reachable
/// through `{modules_dir}`. The paths are derived from [pathInfoProvider] alone,
/// so they resolve even before the module JSON is loaded (the file may simply
/// not exist yet).
void _addModulePlaceholders(RefBase ref, PayloadMap p) {
  final modulesDir = _safe(() => ref.read(pathInfoProvider).modulesDir);
  if (modulesDir == null) return;
  p["modules_dir"] = modulesDir.path;
  p["labels_path"] = modulesDir.filePath("labels.json").path;
  p["skill_info_path"] = modulesDir.filePath("skill_info.json").path;
  p["factor_info_path"] = modulesDir.filePath("factor_info.json").path;
  p["card_info_path"] = modulesDir.filePath("character_card_info.json").path;
}

/// Runs [f], returning null instead of throwing — used to treat a not-yet-loaded
/// sync provider (which throws on `.value!`) as "placeholder unavailable".
T? _safe<T>(T Function() f) {
  try {
    return f();
  } catch (_) {
    return null;
  }
}
