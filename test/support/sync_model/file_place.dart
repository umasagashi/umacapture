// A device of the world as the app's round ([runSyncRoundOn]) reaches the device — its place ([SyncPlace]), the
// model's counterpart of the app's ([AppSyncPlace]) — and the world's server as the round reaches the server — the
// sync endpoints ([SyncServer]). Each operation does to the model what the app's does to its files, at the point the
// round calls it; neither decides anything of sync.
//
// A record's body is a text of what its `record.json` carries that sync carries ([syncBodyBytes]): its id, what it
// shows, its capture, its binding with the geometry and the icon placed with it, its parents and when it was written.
// The server keeps it, and the parts and roots of its list, under the SHA-256 of their bytes, as the Worker does. An
// image file of the model is a real one: the PNG of the image that stands for a capture's three ([modelImage]) is a
// small picture of that capture's own, its reduced JPEG the one the app's archive makes of it ([archiveJpegOf]), its
// icon a picture of its own, and its geometry file the one the app writes of the capture's rect ([geometryRectOf]). A
// binding names each image by the SHA-256 of its bytes, so the app's rules of images — the binding, geometry and icon
// worked out of a directory ([recordBodyImagesOf]), the files a binding names ([imagesBoundBy]), which makes a JPEG of
// a PNG where it knows the JPEG's field alone, and the geometry files a placed form is written with
// ([recordGeometryFiles]) — read the model's images as they read files.

part of 'file_world.dart';

// A name is the SHA-256 of the bytes named, the same in every world: one table of each serves them all.

/// `<capture>/<file>` → the file's bytes, and its name; the name → the capture, and the capture and the file; the
/// bytes → the capture, for the bytes [_imageFile] made.
final _imageBytes = <String, Uint8List>{};
final _fileNames = <String, String>{};
final _capturesByName = <String, String>{};
final _filesByName = <String, (String, String)>{};
final _captureOfBytes = Expando<String>();

/// Body text → its name.
final _bodyNames = <String, String>{};

/// [SyncKeptList.decode] of [bytes], once for each distinct bytes: decoding is a function of the bytes alone.
SyncKeptList _keptOfBytes(Uint8List bytes) =>
    _keptOf.putIfAbsent(String.fromCharCodes(bytes), () => SyncKeptList.decode(bytes));
final _keptOf = <String, SyncKeptList>{};

/// [SyncKeptImages.decode] of [bytes], once for each distinct bytes.
SyncKeptImages _keptImagesOfBytes(Uint8List bytes) =>
    _keptImagesOf.putIfAbsent(String.fromCharCodes(bytes), () => SyncKeptImages.decode(bytes));
final _keptImagesOf = <String, SyncKeptImages>{};

/// The bytes of the file [file] (`skill.png`, `skill.jpg`, …) of the capture [capture]'s images: a PNG of four by
/// four pixels drawn from the SHA-256 of the two, so that no two captures' are alike, and the reduced JPEG the app's
/// archive makes of that PNG; and of its icon ([_iconOf]).
Uint8List _imageFile(String capture, String file) => file == traineeIconFileName
    ? _iconOf(capture)
    : _imageBytes.putIfAbsent('$capture/$file', () {
        final [image, form] = file.split('.');
        final bytes = form == 'jpg'
            ? archiveJpegOf(_imageFile(capture, '$image.png')) ?? (throw StateError('The app makes no JPEG of $file.'))
            : _pictureOf('$capture/$image');
        _captureOfBytes[bytes] = capture;
        return bytes;
      });

/// A PNG of four by four pixels drawn from the SHA-256 of [seed].
Uint8List _pictureOf(String seed) {
  final hash = sha256.convert(utf8.encode(seed)).bytes;
  final picture = img.Image(width: 4, height: 4);
  for (var i = 0; i < 16; i++) {
    picture.setPixelRgb(i % 4, i ~/ 4, hash[i], hash[(i + 16) % 32], hash[(i * 7) % 32]);
  }
  return img.encodePng(picture);
}

/// The bytes of the icon of [capture] (`trainee.jpg`): a picture of its own, which no binding names, and which a body
/// names by its SHA-256 (`metadata.icon`); the recognizer cuts the same from the capture's factor image every time.
Uint8List _iconOf(String capture) => _imageBytes.putIfAbsent('$capture/$traineeIconFileName', () {
  final bytes = _pictureOf('$capture/icon');
  _captureOfBytes[bytes] = capture;
  final name = syncObjectName(bytes);
  _fileNames['$capture/$traineeIconFileName'] = name;
  _capturesByName[name] = capture;
  _filesByName[name] = (capture, traineeIconFileName);
  return bytes;
});

/// The name a binding gives the file [file] of [capture]'s images: the SHA-256 of its bytes.
String _fileName(String capture, String file) => _fileNames.putIfAbsent('$capture/$file', () {
  final name = syncObjectName(_imageFile(capture, file));
  _capturesByName[name] = capture;
  _filesByName[name] = (capture, file);
  return name;
});

/// [_imageFile], the names of both forms of its image known as of [capture] ([_fileName]): the app's rules hash the
/// files they read — and the JPEG they make of a PNG — and give the hashes back.
Uint8List _namedFile(String capture, String file) {
  final image = file.split('.').first;
  _fileName(capture, '$image.png');
  _fileName(capture, '$image.jpg');
  return _imageFile(capture, file);
}

String _captureOfName(String name) =>
    _capturesByName[name] ?? (throw StateError('No image file of the model is named $name.'));

/// The files of a record directory that holds [images], by name, as the app reads them ([readRecordImageFiles]): the
/// PNG and the reduced JPEG of [modelImage] it holds, the icon where it holds it, and the geometry file of
/// [modelImage] where it holds one.
Map<String, Uint8List> _dirFiles(FImages? images) => {
  if (images case final f?) ...{
    if (f.png) '$modelImage.png': _namedFile(f.capture, '$modelImage.png'),
    if (f.jpeg) '$modelImage.jpg': _namedFile(f.capture, '$modelImage.jpg'),
    if (f.icon) traineeIconFileName: _iconOf(f.capture),
    if (f.geometry case final g?) '$modelImage.json': _geometryFile(g),
  },
};

/// The bytes of the geometry file that holds the rect [symbol] names ([geometryRectOfSymbol]), as the app writes one
/// ([geometryFileBytesOf]), made once.
Uint8List _geometryFile(String symbol) =>
    _geometryFiles.putIfAbsent(symbol, () => geometryFileBytesOf(geometryRectOfSymbol(symbol)));
final _geometryFiles = <String, Uint8List>{};

/// The symbol of the rect the geometry file [bytes] holds ([geometrySymbolOf]); `?` where it holds none.
String _geometryIn(Uint8List bytes) => _geometryOfBytes.putIfAbsent(String.fromCharCodes(bytes), () {
  try {
    return geometrySymbolOf(geometryIntersectionOf(jsonDecode(utf8.decode(bytes)))) ?? '?';
  } on FormatException {
    return '?';
  }
});
final _geometryOfBytes = <String, String>{};

/// The model's images of a record directory that holds [files] ([_dirFiles] the other way): none where it holds no
/// form of [modelImage]'s, of the capture those are of, the icon where it holds one, the rect its geometry file holds.
FImages? _imagesOfDir(Map<String, Uint8List> files) {
  final (png, jpeg) = (files['$modelImage.png'], files['$modelImage.jpg']);
  final of = png ?? jpeg;
  if (of == null) return null;
  final capture = _captureOfBytes[of] ?? (throw StateError('The model made no image file of these bytes.'));
  return FImages(
    capture,
    png: png != null,
    jpeg: jpeg != null,
    icon: files.containsKey(traineeIconFileName),
    geometry: switch (files['$modelImage.json']) {
      final json? => _geometryIn(json),
      null => null,
    },
  );
}

/// The reduced JPEG the app's archive makes of [png] ([archiveJpegOf]): of a PNG of the model's, made once, and the
/// bytes [_imageFile] holds for it.
Uint8List? _reducedOf(Uint8List png) => switch (_captureOfBytes[png]) {
  final capture? => _namedFile(capture, '$modelImage.jpg'),
  null => archiveJpegOf(png),
};

/// The geometry file [json] beside the PNG [png], as an archive that reduces the PNG rewrites it: its rect rescaled for
/// the reduced JPEG the archive makes ([rescaledIntersection]); as it is where it holds no rect.
Uint8List _rescaledGeometry(Uint8List json, Uint8List png) =>
    _rescaledGeometries.putIfAbsent('${String.fromCharCodes(json)}|${_captureOfBytes[png]}', () {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(json));
      } on FormatException {
        return json;
      }
      final intersection = geometryIntersectionOf(decoded);
      final reduced = archiveJpegConversionOf(png)?.result;
      if (intersection == null || reduced == null) return json;
      final rescaled = rescaledIntersection(intersection, newWidth: reduced.dstWidth, newHeight: reduced.dstHeight);
      return rescaled == null ? json : geometryFileBytesOf(rescaled);
    });
final _rescaledGeometries = <String, Uint8List>{};

/// The images a record holds once a body bound as [binding] with the geometry [geometry] is put on it, which held
/// [own], and the device's records it may take from held [others] — of its own those it keeps, and those it takes —
/// by the app's rule ([recordImagesBound]), the forms taken with the geometry the body carries of each, in the
/// coordinates of the form it holds ([recordGeometryFiles]), as the app's place writes them; each made once for each
/// distinct input.
({FImages? kept, FImages? taken}) _boundImages(
  RecordBinding? binding,
  RecordGeometry? geometry,
  FImages? own,
  List<FImages?> others,
) {
  final (:img, :pngUnknown, boundToNoImage: _) = _placeFields.read(binding);
  final g = recGeometryOf(geometry);
  final key =
      '$img|$pngUnknown|${binding == null}|${geometry == null}|${g?.png}|${g?.jpeg}|${own?.files}|'
      '${others.map((o) => o?.files).join(';')}';
  return _boundImagesOf.putIfAbsent(key, () {
    final files = _dirFiles(own);
    final bound = recordImagesBound((binding: binding, own: files, others: [for (final o in others) _dirFiles(o)]));
    final placed = {
      ...bound.taken,
      ...recordGeometryFiles(geometry, placed: bound.taken.keys, holds: {...bound.kept, ...bound.taken.keys}),
    };
    return (kept: _imagesOfDir({for (final name in bound.kept) name: ?files[name]}), taken: _imagesOfDir(placed));
  });
}

final _boundImagesOf = <String, ({FImages? kept, FImages? taken})>{};

/// The files [images] are, by image, as the app's rules of images read a directory's: those of [modelImage], which
/// stands for the three.
Map<String, RecordImageFiles> _filesOf(FImages? images) => {
  if (images case final f?)
    modelImage: (
      png: f.png ? _namedFile(f.capture, '$modelImage.png') : null,
      jpeg: f.jpeg ? _namedFile(f.capture, '$modelImage.jpg') : null,
    ),
};

// The app's rules of images are pure, and a decode and an encode of each PNG is the cost of every call: each is called
// once for each distinct input, and its answer kept for every world.

/// The binding, with the geometry and the icon, the app works out of a directory that holds [images]
/// ([recordBodyImagesOf]; [R4-9]), as the model's.
({String? img, bool pngUnknown, bool boundToNoImage, FGeometry geometry, String? icon}) _bodyImagesOfFiles(
  FImages? images,
) => _bodyImagesOf.putIfAbsent(images, () {
  final (:binding, :geometry, :icon) = recordBodyImagesOf(_dirFiles(images));
  final (:img, :pngUnknown, :boundToNoImage) = recBindingOf(binding, _captureOfName);
  return (
    img: img,
    pngUnknown: pngUnknown,
    boundToNoImage: boundToNoImage,
    geometry: recGeometryOf(geometry)!,
    icon: _placeFields.readIcon(icon),
  );
});
final _bodyImagesOf =
    <FImages?, ({String? img, bool pngUnknown, bool boundToNoImage, FGeometry geometry, String? icon})>{};

/// The bindings of the place: the files named by the SHA-256 of their bytes.
final _placeFields = BindingFields(_fileName, _captureOfName);

/// [_namedBy] of a binding, by the model's reading of it ([BindingFields.read]) and whether it is worked out, and of the
/// files.
final _namedFiles = <(String?, bool, bool, FImages), FImages?>{};

/// Of [images], the files [binding] names ([imagesBoundBy]) — the icon with the factor image —, or null where it names
/// none.
FImages? _namedBy(RecordBinding? binding, FImages? images) {
  if (images == null) return null;
  final (:img, :pngUnknown, boundToNoImage: _) = _placeFields.read(binding);
  return _namedFiles.putIfAbsent((img, pngUnknown, binding == null, images), () => _namedNow(binding, images));
}

FImages? _namedNow(RecordBinding? binding, FImages images) {
  final named = imagesBoundBy(binding, _filesOf(images));
  final (png, jpeg) = (named.contains('$modelImage.png'), named.contains('$modelImage.jpg'));
  return png || jpeg
      ? FImages(images.capture, png: png, jpeg: jpeg, icon: images.icon, geometry: images.geometry)
      : null;
}

/// The files of [top] written over those of [under]: a form either holds, the icon of either, and the geometry file of
/// [top], else of [under] — [top]'s alone where it is of another capture (the files of [under] it names the same are
/// gone; one of another name left beside them would mix two captures, which the model does not hold).
FImages? _laidOver(FImages? under, FImages? top) {
  if (under == null || top == null) return top ?? under;
  if (under.capture != top.capture) return top;
  return FImages(
    top.capture,
    png: top.png || under.png,
    jpeg: top.jpeg || under.jpeg,
    icon: top.icon || under.icon,
    geometry: top.geometry ?? under.geometry,
  );
}

/// The body of [r] ([syncBodyBytes]): the same text on every device that holds the same body.
String _bodyText(FRec r) => jsonEncode({
  'id': r.id,
  'content': r.body,
  'captured': r.captured,
  'binding': switch (_placeFields.of(r)) {
    null => null,
    RecordBinding(factorPng: final png?) => png,
    RecordBinding(factorJpeg: final jpeg?) => 'jpeg $jpeg',
    _ => '',
  },
  'geometry': ?switch (r.geometry) {
    (:final png, :final jpeg)? => '$png|$jpeg',
    null => null,
  },
  'icon': ?r.icon,
  'parents': {for (final slot in parentSlots) slot: ?r.parents[slot]},
  'written_at': r.bodyTime,
});

String _bodyNameOf(FRec r) => _bodyNames.putIfAbsent(_bodyText(r), () => syncObjectName(utf8.encode(_bodyText(r))));

/// The name the app's endpoints hold [r]'s body under: the SHA-256 of the record.json a round of the app's sends of it
/// ([_FilePlace.bodyOf]).
String syncBodyNameOf(FRec r) => _bodyNameOf(r);

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
    binding: _placeFields.of(r),
    geometry: recordGeometryOfRec(r.geometry),
    icon: _placeFields.iconOf(r),
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
  final binding = _placeFields.read(r.body.binding);
  return FRec(
    r.id,
    captured: captured,
    recognisedFrom: content.substring(0, at),
    r: int.parse(content.substring(at + 1)),
    bodyTime: r.body.time,
    img: binding.img,
    pngUnknown: binding.pngUnknown,
    boundToNoImage: binding.boundToNoImage,
    geometry: recGeometryOf(r.body.geometry),
    icon: _placeFields.readIcon(r.body.icon),
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
/// image files.
typedef _Carried = ({FRec record, FImages? image});

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
  Future<SyncKeptImages?> readKeptImages() async => d.keptImages;

  /// As the app's, through the bytes it writes and reads back.
  @override
  Future<void> keepImages(SyncKeptImages? images) async =>
      d.keptImages = images == null ? null : _keptImagesOfBytes(images.toBytes());

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
    return (record: r.copy(), image: d.carriesNoFiles ? null : d.images[id]);
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
    // The directory of the record as the round read it, and the files a record split off carries, which go with it
    // whatever its body's source. Where the record keeps the body the device's held ([SyncPublication.imageSources]
    // null), its own files stay as they are; else it keeps those of its own the binding names and lets go of the rest,
    // and where it keeps no form of the images it takes the named ones of the first source that holds any — the icon
    // with the factor image (`recordImagesBoundBy`).
    final own = asRead == null ? null : d.images[id];
    final carried = splitFrom?.carried.image;
    final FImages? image;
    if (sources == null) {
      image = _laidOver(own, carried);
    } else {
      final (:kept, :taken) = _boundImages(r.body.binding, r.body.geometry, own, others);
      image = _laidOver(_laidOver(kept, carried), taken);
    }
    d.store.records[id] = placed;
    image == null ? d.images.remove(id) : d.images[id] = image;
    // Once it commits, a record archived is shaped to the form its stage holds the images in (`afterCommit`).
    d._shape(id);
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

  @override
  Future<SyncRecordImages?> imagesOf(SyncRecord listed) async {
    if (!_heldAsListed(listed)) return null;
    final images = d.images[listed.id];
    final named = _namedBy(listed.body.binding, images);
    // As the app's: the icon the directory holds is the record's, whatever its name ([R4-8] 6).
    return (
      files: _dirFiles(images),
      bound: {
        if (named?.png ?? false) '$modelImage.png',
        if (named?.jpeg ?? false) '$modelImage.jpg',
        if (images?.icon ?? false) traineeIconFileName,
      },
    );
  }

  /// As the app's: the names of the files [_dirFiles] holds, none of them made.
  @override
  Future<Set<String>> imageFileNamesOf(SyncRecord listed) async => {
    if (d.images[listed.id] case final f?) ...{
      if (f.png) '$modelImage.png',
      if (f.jpeg) '$modelImage.jpg',
      if (f.icon) traineeIconFileName,
      if (f.geometry != null) '$modelImage.json',
    },
  };

  /// As the app's: the files over those the directory holds, with the geometry of each form placed in the coordinates
  /// of the form the directory then holds ([recordGeometryFiles]) and that of each form it holds without one
  /// ([recordGeometryLacking]), and once that lands, shaped for the record's stage (`afterCommit`). A write of the
  /// round's, as a publication is ([_lands]).
  @override
  Future<bool> placeImages(SyncRecord listed, Map<String, Uint8List> files) async {
    if (!_heldAsListed(listed)) return false;
    if (!_lands()) return false;
    final id = listed.id;
    final under = d.images[id];
    final holds = {..._dirFiles(under).keys, ...files.keys};
    final geometry = listed.body.geometry;
    final placed = {
      ...files,
      ...recordGeometryFiles(geometry, placed: files.keys, holds: holds),
      ...recordGeometryLacking(geometry, holds),
    };
    // Files that hold no form of the images — the icon alone — go beside the forms the directory holds; beside none,
    // the directory would hold an icon without its images, which is outside the model.
    final top = _imagesOfDir(placed);
    switch (top == null
        ? (under == null ? null : _imagesOfDir({..._dirFiles(under), ...placed}))
        : _laidOver(under, top)) {
      case final image?:
        d.images[id] = image;
      case null:
        d.images.remove(id);
    }
    d._shape(id);
    return true;
  }

  /// Whether the device holds the record [listed] names as [listed] has it, in the store of its stage.
  bool _heldAsListed(SyncRecord listed) => switch (d.store.records[listed.id]) {
    final r? => syncRecordsAgree(listed, _syncRecordOf(r)),
    null => false,
  };
}

/// [s] as the sync endpoints, for the device [device]'s round. The server answers what the Worker answers
/// (`docs/sync-protocol.md`), in the order the app's fake of it does: a root that names an object the server lacks,
/// then a stale generation, then the limits [FServer.slotsPerSwap] and [FServer.operationsPerSwap] — and before them
/// all, as the Worker does, the database's room ([_admitWrite]). [cut]: the swap
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

  bool _holdsBody(String name) => s.holdsBody(name);

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

  /// As the Worker: a body whose name the account holds is there already, whatever the room; a request that puts one it
  /// does not hold needs room for new bytes ([_admitNewBytes]), and refused, it stores nothing.
  @override
  Future<void> putBodies(List<({String name, String body})> bodies) async {
    for (final b in bodies) {
      if (b.name != syncObjectName(utf8.encode(b.body))) _refuse(const SyncRefusal(400, 'invalid_payload', 'name'));
    }
    if (bodies.any((b) => !_holdsBody(b.name))) _admitNewBytes();
    for (final b in bodies) {
      s.syncObjects[b.name] = b.body;
      if (s.putBody(device, _contentIn(b.body)) != FAnswer.stored) throw StateError('$device: a body was not stored');
    }
  }

  /// The room a put of new bytes — a body or an image the account does not hold — needs, as the Worker checks it
  /// (`docs/sync-protocol.md`): the account's cap ([FServer.full]), then the database's room past the reserve
  /// ([FServer.database]).
  void _admitNewBytes() {
    _refusedForRoom |= s.full || s.database != DatabaseRoom.room;
    if (s.full) _refuse(const SyncRefusal(507, 'account_limit', 'bytes'));
    if (s.database != DatabaseRoom.room) _refuse(const SyncRefusal(507, 'database_full'));
  }

  /// Whether a put of new bytes was refused for room in this round ([FServer.roomRefusalEndsTheRound]).
  var _refusedForRoom = false;

  /// The room a write that stores a part or replaces the root needs: the database's, the reserve included. The account's
  /// cap weighs no part ([SetStorageFull]).
  void _admitWrite() {
    if (s.database == DatabaseRoom.none || (s.roomRefusalEndsTheRound && _refusedForRoom)) {
      _refuse(const SyncRefusal(507, 'database_full'));
    }
  }

  /// A part the server holds is there already; a new one needs the database's room ([_admitWrite]).
  @override
  Future<void> putPart(String name, String text) async {
    if (s.syncObjects.containsKey(name)) return;
    _admitWrite();
    s.syncObjects[name] = text;
  }

  @override
  Future<String> imageForm() async => s.imageForm;

  /// A device of the model sets the form between rounds ([SetImageForm]), never through a round's endpoints.
  @override
  Future<void> putImageForm(String form) async => s.imageForm = form;

  @override
  Future<Set<String>> held(List<String> names) async => {
    for (final name in names)
      if (_serverImageOf(name) case final image? when s.images.contains(image)) name,
  };

  /// As the Worker: bytes that do not hash to the name are refused as the bucket refuses them, an image the server
  /// holds is there already, and under the form `none` a new one is refused but the reduced JPEG an archive puts in
  /// place of a PNG the server holds, which a row of its list archived with resized images names with it; a new one
  /// that is taken needs room for new bytes ([_admitNewBytes]). What the app's round does not keep to — the day's rows,
  /// and the room where the world does not run it without that ([FDevice.appRoundLacking]) — refuses the world before
  /// the round runs ([OfTheModelsRound]); the server stores the image as a put of the model's round does
  /// ([FServer.putImage]).
  @override
  Future<void> putImage(String name, Uint8List bytes, {required bool jpeg}) async {
    if (syncObjectName(bytes) != name) throw const SyncRefusal(502, 'storage_refused');
    final image = _serverImageOf(name) ?? (throw StateError('$device: no image of the model is named $name'));
    if (s.images.contains(image)) return;
    if (s.imageForm == 'none' && !(jpeg && _replacements().contains(name))) {
      throw const SyncRefusal(409, 'images_not_synced');
    }
    _admitNewBytes();
    if (s._put(device, s.images, 'i:', image) != FAnswer.stored) throw StateError('$device: an image was not stored');
  }

  @override
  Future<Uint8List?> image(String name) async {
    final image = _serverImageOf(name);
    if (image == null || !s.images.contains(image) || !_referenced().contains(name)) return null;
    final (capture, file) = _filesByName[name]!;
    return _imageFile(capture, file);
  }

  /// The server's name of the image file [name] names, as [RunStep.serverImages] holds it: its capture for the PNG,
  /// `<capture>.jpg` for the reduced JPEG, `<capture>.icon` for the icon; null where no image file of the model is so
  /// named.
  static String? _serverImageOf(String name) => switch (_filesByName[name]) {
    (final capture, traineeIconFileName) => '$capture.icon',
    (final capture, final file) => file.endsWith('.png') ? capture : '$capture.jpg',
    null => null,
  };

  /// Of each row of the server's list, the PNG and reduced JPEG names of each image its binding names, and its state.
  Iterable<({ArchiveImageOption? stage, String? png, String? jpeg})> _rowImages() sync* {
    for (final row in s.syncList.rows.values) {
      final binding = row.record.body.binding;
      if (binding == null) continue;
      for (final (:png, :jpeg) in recordBindingFields(binding).values) {
        yield (stage: row.record.stage.value, png: png, jpeg: jpeg);
      }
    }
  }

  bool _holds(String name) => switch (_serverImageOf(name)) {
    final image? => s.images.contains(image),
    null => false,
  };

  /// What the server's list references of images (`docs/sync-protocol.md`): every image a normal row names; of a row
  /// archived with resized images, each image's JPEG, and its PNG only while the server holds no JPEG of it; and the
  /// icon each of those rows names; none of a row archived without images.
  Set<String> _referenced() => {
    for (final (:stage, :png, :jpeg) in _rowImages())
      ...switch (stage) {
        null => [?png, ?jpeg],
        ArchiveImageOption.resizedJpeg => [?jpeg, if (jpeg == null || !_holds(jpeg)) ?png],
        ArchiveImageOption.none => const <String>[],
      },
    for (final row in s.syncList.rows.values)
      if (row.record.stage.value != ArchiveImageOption.none) ?row.record.body.icon,
  };

  /// The reduced JPEGs the server takes under the form `none`: of each row archived with resized images, the JPEG of
  /// an image whose PNG it holds.
  Set<String> _replacements() => {
    for (final (:stage, :png, :jpeg) in _rowImages())
      if (stage == ArchiveImageOption.resizedJpeg && png != null && _holds(png)) ?jpeg,
  };

  @override
  Future<int> replaceRoot(int generation, String name, String text) async {
    s.beforeSwap?.call(device);
    if (cut case SwapCut(stored: false, :final answered) when _calls++ == answered) throw dropped;
    // As the Worker, the database's room before anything of the root is read.
    _admitWrite();
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
