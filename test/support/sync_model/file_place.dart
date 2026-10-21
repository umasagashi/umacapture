// A device of the world as the app's round ([runSyncRoundOn]) reaches the device — its place ([SyncPlace]), the
// model's counterpart of the app's ([AppSyncPlace]) — and the world's server as the round reaches the server — the
// sync endpoints ([SyncServer]). Each operation does to the model what the app's does to its files, at the point the
// round calls it; neither decides anything of sync.
//
// A record's body is a text of what its `record.json` carries that sync carries ([syncBodyBytes]): its id, what it
// shows, its capture, its binding, its parents and when it was written. The server keeps it, and the parts and roots
// of its list, under the SHA-256 of their bytes, as the Worker does. An image file of the model holds the bytes of
// the image's name ([FRec.img]), and a binding names it by their SHA-256, so the app's image rule ([imagesBoundBy])
// reads the model's images as it reads files.

part of 'file_world.dart';

// A name is the SHA-256 of the bytes named, the same in every world: one table of each serves them all.

/// The model's image → the binding's name of it, and back.
final _bindingNames = <String, String>{};
final _imagesByName = <String, String>{};

/// Body text → its name.
final _bodyNames = <String, String>{};

/// [SyncKeptList.decode] of [bytes], once for each distinct bytes: decoding is a function of the bytes alone.
SyncKeptList _keptOfBytes(Uint8List bytes) =>
    _keptOf.putIfAbsent(String.fromCharCodes(bytes), () => SyncKeptList.decode(bytes));
final _keptOf = <String, SyncKeptList>{};

Uint8List _imageFile(String img) => utf8.encode(img);

String _bindingNameOf(String img) => _bindingNames.putIfAbsent(img, () {
  final name = syncObjectName(_imageFile(img));
  _imagesByName[name] = img;
  return name;
});

String _imageNamed(String name) => _imagesByName[name] ?? (throw StateError('No image of the model is named $name.'));

/// The body of [r] ([syncBodyBytes]): the same text on every device that holds the same body.
String _bodyText(FRec r) => jsonEncode({
  'id': r.id,
  'content': r.body,
  'captured': r.captured,
  'binding': switch (r.img) {
    final img? => _bindingNameOf(img),
    null => r.bound ? '' : null,
  },
  'parents': {for (final slot in parentSlots) slot: ?r.parents[slot]},
  'written_at': r.bodyTime,
});

String _bodyNameOf(FRec r) => _bodyNames.putIfAbsent(_bodyText(r), () => syncObjectName(utf8.encode(_bodyText(r))));

/// Body text → what it shows and its capture.
final _bodyFacts = <String, ({String content, int captured})>{};

({String content, int captured}) _factsIn(String body) => _bodyFacts.putIfAbsent(body, () {
  final json = jsonDecode(body) as Map<String, Object?>;
  return (content: json['content'] as String, captured: json['captured'] as int);
});

int _capturedIn(String body) => _factsIn(body).captured;

String _contentIn(String body) => _factsIn(body).content;

/// [r] as the app reads a record from its directory ([syncRecordOf]): the record says nothing of what it was split
/// off; only a list does.
SyncRecord _syncRecordOf(FRec r) => SyncRecord(
  r.id,
  body: SyncBody(
    r.body,
    binding: r.bound ? RecordBinding(skillPng: r.img == null ? null : _bindingNameOf(r.img!)) : null,
    parents: {...r.parents},
    time: r.bodyTime,
  ),
  absorbed: {...r.absorbed},
  stage: SyncValue(r.stage.archiveOption, r.stageTime),
);

/// The model's record of [r], of the capture [captured].
FRec _recOf(SyncRecord r, {required int captured}) {
  final content = r.body.content;
  final at = content.lastIndexOf('@');
  return FRec(
    r.id,
    captured: captured,
    recognisedFrom: content.substring(0, at),
    r: int.parse(content.substring(at + 1)),
    bodyTime: r.body.time,
    img: switch (r.body.binding?.skillPng) {
      final name? => _imageNamed(name),
      null => null,
    },
    boundToNoImage: r.body.binding != null && r.body.binding?.skillPng == null,
    absorbed: {...r.absorbed},
    stage: FStage.ofArchiveOption(r.stage.value),
    stageTime: r.stage.time,
    parents: {...r.body.parents},
    forkedFrom: r.splitFrom,
  );
}

/// A cell as the list carries it: its value as JSON text.
SyncValue<String?> _listCellOf(FCell c) => SyncValue(c.value == null ? null : jsonEncode(c.value), c.time);

FCell _cellOf(SyncValue<String?> v) => FCell(v.value == null ? null : jsonDecode(v.value!) as String, v.time);

/// [s] as the list carries it: what the app's round reads of a device that holds it.
SyncList _listOf(FState s) => SyncList(
  rows: {for (final r in s.records.values) r.id: SyncListRow(_syncRecordOf(r), bodyName: _bodyNameOf(r))},
  cells: {for (final MapEntry(:key, :value) in s.cells.entries) key: _listCellOf(value)},
  titles: {for (final MapEntry(:key, :value) in s.titles.entries) key: SyncValue(value.value, value.time)},
  dismissed: {
    for (final pair in s.dismissed)
      if (pair.split('+') case [final a, final b]) (a, b),
  },
);

/// The state of [list], the capture of each record read off its body ([bodyOf]).
FState _stateOf(SyncList list, String Function(String bodyName) bodyOf) => FState()
  ..records.addAll({
    for (final MapEntry(key: id, value: row) in list.rows.entries)
      id: _recOf(row.record, captured: _capturedIn(bodyOf(row.bodyName))),
  })
  ..cells.addAll({for (final MapEntry(:key, :value) in list.cells.entries) key: _cellOf(value)})
  ..titles.addAll({for (final MapEntry(:key, :value) in list.titles.entries) key: FCell(value.value, value.time)})
  ..dismissed.addAll({for (final (a, b) in list.dismissed) pairOf(a, b)});

/// What a record split off carries from the device's record it is split off: that record, for its body, and its
/// image.
typedef _Carried = ({FRec record, String? image});

/// [d] as the app's place. [server] gives the bodies a base names, for the state of it the device keeps ([FDevice.base]).
/// [writesLanding]: the writes of the round's result that land — each call of [putMetadata], [publish] and [remove]
/// is one — before every one after fails, as where the app stops ([PlaceCut]); null, all of them.
class _FilePlace implements SyncPlace<_Carried> {
  _FilePlace(this.d, this.server, {int? writesLanding}) : _landing = writesLanding;
  final FDevice d;
  final FServer server;
  int? _landing;

  /// Whether the next write of the result lands.
  bool _lands() {
    final left = _landing;
    if (left == null) return true;
    if (left == 0) return false;
    _landing = left - 1;
    return true;
  }

  String _bodyNamed(String name) =>
      server.syncObjects[name] ??
      [
        for (final r in d.store.records.values)
          if (_bodyNameOf(r) == name) _bodyText(r),
      ].firstOrNull ??
      (throw StateError('${d.name}: no body is named $name.'));

  @override
  Future<SyncKeptList?> readKept(SyncKept which) async => switch (which) {
    SyncKept.base => d.keptBase,
    SyncKept.sent => d.keptSent,
  };

  /// As the app's, through the bytes it writes and reads back.
  @override
  Future<void> keep(SyncKept which, SyncKeptList? written) async {
    final list = written == null ? null : _keptOfBytes(written.toBytes());
    switch (which) {
      case SyncKept.base:
        d.keptBase = list;
        d.base = list == null
            ? null
            : (account: int.parse(list.account), generation: list.generation, list: _stateOf(list.agreed, _bodyNamed));
        if (list != null && list.pending.isEmpty) d.baseGap = null;
      case SyncKept.sent:
        d.keptSent = list;
    }
  }

  @override
  Future<void> loaded() async {}

  @override
  ({List<SyncUnbound> records, int held}) unbound() {
    final held = d.store.records.values;
    return (
      records: [
        for (final archiveStore in [false, true])
          for (final r in held)
            if (!r.bound && (r.stage != FStage.active) == archiveStore) (id: r.id, archiveStore: archiveStore),
      ],
      held: held.length,
    );
  }

  @override
  Future<void> workOutBinding(SyncUnbound record) async => d._bind(record.id);

  @override
  Future<SyncLocal?> read({LocalSyncRead? previous}) async {
    final s = d.store;
    final shelf = d.shelfAsRead ?? d.shelfRead;
    return (
      local: LocalSyncRead(
        _listOf(s),
        quarantined: shelf.named,
        quarantineUnnamed: shelf.unnamed,
        quarantineDeleted: {...d.shelfDeleted},
      ),
      unavailable: const <String>{},
    );
  }

  @override
  Future<_Carried> carriedBy(String id, SyncRecord asRead) async {
    final r = d.store.records[id] ?? (throw StateError('${d.name}: the record $id cannot be read.'));
    return (record: r.copy(), image: d.images[id]);
  }

  @override
  Future<bool> putMetadata(SyncMetadataWrite write) async {
    if (!_lands()) return false;
    final SyncMetadataWrite(:result, read: local, :ids) = write;
    final s = d.store;
    for (final column in write.columns) {
      final read = local.titles[column];
      final heading = write.titles && read != result.titles[column] ? result.titles[column] : null;
      final held = s.titles[column];
      if (heading != null && (read == null || (held != null && SyncValue<String?>(held.value, held.time) == read))) {
        s.titles[column] = FCell(heading.value, heading.time);
      }
      // The column's storage is written, and made where the device held none: as the app's, untitled by the round.
      s.titles.putIfAbsent(column, () => madeTitle);
      for (final id in ids) {
        final key = (column, id);
        final had = switch (s.cells[key]) {
          final c? => _listCellOf(c),
          null => null,
        };
        final cell = result.cells[key];
        if (had != local.cells[key] || had == cell) continue;
        cell == null ? s.cells.remove(key) : s.cells[key] = _cellOf(cell);
      }
    }
    if (write.pairs case final pairs?) {
      final read = local.dismissed;
      final next = {
        for (final pair in s.dismissed)
          if (pair.split('+') case [final a, final b])
            if (syncDismissedPair(a, b) case final p when !read.contains(p) || pairs.contains(p)) p,
        for (final pair in pairs)
          if (!read.contains(pair)) pair,
      };
      s.dismissed
        ..clear()
        ..addAll({for (final (a, b) in next) pairOf(a, b)});
    }
    return true;
  }

  /// Whether the device holds the record [id] now as the round read it ([read]; none where null), or as [orAs].
  bool _heldAsRead(String id, SyncRecord? read, {SyncRecord? orAs}) {
    final now = switch (d.store.records[id]) {
      final r? => _syncRecordOf(r),
      null => null,
    };
    if (read == null ? now == null : syncRecordsAgree(read, now)) return true;
    return orAs != null && syncRecordsAgree(orAs, now);
  }

  @override
  Future<SyncPublished> publish(SyncPublication<_Carried> publication) async {
    final SyncPublication(record: r, :asRead, :source, :splitFrom, :splitAway, imageSources: sources) = publication;
    final id = r.id;
    // The images of the records it takes from, as the device holds them before the record's lock.
    final others = [for (final other in sources ?? const <String>[]) d.images[other]];
    if (!_heldAsRead(id, asRead, orAs: r)) return const SyncNotPublished(SyncWriteStop.changed);
    if (!_lands()) return const SyncNotPublished(SyncWriteStop.failed);
    final captured = switch (source) {
      SyncDeviceBody() => (d.store.records[id] ?? (throw StateError('${d.name} holds no record $id.'))).captured,
      SyncSplitBody() => (splitFrom ?? (throw StateError('$id is split off no record.'))).carried.record.captured,
      SyncServerBody(:final text) => _capturedIn(text),
    };
    final placed = _recOf(r, captured: captured);
    // The files a record split off carries go with it whatever its body's source.
    final carried = splitFrom?.carried.image;
    final String? image;
    if (sources == null) {
      image = carried ?? d.images[id];
    } else {
      bool bound(String img) => imagesBoundBy(r.body.binding, {'skill': (png: _imageFile(img), jpeg: null)}).isNotEmpty;
      final own = asRead == null ? null : d.images[id];
      final kept = own != null && bound(own) ? own : null;
      final taken = kept != null ? null : others.nonNulls.where(bound).firstOrNull;
      image = taken ?? carried ?? kept;
    }
    d.store.records[id] = placed;
    // A record archived without images is shaped to hold none once it is published.
    image == null || placed.stage == FStage.none ? d.images.remove(id) : d.images[id] = image;
    switch ((splitFrom == null ? null : d.bonus[splitFrom.id]) ?? (splitAway ? null : d.bonus[id])) {
      case final bonus?:
        d.bonus[id] = bonus;
      case null:
        d.bonus.remove(id);
    }
    d.tookIn.add(id);
    if (splitFrom != null) d.splitOff[splitFrom.id] = id;
    return SyncPublishedAs(_bodyNameOf(placed));
  }

  @override
  Future<SyncWriteStop?> remove(Map<String, SyncRecord> asRead) async {
    if (!_lands()) return SyncWriteStop.failed;
    for (final archiveStore in [false, true]) {
      var left = false;
      for (final MapEntry(key: id, value: read) in asRead.entries) {
        if ((read.stage.value != null) != archiveStore) continue;
        if (!_heldAsRead(id, read)) {
          left = true;
          continue;
        }
        d._letGo(id);
        d.tookIn.add(id);
      }
      if (left) return SyncWriteStop.changed;
    }
    return null;
  }

  @override
  void published(Iterable<String> ids) {}

  @override
  Future<Uint8List?> bodyOf(SyncRecord listed) async {
    final r = d.store.records[listed.id];
    // The record.json of the store of its stage as listed.
    if (r == null || (r.stage != FStage.active) != (listed.stage.value != null)) return null;
    return utf8.encode(_bodyText(r));
  }
}

/// [s] as the sync endpoints, for the device [device]'s round. The server answers what the Worker answers
/// (`docs/sync-protocol.md`), in the order the app's fake of it does: a root that names an object the server lacks,
/// then a stale generation, then the limits [FServer.slotsPerSwap] and [FServer.operationsPerSwap]. [cut]: the swap
/// past the ones it answers gets no answer, as a connection that drops ([SwapCut]).
class _FileSyncServer implements SyncServer {
  _FileSyncServer(this.s, this.device, {this.cut});
  final FServer s;
  final String device;
  final SwapCut? cut;

  /// Thrown where a swap gets no answer: not a refusal of the server's, so the app's round reads it as no answer
  /// ([SyncRoundEnd.answerLost]).
  static final dropped = StateError('the connection dropped');

  /// The calls of [replaceRoot] in this round, refused ones included: the one [cut] loses the request of.
  var _calls = 0;

  /// Whether the next replacement is the first of an attempt: one begins with a read of the generation.
  var _attemptBegins = false;

  /// Replacements made in this round, for [FServer.afterSwap].
  var _made = 0;

  /// Whether the last refusal was of a replacement over the limits.
  var refusedAsTooLarge = false;

  bool _holdsBody(String name) => switch (s.syncObjects[name]) {
    final text? => s.bodies.contains(_contentIn(text)),
    null => false,
  };

  Never _refuse(SyncRefusal refusal) {
    refusedAsTooLarge = refusal.isTooManyObjects || refusal.partsLimit != null;
    throw refusal;
  }

  @override
  Future<({int generation, String? root})> readGeneration() async {
    _attemptBegins = true;
    return (generation: s.generation, root: s.rootName);
  }

  @override
  Future<String> root(String name) async => s.syncObjects[name] ?? _refuse(const SyncRefusal(404, 'not_found'));

  @override
  Future<String> part(String name) async => s.syncObjects[name] ?? _refuse(const SyncRefusal(404, 'not_found'));

  @override
  Future<List<({String name, String body})>> bodies(List<String> names) async {
    final missing = names.where((name) => !_holdsBody(name)).toList();
    if (missing.isNotEmpty) _refuse(SyncRefusal(404, 'not_found', missing));
    return [for (final name in names) (name: name, body: s.syncObjects[name]!)];
  }

  @override
  Future<void> putBodies(List<({String name, String body})> bodies) async {
    for (final b in bodies) {
      if (b.name != syncObjectName(utf8.encode(b.body))) _refuse(const SyncRefusal(400, 'invalid_payload', 'name'));
      s.syncObjects[b.name] = b.body;
      if (s.putBody(device, _contentIn(b.body)) != FAnswer.stored) throw StateError('$device: a body was not stored');
    }
  }

  @override
  Future<void> putPart(String name, String text) async => s.syncObjects[name] = text;

  @override
  Future<int> replaceRoot(int generation, String name, String text) async {
    s.beforeSwap?.call(device);
    if (cut case SwapCut(stored: false, :final answered) when _calls++ == answered) throw dropped;
    Map<String, Object?> partsOf(String? root) =>
        root == null ? const {} : (jsonDecode(root) as Map<String, Object?>)['parts'] as Map<String, Object?>;
    final parts = partsOf(text);
    final missingParts = parts.values.where((part) => !s.syncObjects.containsKey(part)).toList();
    if (missingParts.isNotEmpty) _refuse(SyncRefusal(409, 'missing_objects', missingParts));
    final list = syncListOfParts([for (final part in parts.values) s.syncObjects[part]!]);
    final missingBodies = [
      for (final row in list.rows.values)
        if (!_holdsBody(row.bodyName)) row.bodyName,
    ];
    if (missingBodies.isNotEmpty) _refuse(SyncRefusal(409, 'missing_objects', missingBodies));
    // The operations it changes, where a limit is set: what the limit weighs, and what the rounds under it send.
    final limited = s.operationsPerSwap != null || s.slotsPerSwap != null;
    final changes = limited ? syncListChanges(s._syncLists[generation] ?? s.syncList, list) : const <SyncListChange>[];
    if (_attemptBegins && limited) s.attempts.add((device: device, changes: changes));
    _attemptBegins = false;
    if (generation != s.generation && s.mutation != FileMutation.swapIgnoresGeneration) {
      s.swapsRefused++;
      _refuse(SyncRefusal(409, 'stale_generation', s.generation));
    }
    final was = partsOf(switch (s.rootName) {
      final root? => s.syncObjects[root],
      null => null,
    });
    final slots = {...was.keys, ...parts.keys}.where((slot) => was[slot] != parts[slot]).length;
    if (s.slotsPerSwap case final limit? when slots > limit) _refuse(SyncRefusal(400, 'too_many_parts', limit));
    if (s.operationsPerSwap case final limit? when changes.length > limit) {
      _refuse(const SyncRefusal(409, 'too_many_objects'));
    }
    if (s.swap(generation, _stateOf(list, (body) => s.syncObjects[body]!)) != true) {
      throw StateError('$device: the server did not swap a replacement it took');
    }
    refusedAsTooLarge = false;
    s.syncObjects[name] = text;
    s
      ..rootName = name
      ..syncList = list
      .._syncLists[s.generation] = list
      ..made.addAll([if (limited) (device: device, changes: changes)]);
    // The answer is the generation this replacement made, whatever another device's round right after it does.
    final made = s.generation;
    final swap = _made++;
    s.afterSwap?.call(device, swap);
    if (cut case SwapCut(stored: true, :final answered) when swap == answered) throw dropped;
    return made;
  }
}
