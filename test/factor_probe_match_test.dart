// Verifies the early duplicate probe's matching primitive on CharaDetailRecord:
// matchesFactorProbe checks that every self-factor (id and star) the probe sent agrees with this
// record's own factors from the top, and -- when the probe states `below_threshold` -- that the
// record's own self-factor count equals the probe's length. And verifies that the duplicate
// decision made from that primitive is driven off the `below_threshold` flag the core sends on the
// same onFactorProbe message -- this side holds no numeric threshold of its own, because `factors`
// arrives already capped to the core's chosen layout's self-factor-count threshold.
//
// The shipped threshold values are NOT pinned here: they live in the core's config, and the native
// config tests pin them.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/factor_probe_match_test.dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';

import 'support/hive.dart';
import 'support/localization.dart';

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// Builds a record carrying only the self-factors the probe reads; everything
// else is dummy. Mirrors the minimal builder in family_registration_test.dart.
CharaDetailRecord makeRecord({required List<Factor> self}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    const RecordId('id', null, null),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    null,
    RecordType.standard,
  );
  return CharaDetailRecord(
    metadata,
    _chara(1),
    0,
    const CharacterStatus(0, 0, 0, 0, 0),
    const AptitudeSet(GroundAptitude(0, 0), DistanceAptitude(0, 0, 0, 0), StyleAptitude(0, 0, 0, 0)),
    const <Skill>[],
    FactorSet(self, const [], const []),
    const <SupportCard>[],
    Family(_parent(0), _parent(0)),
    0,
    const Scenario(0),
    '2026/01/01',
    const <Race>[],
  );
}

/// A record store already holding [initial], so the probe is judged against a loaded store.
class _StoredRecords extends CharaDetailRecordStorage {
  _StoredRecords(this.initial);

  final List<CharaDetailRecord> initial;

  @override
  Future<List<CharaDetailRecord>> build() async => initial;
}

/// An empty archive, so the only candidate is the active record under test.
class _NoArchive extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

/// Exposes a [Ref] so a [PlatformController] can be built against a bare container, exactly as
/// `scroll_ready_wait_test.dart` does.
final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  useHiveForTest(['settings']);

  group('matchesFactorProbe', () {
    test('an identical probe matches, below_threshold false', () {
      final self = [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)];
      final record = makeRecord(self: self);

      expect(record.matchesFactorProbe([...self], belowThreshold: false), isTrue);
    });

    test('a diverging star fails the match', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)]);

      // Same ids, but the second star differs.
      expect(record.matchesFactorProbe([const Factor(1, 1), const Factor(2, 9)], belowThreshold: false), isFalse);
    });

    test('a diverging id fails the match', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)]);

      // Same stars, but the second id differs.
      expect(record.matchesFactorProbe([const Factor(1, 1), const Factor(9, 2)], belowThreshold: false), isFalse);
    });

    test('a mismatch on the very first factor fails the match', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2)]);

      expect(record.matchesFactorProbe([const Factor(9, 9), const Factor(1, 1)], belowThreshold: false), isFalse);
    });

    test('an empty probe matches nothing, regardless of the record or the flag', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2)]);

      expect(record.matchesFactorProbe(const [], belowThreshold: false), isFalse);
      expect(record.matchesFactorProbe(const [], belowThreshold: true), isFalse);

      final emptyRecord = makeRecord(self: const []);
      expect(emptyRecord.matchesFactorProbe(const [], belowThreshold: false), isFalse);
    });

    test('a non-empty probe against a record with no self-factors fails the match', () {
      final record = makeRecord(self: const []);

      expect(record.matchesFactorProbe([const Factor(1, 1)], belowThreshold: false), isFalse);
    });

    // THE FOUR PATTERNS THE DUPLICATE DECISION IS BUILT FROM: full agreement with no count
    // requirement (pattern 1), full agreement with an equal count required and met (pattern 2), full
    // agreement with an equal count required and unmet (pattern 3), and an empty probe (pattern 4).

    test('pattern 1: below_threshold false, every sent factor agrees -> matches', () {
      // The ordinary continuing-list case: the probe is capped by the layout's self-factor-count
      // threshold, not by the character's own factor count, so no count requirement applies. The
      // record legitimately has more self-factors than the probe sent, and that must not defeat the
      // match.
      final self = [for (var i = 1; i <= 16; i++) Factor(i, 1)];
      final record = makeRecord(self: self);

      expect(record.matchesFactorProbe(self.sublist(0, 10), belowThreshold: false), isTrue);
    });

    test('pattern 2: below_threshold true, every sent factor agrees, and the counts are equal -> matches', () {
      // The core's own read ended before the layout's cap: the character really does have exactly as
      // many self-factors as were sent. The old matching rule (leading-run agreement only) could never
      // reach this case at all: a record with as few self-factors as the threshold never had enough of
      // a leading run to fire the check.
      final self = [for (var i = 1; i <= 9; i++) Factor(i, 1)];
      final record = makeRecord(self: self);

      expect(record.matchesFactorProbe([...self], belowThreshold: true), isTrue);
    });

    test('pattern 3: below_threshold true, every sent factor agrees, but the record is longer -> no match', () {
      // The probe stopped short of the layout's cap, but this record has MORE self-factors than the
      // probe read. A prefix agreeing says nothing about the character actually having only that many.
      final self = [for (var i = 1; i <= 12; i++) Factor(i, 1)];
      final record = makeRecord(self: self);

      expect(record.matchesFactorProbe(self.sublist(0, 9), belowThreshold: true), isFalse);
    });

    test('pattern 4: an empty probe -> no match, under either flag value', () {
      final self = [const Factor(1, 1), const Factor(2, 2)];
      final record = makeRecord(self: self);

      expect(record.matchesFactorProbe(const [], belowThreshold: false), isFalse);
      expect(record.matchesFactorProbe(const [], belowThreshold: true), isFalse);
    });

    test('a middle element differing -> no match, under either flag value', () {
      final self = [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)];
      final record = makeRecord(self: self);
      final probe = [const Factor(1, 1), const Factor(9, 9), const Factor(3, 3)];

      expect(record.matchesFactorProbe(probe, belowThreshold: false), isFalse);
      expect(record.matchesFactorProbe(probe, belowThreshold: true), isFalse);
    });
  });

  group('the duplicate check reads below_threshold off the probe message', () {
    // THE FLAG IS THE CORE'S, taken off the message as sent. `factors` already arrives capped to the
    // layout's self-factor-count threshold, so this side holds no numeric threshold to compare a count
    // against; only `below_threshold` decides whether the extra count requirement applies.
    //
    // Driven through the real handler and the real storage method, so what is asserted is the hint the
    // user would see (the capture state's error), not a helper's return value.
    List<Factor> factors(int count) => [for (var i = 0; i < count; i++) Factor(i + 1, i % 3 + 1)];
    final breadcrumbs = <String>[];
    late BreadcrumbSink realSink;

    setUp(() async {
      await Hive.box('settings').clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        (call) async => null,
      );
      breadcrumbs.clear();
      realSink = debugBreadcrumbSink;
      debugBreadcrumbSink = (level, message, error) => breadcrumbs.add(message);
    });

    tearDown(() {
      debugBreadcrumbSink = realSink;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        null,
      );
    });

    /// Stores one record whose self-factors are [stored], sends one probe carrying [probe] plus [fields],
    /// and answers the container along with every chime the probe sounded.
    Future<(ProviderContainer, List<int>)> sendProbe({
      required List<Factor> stored,
      required List<Factor> probe,
      required Map<String, Object?> fields,
    }) async {
      final container = ProviderContainer.test(
        overrides: [
          charaDetailRecordStorageLoaderProvider.overrideWith(() => _StoredRecords([makeRecord(self: stored)])),
          charaDetailArchiveStorageLoaderProvider.overrideWith(_NoArchive.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
      final cues = <int>[];
      final subscription = container.listen<AsyncValue<int>>(
        scrollReadyEventProvider,
        (_, current) => current.whenData(cues.add),
      );
      addTearDown(subscription.close);
      final controller = PlatformController(container.read(_refProvider), const {});
      addTearDown(controller.dispose);

      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailStarted', 'record_id': 'rec-1'}));
      controller.handleNativeMessage(
        jsonEncode({
          'type': 'onFactorProbe',
          'factors': [for (final factor in probe) factor.toMap()],
          'cue_owed': true,
          'record_id': 'rec-1',
          ...fields,
        }),
      );
      await pumpEventQueue();
      return (container, cues);
    }

    CharaDetailCaptureState stateOf(ProviderContainer container) => container.read(charaDetailCaptureStateProvider);

    test('below_threshold false raises the hint on full agreement, with the record longer than the probe', () async {
      final stored = factors(16);
      final (container, cues) = await sendProbe(
        stored: stored,
        probe: stored.sublist(0, 10),
        fields: {'below_threshold': false},
      );

      expect(stateOf(container).error, 'duplicated_character_probe');
      expect(stateOf(container).duplicateRecordId, 'id');
      expect(cues, isEmpty, reason: 'a duplicate withholds the scroll-ready chime');
    });

    test('below_threshold true raises nothing when the stored record is longer than the probe', () async {
      final stored = factors(16);
      final (container, cues) = await sendProbe(
        stored: stored,
        probe: stored.sublist(0, 10),
        fields: {'below_threshold': true},
      );

      expect(stateOf(container).error, isNull);
      expect(cues, hasLength(1), reason: 'not a duplicate, and the latch owed the chime');
    });

    test('below_threshold true raises the hint when the stored count equals the probe length', () async {
      final stored = factors(10);
      final (container, cues) = await sendProbe(
        stored: stored,
        probe: stored.sublist(0, 10),
        fields: {'below_threshold': true},
      );

      expect(stateOf(container).error, 'duplicated_character_probe');
      expect(stateOf(container).duplicateRecordId, 'id');
      expect(cues, isEmpty);
    });

    for (final (label, fields) in <(String, Map<String, Object?>)>[
      ('absent', {}),
      ('null', {'below_threshold': null}),
      ('a string', {'below_threshold': 'true'}),
      ('an int', {'below_threshold': 1}),
    ]) {
      test('a below_threshold that is $label runs no duplicate check, chimes, and says so in the log', () async {
        // Every one of the probe's 16 factors agrees with the stored record, and the record has more
        // self-factors than the probe sent -- the false direction (no count requirement) would raise
        // the hint here, so only SKIPPING the check stays silent. Matching nothing is the same
        // fail-open direction taken for an empty probe; guessing either boolean risks a false positive
        // (false) or a wrong rejection (true) from a fact the message never stated.
        final stored = factors(16);
        final (container, cues) = await sendProbe(stored: stored, probe: stored.sublist(0, 10), fields: fields);

        expect(stateOf(container).error, isNull, reason: 'a malformed/missing flag must not raise a hint');
        expect(cues, hasLength(1), reason: 'fail-open: the chime still follows cue_owed');
        expect(
          breadcrumbs.where((line) => line.contains('below_threshold') && line.contains('skipped')),
          hasLength(1),
          reason: 'the skipped check is logged through logger, so it reaches the crash report too',
        );
      });
    }

    for (final (label, fields) in <(String, Map<String, Object?>)>[
      ('absent', {}),
      ('null', {'below_threshold': null}),
      ('a string', {'below_threshold': 'true'}),
      ('an int', {'below_threshold': 1}),
    ]) {
      test('a below_threshold that is $label matches nothing even where a guessed true would', () async {
        // The fixture above (stored 16, probe 10) only ever distinguishes "skip" from a guessed FALSE:
        // guessing true there also stays silent (16 != 10 fails the count check either way), so it could
        // not catch a regression that guesses true instead of skipping. Here the stored record's count
        // equals the probe's length, so a guessed true would ALSO match (full agreement, equal counts)
        // and wrongly raise the hint -- only skipping the check keeps this silent.
        final stored = factors(10);
        final (container, cues) = await sendProbe(stored: stored, probe: [...stored], fields: fields);

        expect(stateOf(container).error, isNull, reason: 'neither a guessed true nor false may raise a hint here');
        expect(cues, hasLength(1), reason: 'fail-open: the chime still follows cue_owed');
      });
    }
  });

  group('RecordType ordinal contract', () {
    // chara_detail_record.dart states that this order stays aligned with the native RecordType enum, because
    // record_type columns (the saved record's own metadata field, unrelated to onFactorProbe, whose own
    // record_type field was dropped from the wire) map the value to a label by index.
    test('values are in the exact wire order', () {
      expect(RecordType.values, [
        RecordType.standard,
        RecordType.inheritanceOnly,
        RecordType.friendStandard,
        RecordType.friendInheritance,
      ]);
    });

    test('each value maps to its expected ordinal', () {
      expect(RecordType.standard.index, 0);
      expect(RecordType.inheritanceOnly.index, 1);
      expect(RecordType.friendStandard.index, 2);
      expect(RecordType.friendInheritance.index, 3);
    });
  });
}
