// THE OPTIONAL LINE OF A CAPTURE-TAB MESSAGE: silent when the omission is deliberate, loud when it
// is not.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_optional_line_test.dart
//
// `optionalMessageLine` used to translate the key and treat "the answer is the key" as "no line".
// easy_localization renders an unresolvable key as the key, but it logs
// `Localization key [...] not found` first, and `localization_util.dart` forwards that into the app
// logger -- where it becomes a Sentry breadcrumb. A probe designed to miss therefore filled the
// breadcrumb ring of every report the user sent: one measured import spent 38 of 54 breadcrumbs on
// it.
//
// The obvious fix -- ask `trExists` and return null when the key is absent -- would trade this
// defect for a much worse one, because then a key deleted or renamed by mistake also vanishes
// without a word. This project has been bitten by a silently missing key three times on this topic
// alone. So BOTH halves are pinned here, in the same file, on purpose:
//
//   * a deliberate omission, written into `ja.json` as an empty string, logs nothing;
//   * an absent key still logs, still resolves as the raw key, exactly as a mandatory line does.
//
// The third case enumerates the states out of `ja.json` rather than listing them here. A list in a
// test omits an entry as quietly as a list in the code does.
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// ignore: depend_on_referenced_packages
import 'package:easy_logger/easy_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/gui/capture.dart';

import 'support/localization.dart';

const _controlBase = 'pages.capture.capture_control';
const _messageBase = '$_controlBase.message';
const _eventBase = '$_controlBase.event';

/// The single translation file this app ships. Read as data here: nothing in this file decides
/// which lines are optional -- `ja.json` does, and the enumeration below only checks the shape.
const _translationFile = 'assets/translations/ja.json';

/// One line easy_localization asked the app to log, with the level it asked for.
typedef _LogLine = ({LevelMessages? level, String message});

/// Everything easy_localization logs while [body] runs.
///
/// Swaps the printer rather than the whole logger so the levels the app enables are untouched, and
/// restores it afterwards even if [body] throws.
List<_LogLine> _logsDuring(void Function() body) {
  final lines = <_LogLine>[];
  final original = EasyLocalization.logger.printer;
  EasyLocalization.logger.printer = (Object object, {String? name, StackTrace? stackTrace, LevelMessages? level}) {
    lines.add((level: level, message: object.toString()));
  };
  try {
    body();
  } finally {
    EasyLocalization.logger.printer = original;
  }
  return lines;
}

Map<String, dynamic> _translationsAt(String dottedKey) {
  final json = jsonDecode(File(_translationFile).readAsStringSync()) as Map<String, dynamic>;
  dynamic node = json;
  for (final step in dottedKey.split('.')) {
    node = (node as Map<String, dynamic>)[step];
  }
  return node as Map<String, dynamic>;
}

/// Every node under [dottedKey] that carries a `status` line, by its dotted path.
Map<String, Map<String, dynamic>> _statusBearingNodes(String dottedKey) {
  final found = <String, Map<String, dynamic>>{};
  void walk(Map<String, dynamic> node, String path) {
    if (node.containsKey('status')) {
      found[path] = node;
    }
    node.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        walk(value, '$path.$key');
      }
    });
  }

  walk(_translationsAt(dottedKey), dottedKey);
  return found;
}

void main() {
  setUpAll(loadAppTranslations);

  test('a deliberately empty line is answered with null and logged nowhere', () {
    late String? line;
    final logs = _logsDuring(() => line = optionalMessageLine('$_messageBase.importing.action'));

    expect(line, isNull, reason: 'the state says so in `status`; there is nothing for the user to do');
    expect(
      logs,
      isEmpty,
      reason: 'THE POINT OF THIS FILE: a probe that is designed to find nothing must not report it as a fault',
    );
  });

  test('a key that is not in the translations is still reported as missing', () {
    // Not a state the app has -- exactly what a renamed or deleted key looks like from here.
    const absent = '$_messageBase.no_such_state.action';
    late String? line;
    final logs = _logsDuring(() => line = optionalMessageLine(absent));

    expect(
      logs.map((l) => l.message),
      contains(contains(absent)),
      reason: 'THE OTHER POINT: a key that should exist and does not must still be reported',
    );
    expect(logs.map((l) => l.level), contains(LevelMessages.warning), reason: 'reported as a fault, not as chatter');
    expect(line, absent, reason: 'and it reaches the screen as the raw key, as a missing mandatory line does');
  });

  test('every capture-tab state carries both of its lines, the optional one possibly empty', () {
    // Found by shape, not listed: `_StatusMessage` resolves `<base>.status` for every state it can
    // show, so a node carrying `status` IS one of those bases. A state added to the switch without
    // an action line therefore turns this red on its own -- which a list written out here would not,
    // because the way a list fails is by not mentioning the new one.
    final states = _statusBearingNodes(_controlBase);
    expect(states, hasLength(9), reason: 'the shape scan must actually find the states, not zero of them');
    expect(states.keys, contains('$_messageBase.importing'), reason: 'including the one this file is about');

    states.forEach((path, state) {
      expect(state['status'], allOf(isA<String>(), isNotEmpty), reason: '$path: the banner always shows a status');
      // Present. Empty string means "deliberately no action line" -- the representation
      // `optionalMessageLine` reads. Leaving the key out instead makes the app log a missing-key
      // warning on every rebuild of the status widget. A map is the third legal shape: a state whose
      // action depends on something the translations cannot see picks a leaf itself.
      expect(
        state.containsKey('action'),
        isTrue,
        reason: '$path: an action line that is not wanted is written as "", not left out',
      );
      final action = state['action'];
      if (action is Map<String, dynamic>) {
        expect(action, isNotEmpty, reason: '$path: a variant map with no variants resolves to nothing');
        for (final variant in action.entries) {
          expect(variant.value, allOf(isA<String>(), isNotEmpty), reason: '$path.action.${variant.key}');
        }
      } else {
        expect(action, isA<String>(), reason: '$path: an action line is a sentence or ""');
      }
    });
  });

  test('every capture-tab event carries its hint line', () {
    // The same optional-line helper resolves these, so the same rule applies to them.
    final events = _translationsAt(_eventBase);
    final withBodies = events.entries.where((e) => e.value is Map<String, dynamic>);
    expect(withBodies, isNotEmpty);

    for (final entry in withBodies) {
      expect(
        (entry.value as Map<String, dynamic>)['hint'],
        isA<String>(),
        reason: '${entry.key}: a hint that is not wanted is written as "", not left out',
      );
    }
  });

  test('the deliberate omission is an empty string in the shipped file, not a missing key', () {
    // Pins the representation itself: without this, a well-meaning cleanup that deletes the empty
    // value restores the breadcrumb flood, and only the first test above would notice -- and only
    // because it reads the same file.
    final importing = _translationsAt('$_messageBase.importing');
    expect(importing.containsKey('action'), isTrue);
    expect(importing['action'], '');
  });
}
