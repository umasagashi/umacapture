// EVERY BUG REPORT TELLS THE USER WHETHER IT WENT.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_send_failure_test.dart
//
// The defect this file is written against is "the user is told nothing": every report surface
// showed a success toast when the send worked and said nothing at all when it did not -- so a
// reporter who was opted out of telemetry, or whose event the SDK dropped, believed they had filed
// a bug and had not.
//
// What counts as *sent* is the returned `SentryId`, not the future completing. `Hub.captureMessage`
// and `Hub.captureFeedback` (sentry 9.23.0, `hub.dart:206-293`) both catch everything their client
// throws and answer `SentryId.empty()` instead, and both transports answer the same for an event
// that was dropped or could not be handed over. A `.then` that assumes success therefore runs on
// failures too, which is what the success toasts used to do -- and the `onError` beside it was very
// nearly unreachable.
//
// Four surfaces, not three: the feedback sheet had the same defect and files *two* events per
// submission, so it also fixes what a half-landed report means. See the `feedback` group below.
//
// The hub is injected. Under `flutter test` the real hub happens to be disabled, so the real
// senders would take their no-hub branch anyway -- but that is a property of the environment, not
// of these cases, and a suite whose safety rests on "Sentry was never initialised here" is one
// `SentryFlutter.init` away from filing real issues. Nothing here reaches Sentry.
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/hive.dart';
import 'support/localization.dart';

/// A hub that answers however a case needs and never leaves the process.
///
/// [captureMessage] and [captureFeedback] await `withScope` **outside** any try of their own,
/// exactly as sentry 9.23.0's `Hub` does (`hub.dart:220-226` and `hub.dart:268-276`): that is why a
/// rejected future is reachable at all, and a fake that swallowed scope errors would make the
/// rejection case untestable for the wrong reason.
class _FakeHub implements Hub {
  _FakeHub({
    required this.isEnabled,
    this.answer = const SentryId.empty(),
    this.failure,
    this.feedbackAnswer,
    this.feedbackFailure,
  });

  @override
  final bool isEnabled;

  /// The id handed back when the call is allowed to complete.
  final SentryId answer;

  /// Thrown instead of answering, standing in for a scope callback that threw.
  final Object? failure;

  /// The feedback event's own id and own failure. Defaulting to the message event's is what lets
  /// the shared table below drive all four surfaces with one construction; the `feedback` group
  /// sets them apart to make one half land and the other not.
  final SentryId? feedbackAnswer;
  final Object? feedbackFailure;

  final List<String?> messages = [];
  final List<SentryFeedback> feedbacks = [];

  @override
  Future<SentryId> captureMessage(
    String? message, {
    SentryLevel? level,
    String? template,
    List<dynamic>? params,
    Hint? hint,
    ScopeCallback? withScope,
  }) async {
    messages.add(message);
    await withScope?.call(Scope(SentryOptions()));
    final thrown = failure;
    if (thrown != null) {
      throw thrown;
    }
    return answer;
  }

  @override
  Future<SentryId> captureFeedback(SentryFeedback feedback, {Hint? hint, ScopeCallback? withScope}) async {
    feedbacks.add(feedback);
    await withScope?.call(Scope(SentryOptions()));
    final thrown = feedbackFailure ?? failure;
    if (thrown != null) {
      throw thrown;
    }
    return feedbackAnswer ?? answer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One report surface, reduced to what actually differs between them.
///
/// A table so the outcomes below are asserted for *all four* rather than for whichever one someone
/// remembered. A surface added without a row is a surface nobody checked.
typedef _Surface = ({
  Future<void> Function(Hub hub, FilePath png, DirectoryPath directory) send,

  /// The key its success toast has always used. Unchanged by the failure work.
  String successToast,

  /// The vocabulary its failure notice speaks: 報告 for the three evidence reports,
  /// フィードバック for the feedback sheet, matching each one's own success toast.
  String failurePrefix,

  /// What the monthly counter reads after a *successful* send. Feedback is outside that budget and
  /// stays outside it; the three evidence reports each spend one.
  int quotaOnSuccess,

  /// Whether this surface owns a transient PNG that has to be gone whatever happened.
  bool ownsFrame,
});

UserFeedback _userFeedback(String text) => UserFeedback(text: text, screenshot: Uint8List.fromList(const [1, 2, 3]));

final _surfaces = <String, _Surface>{
  'report_screen': (
    send: (hub, png, directory) async => captureScreen('note', png, hub: hub),
    successToast: 'toast.report_screen',
    failurePrefix: 'toast.report_failure',
    quotaOnSuccess: 1,
    ownsFrame: true,
  ),
  'report_record': (
    send: (hub, png, directory) async => captureCharaDetailRecord('note', directory, hub: hub),
    successToast: 'toast.report_record',
    failurePrefix: 'toast.report_failure',
    quotaOnSuccess: 1,
    ownsFrame: false,
  ),
  'report_import': (
    send: (hub, png, directory) async => captureImportError('note', png, contexts: const {}, tags: const {}, hub: hub),
    successToast: 'toast.report_import',
    failurePrefix: 'toast.report_failure',
    quotaOnSuccess: 1,
    ownsFrame: true,
  ),
  'feedback': (
    send: (hub, png, directory) async => captureFeedback(hub: hub)(_userFeedback('note')),
    successToast: 'toast.feedback',
    failurePrefix: 'toast.feedback_failure',
    quotaOnSuccess: 0,
    ownsFrame: false,
  ),
};

void main() {
  late Directory tempDir;
  late Future<void> Function() closeHive;
  late ProviderContainer container;
  late List<ToastData> toasts;
  late ProviderSubscription<AsyncValue<ToastData>> subscription;

  setUpAll(() async {
    loadAppTranslations();
    // The monthly counter is Hive-backed and only a *sent* report may touch it.
    closeHive = await initHiveForTest(['settings']);
  });

  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
    tempDir = Directory.systemTemp.createTempSync('umacapture_report_failure_test');
    container = ProviderContainer();
    toasts = [];
    subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
  });

  tearDown(() {
    subscription.close();
    container.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  FilePath writeFrame() {
    final file = File('${tempDir.path}${Platform.pathSeparator}screenshot_1.png')..writeAsBytesSync(const [1, 2, 3]);
    return FilePath(file.path);
  }

  DirectoryPath recordDir() => DirectoryPath(tempDir.path);

  /// The one thing the user is told. Pumps first: the toast travels over a broadcast stream, so it
  /// lands a microtask after the send returns.
  Future<ToastData> onlyToast() async {
    await pumpEventQueue();
    expect(toasts, hasLength(1), reason: 'exactly one answer per report, and never none');
    return toasts.single;
  }

  for (final entry in _surfaces.entries) {
    final name = entry.key;
    final surface = entry.value;

    group(name, () {
      test('$name says so when reporting is disabled and no send is even attempted', () async {
        final png = writeFrame();
        final hub = _FakeHub(isEnabled: false);
        await surface.send(hub, png, recordDir());

        expect(hub.messages, isEmpty);
        expect(hub.feedbacks, isEmpty);
        final toast = await onlyToast();
        expect(toast.type, ToastType.error);
        expect(toast.description, '${surface.failurePrefix}.disabled'.tr());
        expect(toast.description, contains('設定のプライバシー項目をご確認ください。'));
        expect(getSentryReportCount(), 0, reason: 'a report that was never sent must not spend quota');
        if (surface.ownsFrame) {
          expect(File(png.path).existsSync(), isFalse, reason: 'nothing will ever read the frame again');
        }
      });

      test('$name says so when the SDK answers with no event id', () async {
        final png = writeFrame();
        // What the hub returns for an event dropped by beforeSend / sampling / an event processor,
        // and what both transports return for a handoff or a request that failed.
        final hub = _FakeHub(isEnabled: true);
        await surface.send(hub, png, recordDir());

        expect(hub.messages, ['note'], reason: 'the send really was attempted');
        final toast = await onlyToast();
        expect(toast.type, ToastType.error);
        expect(toast.description, '${surface.failurePrefix}.not_delivered'.tr());
        expect(toast.description, contains('通信環境を確認して、しばらくしてからもう一度お試しください。'));
        expect(getSentryReportCount(), 0);
        if (surface.ownsFrame) {
          expect(File(png.path).existsSync(), isFalse);
        }
      });

      test('$name says so when the send throws', () async {
        final png = writeFrame();
        final hub = _FakeHub(isEnabled: true, failure: StateError('the scope could not be assembled'));
        await surface.send(hub, png, recordDir());

        final toast = await onlyToast();
        expect(toast.type, ToastType.error);
        expect(toast.description, '${surface.failurePrefix}.not_delivered'.tr());
        expect(getSentryReportCount(), 0);
        if (surface.ownsFrame) {
          expect(File(png.path).existsSync(), isFalse, reason: 'the frame is released on this path too');
        }
      });

      test('$name still reports success unchanged when an event id comes back', () async {
        final png = writeFrame();
        final hub = _FakeHub(isEnabled: true, answer: SentryId.newId());
        await surface.send(hub, png, recordDir());

        final toast = await onlyToast();
        expect(toast.type, ToastType.success);
        // Read out of `ja.json` as a literal rather than resolved with `.tr()`: an unresolvable key
        // renders AS the key, so `expect(shown, surface.successToast.tr())` is key-equals-key and
        // would stay green with the success line deleted -- the one sentence that tells the user
        // the report went.
        expect(toast.description, appSentenceAt(surface.successToast));
        expect(
          getSentryReportCount(),
          surface.quotaOnSuccess,
          reason: 'the evidence reports each spend one of the month\'s allowance; feedback is outside that budget',
        );
        if (surface.ownsFrame) {
          expect(File(png.path).existsSync(), isFalse);
        }
      });
    });
  }

  // A submission is two events -- a message event carrying the screenshot, and a `type: 'feedback'`
  // event carrying the note and the back-link (sentry_client.dart:491-511). They are halves of one
  // report, so a half is not a success: the user is told the same retryable failure either way,
  // because retrying is the only thing they can do about either half.
  group('feedback files two events and only both of them count as sent', () {
    Future<ToastData> submit(_FakeHub hub) async {
      await captureFeedback(hub: hub)(_userFeedback('note'));
      await pumpEventQueue();
      expect(toasts, hasLength(1), reason: 'exactly one answer per submission, and never none');
      return toasts.single;
    }

    test('the message event landing without the feedback event is not a success', () async {
      final hub = _FakeHub(isEnabled: true, answer: SentryId.newId(), feedbackAnswer: const SentryId.empty());
      final toast = await submit(hub);

      expect(hub.messages, ['note'], reason: 'the first half really was attempted');
      expect(hub.feedbacks, hasLength(1), reason: 'and so was the second');
      expect(toast.type, ToastType.error);
      expect(toast.description, 'toast.feedback_failure.not_delivered'.tr());
      expect(toast.description, 'フィードバックを送信できませんでした。通信環境を確認して、しばらくしてからもう一度お試しください。');
    });

    test('the feedback event landing without the message event is not a success', () async {
      // The screenshot is attached to the message event's scope, so this half losing it loses the
      // picture -- and the surviving feedback event points back at an id that does not exist.
      final hub = _FakeHub(isEnabled: true, answer: const SentryId.empty(), feedbackAnswer: SentryId.newId());
      final toast = await submit(hub);

      expect(hub.feedbacks, hasLength(1), reason: 'no short circuit: the note still reaches the developer');
      expect(toast.type, ToastType.error);
      expect(toast.description, 'toast.feedback_failure.not_delivered'.tr());
    });

    test('the feedback event throwing is not a success either', () async {
      final hub = _FakeHub(
        isEnabled: true,
        answer: SentryId.newId(),
        feedbackFailure: StateError('the feedback envelope could not be built'),
      );
      final toast = await submit(hub);

      expect(toast.type, ToastType.error);
      expect(toast.description, 'toast.feedback_failure.not_delivered'.tr());
    });

    test('both halves landing is the only success, and it says what it always said', () async {
      final hub = _FakeHub(isEnabled: true, answer: SentryId.newId());
      final toast = await submit(hub);

      expect(toast.type, ToastType.success);
      expect(toast.description, 'toast.feedback'.tr());
      expect(toast.description, 'フィードバックを送信しました。');
      expect(getSentryReportCount(), 0, reason: 'feedback is outside the monthly evidence-report budget');
    });

    test('the second half is linked to the first, and carries the note', () async {
      final id = SentryId.newId();
      final hub = _FakeHub(isEnabled: true, answer: id);
      await captureFeedback(hub: hub)(_userFeedback('note'));

      expect(hub.feedbacks.single.message, 'note');
      expect(hub.feedbacks.single.associatedEventId, id);
    });

    test('a first half that was dropped leaves no back-link at all, rather than a dead one', () async {
      // `SentryFeedback.toJson` emits `associated_event_id` whenever the field is non-null
      // (`protocol/sentry_feedback.dart:47-58`), so passing the all-zeros id would file a User
      // Feedback entry whose "view event" link points at an event that never existed. Developer
      // facing only — what the user is told is unchanged, and asserted by the case above.
      final hub = _FakeHub(isEnabled: true, answer: const SentryId.empty(), feedbackAnswer: SentryId.newId());

      await captureFeedback(hub: hub)(_userFeedback('note'));

      expect(hub.feedbacks.single.message, 'note', reason: 'the note still reaches the developer');
      expect(hub.feedbacks.single.associatedEventId, isNull);
    });
  });

  test('the two failure notices are told apart by whether retrying could ever help', () {
    // Not a catalogue of causes -- the split is the one the user can act on. Collapsing them into
    // one sentence would tell an opted-out reporter to try again later, forever.
    expect(ReportFailure.values, hasLength(2));
    expect('toast.report_failure.disabled'.tr(), isNot('toast.report_failure.not_delivered'.tr()));
    expect('toast.feedback_failure.disabled'.tr(), isNot('toast.feedback_failure.not_delivered'.tr()));
  });

  test('every failure vocabulary answers for every ReportFailure value', () {
    // The toast key is assembled from a namespace and a leaf, so a namespace missing a leaf would
    // degrade to `.tr()` echoing the key on screen rather than failing at compile time. This is the
    // case that pays for that: the leaves are the enum's own names, and every prefix must resolve
    // all of them to real Japanese.
    const prefixes = ['toast.report_failure', 'toast.feedback_failure'];
    final leaves = {ReportFailure.reportingDisabled: 'disabled', ReportFailure.notDelivered: 'not_delivered'};
    expect(leaves.keys, unorderedEquals(ReportFailure.values), reason: 'a new state needs a leaf in both vocabularies');
    for (final prefix in prefixes) {
      for (final leaf in leaves.values) {
        final key = '$prefix.$leaf';
        expect(key.tr(), isNot(key), reason: '$key has no translation and would show as its own key');
        expect(key.tr(), contains('できませんでした'), reason: '$key must read as a failure');
      }
    }
  });

  test('every surface answers for its own success, in the vocabulary that surface speaks', () {
    // The counterpart of the sweep above, which the success side never had: a success key is read
    // once, inside its own case, and a case comparing against `.tr()` is key-equals-key and stays
    // green with the key gone. `_surfaces` is asked for the list -- the same table that drives the
    // cases -- so a surface added without a success line is caught here rather than by a user who
    // is shown `toast.report_screen` and told nothing.
    for (final MapEntry(key: name, value: surface) in _surfaces.entries) {
      final sentence = appSentenceAt(surface.successToast);
      expect(sentence, contains('送信しました'), reason: '$name must read as a completed send');
      final noun = surface.failurePrefix == 'toast.feedback_failure' ? 'フィードバック' : '報告';
      expect(sentence, startsWith(noun), reason: '$name must say it in the same noun as its failure notice');
    }
  });

  test('the two vocabularies differ only in the noun they use for the thing that was not sent', () {
    // Feedback says フィードバック because every other string on that surface does; the evidence
    // reports say 報告 because theirs do. Anything more than that divergence is drift.
    expect('toast.report_failure.not_delivered'.tr(), startsWith('報告を送信できませんでした。'));
    expect('toast.feedback_failure.not_delivered'.tr(), startsWith('フィードバックを送信できませんでした。'));
    expect(
      'toast.report_failure.not_delivered'.tr().replaceFirst('報告', 'フィードバック'),
      'toast.feedback_failure.not_delivered'.tr(),
    );
    expect(
      'toast.report_failure.disabled'.tr().replaceFirst('ため、報告', 'ため、フィードバック'),
      'toast.feedback_failure.disabled'.tr(),
    );
  });
}
