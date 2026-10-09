// The world: devices, the fake server and the judge. Applies operations given as values
// (`ops.dart`), checks after each step, and can drive every device to rest before the final check.
//
// [SyncWorld] is what the judge, the generator and the shrinker see; [World] runs the rules of
// `core.dart` and `LineageWorld` (`lineage_world.dart`) the lineage rules, under the same judge.

import 'device.dart';
import 'fake_server.dart';
import 'judge.dart';
import 'mutations.dart';
import 'observation.dart';
import 'ops.dart';
import 'types.dart';

abstract class SyncWorld {
  SyncWorld({required Set<Accepted> accepted, JudgeReadings judgeReadings = const JudgeReadings()})
    : judge = Judge(accepted: accepted, readings: judgeReadings);

  final Judge judge;

  /// Zip slot → what the export carried; the payload type belongs to the rule set.
  final Map<String, Object> zips = {};
  final List<Op> log = [];
  int _clock = 0;

  int tick() => ++_clock;

  Iterable<String> get deviceNames;

  /// The ids [device] lists, sorted.
  List<String> recordIds(String device);
  bool isActive(String device, String id);
  int versionOf(String device, String id);
  bool syncEnabled(String device);

  /// Whether this rule set has a path for [op] at all (an untracked removal, say).
  bool supports(Op op);

  /// Whether [device] holds nothing and has written nothing, so it may start on an app from before
  /// the operation log ([OldApp]).
  bool startsFresh(String device) => false;

  /// Whether [device] runs an app from before the operation log (until its [Upgrade]).
  bool runsOldApp(String device) => false;

  /// Field [field] (`parent1`, `parent2`, `bonus`) of record [id]'s inheritance link as [device]
  /// shows it; null for rules that do not link records.
  String? linkOf(String device, String id, String field) => null;

  /// Applies [op] to the stores, with no checking.
  void execute(Op op);

  Observation observe();

  void run(Iterable<Op> ops) => ops.forEach(apply);

  void apply(Op op) {
    final before = observe();
    judge.beforeOp(op, before);
    execute(op);
    log.add(op);
    final after = observe();
    judge.afterOp(op, before, after);
    judge.check(after);
  }

  /// Turns sync on everywhere and runs rounds until a whole pass changes nothing.
  bool settle({int maxPasses = 12}) {
    for (final n in deviceNames) {
      if (!syncEnabled(n)) apply(SetSyncEnabled(n, enabled: true));
    }
    for (var pass = 0; pass < maxPasses; pass++) {
      final before = observe().fingerprint;
      for (final n in deviceNames) {
        apply(SyncRound(n));
      }
      if (observe().fingerprint == before) return true;
    }
    return false;
  }

  /// Drives the world to rest and returns the judge's findings.
  List<Violation> finish() {
    final quiesced = settle();
    return judge.finish(observe(), quiesced: quiesced);
  }
}

class World extends SyncWorld {
  /// [mutation] breaks one rule on purpose (a positive control); [accepted] narrows the judge's
  /// accepted outcomes (its own positive control). Both default to the model as designed.
  World(this.rules, List<String> deviceNames, {this.mutation, Set<Accepted>? accepted, super.judgeReadings})
    : server = FakeServer(mutation: mutation),
      super(accepted: accepted ?? acceptedUnderDesigned) {
    for (final n in deviceNames) {
      devices[n] = Device(n, rules, tick, mutation: mutation);
    }
  }

  final Rules rules;
  final Mutation? mutation;
  final FakeServer server;
  final Map<String, Device> devices = {};

  @override
  Iterable<String> get deviceNames => devices.keys;

  @override
  List<String> recordIds(String device) => devices[device]!.records.keys.toList()..sort();

  @override
  bool isActive(String device, String id) => devices[device]!.records[id]?.archive == null;

  @override
  int versionOf(String device, String id) => devices[device]!.records[id]!.version;

  @override
  bool syncEnabled(String device) => devices[device]!.syncEnabled;

  /// These rules have no untracked removal: every delete and merge goes through the record store.
  /// They carry one memo per record, with no send limit, and no ratings, titles, dismissed pairs or
  /// inheritance links.
  @override
  bool supports(Op op) => switch (op) {
    Merge(:final untracked) || Delete(:final untracked) => untracked == Untracked.none,
    EditMemo(:final column, :final value) => column == memoColumn && !overMemoLimit(value),
    EditRating() || Title() || Dismiss() || Link() => false,
    DeleteAccount() || Elapse() || OldApp() || Upgrade() => false,
    SetStorageFull() || SetDailyRows() || SetDailyReads() || PushCut() || ReceiveCut() || Resume() => false,
    _ => true,
  };

  @override
  void execute(Op op) {
    final d = devices[op.device]!;
    switch (op) {
      case DeleteAccount() ||
          Elapse() ||
          OldApp() ||
          Upgrade() ||
          SetStorageFull() ||
          SetDailyRows() ||
          SetDailyReads() ||
          PushCut() ||
          ReceiveCut() ||
          Resume():
        throw UnsupportedError('these rules have no path for $op');
      case Capture(:final id, :final captured, :final withImages):
        d.capture(id, captured, withImages: withImages);
      case Merge(:final a, :final b, :final contentFrom):
        d.merge(a, b, contentFrom: contentFrom);
      case Delete(:final id):
        d.delete(id);
      case Archive(:final id, :final option):
        d.archive(id, option);
      case EditMemo(:final id, :final value):
        tick();
        d.editMemo(id, value);
      case EditRating() || Title() || Dismiss() || Link():
        throw UnsupportedError('these rules have no path for $op');
      case ExportZip(:final id, :final slot):
        zips[slot] = d.exportZip(id);
      case ImportZip(:final slot):
        d.importZip(zips[slot]! as ZipPayload);
      case Rerecognize(:final id, :final version):
        d.rerecognize(id, version);
      case SetImageForm(:final form):
        d.setImageForm(server, form);
      case SyncRound(:final pageSize):
        if (d.syncEnabled) d.syncRound(server, pageSize: pageSize);
      case Pull(:final pageSize):
        if (d.syncEnabled) d.pull(server, pageSize: pageSize);
      case Push():
        if (d.syncEnabled) d.push(server);
      case SetSyncEnabled(:final enabled):
        d.syncEnabled = enabled;
      case LoseStateFile():
        d.loseStateFile();
    }
  }

  @override
  Observation observe() {
    final rows = <String, ObservedRow>{
      for (final r in server.index.values)
        r.id: ObservedRow(
          id: r.id,
          alive: r.alive,
          archiveOption: r.state == RowState.archived ? r.archiveOption : null,
          contentSet: r.alive ? r.contentSet : null,
          imageSet: server.images[r.id]?.set,
        ),
    };
    final devs = <String, ObservedDevice>{
      for (final MapEntry(key: n, value: d) in devices.entries)
        n: ObservedDevice(
          records: {
            for (final r in d.records.values)
              r.id: ObservedRecord(
                id: r.id,
                contentSet: r.contentSet,
                archiveOption: r.archive == ArchiveOption.unknown ? ArchiveOption.resizedJpeg : r.archive,
                imageSet: r.hasImages ? r.imageSet : null,
                forkedFrom: r.forkedFrom,
                hasSnapshot: d.snapshots.containsKey(r.id),
              ),
          },
          annotations: {
            for (final MapEntry(key: id, value: m) in d.memos.entries)
              (column: memoColumn, id: id): ObservedValue(m.value, m.time),
          },
          downloadImages: d.downloadImages,
        ),
    };
    return Observation(
      rows: rows,
      serverAnnotations: {
        for (final MapEntry(key: id, value: a) in server.annotations.entries) (column: memoColumn, id: id): a.value,
      },
      imageForm: server.imageForm,
      devices: devs,
      fingerprint: _fingerprint(),
    );
  }

  String _fingerprint() {
    final b = StringBuffer()
      ..writeAll(server.index.values.map((r) => r.toString()), ';')
      ..write('|${server.images.entries.map((e) => '${e.key}=${e.value.set}/${e.value.form}').join(',')}')
      ..write('|${server.annotations.entries.map((e) => '${e.key}=${e.value.value}@${e.value.time}').join(',')}');
    for (final d in devices.values) {
      b.write('|${d.name}:');
      for (final r in d.records.values) {
        b.write(
          '${r.id}=${r.contentSet}@${r.version}/${r.archive}/${r.imageSet}:${r.imageForm}'
          '/m${r.m?.base}:${r.m?.retired}/f${r.forkedFrom}/g${r.mergedIds},',
        );
      }
      b.write('K${d.intents.entries.map((e) => '${e.key}:${e.value}')}');
      b.write('M${d.memos.entries.map((e) => '${e.key}=${e.value.value}@${e.value.time}')}D${d.dirty}');
    }
    return b.toString();
  }
}
