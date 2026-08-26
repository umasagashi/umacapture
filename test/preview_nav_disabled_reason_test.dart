// A WITHDRAWN NAV BUTTON HAS TO SAY WHY IT IS WITHDRAWN -- not repeat the move it will not make.
// Run: .fvm/flutter_sdk/bin/flutter test test/preview_nav_disabled_reason_test.dart
//
// THE DEFECT THIS FILE EXISTS FOR. The two preview navigation groups -- the dialog's up/down pair
// (`preview_dialog.dart`) and the side panel's up/down/left/right (`side_preview.dart`) -- handed
// `Disabled.tooltip` and the inner `Tooltip.message` the SAME key. `Disabled` mounts its own tooltip
// outside the `IgnorePointer`, so the sentence a user reads while the button is grey came from that
// outer one -- and it said 「表の1つ上のウマ娘を表示します」, i.e. it promised a move that cannot
// happen, in the one state where the user is asking why nothing happens. The sibling
// `report_import_dialog._stepButton` already splits `tooltip` from `disabled_tooltip` for exactly
// this reason, so the branch shipped two standards.
//
// WHY THE EXISTING SUITE COULD NOT SEE IT. `disabled_tooltip_visibility_test.dart` asserts that every
// `Disabled` carries *a* tooltip of its own, and these call sites always did -- they simply carried
// the wrong one. Presence is green through the whole defect; only the sentence's identity is not.
//
// WHAT IS ASSERTED, AND WHY IT IS THE USER'S PROPERTY. Each case hovers a real mouse pointer over
// the real button and reads the text that appears, comparing it against the literal Japanese in the
// shipped `ja.json` (via `appSentenceAt`, never `key.tr()`, which is `key == key` for a key that does
// not resolve). Nothing here looks at `Disabled.disabled` or at which argument a call site passed:
// an implementation that set the flag and left the wording alone stays red.
//
// Every hover assertion is a PAIR -- the same button in the state where the reason is expected and in
// the state where the action sentence is. Without the second half, "the reason appeared" and "the
// harness hovered nothing and both finders found nothing" would be indistinguishable.
import 'dart:io';

// `analyzer` reaches this package transitively through the codegen stack; depended on here rather
// than promoted to a direct dev_dependency for the reason `disabled_tooltip_visibility_test.dart`
// gives -- pinning it would freeze the version the codegen packages resolve to.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/side_preview.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';

const _dialog = 'pages.chara_detail.preview.dialog';
const _panel = 'pages.chara_detail.preview.side_panel';

late Directory _tempDir;

/// What a real mouse hover over [finder] puts on screen, out of the two candidate sentences.
///
/// A mouse rather than a tap: hover is the channel `IgnorePointer` closes, and a long-press would
/// take the touch route into `Tooltip` -- a different path, which would stay green on desktop
/// through the very shape being tested.
Future<({bool showsReason, bool showsAction})> _sentenceOnHover(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  required String action,
}) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(finder));
  // Past `waitDuration` and the hover show delay, both well under a second.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  final result = (
    showsReason: find.text(reason).evaluate().isNotEmpty,
    showsAction: find.text(action).evaluate().isNotEmpty,
  );
  // The pointer is retired between probes, so the next one starts from "nothing shown" rather than
  // from a tooltip that was never dismissed.
  await gesture.moveTo(Offset.zero);
  await tester.pump(const Duration(seconds: 1));
  await gesture.removePointer();
  await tester.pump();
  return result;
}

/// Lets the dialog's three `FutureProvider`s (size json, image paths, prediction probe) resolve.
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

ProviderContainer _container() {
  final dir = DirectoryPath(_tempDir.path);
  final container = ProviderContainer(
    // riverpod 3 retries a failed build by default, which turns a setup mistake into a thirty-second
    // timeout instead of a failure that names itself.
    retry: (_, _) => null,
    overrides: [
      pathInfoProvider.overrideWithValue(
        PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('umacapture_preview_nav_test');
    // Two empty record directories: the dialog degrades to its "no image" message, which is beside
    // the point here -- what matters is that there are two rows, so index 0 is at the top and index
    // 1 is at the bottom and each nav button is reachable in both of its states.
    Directory('${_tempDir.path}/record-a').createSync(recursive: true);
    Directory('${_tempDir.path}/record-b').createSync(recursive: true);
  });
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('the preview dialog says there is no row above, and only promises the move once there is', (
    tester,
  ) async {
    // Tall enough that the dialog's bottom button row is inside the card's clip.
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final container = _container();
    // The real `DialogLayer`, driven through the real `dialogBuilderProvider`. The guard under test
    // lives in the dialog, but the dialog is only ever reached through this layer and `CardDialog`
    // is what lays out and clips the row the nav buttons sit in -- a bare mount would assert about a
    // tree the app never builds.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: appTestLocale,
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => CharaDetailPreviewDialog(
            recordDirs: [DirectoryPath('${_tempDir.path}/record-a'), DirectoryPath('${_tempDir.path}/record-b')],
            initialIdx: 0,
          ),
        );
    await tester.pump();
    await _settleIo(tester);

    final upAction = appSentenceAt('$_dialog.up_button.tooltip');
    final upReason = appSentenceAt('$_dialog.up_button.disabled_tooltip');
    expect(upReason, isNot(equals(upAction)), reason: 'the two keys must not resolve to the same sentence');

    // At the top row: up is withdrawn, and what the user reads has to be the reason.
    final withdrawn = await _sentenceOnHover(
      tester,
      find.byIcon(Symbols.arrow_upward_rounded),
      reason: upReason,
      action: upAction,
    );
    expect(withdrawn.showsReason, isTrue, reason: 'a greyed button that says nothing is the defect');
    expect(
      withdrawn.showsAction,
      isFalse,
      reason: 'announcing "shows the row above" on a button that cannot move is the defect this fixes',
    );

    // Walk the same dialog to the second row rather than reopening it: the sentence has to change
    // back, and an implementation that always shows the reason is the same defect pointing the other
    // way.
    await tester.tap(find.byIcon(Symbols.arrow_downward_rounded));
    await _settleIo(tester);

    final offered = await _sentenceOnHover(
      tester,
      find.byIcon(Symbols.arrow_upward_rounded),
      reason: upReason,
      action: upAction,
    );
    expect(offered.showsAction, isTrue, reason: 'with a row above, the button describes what it does');
    expect(offered.showsReason, isFalse, reason: 'there is no refusal to explain here');

    // And the button at the far end is now the withdrawn one, which pins that the down button was
    // given its own reason too -- not only the up button that the finding named first.
    final downReason = appSentenceAt('$_dialog.down_button.disabled_tooltip');
    final downAction = appSentenceAt('$_dialog.down_button.tooltip');
    final downWithdrawn = await _sentenceOnHover(
      tester,
      find.byIcon(Symbols.arrow_downward_rounded),
      reason: downReason,
      action: downAction,
    );
    expect(downWithdrawn.showsReason, isTrue);
    expect(downWithdrawn.showsAction, isFalse);
  });

  testWidgets('the side panel names the edge it has run into, on the record axis and the image axis', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    // `SidePreviewPanel` is the widget that decides each button's availability -- it is handed
    // `canPrev` / `canNext` / `canModeLeft` / `canModeRight` and turns them into `disabled:`. Mounting
    // it (rather than the private `_NavButton`) is what makes this a test of the guard's owner.
    Future<void> pumpPanel({
      required bool canPrev,
      required bool canNext,
      required bool canModeLeft,
      required bool canModeRight,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: appTestLocale,
          home: Scaffold(
            body: SidePreviewPanel(
              // No record: the image area shows its placeholder, which keeps the case off the record
              // store and the filesystem. The footer -- the whole subject here -- is unaffected.
              recordDir: null,
              mode: CharaDetailRecordImageMode.skillPlain,
              canPrev: canPrev,
              canNext: canNext,
              canModeLeft: canModeLeft,
              canModeRight: canModeRight,
              onNavigate: (_) {},
              onChangeMode: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // Every one of the four buttons, in both of its states, through one shared routine so the four
    // are held to the same standard rather than to four hand-written variants of it.
    Future<void> check(
      String key,
      IconData icon, {
      required Future<void> Function() withdraw,
      required Future<void> Function() offer,
    }) async {
      final action = appSentenceAt('$_panel.$key.tooltip');
      final reason = appSentenceAt('$_panel.$key.disabled_tooltip');
      expect(reason, isNot(equals(action)), reason: '$key resolves both keys to the same sentence');

      await withdraw();
      final withdrawn = await _sentenceOnHover(tester, find.byIcon(icon), reason: reason, action: action);
      expect(withdrawn.showsReason, isTrue, reason: '$key is withdrawn and says nothing about why');
      expect(withdrawn.showsAction, isFalse, reason: '$key promises a move it cannot make');

      await offer();
      final offered = await _sentenceOnHover(tester, find.byIcon(icon), reason: reason, action: action);
      expect(offered.showsAction, isTrue, reason: '$key stopped describing itself when it became usable');
      expect(offered.showsReason, isFalse, reason: '$key keeps explaining a refusal that is over');
    }

    await check(
      'up_button',
      Symbols.arrow_upward_rounded,
      withdraw: () => pumpPanel(canPrev: false, canNext: true, canModeLeft: true, canModeRight: true),
      offer: () => pumpPanel(canPrev: true, canNext: true, canModeLeft: true, canModeRight: true),
    );
    await check(
      'down_button',
      Symbols.arrow_downward_rounded,
      withdraw: () => pumpPanel(canPrev: true, canNext: false, canModeLeft: true, canModeRight: true),
      offer: () => pumpPanel(canPrev: true, canNext: true, canModeLeft: true, canModeRight: true),
    );
    await check(
      'left_button',
      Symbols.arrow_back_rounded,
      withdraw: () => pumpPanel(canPrev: true, canNext: true, canModeLeft: false, canModeRight: true),
      offer: () => pumpPanel(canPrev: true, canNext: true, canModeLeft: true, canModeRight: true),
    );
    await check(
      'right_button',
      Symbols.arrow_forward_rounded,
      withdraw: () => pumpPanel(canPrev: true, canNext: true, canModeLeft: true, canModeRight: false),
      offer: () => pumpPanel(canPrev: true, canNext: true, canModeLeft: true, canModeRight: true),
    );
  });

  // -------------------------------------------------------------------------------------------
  // The same rule as a property of `lib/`, so the next call site written the old way is red without
  // anyone adding a case for it.
  // -------------------------------------------------------------------------------------------

  test('no Disabled hands its own tooltip the same expression its child already shows', () {
    final scan = scanEchoedTooltips();

    // Without these a scan that recognised nothing -- an empty directory, a parse that stopped
    // matching the constructor -- would produce an empty offender set and pass.
    expect(scan.filesScanned, greaterThan(50), reason: 'the lib scan found almost nothing');
    expect(scan.pairsCompared, greaterThan(5), reason: 'no Disabled was seen carrying both sentences');

    expect(
      scan.offenders,
      isEmpty,
      reason:
          'a Disabled whose own tooltip: is textually the same expression as the Tooltip inside it. '
          'The outer one is what the user reads while the control is withdrawn, so this makes a '
          'greyed control describe the action it refuses to take. Give the disabled state its own '
          'sentence, as report_import_dialog._stepButton does.',
    );
  });
}

/// What one sweep of `lib/` found.
class EchoedTooltipScan {
  EchoedTooltipScan(this.filesScanned, this.pairsCompared, this.offenders);

  final int filesScanned;

  /// `Disabled` call sites carrying both an own `tooltip:` and an inner sentence -- i.e. the ones
  /// this rule can say anything about at all.
  final int pairsCompared;

  final Map<String, int> offenders;
}

bool _constructs(AstNode node, String name) {
  if (node is InstanceCreationExpression) {
    return node.constructorName.type.toSource() == name;
  }
  if (node is MethodInvocation) {
    return (node.target == null && node.methodName.name == name) || node.target?.toSource() == name;
  }
  return false;
}

ArgumentList? _argumentsOf(AstNode node) {
  if (node is InstanceCreationExpression) return node.argumentList;
  if (node is MethodInvocation) return node.argumentList;
  return null;
}

Expression? _namedArgument(ArgumentList arguments, String label) {
  for (final argument in arguments.arguments) {
    if (argument is NamedExpression && argument.name.label.name == label) {
      return argument.expression;
    }
  }
  return null;
}

class _DisabledVisitor extends RecursiveAstVisitor<void> {
  final List<ArgumentList> found = [];

  void _record(AstNode node) {
    if (_constructs(node, 'Disabled')) {
      final arguments = _argumentsOf(node);
      if (arguments != null) found.add(arguments);
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _record(node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _record(node);
    super.visitMethodInvocation(node);
  }
}

/// Every sentence the child subtree would render as a tooltip: an explicit `Tooltip(message: …)` and
/// a widget's own `tooltip:` parameter, which is a `Tooltip` the widget builds for itself.
class _InnerSentenceVisitor extends RecursiveAstVisitor<void> {
  final List<String> sentences = [];

  void _check(AstNode node) {
    final arguments = _argumentsOf(node);
    if (arguments == null) return;
    if (_constructs(node, 'Tooltip')) {
      final message = _namedArgument(arguments, 'message');
      if (message != null) sentences.add(message.toSource());
    }
    final own = _namedArgument(arguments, 'tooltip');
    if (own != null) sentences.add(own.toSource());
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _check(node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _check(node);
    super.visitMethodInvocation(node);
  }
}

/// Sweeps `lib/` for a `Disabled` whose own reason is the same expression as one its child shows.
///
/// Compared as source text rather than resolved: the two are written side by side, so an echo is
/// always literally the same expression, and a textual match needs no element model (which an
/// unresolved parse does not have). Nothing here names a file or a widget, so a call site added
/// anywhere under `lib/` is covered without this function being edited.
EchoedTooltipScan scanEchoedTooltips() {
  var filesScanned = 0;
  var pairsCompared = 0;
  final offenders = <String, int>{};

  for (final entity in Directory('lib').listSync(recursive: true).whereType<File>()) {
    final path = entity.path.replaceAll(r'\', '/');
    if (!path.endsWith('.dart')) continue;
    if (path.endsWith('.g.dart') || path.endsWith('.gr.dart') || path.endsWith('.mapper.dart')) continue;
    filesScanned += 1;

    final unit = parseString(content: entity.readAsStringSync(), throwIfDiagnostics: false).unit;
    final visitor = _DisabledVisitor();
    unit.accept(visitor);

    for (final arguments in visitor.found) {
      final own = _namedArgument(arguments, 'tooltip');
      final child = _namedArgument(arguments, 'child');
      if (own == null || own is NullLiteral || child == null) continue;
      final inner = _InnerSentenceVisitor();
      child.accept(inner);
      if (inner.sentences.isEmpty) continue;
      pairsCompared += 1;
      if (inner.sentences.contains(own.toSource())) {
        offenders[path] = (offenders[path] ?? 0) + 1;
      }
    }
  }
  return EchoedTooltipScan(filesScanned, pairsCompared, offenders);
}
