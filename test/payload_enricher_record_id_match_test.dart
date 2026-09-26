// The addon record lookup must not answer with a record other than the one asked for.
//
// `resolveRecordById` reads `active/<id>/record.json` directly when the in-memory store cannot
// answer, and decoded it without ever checking that the decoded `record_id.self` is the `<id>` the
// directory is named after. The canonical loader does check -- mutation authority is derived from
// the directory leaf -- so the two readers of the same file disagreed about which record it is.
// A directory whose contents name a different record therefore answered a lookup for this one, and
// that record's body reached a webhook or a `{record_json}` placeholder.
//
// Skipping the loader's quarantine side effect is what this path wants; skipping its identity check
// was not part of that, and is what this pins.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/payload_enricher_record_id_match_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/addon/payload_enricher.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/riverpod.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  late String fixtureJson;
  late String fixtureId;
  late Directory tempDir;

  setUpAll(() {
    fixtureJson = File('test/fixtures/chara_detail_record.json').readAsStringSync();
    fixtureId = CharaDetailRecordMapper.fromJson(fixtureJson).id;
  });

  setUp(() => tempDir = Directory.systemTemp.createTempSync('umacapture_enricher_id'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  RefBase newRef() {
    final dir = DirectoryPath(tempDir.path);
    final container = ProviderContainer.test(
      overrides: [
        pathInfoProvider.overrideWithValue(
          PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container.read(refBaseProvider);
  }

  // Writes [json] into `active/<directoryName>/record.json` with dart:io directly, so the seeding
  // never goes through the code under test. [directoryName] is deliberately separable from whatever
  // id the json claims -- that divergence is the whole subject here.
  void seed(String directoryName, String json) {
    final dir = Directory('${tempDir.path}/storage/chara_detail/active/$directoryName')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(json);
  }

  test('refuses a directory whose record.json claims a different id', () {
    // The fixture's own id is `fixtureId`; the directory is named something else.
    seed('imposter-id', fixtureJson);
    expect(resolveRecordById(newRef(), 'imposter-id'), isNull);
  });

  test('does not put the wrong record into an enriched payload', () {
    seed('imposter-id', fixtureJson);
    final ref = newRef();
    final result = enrichPayload(ref, {'event': 'record_captured', 'record_id': 'imposter-id'});

    // The install-constant placeholder is still there; the record ones are not, and in particular
    // no `{record_json}` carrying the other record's body.
    expect(result['modules_dir'], ref.read(pathInfoProvider).modulesDir.path);
    expect(result.containsKey('record_json'), isFalse);
    expect(result.containsKey('record_dir'), isFalse);
    expect(result.containsKey('_enriched'), isFalse);
  });

  // Negative control: the check refuses a mismatch, not every disk read.
  test('still resolves a directory whose record.json claims its own id', () {
    seed(fixtureId, fixtureJson);
    expect(resolveRecordById(newRef(), fixtureId)?.id, fixtureId);
  });

  test('still fills an enriched payload for a matching record', () {
    seed(fixtureId, fixtureJson);
    final result = enrichPayload(newRef(), {'event': 'record_captured', 'record_id': fixtureId});

    expect(result['record_dir'], endsWith(fixtureId));
    expect(result['_enriched'], '1');
  });
}
