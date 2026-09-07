/// Windows has no counterpart to "what this site costs the browser": there is no
/// origin, no quota manager, and no store other than the filesystem the view is
/// already walking. So this is `null` — the *absence of the concept*, which is
/// why the storage view does not draw the second summary row at all off web,
/// rather than drawing it with a dash.
///
/// Nothing is logged: an answer that is `null` by construction is not a failure,
/// and warning about it on every build would put a line in every session's log
/// and in Sentry's breadcrumbs for a state that can never be different.
Future<int?> platformOriginStorageUsageBytes() async => null;
