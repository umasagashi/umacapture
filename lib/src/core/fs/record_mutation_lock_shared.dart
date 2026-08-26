import 'dart:async';
import 'dart:collection';
import 'dart:convert';

/// Runs [action] while holding the exclusive lock named by the first argument.
///
/// This small adapter is the fake boundary for deterministic lock tests.
typedef ExclusiveLockRunner =
    Future<Object?> Function(String name, RecordMutationLockMode mode, Future<Object?> Function() action);

enum RecordMutationLockMode { shared, exclusive }

/// Internal lock name source. Only the record/root convenience methods expose
/// mutation authority to callers.
sealed class _RecordMutationScope {
  const _RecordMutationScope._(this.lockName);

  factory _RecordMutationScope.record(String recordId) {
    final encoded = base64Url.encode(utf8.encode(recordId)).replaceAll('=', '');
    return _NamedRecordMutationScope('umacapture:v1:record:$encoded');
  }

  static const _RecordMutationScope root = _NamedRecordMutationScope('umacapture:v1:root');

  final String lockName;
}

final class _NamedRecordMutationScope extends _RecordMutationScope {
  const _NamedRecordMutationScope(super.lockName) : super._();
}

/// Why the platform cannot provide the cross-tab exclusion primitive.
///
/// Named separately from the exception so a caller can tell the two apart
/// without parsing a message: [insecureContext] is fixable by the *deployment*
/// (serve over HTTPS or localhost), [unsupportedBrowser] only by the user
/// switching browsers, and [notConfigured] can only be a wiring mistake.
enum RecordMutationLockUnavailableReason {
  /// The page is not a secure context, so `navigator.locks` is not exposed.
  insecureContext,

  /// The browser does not implement the Web Locks API at all.
  unsupportedBrowser,

  /// No runner was supplied to this [RecordMutationLock] (tests / misuse).
  notConfigured,
}

/// Raised before a mutation starts when the platform cannot provide the
/// required cross-tab exclusion primitive.
final class RecordMutationLockUnavailable implements Exception {
  const RecordMutationLockUnavailable([this.reason = RecordMutationLockUnavailableReason.notConfigured]);

  final RecordMutationLockUnavailableReason reason;

  @override
  String toString() => switch (reason) {
    RecordMutationLockUnavailableReason.insecureContext =>
      'RecordMutationLockUnavailable: navigator.locks is unavailable outside a secure context '
          '(serve the app over HTTPS or localhost); persisted record access was refused.',
    RecordMutationLockUnavailableReason.unsupportedBrowser =>
      'RecordMutationLockUnavailable: this browser does not support navigator.locks; '
          'persisted record access was refused.',
    RecordMutationLockUnavailableReason.notConfigured =>
      'RecordMutationLockUnavailable: no record mutation lock runner is configured; '
          'persisted record access was refused.',
  };
}

/// Raised when a lock could not be acquired within the acquisition budget.
///
/// Distinct from [RecordMutationLockUnavailable]: the primitive works, but
/// something else — another tab mid-regeneration, or a queued exclusive request
/// the Web Locks grant algorithm puts ahead of every later shared one — is
/// holding the name. Bounding the wait is what keeps that from presenting as an
/// indefinite hang with nothing on screen.
final class RecordMutationLockBusy implements Exception {
  const RecordMutationLockBusy(this.lockName, this.timeout);

  final String lockName;
  final Duration timeout;

  @override
  String toString() =>
      'RecordMutationLockBusy: "$lockName" was still held after ${timeout.inSeconds}s; '
      'another tab is probably busy with the record store.';
}

/// Fakeable facade over an exclusive mutation lock.
///
/// A `null` runner deliberately means "unsupported", never "run unlocked".
final class RecordMutationLock {
  const RecordMutationLock(this._runExclusive);

  final ExclusiveLockRunner? _runExclusive;

  Future<T> _runForScope<T>(_RecordMutationScope scope, Future<T> Function() action) async {
    final runner = _runExclusive;
    if (runner == null) {
      throw const RecordMutationLockUnavailable();
    }
    final result = await runner(scope.lockName, RecordMutationLockMode.exclusive, () async => action());
    return result as T;
  }

  Future<T> runForRecord<T>(String recordId, Future<T> Function() action) {
    final runner = _runExclusive;
    if (runner == null) {
      throw const RecordMutationLockUnavailable();
    }
    // Every mutation that reaches this method first takes the shared root gate.
    // Whole-store work — the bulk record scan, the one-time archive geometry
    // repair and the data-root relocation — takes the same name exclusively via
    // [runForRoot], so those cannot race a record mutation. (The desktop capture
    // merge reaches neither: it is synchronous by contract; see
    // `recordMutationLockUnavailabilityProvider`.)
    return _runWithRunner<T>(runner, _RecordMutationScope.root.lockName, RecordMutationLockMode.shared, () {
      return _runWithRunner<T>(
        runner,
        _RecordMutationScope.record(recordId).lockName,
        RecordMutationLockMode.exclusive,
        action,
      );
    });
  }

  /// Locks multiple records in deduplicated lexical lock-name order.
  ///
  /// Fixed ordering prevents cooperating callers from deadlocking. Callers
  /// must not invoke another mutation-lock method from inside [action].
  Future<T> runForRecords<T>(Iterable<String> recordIds, Future<T> Function() action) {
    final runner = _runExclusive;
    if (runner == null) {
      throw const RecordMutationLockUnavailable();
    }
    final names = recordIds.map((id) => _RecordMutationScope.record(id).lockName).toSet().toList()..sort();

    Future<Object?> acquire(int index) {
      if (index == names.length) return action();
      return runner(names[index], RecordMutationLockMode.exclusive, () => acquire(index + 1));
    }

    return _runWithRunner<T>(
      runner,
      _RecordMutationScope.root.lockName,
      RecordMutationLockMode.shared,
      () async => acquire(0),
    );
  }

  Future<T> runForRoot<T>(Future<T> Function() action) {
    return _runForScope(_RecordMutationScope.root, action);
  }

  static Future<T> _runWithRunner<T>(
    ExclusiveLockRunner runner,
    String name,
    RecordMutationLockMode mode,
    Future<Object?> Function() action,
  ) async {
    final result = await runner(name, mode, () async => action());
    return result as T;
  }
}

/// Default acquisition budget for [InProcessNamedLocks].
///
/// Deliberately the same order as the web budget (`recordMutationLockAcquireTimeout`):
/// a bounded wait turns a holder that never releases into a reported
/// [RecordMutationLockBusy] instead of a UI that silently never finishes. In one
/// process the only way to reach it is our own bug (a re-entrant acquisition, or
/// an action whose future never completes), so the bound is a diagnosis aid, not
/// a routine outcome.
const Duration inProcessLockAcquireTimeout = Duration(seconds: 150);

/// Single-isolate implementation of the same grant algorithm the Web Locks API
/// gives the browser build.
///
/// Same semantics, not merely "some mutual exclusion": requests for one name are
/// granted strictly in request order; shared requests run together while the head
/// of the queue is shared; one queued exclusive request parks every later request
/// — including shared ones — behind it; and a request that is never granted
/// within [acquireTimeout] is removed from the queue and fails with
/// [RecordMutationLockBusy] exactly as an aborted `navigator.locks` request does.
/// Locks are therefore **not re-entrant** on either platform: a nested request for
/// a name the caller already holds waits for itself, so every helper that runs
/// inside a critical section must use its `…Unlocked` variant.
///
/// Scope: one Dart isolate. That covers every acquisition the desktop app makes
/// through [RecordMutationLock], all of which are taken on the UI isolate — the
/// work they guard need not run there, as the next paragraph describes.
///
/// Work handed to another isolate therefore has to take the lock *before* it
/// crosses the boundary, because a request made inside the worker would exclude
/// nothing: the worker gets its own empty `_states` map. The desktop archive
/// batch does exactly that — `archive_executor_io.dart` wraps its `compute` call
/// in `runForRecords` on the UI isolate and holds the names for the whole batch.
/// The bulk record scan (`record_loader_io.dart`), the one-time archive geometry
/// repair (`runArchiveGeometryMigrationIfNeeded`) and the data-root relocation
/// (`DataRootMigrationController.migrate`) do the same with the root name, which
/// is what makes those three exclude each other.
///
/// Two desktop writers deliberately take nothing, because this lock cannot reach
/// them: the capture merge is synchronous by contract, and the native capture
/// process is a different process. See
/// `recordMutationLockUnavailabilityProvider` in `storage.dart`.
final class InProcessNamedLocks {
  InProcessNamedLocks({this.acquireTimeout = inProcessLockAcquireTimeout});

  /// How long a single acquisition may wait before it gives up.
  final Duration acquireTimeout;

  final _states = <String, _NamedLockState>{};

  /// Whether nothing is held or queued, for tests and leak checks.
  bool get isIdle => _states.isEmpty;

  /// The [ExclusiveLockRunner] to hand to a [RecordMutationLock].
  Future<Object?> run(String name, RecordMutationLockMode mode, Future<Object?> Function() action) {
    final state = _states.putIfAbsent(name, _NamedLockState.new);
    final request = _NamedLockRequest(mode, action);
    state.queue.add(request);
    _pump(name, state);
    if (!request.granted) {
      // Armed only for a request that actually has to wait, so an uncontended
      // acquisition leaves no pending timer behind for the test framework to
      // trip over.
      request.timeout = Timer(acquireTimeout, () => _abandon(name, state, request));
    }
    return request.result.future;
  }

  void _abandon(String name, _NamedLockState state, _NamedLockRequest request) {
    if (request.granted) {
      return;
    }
    state.queue.remove(request);
    request.result.completeError(RecordMutationLockBusy(name, acquireTimeout));
    // Dropping the request can unblock whatever was queued behind it, the same
    // way aborting a `navigator.locks` request does.
    _pump(name, state);
  }

  void _pump(String name, _NamedLockState state) {
    while (state.queue.isNotEmpty) {
      final head = state.queue.first;
      if (head.mode == RecordMutationLockMode.exclusive) {
        if (state.exclusive || state.shared > 0) break;
        state.queue.removeFirst();
        _start(name, state, head);
        // An exclusive grant blocks the rest of the queue by definition.
        break;
      }
      if (state.exclusive) break;
      state.queue.removeFirst();
      _start(name, state, head);
    }
    _releaseIfIdle(name, state);
  }

  void _start(String name, _NamedLockState state, _NamedLockRequest request) {
    request.granted = true;
    request.timeout?.cancel();
    if (request.mode == RecordMutationLockMode.exclusive) {
      state.exclusive = true;
    } else {
      state.shared++;
    }
    // Invoked synchronously, as the previous native pass-through was, so an
    // uncontended mutation still starts in its caller's turn of the event loop.
    Future<Object?> running;
    try {
      running = request.action();
    } catch (error, stackTrace) {
      running = Future<Object?>.error(error, stackTrace);
    }
    running
        .then<void>(
          (value) => request.result.complete(value),
          onError: (Object error, StackTrace stackTrace) => request.result.completeError(error, stackTrace),
        )
        .whenComplete(() => _release(name, state, request));
  }

  void _release(String name, _NamedLockState state, _NamedLockRequest request) {
    if (request.mode == RecordMutationLockMode.exclusive) {
      state.exclusive = false;
    } else {
      state.shared--;
    }
    _pump(name, state);
  }

  void _releaseIfIdle(String name, _NamedLockState state) {
    // Record names are per-record and unbounded over a session, so a name that
    // nobody holds or wants is forgotten instead of accumulating.
    if (!state.exclusive && state.shared == 0 && state.queue.isEmpty) {
      _states.remove(name);
    }
  }
}

final class _NamedLockRequest {
  _NamedLockRequest(this.mode, this.action);

  final RecordMutationLockMode mode;
  final Future<Object?> Function() action;
  final result = Completer<Object?>();
  Timer? timeout;
  var granted = false;
}

final class _NamedLockState {
  final queue = Queue<_NamedLockRequest>();
  var shared = 0;
  var exclusive = false;
}
