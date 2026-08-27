// Widget test for the "custom sound file is missing" indicator in the settings page.
//
// The indicator is the only thing that tells the user why the default clip is playing instead of
// the file whose path the row still shows. It used to be suppressed on web because the check was
// the desktop-only `existsSync`; a web custom sound lives in OPFS, which the browser may evict, so
// the state the indicator exists to reveal is reachable there too. This test pins the check to the
// asynchronous, cross-backend `PathEntity.exists` by running the whole tile on a backend whose
// synchronous surface throws, exactly as the web backend does.
//
// The three states are asserted inside one `testWidgets` on purpose: they also exercise the
// re-stat listener that reacts to a path change, which separate cases would not.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/sound_missing_indicator_test.dart
import 'dart:io';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/sound_player.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/settling.dart';
import 'support/web_like_fs_backend.dart';

/// The app's own light palette plus the three theme extensions `app_widget.dart` registers, so the
/// warning colour the tile reads (`theme.semantic.warning`) resolves.
ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

Finder _missingIcons() => find.byIcon(Symbols.warning_rounded);

/// The source-path tooltip of a row, told apart from the icon-button tooltips by its message.
Finder _pathTooltip(String contents) {
  return find.byWidgetPredicate((widget) => widget is Tooltip && (widget.message?.contains(contents) ?? false));
}

/// Lets the real filesystem answer the stat, then renders the frame that reflects it -- waiting until
/// [ready] describes what is on screen. Not `pumpAndSettle`: the settings rows carry continuous
/// animations, so "no frame scheduled" never becomes true. Not a fixed window either: the stat goes
/// through `PathEntity.exists`, a `dart:io` call on the thread pool, so how long it takes is a property
/// of the host rather than of this test.
Future<void> _settle(WidgetTester tester, bool Function() ready, {required String describe}) =>
    settleUntil(tester, ready, describe: describe);

/// One turn of the same real time, for the opening assertion: nothing has ever been flagged there, so
/// there is no arrival to wait for.
Future<void> _oneStatTurn(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
}

void main() {
  setUpAll(() async {
    loadAppTranslations();
  });
  useHiveForTest(['settings']);

  testWidgets('warns about a missing custom clip on a backend without a sync surface', (tester) async {
    final tempRoot = Directory.systemTemp.createTempSync('umacapture_sound_indicator_files');
    final present = File('${tempRoot.path}${Platform.pathSeparator}present.wav')..writeAsBytesSync(const [1, 2, 3]);
    final evicted = '${tempRoot.path}${Platform.pathSeparator}evicted.wav';
    final originalBackend = fsBackend;
    // Reproduces the web restriction on the VM: every synchronous FS call throws.
    fsBackend = WebLikeFsBackend(originalBackend);
    addTearDown(() {
      fsBackend = originalBackend;
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    final container = ProviderContainer.test();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _theme(),
          home: const Scaffold(body: SingleChildScrollView(child: SoundSettingsGroup())),
        ),
      ),
    );
    await _oneStatTurn(tester);

    // The bundled default clips are not custom files, so nothing is stat-ed and nothing is flagged.
    expect(_missingIcons(), findsNothing);
    expect(_pathTooltip('ファイルが見つかりません'), findsNothing);

    // A custom clip that is gone: the row keeps showing the path, so it must say the file is absent.
    container.read(soundSettingProvider(SoundType.error).notifier).setCustomFile(evicted);
    await _settle(
      tester,
      () => _missingIcons().evaluate().isNotEmpty,
      describe: 'the stat of the evicted clip to come back missing',
    );
    expect(_missingIcons(), findsOneWidget);
    expect(_pathTooltip('ファイルが見つかりません'), findsOneWidget);
    expect(_pathTooltip('evicted.wav'), findsOneWidget);

    // Pointing the same row at a file that exists clears the warning through the re-stat listener.
    // NOT an absence that can be waited out: the warning is on screen right now and the re-stat is what
    // removes it, so a fixed window asserts before the removal instead of after it.
    container.read(soundSettingProvider(SoundType.error).notifier).setCustomFile(present.path);
    await _settle(
      tester,
      () => _missingIcons().evaluate().isEmpty,
      describe: 'the re-stat of the present clip to clear the warning',
    );
    expect(_missingIcons(), findsNothing);
    expect(_pathTooltip('present.wav'), findsOneWidget);
    expect(_pathTooltip('ファイルが見つかりません'), findsNothing);
  });
}
