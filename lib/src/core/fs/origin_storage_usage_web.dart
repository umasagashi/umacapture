import '/src/core/app_logger.dart';
import 'origin_storage_estimate_web.dart';

/// Reads `navigator.storage.estimate()` and reports what came back.
///
/// The logging lives here because `origin_storage_estimate_web.dart` states that
/// it collapses its three failure modes into one `null` and leaves the reporting
/// to its caller — this is that caller. The two `null`s are logged separately
/// because they are different facts about the engine: one means the call never
/// produced an estimate (no storage manager, a rejection, or a promise that did
/// not settle within the bound), the other means it produced one whose `usage`
/// member the engine omitted, which the spec permits.
///
/// Both are warnings and not errors: the view has a defined rendering for
/// "unknown" and keeps working, so this is a degraded reading rather than a
/// failure of the feature.
Future<int?> platformOriginStorageUsageBytes() async {
  final estimate = await readOriginStorageEstimate();
  if (estimate == null) {
    logger.w('The browser returned no storage estimate for this origin; the site total will read as unknown.');
    return null;
  }
  final usage = estimate.usageBytes;
  if (usage == null) {
    logger.w('The browser returned a storage estimate with no usage member; the site total will read as unknown.');
  }
  return usage;
}
