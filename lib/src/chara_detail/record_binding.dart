// Working out a record's binding (`metadata.binding`) from the images in its directory, for a record whose body
// carries none: one captured before the binding, or one captured since and not yet at a point that needs it. A capture
// writes no binding; each operation that lets go of an image, or carries the record somewhere else, works it out
// first and places it (`placeOnRecord`), so the value is the one a capture would have written. And the other way: the
// images a record holds once a body is put on it that is not the one it had, which a zip import and a sync round work
// out alike ([recordImagesBoundBy]).

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/image_converter.dart';
import '/src/chara_detail/record_body.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';

/// The three images a binding names, by the stem of their file names (`skill.png`, `skill.jpg`, …).
const recordBindingImages = ['skill', 'factor', 'campaign'];

/// The bytes of one image's two forms in a record directory, each null where the file is absent.
typedef RecordImageFiles = ({Uint8List? png, Uint8List? jpeg});

/// The binding of the images in [directory].
///
/// For each image: with its PNG, the PNG's hash and the hash of the reduced JPEG an archive would make of it (the
/// JPEG field stays unknown where the PNG cannot be decoded); with only its reduced JPEG, that JPEG's hash and an
/// unknown PNG; with neither, both unknown. The pixel work runs off the UI isolate where the platform has one
/// (`compute`). Web has none, and there the work is one image at a time: the UI isolate is given back between images,
/// the unit of pixel work that cannot be cut.
Future<RecordBinding> computeRecordBinding(DirectoryPath directory) async {
  final hashes = <String, ({String? png, String? jpeg})>{};
  for (final image in recordBindingImages) {
    final files = (
      png: await _readIfPresent(directory.filePath('$image.png')),
      jpeg: await _readIfPresent(directory.filePath('$image.jpg')),
    );
    hashes[image] = await compute(_hashesOf, files);
  }
  return _bindingOf(hashes);
}

/// The binding of [files], keyed by [recordBindingImages]; see [computeRecordBinding]. Pure.
RecordBinding recordBindingOf(Map<String, RecordImageFiles> files) =>
    _bindingOf({for (final image in recordBindingImages) image: _hashesOf(files[image])});

/// The hashes of one image's two forms in a binding, from its files [f]; see [computeRecordBinding].
({String? png, String? jpeg}) _hashesOf(RecordImageFiles? f) {
  final png = f?.png;
  if (png != null) {
    final jpeg = archiveJpegOf(png);
    return (png: _hash(png), jpeg: jpeg == null ? null : _hash(jpeg));
  }
  final jpeg = f?.jpeg;
  return (png: null, jpeg: jpeg == null ? null : _hash(jpeg));
}

RecordBinding _bindingOf(Map<String, ({String? png, String? jpeg})> hashes) {
  ({String? png, String? jpeg}) of(String image) => hashes[image] ?? (png: null, jpeg: null);
  final skill = of('skill');
  final factor = of('factor');
  final campaign = of('campaign');
  return RecordBinding(
    skillPng: skill.png,
    skillJpeg: skill.jpeg,
    factorPng: factor.png,
    factorJpeg: factor.jpeg,
    campaignPng: campaign.png,
    campaignJpeg: campaign.jpeg,
  );
}

/// Whether [name] is one of a record's images or what goes with one: `<image>.png`, `<image>.jpg` and the image's
/// geometry `<image>.json` of [recordBindingImages], and `trainee.jpg`, cut from the factor image.
bool isRecordImageFile(String name) =>
    name == traineeIconFileName ||
    recordBindingImages.any((image) => name == '$image.png' || name == '$image.jpg' || name == '$image.json');

/// The files of the record directory [directory] that [isRecordImageFile] names, by name.
Future<Map<String, Uint8List>> readRecordImageFiles(DirectoryPath directory) async => {
  await for (final entry in directory.list())
    if (entry is FilePath && isRecordImageFile(entry.name)) entry.name: await entry.readAsBytes(),
};

/// What a record directory holding [own] — its files [readRecordImageFiles] reads — holds of images once its body is
/// one [binding] binds ([R4-8] 5): [RecordImagesBound.kept] of its own, and [RecordImagesBound.taken] from [others],
/// the files of other record directories in the order they are looked in. Worked out off the UI isolate where the
/// platform has one.
///
/// Of its own, a record keeps each form of an image [binding] names ([imagesBoundBy]), with the image's geometry, and
/// `trainee.jpg` where it keeps the factor image; it lets go of every other. Of an image [binding] knows and the record
/// keeps no form of, it takes the forms [binding] names from the first of [others] that holds one, with the geometry
/// and, for the factor image, the `trainee.jpg` that one holds. An image no directory holds a named form of is none.
Future<RecordImagesBound> recordImagesBoundBy(
  RecordBinding? binding,
  Map<String, Uint8List> own, [
  List<Map<String, Uint8List>> others = const [],
]) => compute(_recordImagesBoundBy, (binding: binding, own: own, others: others));

/// The images a record keeps and takes ([recordImagesBoundBy]).
typedef RecordImagesBound = ({Set<String> kept, Map<String, Uint8List> taken});

RecordImagesBound _recordImagesBoundBy(
  ({RecordBinding? binding, Map<String, Uint8List> own, List<Map<String, Uint8List>> others}) input,
) {
  Map<String, RecordImageFiles> formsOf(Map<String, Uint8List> files) => {
    for (final image in recordBindingImages) image: (png: files['$image.png'], jpeg: files['$image.jpg']),
  };
  Set<String> withWhatGoes(Set<String> bound, Map<String, Uint8List> files) => {
    ...bound,
    for (final image in recordBindingImages)
      if ((bound.contains('$image.png') || bound.contains('$image.jpg')) && files.containsKey('$image.json'))
        '$image.json',
    if ((bound.contains('factor.png') || bound.contains('factor.jpg')) && files.containsKey(traineeIconFileName))
      traineeIconFileName,
  };

  final kept = withWhatGoes(imagesBoundBy(input.binding, formsOf(input.own)), input.own);
  final boundOthers = [for (final files in input.others) (files, imagesBoundBy(input.binding, formsOf(files)))];
  final taken = <String, Uint8List>{};
  for (final image in recordBindingImages) {
    bool holds(Set<String> names) => names.contains('$image.png') || names.contains('$image.jpg');
    if (holds(kept)) continue;
    for (final (files, bound) in boundOthers) {
      if (!holds(bound)) continue;
      final names = withWhatGoes({
        for (final name in bound)
          if (name.startsWith('$image.')) name,
      }, files);
      for (final name in names) {
        if (files[name] case final bytes?) taken[name] = bytes;
      }
      break;
    }
  }
  return (kept: kept, taken: taken);
}

/// The files of [files], keyed by [recordBindingImages], that [binding] names, by file name. Pure.
///
/// A PNG is named where its hash is the binding's PNG field of that image, or — that field not known — where the
/// reduced JPEG an archive would make of it has the hash of the JPEG field. A JPEG is named where its hash is the
/// JPEG field. A field that is not known names nothing, nor does a null [binding].
Set<String> imagesBoundBy(RecordBinding? binding, Map<String, RecordImageFiles> files) {
  if (binding == null) return const {};
  final fields = {
    'skill': (png: binding.skillPng, jpeg: binding.skillJpeg),
    'factor': (png: binding.factorPng, jpeg: binding.factorJpeg),
    'campaign': (png: binding.campaignPng, jpeg: binding.campaignJpeg),
  };
  final named = <String>{};
  for (final image in recordBindingImages) {
    final field = fields[image];
    final f = files[image];
    if (field == null || f == null) continue;
    final png = f.png;
    if (png != null && _pngBound(png, field.png, field.jpeg)) named.add('$image.png');
    final jpeg = f.jpeg;
    if (jpeg != null && field.jpeg != null && _hash(jpeg) == field.jpeg) named.add('$image.jpg');
  }
  return named;
}

bool _pngBound(Uint8List png, String? pngField, String? jpegField) {
  if (pngField != null) return _hash(png) == pngField;
  if (jpegField == null) return false;
  final reduced = archiveJpegOf(png);
  return reduced != null && _hash(reduced) == jpegField;
}

/// Places the binding on the record in [directory] when its `record.json` carries none, worked out from the images
/// there now ([computeRecordBinding]), and returns that record's `record.json` bytes with its binding.
///
/// Called by each operation that is about to let go of the record's images or carry the record elsewhere: the
/// archives, the zip exports and the storage view's image delete. A caller on the main isolate places through
/// `placeRecordBindingsUnlocked` (`storage.dart`), which also puts the record into the store that serves it. A record already carrying a binding is returned as
/// stored and nothing is written. Placing changes no time ([placeOnRecord] leaves the body alone).
///
/// A replacement that cannot happen (a read-only `record.json`, say) is logged and does not stop the caller: the
/// bytes returned still carry the computed binding, so a zip built from them carries it too. Answers null, and
/// writes nothing, where the directory holds no `record.json` this can decode; the caller goes on with the files as
/// they are. The caller holds [directory]'s record lock or the store's root scope.
Future<Uint8List?> placeRecordBindingUnlocked(DirectoryPath directory) async {
  final recordFile = directory.filePath('record.json');
  final CharaDetailRecord stored;
  try {
    if (!await recordFile.exists()) {
      return null;
    }
    stored = CharaDetailRecord.fromRecordJson(await recordFile.readAsString());
    CharaDetailRecord.validateDirectoryId(directory, stored);
  } catch (error, stackTrace) {
    logger.w('No binding placed on ${directory.name}: its record.json could not be read.', error, stackTrace);
    return null;
  }
  if (stored.metadata.binding != null) {
    return stored.toRecordJsonBytes();
  }
  final placed = placeOnRecord(stored, binding: await computeRecordBinding(directory));
  final bytes = placed.toRecordJsonBytes();
  try {
    await CharaDetailRecord.replaceRecordJsonUnlocked(directory, bytes);
  } catch (error, stackTrace) {
    logger.e(
      'The binding worked out for ${directory.name} could not be written to its record.json.',
      error,
      stackTrace,
    );
    // The replacement's staging file would otherwise go out in the record directory the caller is about to archive
    // or pack.
    try {
      await directory.filePath(CharaDetailRecord.recordJsonReplacementName).delete(emptyOk: true);
    } catch (error, stackTrace) {
      logger.w('The staging file of ${directory.name}\'s record.json could not be removed.', error, stackTrace);
    }
  }
  return bytes;
}

/// The record directories the storage view's [target] is or holds: a store (`active/`, `archive/`) holds each of its
/// child directories, and a child directory of a store is one. Anything else — another group's folder, a file —
/// holds none.
Future<List<DirectoryPath>> recordDirectoriesAt(PathInfo info, PathEntity target) async {
  if (await target.isFile()) {
    return const [];
  }
  final directory = target.asDirectoryPath;
  for (final store in [info.charaDetailActiveDir, info.charaDetailArchiveDir]) {
    if (listEquals(directory.segments, store.segments)) {
      return [
        await for (final child in directory.list())
          if (child is DirectoryPath) child,
      ];
    }
    if (listEquals(directory.parent.segments, store.segments)) {
      return [directory];
    }
  }
  return const [];
}

/// Whether the storage view's [target] is one of the images a binding names, in a record directory: a file whose
/// removal lets go of an image the record's body was read from.
bool isRecordBindingImage(PathInfo info, PathEntity target) {
  final name = target.segments.last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || !recordBindingImages.contains(name.substring(0, dot))) {
    return false;
  }
  final extension = name.substring(dot + 1);
  if (extension != 'png' && extension != 'jpg') {
    return false;
  }
  final store = target.parent.parent.segments;
  return listEquals(store, info.charaDetailActiveDir.segments) ||
      listEquals(store, info.charaDetailArchiveDir.segments);
}

String _hash(Uint8List bytes) => sha256.convert(bytes).toString();

Future<Uint8List?> _readIfPresent(FilePath file) async => await file.exists() ? await file.readAsBytes() : null;
