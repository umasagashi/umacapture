// Importing a record another person shared, from its link, as a friend's record.
//
// Shared by web and Windows. The record is read from the sharing server's import endpoint
// (`GET /api/shares/<id>`), which answers the stored posted form and the state of the share's images, and, where the
// share declares images, their bundle (`GET /api/shares/<id>/images`). What this file hands on is the files of one
// record directory; they go into the store through the way every import takes (`RecordZipService.importFiles`).
//
// Nothing is written unless the share is complete: a share that declares no images, or one whose bundle was fetched
// and matches what the import endpoint declared of it. A share whose images are not stored yet, are paused, cannot
// be fetched or do not match is refused whole, so a later try of the same link brings the images with the record.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '/const.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/image_converter.dart';
import '/src/chara_detail/record_binding.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/core/fs/web_record_persistence.dart';

/// Why a link was not imported, before anything reached the store.
enum LinkImportRefusal {
  /// The text is not the link of one shared record on [Const.sharingOrigin].
  notALink,

  /// The server holds no share of that id: it was never made, or it was unshared.
  notFound,

  /// The share was posted before shares carried the icons and the family's ranks, which a record holds.
  oldFormat,

  /// This device made the share.
  ownShare,

  /// The share declares images, and the sharer's device has not sent them yet.
  imagesPending,

  /// The share declares images, and the server has stopped handing images out.
  imagesUnavailable,

  /// The share's images are stored, and they could not be fetched, or did not match what the share declares.
  imagesUnreachable,

  /// The server answered 429 twice, 10 seconds apart.
  busy,

  /// The server could not be reached, or answered something this build cannot read.
  unreachable,
}

/// What reading a link gives: the files of the record to import, or why there are none.
sealed class LinkImportFetch {
  const LinkImportFetch();
}

/// The files of one record directory ([RecordPersistenceFile]s of one record id): `record.json`, and where the share
/// carries images, each image's reduced JPEG, its geometry and the icon.
final class LinkImportFiles extends LinkImportFetch {
  final List<RecordPersistenceFile> files;

  const LinkImportFiles(this.files);
}

final class LinkImportRefused extends LinkImportFetch {
  final LinkImportRefusal reason;

  const LinkImportRefused(this.reason);
}

/// The characters a share's public id is made of, and its length: what the server's routes accept.
final _shareId = RegExp(r'^[0-9a-hjkmnp-tv-z]{10}$');

/// The public id of the shared record [text] links to, or null where [text] is not such a link: `/r/<id>` or
/// `/r/<id>.json` on [Const.sharingOrigin], with any query or fragment. The link of an account's list (`/u/…`), and
/// any other host, is not one: nothing is fetched from anywhere else.
String? sharedRecordIdOf(String text) {
  final uri = Uri.tryParse(text.trim());
  final origin = Uri.parse(Const.sharingOrigin);
  // `origin` throws for a scheme other than http(s) and for an empty host, so those are told apart first.
  if (uri == null || uri.scheme != origin.scheme || uri.host.isEmpty || uri.origin != origin.origin) return null;
  final segments = uri.pathSegments;
  if (segments.length != 2 || segments[0] != 'r') return null;
  final name = segments[1];
  final id = name.endsWith('.json') ? name.substring(0, name.length - '.json'.length) : name;
  return _shareId.hasMatch(id) ? id : null;
}

/// The `captured_date` of a record shared on [sharedOn] (`YYYY-MM-DD`): that day's 00:00:00 with this device's offset
/// from UTC at that moment, in the form the recognizer writes (`%FT%T%z`). The share does not carry when the record
/// was captured, and a time of day it does not have is written as the start of the day the share page shows.
String capturedDateOfSharedDay(String sharedOn) {
  final day = DateTime.parse(sharedOn);
  final offset = DateTime(day.year, day.month, day.day).timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${sharedOn}T00:00:00${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}${two(minutes % 60)}';
}

/// The friend's record type of a shared record of [type]: a share is always another trainer's training.
RecordType? _friendTypeOf(Object? type) => switch (type) {
  'Standard' => RecordType.friendStandard,
  'InheritanceOnly' => RecordType.friendInheritance,
  _ => null,
};

/// Whether [record], a posted form as the import endpoint answers it, carries what shares carry since they carry the
/// icons and the family's ranks: the trainee's icon, and each family member's icon and rank.
bool _carriesIcons(Map<String, Object?> record) {
  bool chara(Object? value) => value is Map && value['icon'] is int && value['rank'] is int;
  final trainee = record['trainee'];
  final family = record['family'];
  if (trainee is! Map || trainee['icon'] is! int || family is! Map) return false;
  for (final parent in ['parent1', 'parent2']) {
    final member = family[parent];
    if (member is! Map || !['self', 'parent1', 'parent2'].every((key) => chara(member[key]))) return false;
  }
  return true;
}

/// The `record.json` of the shared [record] (a posted form as the import endpoint answers it), as a record of this
/// device: a friend's record of an unknown trainer under the new id [recordId], captured on the day it was shared
/// ([capturedDateOfSharedDay]). [withImages] is whether the record comes with its images: where it does not, its
/// binding knows none of them; where it does, the binding is left to be worked out of the images it comes with.
/// Null where the form is not one this build can read.
CharaDetailRecord? sharedRecordOf(
  Map<String, Object?> record, {
  required String recordId,
  required String sharedOn,
  required bool withImages,
}) {
  final type = _friendTypeOf(record['record_type']);
  if (type == null) return null;
  final body = {
    for (final key in const [
      'trainee',
      'evaluation_value',
      'status',
      'aptitudes',
      'skills',
      'factors',
      'support_cards',
      'family',
      'fans',
      'scenario',
      'trained_date',
      'races',
    ])
      key: record[key],
  };
  try {
    return CharaDetailRecordMapper.fromMap({
      ...body,
      'metadata': {
        'format_version': recordFormatVersion,
        'region': record['region'],
        'record_id': {'self': recordId},
        'trainer_id': unknownTrainerId,
        'captured_date': capturedDateOfSharedDay(sharedOn),
        'recognizer_version': record['recognizer_version'],
        'stage': 'active',
        'strategy': record['strategy'],
        'record_type': type.toValue(),
        if (!withImages) 'binding': const <String, Object?>{},
      },
    });
  } catch (_) {
    return null;
  }
}

/// The image files of [bundle], a share's images as the bundle's request answers them, cut by what the import
/// endpoint states of them ([images], the `stored` state): each image's reduced JPEG `<kind>.jpg` with its geometry
/// `<kind>.json`, and the icon `trainee.jpg`. Null where the bundle does not match: its size, its name (its SHA-256),
/// or any part's SHA-256; or where the parts are not the three images in their order, with their geometry, and the
/// icon at most.
Map<String, Uint8List>? sharedImageFilesOf(Map<String, Object?> images, Uint8List bundle) {
  final parts = images['parts'];
  if (images['size'] != bundle.length || parts is! List) return null;
  if (sha256.convert(bundle).toString() != images['name']) return null;
  final kinds = [for (final part in parts) part is Map ? part['kind'] : null];
  if (!(kinds.length == 3 || (kinds.length == 4 && kinds[3] == 'trainee'))) return null;
  for (var i = 0; i < recordBindingImages.length; i++) {
    if (kinds[i] != recordBindingImages[i]) return null;
  }
  final files = <String, Uint8List>{};
  var offset = 0;
  for (final part in parts.cast<Map<Object?, Object?>>()) {
    final size = part['size'];
    if (size is! int || size < 0 || offset + size > bundle.length) return null;
    final bytes = Uint8List.sublistView(bundle, offset, offset + size);
    offset += size;
    if (sha256.convert(bytes).toString() != part['sha256']) return null;
    final kind = part['kind'] as String;
    if (kind == 'trainee') {
      files[traineeIconFileName] = bytes;
      continue;
    }
    final intersection = part['intersection'];
    if (intersection is! Map<String, Object?>) return null;
    files['$kind.jpg'] = bytes;
    files['$kind.json'] = geometryFileBytesOf(intersection);
  }
  return offset == bundle.length ? files : null;
}

/// Reads the shared record [shareId] from the sharing server through [dio], as the files of a new record directory
/// ([LinkImportFiles]), or why it is not imported ([LinkImportRefused]). Writes nothing.
///
/// [ownShareIds] are the ids of the shares this device made: such a share is refused. A request answered 429 is sent
/// once more after [retryDelay]. [timeout] bounds the import endpoint's request and [imagesTimeout] the bundle's.
Future<LinkImportFetch> fetchSharedRecord(
  Dio dio,
  String shareId, {
  required Iterable<String> ownShareIds,
  required Duration retryDelay,
  required Duration timeout,
  required Duration imagesTimeout,
}) async {
  if (ownShareIds.contains(shareId)) return const LinkImportRefused(LinkImportRefusal.ownShare);
  final ShareAnswer answer;
  try {
    answer = await _retryingOnce(
      () => sendShareRequest(dio, 'GET', '/api/shares/$shareId', timeout: timeout),
      (answer) => answer.status,
      retryDelay,
    );
  } on DioException {
    return const LinkImportRefused(LinkImportRefusal.unreachable);
  }
  final body = answer.body;
  switch (answer.status) {
    case 200 when body != null:
      break;
    case 404:
      return const LinkImportRefused(LinkImportRefusal.notFound);
    case 429:
      return const LinkImportRefused(LinkImportRefusal.busy);
    default:
      return const LinkImportRefused(LinkImportRefusal.unreachable);
  }
  final record = body['record'];
  final sharedOn = body['shared_on'];
  if (body['schema'] != 1 ||
      body['id'] != shareId ||
      record is! Map<String, Object?> ||
      sharedOn is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(sharedOn)) {
    return const LinkImportRefused(LinkImportRefusal.unreachable);
  }
  if (!_carriesIcons(record)) return const LinkImportRefused(LinkImportRefusal.oldFormat);

  final images = body['images'];
  Map<String, Uint8List> imageFiles = const {};
  switch (images) {
    case null:
      break;
    case {'state': 'pending'}:
      return const LinkImportRefused(LinkImportRefusal.imagesPending);
    case {'state': 'unavailable'}:
      return const LinkImportRefused(LinkImportRefusal.imagesUnavailable);
    case {'state': 'stored'} when images is Map<String, Object?>:
      final ({int status, Uint8List? bytes}) bundle;
      try {
        bundle = await _retryingOnce(
          () => _getBytes(dio, '/api/shares/$shareId/images', timeout: imagesTimeout),
          (answer) => answer.status,
          retryDelay,
        );
      } on DioException {
        return const LinkImportRefused(LinkImportRefusal.imagesUnreachable);
      }
      if (bundle.status == 429) return const LinkImportRefused(LinkImportRefusal.busy);
      final bytes = bundle.bytes;
      final files = bundle.status == 200 && bytes != null ? sharedImageFilesOf(images, bytes) : null;
      if (files == null) return const LinkImportRefused(LinkImportRefusal.imagesUnreachable);
      imageFiles = files;
    default:
      return const LinkImportRefused(LinkImportRefusal.unreachable);
  }

  final recordId = const Uuid().v4();
  final imported = sharedRecordOf(record, recordId: recordId, sharedOn: sharedOn, withImages: imageFiles.isNotEmpty);
  if (imported == null) return const LinkImportRefused(LinkImportRefusal.unreachable);
  return LinkImportFiles([
    (recordId: recordId, relativeSegments: const ['record.json'], bytes: imported.toRecordJsonBytes()),
    for (final MapEntry(key: name, value: bytes) in imageFiles.entries)
      (recordId: recordId, relativeSegments: [name], bytes: bytes),
  ]);
}

/// [send], sent once more after [delay] where its answer's status ([statusOf]) is 429: the WAF's window on `/api/`.
Future<T> _retryingOnce<T>(Future<T> Function() send, int Function(T) statusOf, Duration delay) async {
  final first = await send();
  if (statusOf(first) != 429) return first;
  await Future<void>.delayed(delay);
  return send();
}

/// A GET of [path] on [Const.sharingOrigin] whose answer is bytes, bounded by [timeout] as [sendShareRequest] bounds
/// its requests. A transport failure, and a request still unanswered at [timeout], are thrown as [DioException].
Future<({int status, Uint8List? bytes})> _getBytes(Dio dio, String path, {required Duration timeout}) async {
  final cancel = CancelToken();
  final deadline = Timer(timeout, cancel.cancel);
  try {
    final response = await dio.get<List<int>>(
      '${Const.sharingOrigin}$path',
      cancelToken: cancel,
      options: Options(responseType: ResponseType.bytes, validateStatus: (_) => true),
    );
    final data = response.data;
    return (status: response.statusCode ?? 0, bytes: data == null ? null : Uint8List.fromList(data));
  } finally {
    deadline.cancel();
  }
}
