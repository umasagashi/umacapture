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
import 'package:hive_ce/hive.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/sound_player.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/localization.dart';
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

/// Lets the real filesystem answer the stat, then renders the frame that reflects it. Not
/// `pumpAndSettle`: the settings rows carry continuous animations, so "no frame scheduled" never
/// becomes true.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
}

void main() {
  setUpAll(() async {
    loadAppTranslations();
    Hive.init(Directory.systemTemp.createTempSync('umacapture_sound_indicator_test').path);
    await Hive.openBox('settings');
  });

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
    await _settle(tester);

    // The bundled default clips are not custom files, so nothing is stat-ed and nothing is flagged.
    expect(_missingIcons(), findsNothing);
    expect(_pathTooltip('ファイルが見つかりません'), findsNothing);

    // A custom clip that is gone: the row keeps showing the path, so it must say the file is absent.
    container.read(soundSettingProvider(SoundType.error).notifier).setCustomFile(evicted);
    await _settle(tester);
    expect(_missingIcons(), findsOneWidget);
    expect(_pathTooltip('ファイルが見つかりません'), findsOneWidget);
    expect(_pathTooltip('evicted.wav'), findsOneWidget);

    // Pointing the same row at a file that exists clears the warning through the re-stat listener.
    container.read(soundSettingProvider(SoundType.error).notifier).setCustomFile(present.path);
    await _settle(tester);
    expect(_missingIcons(), findsNothing);
    expect(_pathTooltip('present.wav'), findsOneWidget);
    expect(_pathTooltip('ファイルが見つかりません'), findsNothing);
  });
}
