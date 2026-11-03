// Random operation sequences over the model: generated from a seed, replayed, and shrunk to a
// minimal sequence when the judge reports something. Pure Dart (no test framework), so the fixed
// seeds of the rules of file sync in `test/sync_model_test.dart` (CI), those of the superseded rule sets in
// `tool/sync_model_superseded_rules.dart` and the large runs of `tool/sync_model_random.dart` share it.
//
// The generator draws one operation at a time against the world it is building, so every drawn
// operation is valid where it lands. A shrunk sequence is replayed with the operations that no
// longer apply skipped (a merge whose records are gone, an import of a zip never exported).
//
// Ratings, a second memo column, memos over the send limit, titles, dismissed pairs and inheritance
// links are drawn on a stream of their own, between the operations of the main draw
// ([AnnotationOpKind]). The account deleted, days passing and the data an app from before the
// operation log left are drawn on a third ([LifecycleGenerator]), and what goes wrong between a device
// and the server — a full storage, the day's rows used up, a push cut short with an answer or a
// request lost — on a fourth ([FaultGenerator]). What a log that never syncs takes in by zip is drawn
// on a fifth ([BystanderGenerator]), a round that ends while it receives on a sixth
// ([ReceiveCutGenerator]), and the limits on the day's reads on a seventh ([ReadLimitGenerator]).

import 'dart:math';

import 'package:umacapture/src/chara_detail/record_sync_merge.dart';

import 'file_mutations.dart';
import 'file_world.dart';
import 'judge.dart';
import 'lineage_mutations.dart';
import 'lineage_world.dart';
import 'mutations.dart';
import 'observation.dart';
import 'ops.dart';
import 'oplog_core.dart';
import 'oplog_mutations.dart';
import 'oplog_world.dart';
import 'types.dart';
import 'world.dart';

/// The kinds of operation the main draw draws. A new kind of operation is one more value here, a
/// weight and a case in [OpGenerator._build].
enum OpKind {
  capture,
  merge,
  delete,
  archive,
  editMemo,
  exportZip,
  importZip,
  rerecognize,
  setImageForm,
  syncRound,
  pull,
  push,
  toggleSync,
  loseStateFile,

  /// A merge, a delete, or a storage-screen delete that leaves no lineage and no delete tombstone
  /// ([Untracked]). Drawn only by [untrackedGenerator] and [deepUntrackedGenerator]: the rules in
  /// `core.dart` have no path for them.
  untrackedMerge,
  untrackedDelete,
  storageScreenDelete,
}

/// Relative weights. Sync rounds dominate so most changes travel; merges are the next most common
/// because nearly every rule of the design is about what a merge does to the other device.
const Map<OpKind, int> defaultWeights = {
  OpKind.capture: 8,
  OpKind.merge: 12,
  OpKind.delete: 5,
  OpKind.archive: 4,
  OpKind.editMemo: 6,
  OpKind.exportZip: 2,
  OpKind.importZip: 3,
  OpKind.rerecognize: 3,
  OpKind.setImageForm: 3,
  OpKind.syncRound: 24,
  OpKind.pull: 4,
  OpKind.push: 4,
  OpKind.toggleSync: 2,
  OpKind.loseStateFile: 1,
};

/// The weights of [deepGenerator]: more captures and merges, so both devices keep holding the same
/// records and merge them between two of their syncs.
const Map<OpKind, int> deepWeights = {
  OpKind.capture: 12,
  OpKind.merge: 16,
  OpKind.delete: 5,
  OpKind.archive: 4,
  OpKind.editMemo: 6,
  OpKind.exportZip: 2,
  OpKind.importZip: 3,
  OpKind.rerecognize: 3,
  OpKind.setImageForm: 3,
  OpKind.syncRound: 24,
  OpKind.pull: 4,
  OpKind.push: 4,
  OpKind.toggleSync: 2,
  OpKind.loseStateFile: 1,
};

/// The operations drawn on their own stream: ratings, memos in a second memo column, memos over the
/// send limit, column titles, a column's store deleted, dismissed pairs (and the file they are kept in
/// deleted) and inheritance links. None of them changes which
/// records a device lists, their versions, their state or the zips, which is all the main draw reads,
/// so drawing them between its operations from another random stream leaves the main draw of a seed
/// as it was before they existed. Each world draws from the kinds its rules have a path for and only
/// those ([AnnotationGenerator]), so a kind one rule set alone takes leaves every other rule set's
/// sequences as they were — and a rule set with no path for any (the rules in `core.dart` and the
/// lineage rules) draws exactly the sequences it drew before.
enum AnnotationOpKind { rating, secondMemo, longMemo, title, deleteColumnStore, dismiss, link }

const Map<AnnotationOpKind, int> defaultAnnotationWeights = {
  AnnotationOpKind.rating: 3,
  AnnotationOpKind.secondMemo: 2,
  AnnotationOpKind.longMemo: 1,
  AnnotationOpKind.title: 2,
  AnnotationOpKind.deleteColumnStore: 1,
  AnnotationOpKind.dismiss: 2,
  AnnotationOpKind.link: 3,
};

/// The columns the annotation stream writes: two memo columns and two rating columns.
const List<Column> annotationColumns = [
  memoColumn,
  (kind: AnnotationKind.memo, key: 'memo2'),
  (kind: AnnotationKind.rating, key: 'rating1'),
  (kind: AnnotationKind.rating, key: 'rating2'),
];

class GeneratorConfig {
  const GeneratorConfig({
    this.devices = const ['A', 'B'],
    this.minLength = 8,
    this.maxLength = 30,
    this.maxRecordsPerDevice = 6,
    this.weights = defaultWeights,
    this.startForms = const [ImageForm.png],
    this.annotationWeights = defaultAnnotationWeights,
    this.annotationEvery = 3,
    this.lifecycleEvery = 8,
    this.accountDeletionWeight = 1,
    this.elapseWeight = 24,
    this.oldDataEvery = 3,
    this.oldMemoEvery = 20,
    this.oldRecordEvery = 4,
    this.oldOtherContentEvery = 2,
    this.faultEvery = 10,
    this.bystander,
    this.bystanderEvery = 6,
    this.receiveCutEvery = 12,
    this.readLimitEvery = 24,
    this.mergesArchived = false,
  });

  final List<String> devices;
  final int minLength;
  final int maxLength;

  /// Captures stop while a device holds this many records, so merges keep finding pairs.
  final int maxRecordsPerDevice;
  final Map<OpKind, int> weights;

  /// The account image forms a sequence may start in, drawn uniformly: the form the user chose
  /// before anything else, so a sequence begins with that [SetImageForm] unless the rules' new
  /// account is in that form already. The form is an account setting a user lives with, not only
  /// something toggled now and then, and the form `none` is what leaves an image on the one device
  /// that captured it — the state every accepted image loss and every image-routing rule is about.
  final List<String> startForms;

  /// Relative weights of the annotation stream; empty draws none.
  final Map<AnnotationOpKind, int> annotationWeights;

  /// After each operation of the main draw, the annotation stream draws one with chance
  /// 1 / [annotationEvery].
  final int annotationEvery;

  /// After each operation of the main draw, the lifecycle stream draws one with chance
  /// 1 / [lifecycleEvery]: the account deleted or days passing, by these weights.
  final int lifecycleEvery;
  final int accountDeletionWeight;
  final int elapseWeight;

  /// One sequence in [oldDataEvery] starts with the data an app from before the operation log left
  /// (0: none).
  final int oldDataEvery;

  /// One sequence in [oldMemoEvery] starts with a device holding a record whose memo is one from before
  /// the limit, over it ([OldMemoGenerator]; 0: none).
  final int oldMemoEvery;

  /// One sequence in [oldRecordEvery] starts with records captured before the upgrade, which carry no
  /// binding of what they show to their images ([OldRecordGenerator]; 0: none).
  final int oldRecordEvery;

  /// Of the sequences that start with a record from before the upgrade on two devices, one in
  /// [oldOtherContentEvery] goes on with the app before putting a zip of another capture's content over it
  /// on one of them ([OldOtherContentGenerator]; 0: none).
  final int oldOtherContentEvery;

  /// After each operation of the main draw, the fault stream draws one with chance 1 / [faultEvery]
  /// (0: none).
  final int faultEvery;

  /// The log that never syncs and only takes zips in ([BystanderGenerator]), or null; and after each
  /// operation of the main draw, the chance 1 / [bystanderEvery] that it takes one in.
  final String? bystander;
  final int bystanderEvery;

  /// After each operation of the main draw, the chance 1 / [receiveCutEvery] that a round ends while
  /// it receives (0: none).
  final int receiveCutEvery;

  /// After each operation of the main draw, the chance 1 / [readLimitEvery] that the day's reads are
  /// limited, or the limit is lifted (0: never).
  final int readLimitEvery;

  /// The main draw merges archived records too — with an active one, or two of them — where the app
  /// of the rules offers them ([SyncWorld.mergesArchived]); else only active ones. A switch of its
  /// own: with it a seed draws other sequences than without.
  final bool mergesArchived;

  /// This configuration with [devices] and, when [faults] is false, no fault, no round cut while it
  /// receives and no limit on the day's reads drawn: the sequences as they were drawn before those
  /// streams existed.
  GeneratorConfig copyWith({List<String>? devices, bool faults = true, String? bystander}) => GeneratorConfig(
    bystander: bystander ?? this.bystander,
    bystanderEvery: bystanderEvery,
    receiveCutEvery: faults ? receiveCutEvery : 0,
    readLimitEvery: faults ? readLimitEvery : 0,
    devices: devices ?? this.devices,
    minLength: minLength,
    maxLength: maxLength,
    maxRecordsPerDevice: maxRecordsPerDevice,
    weights: weights,
    startForms: startForms,
    annotationWeights: annotationWeights,
    annotationEvery: annotationEvery,
    lifecycleEvery: lifecycleEvery,
    accountDeletionWeight: accountDeletionWeight,
    elapseWeight: elapseWeight,
    oldDataEvery: oldDataEvery,
    oldMemoEvery: oldMemoEvery,
    oldRecordEvery: oldRecordEvery,
    oldOtherContentEvery: oldOtherContentEvery,
    faultEvery: faults ? faultEvery : 0,
    mergesArchived: mergesArchived,
  );
}

/// Sequences that reach what [GeneratorConfig]'s defaults almost never do: a device that receives
/// another device's merge while its own unsent merge has retired the record that merge kept. That
/// takes two devices holding the same records, both merging them between two syncs, and the image
/// staying on the one device that captured it; with the defaults (up to 30 operations, every
/// sequence starting in `png`) 50,000 sequences reached it 0 times, with these about once in 2,000.
/// Each sequence is about twice as long, so a run costs about twice the time.
const deepGenerator = GeneratorConfig(
  maxLength: 60,
  weights: deepWeights,
  startForms: [ImageForm.png, ImageForm.jpeg, ImageForm.none],
);

/// The default generator, and the deep one, merging archived records too ([GeneratorConfig.mergesArchived]).
const archivedMergeGenerator = GeneratorConfig(mergesArchived: true);
const deepArchivedMergeGenerator = GeneratorConfig(
  maxLength: 60,
  weights: deepWeights,
  startForms: [ImageForm.png, ImageForm.jpeg, ImageForm.none],
  mergesArchived: true,
);

/// The weights of [untrackedGenerator]: the defaults, plus the removals an app without lineages or
/// the storage screen makes, rarely (one in about 85 operations each).
const Map<OpKind, int> untrackedWeights = {
  ...defaultWeights,
  OpKind.untrackedMerge: 1,
  OpKind.untrackedDelete: 1,
  OpKind.storageScreenDelete: 1,
};

/// The default generator with untracked removals; only the lineage rules support it.
const untrackedGenerator = GeneratorConfig(weights: untrackedWeights);

/// The deep generator with untracked removals.
const deepUntrackedGenerator = GeneratorConfig(
  maxLength: 60,
  weights: {...deepWeights, OpKind.untrackedMerge: 1, OpKind.untrackedDelete: 1, OpKind.storageScreenDelete: 1},
  startForms: [ImageForm.png, ImageForm.jpeg, ImageForm.none],
);

/// Whether [op] can be applied to [w] as it stands (the same test a GUI would make).
bool applicable(SyncWorld w, Op op) {
  if (!w.deviceNames.contains(op.device) || !w.supports(op)) return false;
  bool has(String id) => w.recordIds(op.device).contains(id);
  bool active(String id) => has(id) && w.isActive(op.device, id);
  bool merges(String id) => w.mergesArchived ? has(id) : active(id);
  if (w.runsOldApp(op.device) && !_oldAppDoes(op)) return false;
  return switch (op) {
    Capture(:final id) => !w.deviceNames.any((x) => w.recordIds(x).contains(id)),
    Merge(:final a, :final b, :final contentFrom) =>
      a != b && merges(a) && merges(b) && (contentFrom == a || contentFrom == b),
    Delete(:final id) => has(id),
    Archive(:final id) => active(id),
    EditAnnotation(:final id) => has(id),
    Dismiss(:final a, :final b) => a != b && has(a) && has(b),
    Link(:final id, :final slot, :final parent) =>
      (w.derivesParents || (id != parent && has(parent))) && has(id) && w.linkOf(op.device, id, 'parent$slot') == null,
    ExportZip(:final id) => has(id),
    ImportZip(:final slot) => w.zips.containsKey(slot),
    Rerecognize(:final id) => has(id),
    OldApp() => w.startsFresh(op.device),
    Upgrade() => w.runsOldApp(op.device),
    _ => true,
  };
}

/// What an app from before the operation log does on a device: no sync, annotation or setting of
/// the account. Its inheritance resolver links records as the app of the log's does.
bool _oldAppDoes(Op op) => switch (op) {
  Capture() ||
  Merge() ||
  Delete() ||
  Archive() ||
  Rerecognize() ||
  ExportZip() ||
  ImportZip() ||
  Link() ||
  Upgrade() => true,
  _ => false,
};

class OpGenerator {
  OpGenerator(this.random, this.config) {
    for (final MapEntry(key: k, value: v) in config.weights.entries) {
      for (var i = 0; i < v; i++) {
        _bag.add(k);
      }
    }
  }

  final Random random;
  final GeneratorConfig config;
  final List<OpKind> _bag = [];
  int _captures = 0;
  int _slots = 0;
  int _memos = 0;

  T _pick<T>(List<T> xs) => xs[random.nextInt(xs.length)];

  /// An operation valid in [w], drawn by weight.
  Op next(SyncWorld w) {
    for (var attempt = 0; attempt < 64; attempt++) {
      final op = _build(_pick(_bag), _pick(config.devices), w);
      if (op != null && applicable(w, op)) return op;
    }
    return SyncRound(_pick(config.devices));
  }

  Op? _build(OpKind kind, String device, SyncWorld w) {
    final ids = w.recordIds(device);
    final activeIds = [
      for (final id in ids)
        if (w.isActive(device, id)) id,
    ];
    switch (kind) {
      case OpKind.capture:
        if (ids.length >= config.maxRecordsPerDevice) return null;
        _captures++;
        return Capture(device, 'R$_captures', _captures, withImages: random.nextInt(8) != 0);
      case OpKind.merge:
        final offered = config.mergesArchived && w.mergesArchived ? ids : activeIds;
        if (offered.length < 2) return null;
        final a = _pick(offered);
        final b = _pick(offered.where((x) => x != a).toList());
        return Merge(device, a, b, contentFrom: random.nextBool() ? a : b);
      case OpKind.delete:
        return ids.isEmpty ? null : Delete(device, _pick(ids));
      case OpKind.archive:
        if (activeIds.isEmpty) return null;
        return Archive(device, _pick(activeIds), random.nextBool() ? ArchiveOption.none : ArchiveOption.resizedJpeg);
      case OpKind.editMemo:
        if (ids.isEmpty) return null;
        return EditMemo(device, _pick(ids), random.nextInt(5) == 0 ? null : 'memo${++_memos}');
      case OpKind.exportZip:
        return ids.isEmpty ? null : ExportZip(device, _pick(ids), 'z${++_slots}');
      case OpKind.importZip:
        // The zips a device exported for a bystander are that log's alone.
        final slots = w.zips.keys.where((s) => !s.startsWith(BystanderGenerator.slotPrefix)).toList()..sort();
        return slots.isEmpty ? null : ImportZip(device, _pick(slots));
      case OpKind.rerecognize:
        if (ids.isEmpty) return null;
        final id = _pick(ids);
        // Where the rules write at an older module too, half the draws are of a module no newer than the
        // record's, from the first up to its own; else, and the other half, one or two past it.
        final shown = w.versionOf(device, id);
        final older = w.rerecognizesAtAnyModule && random.nextBool();
        return Rerecognize(device, id, older ? 1 + random.nextInt(shown) : shown + 1 + random.nextInt(2));
      case OpKind.setImageForm:
        return SetImageForm(device, _pick(const [ImageForm.png, ImageForm.jpeg, ImageForm.none]));
      case OpKind.syncRound:
        return SyncRound(device, pageSize: _pageSize());
      case OpKind.pull:
        return Pull(device, pageSize: _pageSize());
      case OpKind.push:
        return Push(device);
      case OpKind.toggleSync:
        return SetSyncEnabled(device, enabled: !w.syncEnabled(device));
      case OpKind.loseStateFile:
        return LoseStateFile(device);
      case OpKind.untrackedMerge:
        if (activeIds.length < 2) return null;
        final a = _pick(activeIds);
        final b = _pick(activeIds.where((x) => x != a).toList());
        return Merge(device, a, b, contentFrom: random.nextBool() ? a : b, untracked: Untracked.legacyApp);
      case OpKind.untrackedDelete:
        return ids.isEmpty ? null : Delete(device, _pick(ids), untracked: Untracked.legacyApp);
      case OpKind.storageScreenDelete:
        return ids.isEmpty ? null : Delete(device, _pick(ids), untracked: Untracked.storageScreen);
    }
  }

  /// Mostly whole pages; sometimes a cut after one or two items, so a page boundary can fall
  /// between a tombstone and the row it points to.
  int _pageSize() => switch (random.nextInt(6)) {
    0 => 1,
    1 => 2,
    _ => 500,
  };
}

/// Draws the operations of the annotation stream ([AnnotationOpKind]) from a bag of the kinds [w]'s rules
/// have a path for: a kind they refuse takes no place in it, so it moves no other kind's draw.
class AnnotationGenerator {
  AnnotationGenerator(this.random, this.config, SyncWorld w) {
    for (final MapEntry(key: k, value: v) in config.annotationWeights.entries) {
      if (!_offered(k, config.devices.first, w)) continue;
      for (var i = 0; i < v; i++) {
        _bag.add(k);
      }
    }
  }

  final Random random;
  final GeneratorConfig config;
  final List<AnnotationOpKind> _bag = [];
  int _n = 0;

  T _pick<T>(List<T> xs) => xs[random.nextInt(xs.length)];

  /// Whether [w]'s rules take some operation of [kind] as [_build] makes them, asked of [w] itself.
  static bool _offered(AnnotationOpKind kind, String device, SyncWorld w) {
    const memo = 'note';
    final long = 'long'.padRight(memoSendLimit + 1, '.');
    final ops = switch (kind) {
      AnnotationOpKind.rating => [for (final c in annotationColumns.sublist(2)) EditRating(device, '', c, 0)],
      AnnotationOpKind.secondMemo => [EditMemo(device, '', memo, column: annotationColumns[1])],
      AnnotationOpKind.longMemo => [for (final c in annotationColumns.take(2)) EditMemo(device, '', long, column: c)],
      AnnotationOpKind.title => [for (final c in annotationColumns) Title(device, c, 'name')],
      AnnotationOpKind.deleteColumnStore => [for (final c in annotationColumns) DeleteColumnStore(device, c)],
      AnnotationOpKind.dismiss => [
        for (final dismissed in [true, false]) Dismiss(device, '', '', dismissed: dismissed),
        DeleteDismissalFile(device),
      ],
      AnnotationOpKind.link => [Link(device, '', 1, '', 0)],
    };
    return ops.any(w.supports);
  }

  /// After an operation of the main draw: an annotation operation valid in [w], or null.
  Op? after(SyncWorld w) {
    if (_bag.isEmpty || random.nextInt(config.annotationEvery) != 0) return null;
    final op = _build(_pick(_bag), _pick(config.devices), w);
    return op != null && applicable(w, op) ? op : null;
  }

  Op? _build(AnnotationOpKind kind, String device, SyncWorld w) {
    final ids = w.recordIds(device);
    if (ids.isEmpty && kind != AnnotationOpKind.title && kind != AnnotationOpKind.deleteColumnStore) return null;
    switch (kind) {
      case AnnotationOpKind.rating:
        final rating = random.nextInt(7);
        return EditRating(device, _pick(ids), annotationColumns[2 + random.nextInt(2)], rating == 6 ? null : rating);
      case AnnotationOpKind.secondMemo:
        return EditMemo(
          device,
          _pick(ids),
          random.nextInt(5) == 0 ? null : 'note${++_n}',
          column: annotationColumns[1],
        );
      case AnnotationOpKind.longMemo:
        // One character over the send limit, and unique like every memo drawn. Rules under which a user
        // types no memo that long (file sync, S-03) refuse it; there [OldMemoGenerator] puts one in.
        final text = 'long${++_n}'.padRight(memoSendLimit + 1, '.');
        return EditMemo(device, _pick(ids), text, column: annotationColumns[random.nextInt(2)]);
      case AnnotationOpKind.title:
        return Title(device, _pick(annotationColumns), random.nextInt(4) == 0 ? null : 'name${++_n}');
      case AnnotationOpKind.deleteColumnStore:
        return DeleteColumnStore(device, _pick(annotationColumns));
      case AnnotationOpKind.dismiss:
        if (ids.length < 2) return null;
        final a = _pick(ids);
        final op = Dismiss(device, a, _pick(ids.where((x) => x != a).toList()), dismissed: random.nextInt(4) != 0);
        // Rules that offer no pair again by itself delete the file the pairs are kept in instead.
        return w.supports(op) ? op : DeleteDismissalFile(device);
      case AnnotationOpKind.link:
        if (ids.length < 2) return null;
        final id = _pick(ids);
        final slot = 1 + random.nextInt(2);
        return Link(device, id, slot, _pick(ids.where((x) => x != id).toList()), random.nextInt(31));
    }
  }
}

/// Draws the operations of the lifecycle stream: at the start of some sequences, what an app from
/// before the operation log left on each device (its records, a copy of some of them by zip on the
/// other device, its merges, deletes and archives) and the first start of the app of the log; after
/// operations of the main draw, the account deleted or days passing. None of them is applicable under
/// rules that have no path for it, so those rules draw what they drew before.
class LifecycleGenerator {
  LifecycleGenerator(this.random, this.config);

  final Random random;
  final GeneratorConfig config;
  int _old = 0;
  int _slots = 0;

  T _pick<T>(List<T> xs) => xs[random.nextInt(xs.length)];

  /// The operations a sequence starts with, before the main draw: none, or the data an app from
  /// before the log left and the first start of the app of the log on every device. Applied one by
  /// one by the caller, each against the world the ones before it made.
  Iterable<Op> start(SyncWorld w) sync* {
    final devices = config.devices;
    if (config.oldDataEvery == 0 || !devices.every(w.startsFresh) || random.nextInt(config.oldDataEvery) != 0) return;
    for (final d in devices) {
      yield OldApp(d);
    }
    final first = devices.first;
    for (var i = 1 + random.nextInt(3); i > 0; i--) {
      yield Capture(first, 'L${++_old}', _old, withImages: random.nextInt(6) != 0);
    }
    // A copy of the first device's data on the others, by the zips of the app before.
    if (random.nextBool()) {
      for (final id in w.recordIds(first)) {
        if (random.nextInt(3) == 0) continue;
        final slot = 'o${++_slots}';
        yield ExportZip(first, id, slot);
        for (final d in devices.skip(1)) {
          yield ImportZip(d, slot);
        }
      }
    }
    for (final d in devices.skip(1)) {
      for (var i = random.nextInt(3); i > 0; i--) {
        yield Capture(d, 'L${++_old}', _old, withImages: random.nextInt(6) != 0);
      }
    }
    for (var i = random.nextInt(5); i > 0; i--) {
      final d = _pick(devices);
      final ids = w.recordIds(d);
      if (ids.isEmpty) continue;
      final active = [
        for (final id in ids)
          if (w.isActive(d, id)) id,
      ];
      switch (random.nextInt(6)) {
        case 0 || 1 when active.length >= 2:
          final a = _pick(active);
          final b = _pick(active.where((x) => x != a).toList());
          yield Merge(d, a, b, contentFrom: random.nextBool() ? a : b, untracked: Untracked.legacyApp);
        case 2:
          yield Delete(d, _pick(ids), untracked: Untracked.legacyApp);
        case 3 when active.isNotEmpty:
          yield Archive(d, _pick(active), random.nextBool() ? ArchiveOption.none : ArchiveOption.resizedJpeg);
        case 4:
          final id = _pick(ids);
          yield Rerecognize(d, id, w.versionOf(d, id) + 1);
        default:
          // A zip the app before made, left for the app of the log to import.
          yield ExportZip(d, _pick(ids), 'o${++_slots}');
      }
    }
    for (final d in devices) {
      yield Upgrade(d);
    }
  }

  /// After an operation of the main draw: a lifecycle operation valid in [w], or null.
  Op? after(SyncWorld w) {
    if (random.nextInt(config.lifecycleEvery) != 0) return null;
    final device = _pick(config.devices);
    final op = random.nextInt(config.accountDeletionWeight + config.elapseWeight) < config.accountDeletionWeight
        ? DeleteAccount(device)
        : Elapse(device, _pick(const [1, 2, 4, 8]));
    return applicable(w, op) ? op : null;
  }
}

/// Draws what a sequence starts with where the rules keep a memo from before the limit
/// ([EditMemo.fromBeforeTheLimit]): a device's record, captured before the upgrade, whose memo is over the
/// limit. A user types no memo that long, so this is the one way the generator puts one in a cell. None of
/// it is drawn under rules that do not keep such a memo, so those rules draw what they drew before.
class OldMemoGenerator {
  OldMemoGenerator(this.random, this.config);

  final Random random;
  final GeneratorConfig config;

  /// The id of the record; no other draw names a record so.
  static const id = 'M1';

  Iterable<Op> start(SyncWorld w) sync* {
    if (config.oldMemoEvery == 0 || random.nextInt(config.oldMemoEvery) != 0) return;
    final device = config.devices[random.nextInt(config.devices.length)];
    final column = annotationColumns[random.nextInt(2)];
    final memo = EditMemo(device, id, 'old'.padRight(memoSendLimit + 1, '.'), column: column, fromBeforeTheLimit: true);
    if (!w.supports(memo)) return;
    yield Capture(device, id, 0, withImages: random.nextInt(6) != 0, beforeTheUpgrade: true);
    yield memo;
  }
}

/// Draws what a sequence starts with where the rules bind what a record shows to its images
/// ([Capture.beforeTheUpgrade]): records each device captured before the upgrade, which carry no binding
/// — some with their images, some without. None of it is drawn under rules that have no such record, so
/// those rules draw what they drew before.
class OldRecordGenerator {
  OldRecordGenerator(this.random, this.config);

  final Random random;
  final GeneratorConfig config;
  int _old = 0;

  /// The prefix of the slots of the zips the app before made; no other draw names a slot so.
  static const slotPrefix = 'p';

  /// The prefix of the ids of the records; no other draw names a record so.
  static const idPrefix = 'P';

  Iterable<Op> start(SyncWorld w) sync* {
    if (config.oldRecordEvery == 0 || random.nextInt(config.oldRecordEvery) != 0) return;
    if (!w.supports(Capture(config.devices.first, '${idPrefix}0', 0, beforeTheUpgrade: true))) return;
    final made = <(String, String)>[];
    for (final device in config.devices) {
      for (var i = random.nextInt(3); i > 0; i--) {
        final id = '$idPrefix${++_old}';
        made.add((device, id));
        yield Capture(device, id, 0, withImages: random.nextInt(4) != 0, beforeTheUpgrade: true);
      }
    }
    // A copy of some of them on another device, made by the app before with its zips, before the upgrade:
    // the same record there, carrying no binding and no time either. Taking such a zip in after the upgrade
    // is the main draw's, as any other zip.
    for (final (device, id) in made) {
      if (random.nextBool()) continue;
      final slot = '$slotPrefix$id';
      yield ExportZip(device, id, slot, beforeTheUpgrade: true);
      for (final other in config.devices.where((x) => x != device)) {
        yield ImportZip(other, slot, beforeTheUpgrade: true);
      }
    }
  }
}

/// Draws, after [OldRecordGenerator]'s start, how a record from before the upgrade comes to show one capture
/// while its directory holds the images of another (v6 §4): the app before puts a zip of another capture's
/// content, holding no images, over the record on a device that holds it with its images — that app
/// compares nothing and leaves the directory as it is ([FDevice.importZip]).
///
/// The zip is made on the other device that holds the record: it captures another, merges it into the
/// record keeping the content of the capture, and zips the record. A zip of the app before holds the
/// images its record's directory holds, so the capture is either one taken without its images, or one
/// with them, and then the device zips the record twice — with the images, and after archiving it without
/// them — deletes it and takes the first zip in again: it holds the content with its own capture's images,
/// the other device the content with another capture's. Every operation is the app before's: its merge,
/// archive and delete carry [Untracked.legacyApp], its zips [ImportZip.beforeTheUpgrade].
///
/// Its own random stream, drawn after the rest of the start: under rules that have no merge of the app
/// before or no record from before the upgrade, and in a sequence with no such record on two devices,
/// nothing is drawn, and the sequence is the one drawn before this stream existed.
class OldOtherContentGenerator {
  OldOtherContentGenerator(this.random, this.config);

  final Random random;
  final GeneratorConfig config;

  /// The prefix of the ids of the captures merged in and of the slots of the zips; no other draw names a
  /// record or a slot so.
  static const idPrefix = 'Q';
  static const slotPrefix = 'q';

  T _pick<T>(List<T> xs) => xs[random.nextInt(xs.length)];

  Iterable<Op> start(SyncWorld w) sync* {
    final devices = config.devices;
    if (config.oldOtherContentEvery == 0) return;
    if (!w.supports(Merge(devices.first, '', '', contentFrom: '', untracked: Untracked.legacyApp)) ||
        !w.supports(Archive(devices.first, '', ArchiveOption.none, untracked: Untracked.legacyApp)) ||
        !w.supports(Capture(devices.first, '${idPrefix}0', 0, beforeTheUpgrade: true))) {
      return;
    }
    final shown = w.observe().devices;
    final pairs = [
      for (final maker in devices)
        for (final id in w.recordIds(maker))
          if (id.startsWith(OldRecordGenerator.idPrefix))
            for (final taker in devices)
              if (taker != maker && shown[taker]?.records[id]?.imageSet != null) (maker, taker, id),
    ];
    if (pairs.isEmpty || random.nextInt(config.oldOtherContentEvery) != 0) return;
    final (maker, taker, id) = _pick(pairs);
    final capture = '$idPrefix${id.substring(OldRecordGenerator.idPrefix.length)}';
    final slot = '$slotPrefix$id';
    final withImages = random.nextBool();
    yield Capture(maker, capture, 0, withImages: withImages, beforeTheUpgrade: true);
    // The record captured first is the older: it keeps its id.
    yield Merge(maker, id, capture, contentFrom: capture, untracked: Untracked.legacyApp);
    if (!withImages) {
      yield ExportZip(maker, id, slot, beforeTheUpgrade: true);
      yield ImportZip(taker, slot, beforeTheUpgrade: true);
      return;
    }
    yield ExportZip(maker, id, '${slot}a', beforeTheUpgrade: true);
    yield Archive(maker, id, ArchiveOption.none, untracked: Untracked.legacyApp);
    yield ExportZip(maker, id, slot, beforeTheUpgrade: true);
    yield Delete(maker, id, untracked: Untracked.legacyApp);
    yield ImportZip(maker, '${slot}a', beforeTheUpgrade: true);
    yield ImportZip(taker, slot, beforeTheUpgrade: true);
  }
}

/// Draws the operations of the fault stream: the storage full or with room again, the day's rows
/// limited or not, a push cut short (the answer or the request of one operation lost), and a sync the
/// user asks for. None of them is applicable under rules that have no path for it, so those rules
/// draw what they drew before.
class FaultGenerator {
  FaultGenerator(this.random, this.config);

  final Random random;
  final GeneratorConfig config;

  /// After an operation of the main draw: a fault valid in [w], or null.
  Op? after(SyncWorld w) {
    if (config.faultEvery == 0 || random.nextInt(config.faultEvery) != 0) return null;
    final device = config.devices[random.nextInt(config.devices.length)];
    final op = switch (random.nextInt(12)) {
      0 || 1 => SetStorageFull(device, full: true),
      2 || 3 => SetStorageFull(device, full: false),
      4 => SetDailyRows(device, 1 + random.nextInt(3)),
      5 || 6 => SetDailyRows(device, null),
      7 || 8 || 9 => PushCut(device, random.nextInt(3), stored: random.nextBool()),
      _ => Resume(device),
    };
    return applicable(w, op) ? op : null;
  }
}

/// Draws what a log that never syncs takes in ([GeneratorConfig.bystander]): a zip a device of the
/// account exports for it — of a record made beside another, whose id has a suffix, where that device
/// lists one, since its zip is the one whose operations may not make it under its id elsewhere — or
/// a zip the main draw exported. The bystander only takes in: it sends nothing, exports nothing and
/// reads no clock but its own, so the devices of the account do what they did without it, and the
/// main draw draws what it drew. Nothing is drawn in a world that has no such log.
class BystanderGenerator {
  BystanderGenerator(this.random, this.config);

  /// The slots of the zips exported for a bystander; the main draw imports none of them.
  static const slotPrefix = 'c';

  final Random random;
  final GeneratorConfig config;
  int _slots = 0;

  T _pick<T>(List<T> xs) => xs[random.nextInt(xs.length)];

  /// After an operation of the main draw: the operations of one import, or none.
  List<Op> after(SyncWorld w) {
    final bystander = config.bystander;
    if (bystander == null || !w.deviceNames.contains(bystander)) return const [];
    if (random.nextInt(config.bystanderEvery) != 0) return const [];
    if (random.nextInt(3) == 0) {
      final slots = w.zips.keys.where((s) => !s.startsWith(slotPrefix)).toList()..sort();
      return slots.isEmpty ? const [] : [ImportZip(bystander, _pick(slots))];
    }
    final device = _pick(config.devices);
    final ids = w.recordIds(device);
    if (ids.isEmpty) return const [];
    final beside = [
      for (final id in ids)
        if (id.contains(recordSyncSplitSeparator)) id,
    ];
    final slot = '$slotPrefix${++_slots}';
    return [ExportZip(device, _pick(beside.isEmpty ? ids : beside), slot), ImportZip(bystander, slot)];
  }
}

/// Draws the rounds that end while they receive ([ReceiveCut]): a device takes the first one to three
/// operations the server holds for it and no more, so it holds a log that stops partway through what
/// the other devices did — the state in which its log may show a record whose body it has not taken,
/// or one whose body the server holds no longer. Not applicable under rules that have no path for
/// it, so those rules draw what they drew before.
class ReceiveCutGenerator {
  ReceiveCutGenerator(this.random, this.config);

  final Random random;
  final GeneratorConfig config;

  /// After an operation of the main draw: a round cut while it receives, or null.
  Op? after(SyncWorld w) {
    if (config.receiveCutEvery == 0 || random.nextInt(config.receiveCutEvery) != 0) return null;
    final op = ReceiveCut(config.devices[random.nextInt(config.devices.length)], 1 + random.nextInt(3));
    return applicable(w, op) ? op : null;
  }
}

/// Draws the limit on the day's reads ([SetDailyReads]): the server answers one to three reads a day,
/// or as many as it is asked again. Under a limit a round ends where the reads run out — while it
/// receives, or with some of the bodies or the images it has to take — and the rounds of the days
/// after go on from there. Not applicable under rules that have no path for it, so those rules draw
/// what they drew before.
class ReadLimitGenerator {
  ReadLimitGenerator(this.random, this.config);

  final Random random;
  final GeneratorConfig config;

  /// After an operation of the main draw: a limit set or lifted, or null.
  Op? after(SyncWorld w) {
    if (config.readLimitEvery == 0 || random.nextInt(config.readLimitEvery) != 0) return null;
    final device = config.devices[random.nextInt(config.devices.length)];
    final op = SetDailyReads(device, random.nextBool() ? 1 + random.nextInt(3) : null);
    return applicable(w, op) ? op : null;
  }
}

/// Draws what each capture shows of the inheritance ([Capture.parents]), from a stream of its own, so the
/// operations every stream draws are the ones they drew without it. A capture names, in each slot, one of
/// the captures drawn before it, and none one time in four or where there is none to name; the two slots
/// name two captures. A capture drawn again under its name shows what it showed.
class InheritanceGenerator {
  InheritanceGenerator(this.random);

  final Random random;
  final List<String> _order = [];
  final Map<String, Map<int, String>> _of = {};

  /// [op], a capture with what it shows of the inheritance; any other operation as it is.
  Op of(Op op) {
    if (op is! Capture) return op;
    final parents = _of[op.id] ??= _draw(op.id);
    return Capture(
      op.device,
      op.id,
      op.captured,
      withImages: op.withImages,
      beforeTheUpgrade: op.beforeTheUpgrade,
      parents: parents,
    );
  }

  Map<int, String> _draw(String capture) {
    final earlier = [..._order];
    _order.add(capture);
    final parents = <int, String>{};
    for (final slot in [1, 2]) {
      final pool = earlier.where((c) => !parents.containsValue(c)).toList();
      if (pool.isNotEmpty && random.nextInt(4) != 0) parents[slot] = pool[random.nextInt(pool.length)];
    }
    return parents;
  }
}

/// Everything a configuration of the model needs besides the operations.
class ModelConfig {
  const ModelConfig({
    this.rules = Rules.designed,
    this.mutation,
    this.lineageMutation,
    this.oplogMutation,
    this.fileMutation,
    this.readings = LineageReadings.literal,
    this.accepted,
    this.judgeReadings = const JudgeReadings(),
    this.devices = const ['A', 'B'],
    this.bystander,
  });

  /// The lineage rules as written, with the judge's accepted outcomes for them.
  static const lineage = ModelConfig(rules: Rules.lineage);

  final Rules rules;

  /// Read by the rules in `core.dart` only.
  final Mutation? mutation;

  /// Read by the lineage rules only, as are [readings].
  final LineageMutation? lineageMutation;

  /// Read by the operation-log rules only.
  final OplogMutation? oplogMutation;

  /// Read by the rules of file sync only.
  final FileMutation? fileMutation;
  final LineageReadings readings;
  final Set<Accepted>? accepted;
  final JudgeReadings judgeReadings;
  final List<String> devices;

  /// Under the operation-log rules and the rules of file sync: a log, or a device, beside [devices]
  /// that never syncs and only takes zips in.
  final String? bystander;

  SyncWorld newWorld() => switch (rules) {
    Rules.lineage => LineageWorld(
      devices,
      mutation: lineageMutation,
      readings: readings,
      accepted: accepted,
      judgeReadings: judgeReadings,
    ),
    Rules.oplog => withLogView(
      OplogWorld(
        devices,
        mutation: oplogMutation,
        accepted: accepted,
        judgeReadings: judgeReadings,
        bystanders: [?bystander],
      ),
    ),
    Rules.file => FileWorld(
      devices,
      mutation: fileMutation,
      accepted: accepted,
      judgeReadings: judgeReadings,
      bystanders: [?bystander],
    ),
    _ => World(rules, devices, mutation: mutation, accepted: accepted, judgeReadings: judgeReadings),
  };
}

/// Hands [w]'s judge the operation log as data ([OperationLogView]): the operations each device's log
/// holds with the versions they saw, the version each record shows, and what each zip carries. Read
/// here, outside the judge, so the judge never imports the rules that fold the log.
OplogWorld withLogView(OplogWorld w) => w..judge.log = _OplogLogView(w);

class _OplogLogView implements OperationLogView {
  _OplogLogView(this.w);
  final OplogWorld w;

  /// A device of the account, or a log that never syncs.
  ODevice _holder(String device) => w.devices[device] ?? w.bystanders[device]!;

  @override
  Iterable<LoggedOp> log(String device) => _holder(device).arrival.map(
    (o) => LoggedOp(
      o.opId,
      o.kind.name,
      [
        for (final v in [o.seen, o.otherSeen])
          if (v.isNotEmpty) v,
      ],
      on: o.id,
      body: bodyOf(o),
      value: o.kind == OKind.annotate ? o.value : null,
      over: o.fromVer.isEmpty ? null : o.fromVer,
      zip: o.zipVer.isEmpty ? null : o.zipVer,
      // What the device waits for: read from its log as it stands, not kept with the operation.
      after: _holder(device).afterOf(o),
    ),
  );

  @override
  String? shown(String device, String id) => _holder(device).records[id]?.ver;

  @override
  String? row(String id) {
    final r = w.server.state.records[id];
    return r != null && r.live ? r.ver : null;
  }

  @override
  String? holder(String device, String version) => _holder(device).view.byVer[version];

  @override
  String? rowHolder(String version) => w.server.state.byVer[version];

  @override
  ObservedImport? imported(String device) => _holder(device).lastImport;

  @override
  bool stored(String id) => w.server.seqOf.containsKey(id);

  @override
  bool tookInAll(String device) => _holder(device).holdsAllOf(w.server);

  @override
  Iterable<String> storedTwice() => w.server.storedAgain;
}

class RunResult {
  RunResult(this.ops, this.violations, this.crash, this.world);

  /// The operations actually applied (inapplicable ones skipped), without the final settling.
  final List<Op> ops;
  final List<Violation> violations;

  /// An exception thrown by the model itself — a model bug, never a finding about the design.
  final Object? crash;
  final SyncWorld world;

  bool get failed => crash != null || violations.isNotEmpty;

  /// What a shrink must preserve: the crash's type, or the kinds of violation found.
  Set<String> get signature =>
      crash != null ? {'crash:${crash.runtimeType}'} : {for (final v in violations) v.kind.name};
}

/// Replays [ops] (skipping inapplicable ones) and drives the world to rest.
RunResult replay(ModelConfig config, List<Op> ops) {
  final w = config.newWorld();
  final applied = <Op>[];
  try {
    for (final op in ops) {
      if (!applicable(w, op)) continue;
      w.apply(op);
      applied.add(op);
    }
    return RunResult(applied, w.finish(), null, w);
  } on Object catch (e) {
    return RunResult(applied, const [], e, w);
  }
}

/// The world once [ops] ran (inapplicable ones skipped), before it is driven to rest.
SyncWorld worldAfter(ModelConfig config, List<Op> ops) {
  final w = config.newWorld();
  for (final op in ops) {
    if (applicable(w, op)) w.apply(op);
  }
  return w;
}

/// Seeds the annotation stream apart from the main draw of the same seed.
const _annotationStream = 0x5a17;

/// Seeds the lifecycle stream apart from the other two.
const _lifecycleStream = 0x2c4b;

/// Seeds the fault stream apart from the other three.
const _faultStream = 0x7f31;

/// Seeds the bystander's stream apart from the other four.
const _bystanderStream = 0x39d5;

/// Seeds the stream of the rounds cut while they receive apart from the other five.
const _receiveCutStream = 0x61e7;

/// Seeds the stream of the limits on the day's reads apart from the other six.
const _readLimitStream = 0x4d93;

/// Seeds the stream of the memos from before the limit apart from the other seven.
const _oldMemoStream = 0x1b6f;

/// Seeds the stream of the records from before the upgrade apart from the other eight.
const _oldRecordStream = 0x6a2d;

/// Seeds the stream of the zips of another capture's content the app before took in apart from the other nine.
const _oldOtherContentStream = 0x3e85;

/// Seeds the stream of what each capture shows of the inheritance apart from the other ten.
const _inheritanceStream = 0x5c3b;

/// The sequence seed [seed] generates: drawn step by step against a world under [config], the main
/// draw and the other streams each from a random stream of its own of the seed.
List<Op> generate(int seed, ModelConfig config, {GeneratorConfig gen = const GeneratorConfig()}) {
  final random = Random(seed);
  final drawn = gen.copyWith(devices: config.devices, bystander: config.bystander);
  final w = config.newWorld();
  final g = OpGenerator(random, drawn);
  final annotations = AnnotationGenerator(Random(seed ^ _annotationStream), drawn, w);
  final lifecycle = LifecycleGenerator(Random(seed ^ _lifecycleStream), drawn);
  final faults = FaultGenerator(Random(seed ^ _faultStream), drawn);
  final bystander = BystanderGenerator(Random(seed ^ _bystanderStream), drawn);
  final cuts = ReceiveCutGenerator(Random(seed ^ _receiveCutStream), drawn);
  final readLimits = ReadLimitGenerator(Random(seed ^ _readLimitStream), drawn);
  final oldMemos = OldMemoGenerator(Random(seed ^ _oldMemoStream), drawn);
  final oldRecords = OldRecordGenerator(Random(seed ^ _oldRecordStream), drawn);
  final oldOtherContents = OldOtherContentGenerator(Random(seed ^ _oldOtherContentStream), drawn);
  final inheritance = InheritanceGenerator(Random(seed ^ _inheritanceStream));
  final length = gen.minLength + random.nextInt(gen.maxLength - gen.minLength + 1);
  final ops = <Op>[];
  void take(Op drawnOp) {
    final op = inheritance.of(drawnOp);
    w.apply(op);
    ops.add(op);
  }

  final start = gen.startForms.length == 1 ? gen.startForms.single : g._pick(gen.startForms);
  try {
    if (start != w.observe().imageForm) take(SetImageForm(config.devices.first, start));
    // The main draw's length counts neither what the lifecycle stream starts the sequence with nor
    // the choice of `png`: under every rule set a seed draws the operations it would draw for an
    // account made in that form.
    final first = start == ImageForm.png ? 0 : 1;
    // Each stream's start draws against the world the operations before it made.
    for (final drawStart in [lifecycle.start, oldMemos.start, oldRecords.start, oldOtherContents.start]) {
      for (final op in drawStart(w)) {
        if (applicable(w, op)) take(op);
      }
    }
    for (var i = first; i < length; i++) {
      take(g.next(w));
      if (annotations.after(w) case final a?) take(a);
      if (lifecycle.after(w) case final l?) take(l);
      if (faults.after(w) case final f?) take(f);
      bystander.after(w).forEach(take);
      if (cuts.after(w) case final c?) take(c);
      if (readLimits.after(w) case final r?) take(r);
    }
  } on Object {
    // The replay reports the crash with its sequence; the prefix up to it is what reproduces it.
  }
  return ops;
}

/// Removes operations from [ops] while [stillFails] holds (delta debugging over chunks, then single
/// operations), then normalises page sizes. [stillFails] returns the operations it actually applied
/// when the candidate still fails, or null.
List<Op> shrinkOps(List<Op> ops, List<Op>? Function(List<Op>) stillFails) {
  var best = ops;
  var chunk = best.length ~/ 2;
  while (chunk >= 1) {
    var changed = false;
    for (var start = 0; start < best.length;) {
      final applied = stillFails([...best.sublist(0, start), ...best.sublist(min(start + chunk, best.length))]);
      if (applied != null && applied.length < best.length) {
        best = applied;
        changed = true;
      } else {
        start += chunk;
      }
    }
    if (!changed) chunk ~/= 2;
  }
  for (var i = 0; i < best.length; i++) {
    final op = best[i];
    final plain = switch (op) {
      SyncRound(:final pageSize) when pageSize != 500 => SyncRound(op.device),
      Pull(:final pageSize) when pageSize != 500 => Pull(op.device),
      _ => null,
    };
    if (plain == null) continue;
    final applied = stillFails([...best.sublist(0, i), plain, ...best.sublist(i + 1)]);
    if (applied != null) best = applied;
  }
  return best;
}

/// Shrinks a failing run while it keeps failing with the first kind of failure it had.
RunResult shrink(ModelConfig config, RunResult failing) {
  final kind = failing.signature.first;
  final ops = shrinkOps(failing.ops, (c) {
    final r = replay(config, c);
    return r.failed && r.signature.contains(kind) ? r.ops : null;
  });
  return replay(config, ops);
}

/// A sequence on which [mutant] fails while [baseline] passes: the mutant is caught by the
/// judge, not by a failure the baseline already has.
class Detection {
  Detection(this.seed, this.sequencesRun, this.original, this.shrunk);
  final int seed;
  final int sequencesRun;
  final RunResult original;
  final RunResult shrunk;
}

/// Every positive control: each mutation, the rules with retirement shortcuts, and the judge without
/// each accepted outcome.
/// Each must be caught by some generated sequence on which the rules as designed pass.
final Map<String, ModelConfig> positiveControls = {
  for (final m in Mutation.values) 'mutation ${m.name}': ModelConfig(mutation: m),
  'rules retirementShortcuts': const ModelConfig(rules: Rules.retirementShortcuts),
  for (final a in acceptedUnderDesigned)
    'judge without ${a.name}': ModelConfig(accepted: acceptedUnderDesigned.toSet()..remove(a)),
};

/// The positive controls of the lineage rules: each lineage mutation, and the judge without each of
/// the lineage rules' accepted outcomes. Each must be caught by some sequence of
/// [deepUntrackedGenerator] on which [ModelConfig.lineage] passes.
final Map<String, ModelConfig> lineagePositiveControls = {
  for (final m in LineageMutation.values)
    'lineage mutation ${m.name}': ModelConfig(rules: Rules.lineage, lineageMutation: m),
  for (final a in acceptedUnderLineage)
    'lineage judge without ${a.name}': ModelConfig(
      rules: Rules.lineage,
      accepted: acceptedUnderLineage.toSet()..remove(a),
    ),
};

/// The log the large random runs of the operation-log rules put beside the two devices
/// ([ModelConfig.bystander]).
const oplogBystander = 'C';

/// The positive controls of the operation-log rules: each mutation, and the judge without each of
/// their accepted outcomes. Each must be caught by some sequence of [deepUntrackedGenerator] on
/// which the operation-log rules pass.
final Map<String, ModelConfig> oplogPositiveControls = {
  for (final m in OplogMutation.values) 'oplog mutation ${m.name}': ModelConfig(rules: Rules.oplog, oplogMutation: m),
  for (final a in acceptedUnderOplog)
    'oplog judge without ${a.name}': ModelConfig(rules: Rules.oplog, accepted: acceptedUnderOplog.toSet()..remove(a)),
};

/// The device the large random runs of the rules of file sync put beside the two that sync.
const fileBystander = 'C';

/// The positive controls of the rules of file sync: each mutation, and the judge without each of
/// their accepted outcomes, under the readings these rules are run with ([fileReadings]).
final Map<String, ModelConfig> filePositiveControls = {
  for (final m in FileMutation.values)
    'file mutation ${m.name}': ModelConfig(rules: Rules.file, fileMutation: m, judgeReadings: fileReadings),
  for (final a in acceptedUnderFile)
    'file judge without ${a.name}': ModelConfig(
      rules: Rules.file,
      accepted: acceptedUnderFile.toSet()..remove(a),
      judgeReadings: fileReadings,
    ),
};

/// Runs seeds from [from] until the first sequence that separates [mutant] from [baseline], or
/// null after [limit] seeds. Each sequence is generated under the mutant.
Detection? detect(
  ModelConfig mutant,
  ModelConfig baseline, {
  int from = 1,
  int limit = 2000,
  GeneratorConfig gen = const GeneratorConfig(),
}) {
  List<Op>? separates(List<Op> c) {
    final r = replay(mutant, c);
    if (!r.failed || replay(baseline, r.ops).failed) return null;
    return r.ops;
  }

  for (var seed = from; seed < from + limit; seed++) {
    final ops = separates(generate(seed, mutant, gen: gen));
    if (ops == null) continue;
    final original = replay(mutant, ops);
    return Detection(seed, seed - from + 1, original, replay(mutant, shrinkOps(ops, separates)));
  }
  return null;
}

class Finding {
  Finding(this.seed, this.original, this.shrunk);
  final int seed;
  final RunResult original;
  final RunResult shrunk;
}

/// Runs seeds [from], [from]+1, … for [count] seeds; returns the failures (shrunk when [shrinkAll]).
/// Stops after the first failure when [stopAtFirst].
List<Finding> check(
  ModelConfig config, {
  required int from,
  required int count,
  bool stopAtFirst = false,
  bool shrinkAll = true,
  GeneratorConfig gen = const GeneratorConfig(),
}) {
  final found = <Finding>[];
  for (var seed = from; seed < from + count; seed++) {
    final r = replay(config, generate(seed, config, gen: gen));
    if (!r.failed) continue;
    found.add(Finding(seed, r, shrinkAll ? shrink(config, r) : r));
    if (stopAtFirst) break;
  }
  return found;
}

/// A finding as text: the shrunk sequence, what the judge said, and the state-table rows each
/// device and the server went through.
String describe(Finding f) {
  final r = f.shrunk;
  final b = StringBuffer()
    ..writeln('seed ${f.seed}: ${f.original.ops.length} ops -> ${r.ops.length} ops')
    ..writeln('  ops:');
  for (final op in r.ops) {
    b.writeln('    $op');
  }
  if (r.crash != null) b.writeln('  crash: ${r.crash}');
  for (final v in r.violations) {
    final c = r.world.judge.candidates['${v.kind.name}:${v.subject}'];
    b.writeln('  violation: $v${c == null ? '' : ' [candidate ${c.name}]'}');
  }
  final w = r.world;
  switch (w) {
    case World():
      for (final d in w.devices.values) {
        b.writeln('  rows ${d.name}: ${d.trace.join(' ')}');
      }
      b.writeln('  server: ${w.server.trace.join(' ')}');
    case LineageWorld():
      for (final d in w.devices.values) {
        b.writeln('  rules ${d.name}: ${d.trace.join(' ')}');
      }
      b.writeln('  server: ${w.server.trace.join(' ')}');
    case OplogWorld():
      for (final d in [...w.devices.values, ...w.bystanders.values]) {
        b.writeln('  rows ${d.name}: ${d.view.trace.join(' ')} ${d.trace.join(' ')}');
      }
      b.writeln('  server: ${w.server.state.trace.join(' ')}');
  }
  return b.toString();
}
