import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/theme_extensions.dart';

part 'logic.mapper.dart';

// ignore: constant_identifier_names
const tr_logic = "pages.chara_detail.column_predicate.logic";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

@MappableEnum()
enum LogicMode { and, or, not, xor, nand, nor, xnor }

extension LogicModeExtension on LogicMode {
  /// Translation key suffix used for the localized mode name (e.g. "logic.mode.and").
  String get translationKey => name;

  /// Whether this mode accepts more than one input column.
  bool get isMultiInput => this != LogicMode.not;

  /// Applies the operator to one row's worth of input bits. The single source of
  /// truth for the operator semantics, shared by filter-time combination
  /// ([LogicColumnSpec.combine]) and the add-column truth table, so the displayed
  /// table can never drift from what actually filters. NOT is unary once arity is
  /// enforced; `!any` keeps it well-defined for any input count.
  bool apply(List<bool> inputs) => switch (this) {
    LogicMode.and => inputs.every((e) => e),
    LogicMode.or => inputs.any((e) => e),
    LogicMode.not => !inputs.any((e) => e),
    LogicMode.xor => inputs.where((e) => e).length.isOdd,
    LogicMode.nand => !inputs.every((e) => e),
    LogicMode.nor => !inputs.any((e) => e),
    LogicMode.xnor => inputs.where((e) => e).length.isEven,
  };
}

class LogicCellData implements CellData {
  final bool passed;

  LogicCellData(this.passed);

  @override
  String get csv => passed ? "1" : "0";

  @override
  CellSelectedCallback? get onSelected => null;
}

/// A column that combines the filter conditions of its [children] with a logical
/// operator ([LogicMode]). Unlike leaf columns it has no value of its own; it
/// renders a pass/fail (✓/✗) cell for each row reflecting the combined condition.
///
/// Children are nested [ColumnSpec]s injected via drag & drop. A logic column can
/// itself be a child of another logic column, forming an arbitrary tree. The grid
/// builder ([_buildGrid] in loader.dart) walks the tree directly for efficiency;
/// [parse]/[evaluate] here provide a correct stand-alone fallback.
@MappableClass(discriminatorValue: 'LogicColumnSpec', ignoreNull: true)
class LogicColumnSpec extends ColumnSpec<bool> with LogicColumnSpecMappable, ContainerColumnSpec {
  final LogicMode logic;

  @override
  final List<ColumnSpec> children;

  @override
  final String id;

  @override
  final String title;

  @override
  final bool hidden;

  @override
  final String? description;

  @override
  final double? width;

  LogicColumnSpec({
    required this.id,
    required this.title,
    required this.logic,
    this.children = const [],
    this.hidden = false,
    this.description,
    this.width,
  });

  // Renders a fixed-size pass/fail icon, not wrapping text.
  @override
  bool get wrapsText => false;

  @override
  bool get acceptsChildren => true;

  /// NOT accepts a single input; AND/OR accept any number.
  @override
  bool get acceptsMoreChildren => logic.isMultiInput || children.isEmpty;

  @override
  LogicColumnSpec withChildren(List<ColumnSpec> children) => copyWith(children: children);

  @override
  LogicColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  LogicColumnSpec copyWith({
    String? id,
    String? title,
    LogicMode? logic,
    List<ColumnSpec>? children,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return LogicColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      logic: logic ?? this.logic,
      children: children ?? this.children,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  /// Combine per-child condition lists ([childConditions], each one bool per row)
  /// into a single per-row condition according to [logic]. With no children the
  /// column folds to the operator's identity (empty OR/XOR/NAND = false,
  /// empty AND/NOR/XNOR/NOT = true).
  ///
  /// By design, an empty OR/XOR/NAND column therefore evaluates to false and
  /// rejects every row — set-operation correctness (the identity of the empty
  /// fold) is deliberately preferred over the old "empty column passes all" UX.
  /// This is not a bug: the column's (hidden) chip still shows a pass-count
  /// badge of 0, so an empty filter that blanks the grid is diagnosable from the
  /// customization area.
  List<bool> combine(List<List<bool>> childConditions, int rowCount) {
    if (childConditions.isEmpty) {
      // Kept in lockstep with [LogicMode.apply] so an empty column filters
      // consistently with how a populated one would for the same operator.
      return List<bool>.filled(rowCount, logic.apply(const <bool>[]));
    }
    return childConditions.transpose().map(logic.apply).toList();
  }

  @override
  List<bool> combineChildren(List<List<bool>> childConditions, int rowCount) => combine(childConditions, rowCount);

  @override
  TrinaCell conditionCell(RefBase ref, bool passed) => plutoCell(ref, passed);

  @override
  List<bool> parse(RefBase ref, List<CharaDetailRecord> records) {
    final childConditions = children.map((c) => c.evaluate(ref, c.parse(ref, records))).toList();
    return combine(childConditions, records.length);
  }

  @override
  List<bool> evaluate(RefBase ref, List<bool> values) => values;

  @override
  TrinaCell plutoCell(RefBase ref, bool value) {
    return TrinaCell(value: value ? 1 : 0)..setUserData(LogicCellData(value));
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.number(),
      textAlign: TrinaColumnTextAlign.center,
      width: width ?? TrinaGridSettings.columnWidth,
      enableContextMenu: false,
      enableDropToResize: true,
      enableColumnDrag: false,
      enableEditingMode: false,
      readOnly: true,
      renderer: (TrinaColumnRendererContext rendererContext) {
        final data = rendererContext.cell.getUserData<LogicCellData>()!;
        // The Trina renderer has no BuildContext; a Builder gives one so the
        // pass/fail icon can read the theme's semantic success/danger roles.
        return Builder(
          builder: (context) {
            final semantic = Theme.of(context).semantic;
            return Icon(
              data.passed ? Symbols.check_rounded : Symbols.close_rounded,
              color: data.passed ? semantic.success : semantic.danger,
              size: 18,
            );
          },
        );
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    final mode = "$tr_logic.mode.${logic.translationKey}".tr();
    if (children.isEmpty) {
      return "$mode: ${"$tr_logic.tooltip.empty".tr()}";
    }
    return "$mode\n${children.map((c) => "- ${c.title}").join("\n")}";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return LogicColumnSelector(specId: id, onDecided: onDecided);
  }
}

final _clonedSpecProvider = SpecProviderAccessor<LogicColumnSpec>();

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _NotationSelector({required this.specId, required this.onDecided});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;

  @override
  void initState() {
    super.initState();
    title = _clonedSpecProvider.read(ref, widget.specId).title;
    widget.onDecided.addListener(() {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_logic.notation.label".tr()),
      description: Text("$tr_logic.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_logic.notation.title.label".tr()),
          children: [
            DenseTextField(
              initialText: title,
              onChanged: (value) {
                title = value;
              },
            ),
          ],
        ),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class LogicColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const LogicColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _NotationSelector(specId: specId, onDecided: onDecided),
        const SizedBox(height: 32),
        FormGroup(
          title: Text("$tr_logic.usage.label".tr()),
          description: Text("$tr_logic.usage.description".tr()),
          children: const [],
        ),
      ],
    );
  }
}

class LogicColumnBuilder extends ColumnBuilder {
  final LogicMode logic;

  @override
  final String title;

  @override
  final ColumnCategory category;

  LogicColumnBuilder({required this.title, required this.logic, this.category = ColumnCategory.logic});

  @override
  String get tooltip => "$tr_logic.builder.${logic.translationKey}".tr();

  /// Truth table rows (header first) for this operator. NOT is unary; AND/OR are
  /// binary. Output is computed from the same rule used at filter time.
  @override
  List<List<String>> get truthTable {
    final output = "$tr_logic.truth_table.output".tr();
    String bit(bool v) => v ? "1" : "0";
    if (logic == LogicMode.not) {
      return [
        ["A", output],
        for (final a in [false, true])
          [
            bit(a),
            bit(logic.apply([a])),
          ],
      ];
    }
    return [
      ["A", "B", output],
      for (final a in [false, true])
        for (final b in [false, true])
          [
            bit(a),
            bit(b),
            bit(logic.apply([a, b])),
          ],
    ];
  }

  @override
  bool get includeInAddAll => false;

  @override
  LogicColumnSpec build(RefBase ref) {
    // Logic columns are filters first; a freshly added one starts hidden so it
    // acts as an invisible filter by default. Existing (legacy) logic columns
    // lack the field and decode as shown, so they are never retroactively hidden.
    // Being hidden, a still-empty column shows no table column — its effect (e.g.
    // an empty OR folding to false and rejecting all rows, see combine()) is read
    // from the chip's pass-count badge rather than the grid. This is intended.
    return LogicColumnSpec(id: const Uuid().v4(), title: title, logic: logic, hidden: true);
  }
}
