// The world under the lineage rules: the same judge, the same operations and the same generator as
// the other rule set (`world.dart`), over `lineage_server.dart` and `lineage_device.dart`.

import 'judge.dart';
import 'lineage_core.dart';
import 'lineage_device.dart';
import 'lineage_mutations.dart';
import 'lineage_server.dart';
import 'observation.dart';
import 'ops.dart';
import 'world.dart';

class LineageWorld extends SyncWorld {
  LineageWorld(
    List<String> deviceNames, {
    this.mutation,
    this.readings = LineageReadings.literal,
    Set<Accepted>? accepted,
    super.judgeReadings,
  }) : server = LineageServer(mutation: mutation),
       super(accepted: accepted ?? acceptedUnderLineage) {
    for (final n in deviceNames) {
      devices[n] = LineageDevice(n, tick, mutation: mutation, readings: readings, onFork: _noteFork);
    }
  }

  final LineageMutation? mutation;
  final LineageReadings readings;
  final LineageServer server;
  final Map<String, LineageDevice> devices = {};

  /// Forks between two versions whose heads are both the first head of a record merged without a
  /// lineage, made from the same `merged_ids`: the same merge, read at different recognizer versions.
  /// Not a loss (both stay), so the judge does not see it; counted here so a run can report it.
  int untrackedHeadForks = 0;

  void _noteFork(Lineage local, Lineage row) {
    final a = local.events.lastOrNull;
    final b = row.events.lastOrNull;
    if (a == null || b == null || a.head != local.head || b.head != row.head) return;
    bool untracked(Event e) => e.kind == EventKind.legacy || e.kind == EventKind.external;
    if (untracked(a) && untracked(b) && a.marker.length == b.marker.length && a.marker.containsAll(b.marker)) {
      untrackedHeadForks++;
    }
  }

  @override
  Iterable<String> get deviceNames => devices.keys;

  @override
  List<String> recordIds(String device) => devices[device]!.records.keys.toList()..sort();

  @override
  bool isActive(String device, String id) => devices[device]!.records[id]?.stage == Stage.active;

  @override
  int versionOf(String device, String id) => devices[device]!.records[id]!.version;

  @override
  bool syncEnabled(String device) => devices[device]!.syncEnabled;

  /// One memo per record, with no send limit, and no ratings, titles, dismissed pairs or inheritance
  /// links.
  @override
  bool supports(Op op) => switch (op) {
    Merge(:final untracked) => untracked != Untracked.storageScreen,
    Capture(:final beforeTheUpgrade) || ExportZip(:final beforeTheUpgrade) => !beforeTheUpgrade,
    EditMemo(:final column, :final value) => column == memoColumn && !overMemoLimit(value),
    EditRating() || Title() || DeleteColumnStore() || Dismiss() || DeleteDismissalFile() || Link() => false,
    DeleteAccount() || Elapse() || OldApp() || Upgrade() => false,
    SetStorageFull() || SetDailyRows() || SetDailyReads() || PushCut() || ReceiveCut() || Resume() => false,
    ShelfOp() => false,
    _ => true,
  };

  @override
  void execute(Op op) {
    final d = devices[op.device]!;
    final how = switch (op) {
      Merge(:final untracked) || Delete(:final untracked) => untracked,
      _ => Untracked.none,
    };
    // The storage screen is part of the app the rules describe and writes the delete tombstone (D2)
    // as the record store does; only an app without lineages leaves no trace.
    final untracked =
        how == Untracked.legacyApp ||
        (how == Untracked.storageScreen && mutation == LineageMutation.storageScreenLeavesNoTomb);
    if (how != Untracked.legacyApp) d.readUntrackedMerges();
    switch (op) {
      case Capture(:final id, :final captured, :final withImages):
        d.capture(id, captured, withImages: withImages);
      case Merge(:final a, :final b, :final contentFrom):
        d.merge(a, b, contentFrom: contentFrom, tracked: !untracked);
      case Delete(:final id):
        d.delete(id, tracked: !untracked);
      case Archive(:final id, :final option):
        d.archive(id, option);
      case EditMemo(:final id, :final value):
        tick();
        d.editMemo(id, value);
      case EditRating() || Title() || DeleteColumnStore() || Dismiss() || DeleteDismissalFile() || Link():
      case DeleteAccount() || Elapse() || OldApp() || Upgrade():
      case SetStorageFull() || SetDailyRows() || SetDailyReads() || PushCut() || ReceiveCut() || Resume():
      case ShelfOp():
        throw UnsupportedError('these rules have no path for $op');
      case ExportZip(:final id, :final slot):
        zips[slot] = d.exportZip(id);
      case ImportZip(:final slot):
        d.importZip(zips[slot]! as LZip);
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
          alive: r.live,
          archiveOption: r.live ? r.stage.option : null,
          contentSet: r.live ? r.contentSet : null,
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
                archiveOption: r.stage.option,
                imageSet: r.hasImages ? r.imageSet : null,
                forkedFrom: r.forkedFrom,
                hasSnapshot: d.seen.containsKey(r.id),
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
          '${r.id}=${r.contentSet}@${r.version}/${r.stage.name}/${r.imageSet}:${r.imageForm}'
          '/h${r.lineage.head}/f${r.forkedFrom}/g${r.marker},',
        );
      }
      b.write('K${d.ownTombs.keys}T${d.knownTombs.entries.map((e) => '${e.key}:${e.value.length}')}');
      b.write('M${d.memos.entries.map((e) => '${e.key}=${e.value.value}@${e.value.time}')}D${d.dirty}');
    }
    return b.toString();
  }
}
