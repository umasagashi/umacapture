// Working out a record's binding (`metadata.binding`) from the images in its directory, with the geometry of those
// images (`metadata.geometry`) and the name of its icon (`metadata.icon`), for a record whose body carries none: one
// captured before the binding, or one captured since and not yet at a point that needs it. A capture writes none of
// the three; each operation that lets go of an image, or carries the record somewhere else, works them out first, the
// three from one reading of the directory, and places them in one write (`placeOnRecord`), so the value is the one a
// capture would have written. And the other way: the
// images a record holds once a body is put on it that is not the one it had, which a zip import and a sync round work
// out alike ([recordImagesBoundBy]).

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'dart:convert';

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

/// The fields of [binding] by the image they are of, keyed by [recordBindingImages]: each image's PNG and reduced JPEG
/// field, null where it is not known.
Map<String, ({String? png, String? jpeg})> recordBindingFields(RecordBinding binding) => {
  'skill': (png: binding.skillPng, jpeg: binding.skillJpeg),
  'factor': (png: binding.factorPng, jpeg: binding.factorJpeg),
  'campaign': (png: binding.campaignPng, jpeg: binding.campaignJpeg),
};

/// The binding, geometry and icon of the images in [directory] ([RecordBodyImages]), worked out together from what the
/// directory holds.
///
/// The binding, for each image: with its PNG, the PNG's hash and the hash of the reduced JPEG an archive would make of
/// it (the JPEG field stays unknown where the PNG cannot be decoded); with only its reduced JPEG, that JPEG's hash and
/// an unknown PNG; with neither, both unknown. The geometry is worked out as [recordBodyImagesOf] states, and the icon
/// the name of the `trainee.jpg` the directory holds ([recordIconName]), none where it holds none. The pixel work runs
/// off the UI isolate where the platform has one (`compute`). Web has none, and there the work is one image at a time:
/// the UI isolate is given back between images, the unit of pixel work that cannot be cut.
Future<({RecordBinding binding, RecordGeometry geometry, String? icon})> computeRecordBodyImages(
  DirectoryPath directory,
) async {
  final images = <String, _ImageFiles>{};
  for (final image in recordBindingImages) {
    final files = (
      png: await _readIfPresent(directory.filePath('$image.png')),
      jpeg: await _readIfPresent(directory.filePath('$image.jpg')),
    );
    images[image] = (
      hashes: await compute(_hashesOf, files),
      png: files.png != null,
      jpeg: files.jpeg != null,
      json: await _readIfPresent(directory.filePath('$image.json')),
    );
  }
  return (
    binding: _bindingOf({for (final MapEntry(:key, :value) in images.entries) key: value.hashes}),
    geometry: _geometryOf(images),
    icon: recordIconName(await _readIfPresent(directory.filePath(traineeIconFileName))),
  );
}

/// The binding, geometry and icon of a record directory holding [files], by name ([readRecordImageFiles]); see
/// [computeRecordBodyImages]. Pure.
///
/// The geometry, for each image: its geometry file `<image>.json` is in the coordinates of the form held beside it —
/// its PNG where the directory holds the PNG (the native pipeline writes it for the PNG, and an archive that reduces
/// the PNG rewrites it for the JPEG as it lets go of the PNG), else its reduced JPEG —, and that form's field is the
/// file's `intersection` ([geometryIntersectionOf]). Where that form is the PNG, the reduced JPEG's field is the rect
/// the archive writes into the file as it reduces that PNG: the PNG's rescaled for the JPEG the archive makes of it
/// ([rescaledIntersection]), not known where the PNG cannot be decoded. Where it is the reduced JPEG, the PNG's field
/// is not known: the rescaling rounds, and does not go back. An image whose file is absent, does not decode or holds
/// no intersection, or that has neither form, knows neither field.
({RecordBinding binding, RecordGeometry geometry, String? icon}) recordBodyImagesOf(Map<String, Uint8List> files) {
  final forms = _formsOf(files);
  final images = {
    for (final image in recordBindingImages)
      image: (
        hashes: _hashesOf(forms[image]),
        png: files.containsKey('$image.png'),
        jpeg: files.containsKey('$image.jpg'),
        json: files['$image.json'],
      ),
  };
  return (
    binding: _bindingOf({for (final MapEntry(:key, :value) in images.entries) key: value.hashes}),
    geometry: _geometryOf(images),
    icon: recordIconName(files[traineeIconFileName]),
  );
}

/// The binding of [files], keyed by [recordBindingImages]; see [computeRecordBodyImages]. Pure.
RecordBinding recordBindingOf(Map<String, RecordImageFiles> files) =>
    _bindingOf({for (final image in recordBindingImages) image: _hashesOf(files[image])});

/// The geometry files `<image>.json` a record directory writes as forms of its images are placed in it from elsewhere
/// — from the server, another record of the device, a zip —: [placed], the image files placed (`<image>.png`,
/// `<image>.jpg` of [recordBindingImages]), where the directory holds the image files [holds] once they are (those
/// included), and its body's geometry is [geometry] (S-11). Pure.
///
/// Of each image a form of which is placed, the file is in the coordinates of the form the directory holds as
/// [recordBodyImagesOf] reads one — its PNG where it holds the PNG, else its reduced JPEG —, and holds that form's
/// field of [geometry] ([geometryFileBytesOf]). None of an image whose field is not known: the body was read from a
/// directory that held no geometry of it, and the directory is left as it is.
Map<String, Uint8List> recordGeometryFiles(
  RecordGeometry? geometry, {
  required Iterable<String> placed,
  required Set<String> holds,
}) {
  if (geometry == null) return const {};
  final fields = {
    'skill': (png: geometry.skillPng, jpeg: geometry.skillJpeg),
    'factor': (png: geometry.factorPng, jpeg: geometry.factorJpeg),
    'campaign': (png: geometry.campaignPng, jpeg: geometry.campaignJpeg),
  };
  return {
    for (final image in recordBindingImages)
      if (placed.contains('$image.png') || placed.contains('$image.jpg'))
        if ((holds.contains('$image.png') ? fields[image]?.png : fields[image]?.jpeg) case final intersection?)
          '$image.json': geometryFileBytesOf(intersection),
  };
}

/// The geometry files ([recordGeometryFiles]) a record directory that holds the image files [holds] lacks, where its
/// body's geometry is [geometry]: of each image it holds a form of and holds no `<image>.json` of, the file of the form
/// it holds, where [geometry] knows that form's field. What a placement writes again, whatever removed it (S-11: a
/// record a device holds has its images' geometry where the body carries it). Pure.
Map<String, Uint8List> recordGeometryLacking(RecordGeometry? geometry, Set<String> holds) => recordGeometryFiles(
  geometry,
  placed: [
    for (final image in recordBindingImages)
      if (!holds.contains('$image.json'))
        for (final form in ['$image.png', '$image.jpg'])
          if (holds.contains(form)) form,
  ],
  holds: holds,
);

/// The hashes of one image's two forms in a binding, with the dimensions of the reduced JPEG an archive makes of its
/// PNG where that is what the JPEG's hash is of ([_hashesOf]).
typedef _ImageHashes = ({String? png, String? jpeg, ({int width, int height})? reduced});

/// Of one image of a record directory: its hashes ([_hashesOf]), whether it holds the PNG and the reduced JPEG, and
/// the geometry file's bytes.
typedef _ImageFiles = ({_ImageHashes hashes, bool png, bool jpeg, Uint8List? json});

RecordGeometry _geometryOf(Map<String, _ImageFiles> files) {
  ({Map<String, dynamic>? png, Map<String, dynamic>? jpeg}) of(String image) {
    final f = files[image];
    final json = f?.json;
    if (f == null || json == null || !(f.png || f.jpeg)) return (png: null, jpeg: null);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(json));
    } on FormatException {
      decoded = null;
    }
    final intersection = geometryIntersectionOf(decoded);
    if (!f.png) return (png: null, jpeg: intersection);
    final reduced = f.hashes.reduced;
    return (
      png: intersection,
      jpeg: intersection == null || reduced == null
          ? null
          : rescaledIntersection(intersection, newWidth: reduced.width, newHeight: reduced.height),
    );
  }

  final skill = of('skill');
  final factor = of('factor');
  final campaign = of('campaign');
  return RecordGeometry(
    skillPng: skill.png,
    skillJpeg: skill.jpeg,
    factorPng: factor.png,
    factorJpeg: factor.jpeg,
    campaignPng: campaign.png,
    campaignJpeg: campaign.jpeg,
  );
}

/// The hashes of one image's two forms in a binding, from its files [f]; see [computeRecordBodyImages].
_ImageHashes _hashesOf(RecordImageFiles? f) {
  final png = f?.png;
  if (png != null) {
    final reduced = archiveJpegConversionOf(png);
    return (
      png: _hash(png),
      jpeg: reduced == null ? null : _hash(reduced.bytes),
      reduced: reduced == null ? null : (width: reduced.result.dstWidth, height: reduced.result.dstHeight),
    );
  }
  final jpeg = f?.jpeg;
  return (png: null, jpeg: jpeg == null ? null : _hash(jpeg), reduced: null);
}

RecordBinding _bindingOf(Map<String, _ImageHashes> hashes) {
  ({String? png, String? jpeg}) of(String image) {
    final h = hashes[image];
    return (png: h?.png, jpeg: h?.jpeg);
  }

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

/// [recordImagesBound], worked out off the UI isolate where the platform has one.
Future<RecordImagesBound> recordImagesBoundBy(
  RecordBinding? binding,
  Map<String, Uint8List> own, [
  List<Map<String, Uint8List>> others = const [],
]) => compute(recordImagesBound, (binding: binding, own: own, others: others));

/// The images a record keeps and takes ([recordImagesBound]).
typedef RecordImagesBound = ({Set<String> kept, Map<String, Uint8List> taken});

/// What a record directory holding `own` — its files [readRecordImageFiles] reads — holds of images once its body is
/// one `binding` binds ([R4-8] 5): [RecordImagesBound.kept] of its own, and [RecordImagesBound.taken] from `others`,
/// the files of other record directories in the order they are looked in. Pure.
///
/// Of its own, a record keeps each form of an image `binding` names ([imagesBoundBy]), with the image's geometry, and
/// `trainee.jpg` where it keeps the factor image; it lets go of every other. Of an image `binding` knows and the record
/// keeps no form of, it takes the forms `binding` names from the first of `others` that holds one, with the geometry
/// and, for the factor image, the `trainee.jpg` that one holds. An image no directory holds a named form of is none.
RecordImagesBound recordImagesBound(
  ({RecordBinding? binding, Map<String, Uint8List> own, List<Map<String, Uint8List>> others}) input,
) {
  Set<String> withWhatGoes(Set<String> bound, Map<String, Uint8List> files) => {
    ...bound,
    for (final image in recordBindingImages)
      if ((bound.contains('$image.png') || bound.contains('$image.jpg')) && files.containsKey('$image.json'))
        '$image.json',
    if ((bound.contains('factor.png') || bound.contains('factor.jpg')) && files.containsKey(traineeIconFileName))
      traineeIconFileName,
  };

  final kept = withWhatGoes(imagesBoundBy(input.binding, _formsOf(input.own)), input.own);
  final boundOthers = [for (final files in input.others) (files, imagesBoundBy(input.binding, _formsOf(files)))];
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

/// The image files of a record directory, its [files] by name ([readRecordImageFiles]), by image.
Map<String, RecordImageFiles> _formsOf(Map<String, Uint8List> files) => {
  for (final image in recordBindingImages) image: (png: files['$image.png'], jpeg: files['$image.jpg']),
};

/// Of the files of a record directory — `files`, by name ([readRecordImageFiles]) — those `binding` names
/// ([imagesBoundBy]), by file name. Pure.
Set<String> recordImageFilesBoundBy(({RecordBinding? binding, Map<String, Uint8List> files}) input) =>
    imagesBoundBy(input.binding, _formsOf(input.files));

/// The files of [files], keyed by [recordBindingImages], that [binding] names, by file name. Pure.
///
/// A PNG is named where its hash is the binding's PNG field of that image, or — that field not known — where the
/// reduced JPEG an archive would make of it has the hash of the JPEG field. A JPEG is named where its hash is the
/// JPEG field. A field that is not known names nothing, nor does a null [binding].
Set<String> imagesBoundBy(RecordBinding? binding, Map<String, RecordImageFiles> files) {
  if (binding == null) return const {};
  final fields = recordBindingFields(binding);
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

/// A record's `record.json` bytes with its binding, as [placeRecordBindingUnlocked] answers them, and whether the
/// `record.json` in its directory holds those bytes: false where the binding was worked out but could not be written.
typedef PlacedRecordJson = ({Uint8List bytes, bool stored});

/// Places the binding on the record in [directory] when its `record.json` carries none, worked out from the images
/// there now with their geometry and the icon ([computeRecordBodyImages]) and placed with them in one write, and returns
/// that record's `record.json` bytes with its binding.
///
/// Called by each operation that is about to let go of the record's images or carry the record elsewhere: the
/// archives, the zip exports and the storage view's image delete. A caller on the main isolate places through
/// `placeRecordBindingsUnlocked` (`storage.dart`), which also puts the record into the store that serves it. A record already carrying a binding is returned as
/// stored and nothing is written. Placing changes no time ([placeOnRecord] leaves the body alone).
///
/// A replacement that cannot happen (a read-only `record.json`, say) is logged and does not stop the caller: the
/// bytes returned still carry the computed binding, so a zip built from them carries it too, and say the file does not
/// hold them ([PlacedRecordJson.stored]), so that no store takes a binding its file lacks. Answers null, and
/// writes nothing, where the directory holds no `record.json` this can decode; the caller goes on with the files as
/// they are. The caller holds [directory]'s record lock or the store's root scope.
Future<PlacedRecordJson?> placeRecordBindingUnlocked(DirectoryPath directory) async {
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
    return (bytes: stored.toRecordJsonBytes(), stored: true);
  }
  final placed = placeOnRecord(stored, images: await computeRecordBodyImages(directory));
  final bytes = placed.toRecordJsonBytes();
  var written = true;
  try {
    await CharaDetailRecord.replaceRecordJsonUnlocked(directory, bytes);
  } catch (error, stackTrace) {
    logger.e(
      'The binding worked out for ${directory.name} could not be written to its record.json.',
      error,
      stackTrace,
    );
    written = false;
    // The replacement's staging file would otherwise go out in the record directory the caller is about to archive
    // or pack.
    try {
      await directory.filePath(CharaDetailRecord.recordJsonReplacementName).delete(emptyOk: true);
    } catch (error, stackTrace) {
      logger.w('The staging file of ${directory.name}\'s record.json could not be removed.', error, stackTrace);
    }
  }
  return (bytes: bytes, stored: written);
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
