// Structural guard for `assets/config/platform.json`.
// Run: .fvm/flutter_sdk/bin/flutter test test/platform_config_keys_test.dart
//
// Nothing else in the repo checks the *spelling* of these keys. Every consumer looks them up by string and
// degrades silently when the lookup misses:
//   * `web/worker.js:livePullIntervalMs` falls back to LIVE_PULL_INTERVAL_FALLBACK_MS;
//   * `windows/runner/window_recorder.h` declares every field `std::optional`, so a misspelt key simply stays
//     unset and the recorder keeps its built-in default.
// So a typo here does not fail any build or any other test -- it just quietly changes runtime behaviour on one
// platform. This test asserts the path of each key an out-of-Dart consumer reads, and the type it expects.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Walks `path` through nested maps, failing with the full path when a segment is missing.
Object? _at(Map<String, dynamic> root, List<String> path) {
  Object? node = root;
  final walked = <String>[];
  for (final key in path) {
    expect(node, isA<Map<String, dynamic>>(), reason: '${walked.join('.')} is not an object');
    final map = node as Map<String, dynamic>;
    walked.add(key);
    expect(map.containsKey(key), isTrue, reason: 'missing key ${walked.join('.')} in assets/config/platform.json');
    node = map[key];
  }
  return node;
}

void main() {
  late Map<String, dynamic> config;

  setUpAll(() {
    final text = File('assets/config/platform.json').readAsStringSync();
    config = jsonDecode(text) as Map<String, dynamic>;
  });

  group('platform.json', () {
    // Read by web/worker.js at "platform.web.live_pull_interval_ms" (the `platform` prefix is added by
    // platform_controller.dart when it folds the file into the init config).
    test('the web live pull cadence is present and positive', () {
      final value = _at(config, ['web', 'live_pull_interval_ms']);
      expect(value, isA<int>());
      expect(value as int, greaterThan(0));
    });

    // Read by windows/runner/window_recorder.h via EXTENDED_JSON_TYPE_NDC(WindowRecorder, ...). Each field is
    // optional there, so an absent or misspelt key is not an error at parse time -- only here.
    test('the windows recorder section carries the fields the runner reads', () {
      final recorder = _at(config, ['windows', 'window_recorder']);
      expect(recorder, isA<Map<String, dynamic>>());
      final map = recorder as Map<String, dynamic>;
      expect(map['recording_fps'], isA<int>());
      expect(map['minimum_size'], isA<Map<String, dynamic>>());
      expect((map['minimum_size'] as Map<String, dynamic>)['width'], isA<int>());
      expect((map['minimum_size'] as Map<String, dynamic>)['height'], isA<int>());
      expect(map['window_targets'], isA<List<dynamic>>());
      expect(map['window_targets'], isNotEmpty);
      for (final target in map['window_targets'] as List<dynamic>) {
        expect(target, isA<Map<String, dynamic>>());
        final entry = target as Map<String, dynamic>;
        expect(entry['window_class'], isA<String>());
        expect(entry['window_title'], isA<String>());
      }
    });

    // The file is bundled as an asset; a section added outside the two platform roots would never reach either
    // consumer, so an unexpected top-level key is a mistake worth catching at once.
    test('no third top-level section has appeared unnoticed', () {
      expect(config.keys.toSet(), {'windows', 'web'});
    });
  });
}
