// What of a record is its body, and the two ways a record changes: a body write and a placement.
//
// A record's body is what the recognizer read and the recognizer version that read it. A body write is the one
// operation that changes it ([composeBodyWrite]); it happens when a capture or a re-recognition lands. Everything else
// that changes a stored `record.json` either places a value that goes with the body — the inheritance parents, the
// relation bonus — without changing the body ([placeOnRecord]), or merges two records, which decides for itself, or
// imports one ([composeBodyImport]). Whether two records hold the same body is [recognizedContentKey] alone, so a placement can never make a
// record read as changed.
//
// Pure functions over the decoded model, run on any isolate and on both platforms: the desktop store calls them on
// the files the recognizer leaves in the record directory, and the web harvest on the files the worker hands over.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_operation.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/value_write_time.dart';

/// The name of the content of [record]'s body: the SHA-256 of the record serialised as `record.json` is, with every
/// field that is not part of the body left blank.
///
/// The body is the recognised content and the recognizer's metadata (region, trainer id, recognizer version, stage,
/// strategy, record type). It leaves out the record's id and capture date, which belong to the record rather than to
/// what was read; the inheritance parents, the relation bonus, and the binding with the geometry and the icon worked
/// out with it, which are placed on the record ([placeOnRecord]); the time the body was written, which is when the value was written and not the value; and the
/// format version, because the key is taken over the record upgraded to the current format,
/// so two files that differ only in how they spell the same values have one key.
///
/// Every field is named here through the constructors, so a field added to either class does not compile until it is
/// decided whether it belongs to the body.
///
/// Worked out once a record instance ([_contentKeys]): a record is immutable, and every change of one is a new
/// instance, which has no key yet.
String recognizedContentKey(CharaDetailRecord record) => _contentKeys[record] ??= _workOutContentKey(record);

/// The key [recognizedContentKey] worked out of each record instance, held by the instance's identity and gone with
/// it.
final _contentKeys = Expando<String>('recognizedContentKey');

String _workOutContentKey(CharaDetailRecord record) {
  final r = record.upgradeFormat();
  final m = r.metadata;
  final body = CharaDetailRecord(
    Metadata(
      '',
      m.region,
      const RecordId('', null, null),
      m.trainerId,
      '',
      m.recognizerVersion,
      m.stage,
      m.strategy,
      null,
      m.recordType,
      null,
      null,
      null,
      null,
    ),
    r.trainee,
    r.evaluationValue,
    r.status,
    r.aptitudes,
    r.skills,
    r.factors,
    r.supportCards,
    r.family,
    r.fans,
    r.scenario,
    r.trainedDate,
    r.races,
  );
  return sha256.convert(body.toRecordJsonBytes()).toString();
}

/// The body of [record] as sync carries it: the name of its content ([recognizedContentKey]), its binding, geometry
/// and icon, and its inheritance parents, at the time it was written (0 where it carries none).
SyncBody syncBodyOf(CharaDetailRecord record) {
  final m = record.metadata;
  return SyncBody(
    recognizedContentKey(record),
    binding: m.binding,
    geometry: m.geometry,
    icon: m.icon,
    parents: {'parent1': ?m.recordId.parent1, 'parent2': ?m.recordId.parent2},
    time: m.bodyWrittenAt ?? 0,
  );
}

/// The name of a record's icon ([Metadata.icon]) whose `trainee.jpg` holds [bytes]: their SHA-256, as an image's name
/// is. Null where there is no `trainee.jpg` ([bytes] null).
String? recordIconName(Uint8List? bytes) => bytes == null ? null : sha256.convert(bytes).toString();

/// The record to write when the recognizer's result [recognized] lands on the stored record [stored], or null when
/// nothing is to be written. [icon] is the name ([recordIconName]) of the `trainee.jpg` the record directory holds
/// beside the result, null where it holds none.
///
/// Whether and when the body is written is [syncBodyWrite]'s decision, by [valueWriteTime] over the stored body's
/// time, and the record written carries that time as its body's, in the same `record.json` as the body. With no
/// stored record (a capture), the record is [recognized] as the recognizer wrote it. Over a stored record (a
/// re-recognition), the body comes from [recognized] and is written in the current format, and the record's own
/// fields stay the stored record's: its id and capture date, its inheritance parents, its relation bonus, and its
/// binding and geometry — a re-recognition reads the images the stored body was read from, so the binding is the
/// stored one, or still not worked out, and so is where the screen falls on them. The icon is [icon] where the binding
/// is worked out: the recognizer cut it again. A capture writes no binding, geometry or icon: they are worked out
/// together the first time the record needs them ([placeOnRecord]). A result whose content is the stored one
/// ([recognizedContentKey]) and whose icon is the one the stored body names writes nothing, so a re-recognition that
/// read the same leaves the stored `record.json` as it was, its body's time included, whatever has been placed on it;
/// one that read the same but cut the icon into other bytes writes the body, naming the new icon.
CharaDetailRecord? composeBodyWrite(CharaDetailRecord? stored, CharaDetailRecord recognized, {required String? icon}) {
  final r = recognized.upgradeFormat();
  final read = syncBodyOf(r);
  final body = syncBodyWrite(
    (value: stored == null ? null : syncBodyOf(stored), time: stored?.metadata.bodyWrittenAt),
    SyncBody(
      read.content,
      binding: read.binding,
      geometry: read.geometry,
      icon: icon,
      parents: read.parents,
      time: read.time,
    ),
    writeAt: valueWriteTime,
  );
  if (body == null) return null;
  final m = r.metadata;
  final own = (stored ?? r).metadata;
  return CharaDetailRecord(
    Metadata(
      m.formatVersion,
      m.region,
      RecordId(own.recordId.self, body.parents['parent1'], body.parents['parent2']),
      m.trainerId,
      own.capturedDate,
      m.recognizerVersion,
      m.stage,
      m.strategy,
      own.relationBonus,
      m.recordType,
      body.binding,
      body.geometry,
      body.icon,
      body.time,
    ),
    r.trainee,
    r.evaluationValue,
    r.status,
    r.aptitudes,
    r.skills,
    r.factors,
    r.supportCards,
    r.family,
    r.fans,
    r.scenario,
    r.trainedDate,
    r.races,
  );
}

/// The record an import writes when the record [imported] arrives over the record the device holds [stored] (null
/// where it holds none, or holds one it cannot read), its body the one [syncImport] decided on, [body], written where
/// [writes].
///
/// Where the body is not written, the stored record stays, its body's time included, with [body]'s parents, and its
/// binding, geometry and icon, placed on it. Else the body is the imported one, with [body]'s parents, binding,
/// geometry, icon and time, in the current format.
/// Either way the record keeps what only this device holds: the stored record's relation bonus, none where there is no
/// stored record. Nothing the import carries of a time or a relation bonus is read.
CharaDetailRecord composeBodyImport(
  CharaDetailRecord? stored,
  CharaDetailRecord imported, {
  required SyncBody body,
  required bool writes,
}) {
  final parents = (parent1: body.parents['parent1'], parent2: body.parents['parent2']);
  if (!writes) {
    final held = stored ?? (throw ArgumentError('An import keeps the body of a record the device holds.'));
    return placeOnRecord(
      held,
      parents: parents,
      images: (binding: body.binding, geometry: body.geometry, icon: body.icon),
    );
  }
  final i = imported.upgradeFormat();
  final m = i.metadata;
  return CharaDetailRecord(
    Metadata(
      m.formatVersion,
      m.region,
      RecordId(m.recordId.self, parents.parent1, parents.parent2),
      m.trainerId,
      m.capturedDate,
      m.recognizerVersion,
      m.stage,
      m.strategy,
      stored?.metadata.relationBonus,
      m.recordType,
      body.binding,
      body.geometry,
      body.icon,
      body.time,
    ),
    i.trainee,
    i.evaluationValue,
    i.status,
    i.aptitudes,
    i.skills,
    i.factors,
    i.supportCards,
    i.family,
    i.fans,
    i.scenario,
    i.trainedDate,
    i.races,
  );
}

/// A record's two inheritance parent slots.
typedef RecordParents = ({String? parent1, String? parent2});

/// What a record's body carries of the images it was read from: which they are ([Metadata.binding]), where the game
/// screen falls on each ([Metadata.geometry]) and the name of the icon cut from the factor image ([Metadata.icon]).
/// One value, because the three are worked out together, from one directory's files, and placed in one write
/// ([R4-9]): a record whose binding is worked out holds the geometry and the icon worked out with it.
typedef RecordBodyImages = ({RecordBinding? binding, RecordGeometry? geometry, String? icon});

/// [record] with the given values placed on it, and its body untouched.
///
/// [parents] replaces both parent slots, [relationBonus] the relation bonus (its `value` may be null, which clears
/// it), and [images] the binding, geometry and icon, the three together; a value left out stays as it is. The body
/// and its time are not among the parameters, so nothing placed through here can change [recognizedContentKey] or
/// move the body's time.
CharaDetailRecord placeOnRecord(
  CharaDetailRecord record, {
  RecordParents? parents,
  ({int? value})? relationBonus,
  RecordBodyImages? images,
}) {
  final m = record.metadata;
  return CharaDetailRecord(
    Metadata(
      m.formatVersion,
      m.region,
      parents == null ? m.recordId : RecordId(m.recordId.self, parents.parent1, parents.parent2),
      m.trainerId,
      m.capturedDate,
      m.recognizerVersion,
      m.stage,
      m.strategy,
      relationBonus == null ? m.relationBonus : relationBonus.value,
      m.recordType,
      images == null ? m.binding : images.binding,
      images == null ? m.geometry : images.geometry,
      images == null ? m.icon : images.icon,
      m.bodyWrittenAt,
    ),
    record.trainee,
    record.evaluationValue,
    record.status,
    record.aptitudes,
    record.skills,
    record.factors,
    record.supportCards,
    record.family,
    record.fans,
    record.scenario,
    record.trainedDate,
    record.races,
  );
}
