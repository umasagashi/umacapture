// A DISABLED CONTROL MUST STILL BE ABLE TO SAY WHY -- AND A `Tooltip` INSIDE `Disabled` CANNOT.
// Run: .fvm/flutter_sdk/bin/flutter test test/disabled_tooltip_visibility_test.dart
//
// THE DEFECT THIS FILE EXISTS FOR. `Disabled` wraps its child in an `IgnorePointer`. That refuses
// hover as well as taps -- `RenderIgnorePointer.hitTest` returns false, and `MouseTracker` finds the
// `MouseRegion` a `Tooltip` installs only by hit-testing. So a `Tooltip` written *inside* `Disabled`
// is mute for exactly as long as the control is unavailable: the explanation is withheld in the one
// state that needs explaining, and it comes back the moment it is no longer wanted. Four call sites
// were written that way (the two preview nav pairs and the capture-report Send button); `capture.dart`
// was not, and is the shape the others were brought to -- the reason goes to `Disabled.tooltip`,
// which is mounted *outside* the `IgnorePointer`, and the inner `Tooltip` stays to cover the offered
// state.
//
// WHY THESE CASES CANNOT PASS BY ACCIDENT. Every hover assertion is a pair: the same widget in the
// state where the sentence is expected AND in the state where a different one (or none) is. Without
// the positive half, "no tooltip appeared" and "the harness never managed to hover" read identically,
// and the file would stay green if `moveTo` stopped delivering hover, if the finder stopped matching,
// or if `Tooltip` stopped mounting its overlay at all.
//
// The wrong implementations these cases are here to exclude, named:
//   * the shipped defect -- the reason left inside `Disabled` -- fails L1's "disabled" case and the
//     L3 scan.
//   * `Disabled.tooltip` supplied but `Disabled` reverted to mounting its `Tooltip` *inside* the
//     `IgnorePointer` -- fails L1's "the reason handed to Disabled is readable while disabled".
//   * the inner `Tooltip` deleted instead of kept -- fails L1's "enabled" case, which is what the
//     user reads the other 99% of the time.
//   * the four reported call sites hand-patched while the next one written the old way is not --
//     that is L3, which enumerates instead of listing.
//   * a wording assertion made with `key.tr()`, which is `key == key` for a key that does not
//     resolve -- every sentence here comes from `appSentenceAt`, i.e. out of the shipped ja.json.
import 'dart:io';

// `analyzer` reaches this package transitively (through the codegen stack). Depended on here rather
// than promoted to a direct dev_dependency because pinning it would freeze the version the codegen
// packages resolve to, and this guard only ever needs the parser.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';

const _innerMessage = 'what this button does';
const _reasonMessage = 'why you cannot use it right now';

// ---------------------------------------------------------------------------------------------
// L1 -- the primitive, with a control no product file touches.
// ---------------------------------------------------------------------------------------------

Future<void> _pumpPrimitive(WidgetTester tester, {required bool disabled, String? reason}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Disabled(
            disabled: disabled,
            tooltip: reason,
            child: Tooltip(
              message: _innerMessage,
              child: TextButton(onPressed: () {}, child: const Text('subject')),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Hovers the pointer over [finder] and lets any tooltip settle.
///
/// A real mouse pointer rather than a tap: hover is the channel `IgnorePointer` closes, and a
/// long-press would exercise the touch path instead -- a different route into `Tooltip`, which would
/// have kept this file green through the shipped defect on desktop.
Future<void> _hover(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(() => gesture.removePointer());
  await tester.pump();
  await gesture.moveTo(tester.getCenter(finder));
  // Past `waitDuration` and the hover show delay, both well under a second.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  group('L1 -- the Disabled primitive', () {
    testWidgets('positive control: while it is offered, the inner Tooltip answers a hover', (tester) async {
      await _pumpPrimitive(tester, disabled: false, reason: _reasonMessage);

      await _hover(tester, find.text('subject'));

      expect(find.text(_innerMessage), findsOneWidget, reason: 'this is the measuring instrument');
      expect(find.text(_reasonMessage), findsNothing, reason: 'there is no reason to give while it is offered');
    });

    testWidgets('a Tooltip inside Disabled goes mute the moment the control is disabled', (tester) async {
      // The defect itself, pinned as behaviour of the primitive rather than of any one call site:
      // this is why a reason may not be written inside.
      await _pumpPrimitive(tester, disabled: true);

      await _hover(tester, find.text('subject'));

      expect(
        find.text(_innerMessage),
        findsNothing,
        reason: 'IgnorePointer refuses hover, so anything inside Disabled cannot be reached',
      );
    });

    testWidgets('the reason handed to Disabled is readable while disabled', (tester) async {
      await _pumpPrimitive(tester, disabled: true, reason: _reasonMessage);

      await _hover(tester, find.text('subject'));

      expect(
        find.text(_reasonMessage),
        findsOneWidget,
        reason: 'Disabled mounts its own Tooltip outside IgnorePointer',
      );
      expect(find.text(_innerMessage), findsNothing, reason: 'the inner one is still behind the IgnorePointer');
    });
  });

  // -------------------------------------------------------------------------------------------
  // L3 -- every call site, enumerated out of the source.
  // -------------------------------------------------------------------------------------------

  group('L3 -- the call sites', () {
    test('no Disabled hides a tooltip inside itself without also carrying its own', () {
      final scan = scanDisabledCallSites();

      // Without this the whole case passes by scanning an empty directory or by a parse that stopped
      // recognising the constructor.
      expect(scan.filesScanned, greaterThan(50), reason: 'the lib scan found almost nothing');
      expect(scan.sites, greaterThan(10), reason: 'no Disabled call sites were recognised at all');
      expect(
        scan.withOwnTooltip,
        greaterThan(5),
        reason: 'no call site was seen passing tooltip:, so the check for it reads nothing',
      );

      expect(
        scan.offenders,
        equals(knownOffenders),
        reason:
            'a Disabled whose child carries a Tooltip (or a widget `tooltip:`) but which passes no '
            'tooltip: of its own. The inner one is behind an IgnorePointer, so the control says '
            'nothing while it is disabled -- hand the reason to Disabled.tooltip, as capture.dart '
            'does. If an entry above was fixed, delete it from knownOffenders.',
      );
    });
  });
}

/// The call sites still left in this shape, by file and count. **Empty, and it stays empty**: the
/// comparison is exact in both directions, so a newly written offender and a repaired one that was
/// not struck off here are each red rather than silently absorbed.
///
/// The last entry was `lib/src/gui/chara_detail/report_import_dialog.dart` -- the import-report
/// dialog's Send button, the same defect as the capture-report dialog's. It now derives its reason
/// from the same `_grabbed == null` local that withdraws the button and hands it to
/// `Disabled.tooltip`, so the generic `ok_button.tooltip` it keeps inside is only ever read in the
/// state where the button is offered.
const knownOffenders = <String, int>{};

/// What one sweep of `lib/` found. The counters exist to be asserted on: a scan that recognises
/// nothing produces an empty [offenders] set and would otherwise pass.
class DisabledScan {
  DisabledScan(this.filesScanned, this.sites, this.withOwnTooltip, this.offenders);

  final int filesScanned;
  final int sites;
  final int withOwnTooltip;
  final Map<String, int> offenders;
}

/// Whether [node] constructs a widget named [name].
///
/// Both AST shapes are accepted because this is an *unresolved* parse: `const Disabled(...)` comes
/// back as an `InstanceCreationExpression` while a bare `Disabled(...)` is indistinguishable from a
/// function call and comes back as a `MethodInvocation`. Matching only one of them would quietly
/// skip most of the call sites.
bool _constructs(AstNode node, String name) {
  if (node is InstanceCreationExpression) {
    return node.constructorName.type.toSource() == name;
  }
  if (node is MethodInvocation) {
    // `Tooltip(...)` and `Tooltip.rich(...)`; a `target` of `Tooltip` covers the named constructor.
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

/// Every `Disabled(...)` in one compilation unit.
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

/// Whether the subtree rooted at [node] contains something that would render a tooltip.
///
/// Two shapes, because both die the same way under the `IgnorePointer`: an explicit `Tooltip(...)`,
/// and a widget's own `tooltip:` parameter (`IconButton(tooltip: …)`), which is a `Tooltip` the
/// widget builds for itself.
class _TooltipVisitor extends RecursiveAstVisitor<void> {
  bool found = false;

  void _check(AstNode node) {
    if (_constructs(node, 'Tooltip')) found = true;
    final arguments = _argumentsOf(node);
    if (arguments != null && _namedArgument(arguments, 'tooltip') != null) found = true;
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

/// Sweeps `lib/` for `Disabled(...)` call sites and reports the ones that bury a tooltip.
///
/// Parsed rather than pattern-matched: the child is an expression spanning tens of lines with
/// strings, interpolations and comments in it, and a bracket-counting scan over that text gets the
/// span wrong in both directions. Nothing here names a file or a widget, so a call site added
/// anywhere under `lib/` is covered without this function being edited.
DisabledScan scanDisabledCallSites() {
  var filesScanned = 0;
  var sites = 0;
  var withOwnTooltip = 0;
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
      sites += 1;
      // `tooltip: null` is not a reason: a call site that always passes null is the defect written
      // with an argument. Anything else -- a literal, a conditional, a nullable local -- is a
      // sentence the control can produce in at least one state.
      final own = _namedArgument(arguments, 'tooltip');
      final carriesOwn = own != null && own is! NullLiteral;
      if (carriesOwn) withOwnTooltip += 1;

      final child = _namedArgument(arguments, 'child');
      if (child == null) continue;
      final inner = _TooltipVisitor();
      child.accept(inner);
      if (inner.found && !carriesOwn) {
        offenders[path] = (offenders[path] ?? 0) + 1;
      }
    }
  }
  return DisabledScan(filesScanned, sites, withOwnTooltip, offenders);
}
