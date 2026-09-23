// What an enhancement merge writes into a rating key file: the route's default, and the value the
// merge dialog's rating field overrides it with.
//
// Measured on disk, for the same reason the rest of the merge is: the key file is the only place a
// rating exists, and a re-keying that dropped the user's edit would still leave a container holding
// the number they typed.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/enhancement_merge_rating_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/enhancement_merge_scratch.dart';
import 'support/localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;

  late PathInfo info;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_merge_rating');
    info = mergeScratchPathInfo(DirectoryPath(tempRoot.path));
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  void seedPair() {
    writeRecord(info.charaDetailActiveDir, preRecord('older'));
    writeRecord(info.charaDetailActiveDir, postRecord('retired'));
  }

  test('the rating the dialog was left holding is the one the survivor ends up with', () async {
    // The override is the whole point of the field: without it the survivor would keep the route's
    // default (4.0 here, the enhanced side's), and the number the user typed would be lost with no
    // sign that it had been.
    seedPair();
    writeKeyFile(info.charaDetailRatingDir, 'main', {'older': 1.0, 'retired': 4.0});

    final container = await loadedMergeContainer(info: info);
    final result = await mergeOne(
      container,
      choices: const EnhancementMergeChoices(route: EnhancementMergeRoute.settings, rating: {'main': 2.5}),
    );

    expect(result.outcome, EnhancementMergeOutcome.merged);
    expect(keyFileData(info.charaDetailRatingDir, 'main'), {'older': 2.5});
  });

  test('an emptied rating field leaves the survivor with no rating, and leaves other records alone', () async {
    // The other half of the field's contract: "no rating" is a value it can carry, and carrying it
    // must not take the key file's other entries with it.
    seedPair();
    writeKeyFile(info.charaDetailRatingDir, 'main', {'other': 3.0, 'older': 1.0, 'retired': 4.0});

    final container = await loadedMergeContainer(info: info);
    final result = await mergeOne(
      container,
      choices: const EnhancementMergeChoices(route: EnhancementMergeRoute.settings, rating: {'main': null}),
    );

    expect(result.outcome, EnhancementMergeOutcome.merged);
    expect(keyFileData(info.charaDetailRatingDir, 'main'), {'other': 3.0});
  });

  test('a key the dialog said nothing about keeps the route default', () async {
    // The negative control for both cases above: an absent key is not an override, so the two
    // assertions there are about the override and not about re-keying in general.
    seedPair();
    writeKeyFile(info.charaDetailRatingDir, 'main', {'older': 1.0, 'retired': 4.0});

    final container = await loadedMergeContainer(info: info);
    final result = await mergeOne(
      container,
      choices: const EnhancementMergeChoices(route: EnhancementMergeRoute.settings),
    );

    expect(result.outcome, EnhancementMergeOutcome.merged);
    expect(keyFileData(info.charaDetailRatingDir, 'main'), {
      'older': 4.0,
    }, reason: "the settings route keeps the enhanced side's value");
  });
}
