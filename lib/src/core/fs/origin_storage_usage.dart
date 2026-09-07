/// The one question the storage view asks the *host* rather than the filesystem:
/// how much this origin costs the browser.
///
/// Split from `origin_storage_estimate_web.dart` rather than folded into it
/// because that file is deliberately free of `package:flutter` so
/// `dart test --platform chrome` can compile it, while the reporting duty the
/// same file hands to its caller ("Nothing is thrown and nothing is logged here
/// … the caller does the reporting") needs `app_logger`. This pair is that
/// caller: the web half logs, and the conditional import keeps the io build from
/// referring to `dart:js_interop` at all.
library;

import 'origin_storage_usage_io.dart' if (dart.library.js_interop) 'origin_storage_usage_web.dart';

/// Bytes the host reports for this origin, or `null` when there is no answer.
///
/// `null` is not an error state and is not zero. It means one of two things that
/// the UI renders identically as "unknown": on Windows the question does not
/// exist (there is no origin and no browser-side accounting), and on web the
/// browser declined, failed, or never settled — the three failures
/// `readOriginStorageEstimate` flattens, each of which the web half logs.
Future<int?> readOriginStorageUsageBytes() => platformOriginStorageUsageBytes();
