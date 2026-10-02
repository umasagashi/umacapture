import '/src/addon/execution/execution_models.dart';
import '/src/chara_detail/chara_detail_record.dart';
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
/// reference `{record_json_path}`, `{record_dir}`, `{modules_dir}` etc. instead
/// of just `{record_id}`.
///
/// The `{modules_dir}` placeholder is install-constant and added for every
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
  final directory = ref.read(pathInfoProvider).charaDetailActiveDir / recordId;
  final file = directory.filePath(recordJsonName);
  try {
    if (!file.existsSync()) return null;
    final record = CharaDetailRecord.fromRecordJson(file.readAsStringSync());
    // The same check the canonical loader applies, called rather than respelled:
    // skipping the quarantine side effect is what this path wants, and that is not
    // a reason to skip the identity check too. Without it a directory whose
    // `record.json` names some other record answers a lookup for this one, and the
    // contents of the wrong record reach a webhook body or a `{record_json}`
    // placeholder.
    CharaDetailRecord.validateDirectoryId(directory, record);
    return record;
  } on RecordIdMismatch catch (error) {
    // "Not found" is the honest answer: the directory holds no record with the
    // requested id. Logged rather than thrown, because every caller here treats an
    // unresolvable record as a missing one and the scan will quarantine the
    // directory on its own.
    logger.w("Refusing the on-disk record for $recordId: $error");
    return null;
  } on UnsupportedError {
    // The on-disk fallback is io-only: OPFS has no synchronous main-thread API,
    // so the web FsBackend rejects the whole sync surface. Without this, a web
    // lookup that misses the in-memory store threw out of here instead of
    // reporting "not found" — `_requireRecord` surfaced an UnsupportedError to
    // the user rather than its own message. "Not found" is also the honest
    // answer there: the in-memory store is the only source web can consult
    // synchronously, so a miss is all this function can determine.
    return null;
  }
}

void _addRecordPlaceholders(RefBase ref, PayloadMap p, CharaDetailRecord r) {
  final activeDir = _safe(() => ref.read(pathInfoProvider).charaDetailActiveDir);
  if (activeDir != null) {
    final recordDir = activeDir / r.id;
    p["record_dir"] = recordDir.path;
    final jsonFile = recordDir.filePath(recordJsonName);
    p["record_json_path"] = jsonFile.path;
    // The decoded record.json contents, so a template can send the record body
    // directly (e.g. a webhook) instead of just its path. Best-effort: if the
    // file isn't on disk yet (a just-captured record resolved from memory before
    // it is flushed), leave the placeholder absent so it expands to empty.
    final json = _safe(() => jsonFile.readAsStringSync());
    if (json != null) p["record_json"] = json;
    // Reuse the record's own relative icon path so the "trainee.jpg" literal
    // lives only on CharaDetailRecord.traineeIconPath.
    p["trainee_icon_path"] = activeDir.filePath(r.traineeIconPath).path;
    // Reuse CharaDetailRecordImageMode.fileName so the capture-image filenames
    // are not duplicated here.
    p["skill_image_path"] = recordDir.filePath(CharaDetailRecordImageMode.skillPlain.fileName).path;
    p["factor_image_path"] = recordDir.filePath(CharaDetailRecordImageMode.factorPlain.fileName).path;
    p["campaign_image_path"] = recordDir.filePath(CharaDetailRecordImageMode.campaignPlain.fileName).path;
  }
}

/// Adds the install-constant `{modules_dir}` placeholder: the directory holding
/// the downloaded master data (the ID→name decode tables). Any module file is
/// reachable through it. The path is derived from [pathInfoProvider] alone, so
/// it resolves even before the module JSON is loaded (the file may simply not
/// exist yet).
void _addModulePlaceholders(RefBase ref, PayloadMap p) {
  final modulesDir = _safe(() => ref.read(pathInfoProvider).modulesDir);
  if (modulesDir == null) return;
  p["modules_dir"] = modulesDir.path;
}

/// Runs [f], returning null instead of throwing — used to treat a sync provider
/// that has not resolved yet (which throws rather than answering) as
/// "placeholder unavailable".
T? _safe<T>(T Function() f) {
  try {
    return f();
  } catch (_) {
    return null;
  }
}
