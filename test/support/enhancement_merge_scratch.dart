// The scratch-store fixture the on-disk enhancement-merge suites share: a
// `PathInfo` over a temporary directory, the pre/post pair every case seeds, the
// raw record and metadata key files the app writes, and a container loaded over
// them.
//
// Shared because both suites assert on the same bytes: `enhancement_merge_test.dart`
// on the records and the journal, `enhancement_merge_rating_test.dart` on a rating
// key file. Two copies of a fixture can only disagree about what "the app writes"
// means, and then one suite's green says nothing about the other's.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'factor_classifier.dart';
import 'records.dart';

/// A [PathInfo] whose every root is [root], so one scratch directory holds the
/// stores, the metadata and the data root together.
PathInfo mergeScratchPathInfo(DirectoryPath root) => PathInfo(
  documentDir: root,
  supportDir: root,
  executableDir: root / 'exe',
  downloadDir: root / 'dl',
  dataRoot: root,
);

/// The pre-enhancement side: five whites, coloured factors at one star.
CharaDetailRecord preRecord(String id, {String capturedDate = '2026-01-01T00:00:00+0900'}) =>
    makeRecord(id: id, card: 7, self: [...coloured(1, 1, 1), ...whites(5)], capturedDate: capturedDate);

/// The enhanced side of [preRecord]: the same coloured kinds at three stars,
/// with one white added.
CharaDetailRecord postRecord(String id, {String capturedDate = '2026-02-01T00:00:00+0900'}) =>
    makeRecord(id: id, card: 7, self: [...coloured(3, 3, 3), ...whites(6)], capturedDate: capturedDate);

/// Writes [record] into [storeDir] with its own images, so a tree comparison
/// has something to compare beyond `record.json`.
void writeRecord(DirectoryPath storeDir, CharaDetailRecord record, {Map<String, String> files = const {}}) {
  final dir = storeDir / record.id;
  File('${dir.path}/record.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  final images = files.isEmpty ? {'front.png': 'front of ${record.id}', 'skill.png': 'skills of ${record.id}'} : files;
  images.forEach((name, content) {
    File('${dir.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  });
}

/// Writes one `metadata/<store>/<key>.json` the way the app writes it.
void writeKeyFile(DirectoryPath directory, String key, Map<String, Object> data) {
  File(directory.filePath('$key.json').path)
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert({'title': key, 'data': data}));
}

/// One key file's record map, read raw.
Map<String, dynamic> keyFileData(DirectoryPath directory, String key) =>
    ((jsonDecode(File(directory.filePath('$key.json').path).readAsStringSync()) as Map)['data'] as Map)
        .cast<String, dynamic>();

/// A container over [info], with [overrides] layered on top of the three loaders
/// every on-disk merge case needs.
///
/// [factorInfo] is what the factor table loader resolves to; by default the
/// [testFactorInfo] table, at once.
ProviderContainer makeMergeContainer({
  required PathInfo info,
  List<Override> overrides = const [],
  Future<List<FactorInfo>> Function()? factorInfo,
}) {
  final container = ProviderContainer(
    overrides: [
      pathInfoLoader.overrideWith((ref) async => info),
      moduleVersionLoader.overrideWith((ref) async => null),
      factorInfoLoader.overrideWith((ref) => factorInfo?.call() ?? Future.value(testFactorInfo)),
      ...overrides,
    ],
  );
  addTearDown(() {
    try {
      container.dispose();
    } catch (_) {
      // Already disposed by a case that simulated a restart.
    }
  });
  return container;
}

/// [makeMergeContainer] with both stores read to completion.
///
/// A store that fails to load is left as an error rather than rethrown here:
/// several cases seed exactly that state on purpose, and the assertion they make
/// is about what the merge then does, not about the load.
Future<ProviderContainer> loadedMergeContainer({required PathInfo info, List<Override> overrides = const []}) async {
  final container = makeMergeContainer(info: info, overrides: overrides);
  await container.read(factorInfoLoader.future);
  await container.read(charaDetailRecordStorageLoaderProvider.future).then((_) {}, onError: (_) {});
  await container.read(charaDetailArchiveStorageLoaderProvider.future).then((_) {}, onError: (_) {});
  return container;
}

/// The candidates the app would offer over what both stores currently hold.
List<EnhancementCandidate> candidatesIn(ProviderContainer container) => findEnhancementCandidates([
  ...container.read(charaDetailRecordStorageLoaderProvider).requireValue,
  ...container.read(charaDetailArchiveStorageLoaderProvider).requireValue,
], testClassifier);

/// Merges the one pair the fixture offers.
///
/// The count is asserted, not assumed: a fixture that grew a second pair would
/// otherwise merge whichever one came first and still look green.
Future<EnhancementMergeResult> mergeOne(
  ProviderContainer container, {
  String? keptContentId,
  EnhancementMergeChoices choices = const EnhancementMergeChoices(),
}) async {
  final candidates = candidatesIn(container);
  expect(candidates, hasLength(1), reason: 'the fixture is meant to offer exactly one pair');
  return container
      .read(enhancementMergeProvider)
      .merge(candidates.single, keptContentId: keptContentId, choices: choices);
}
