/// Native keeps the flat, single-process temp tree it always had: no second
/// context can own part of it, so there is no session to claim and nothing a
/// sweeper would have to spare. The startup clear stays a plain `clearSync` of
/// the whole tree.
Future<String?> claimTempSession() async => null;

/// Never consulted on native — the flat tree is cleared outright — and `null`
/// keeps the sweep refusing to delete anything if it ever is.
Future<Set<String>?> liveTempSessionIds() async => null;
