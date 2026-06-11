import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'logic.mapper.dart';

// ignore: constant_identifier_names
const tr_logic = "pages.chara_detail.column_predicate.logic";

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
  Predicate<TrinaGridOnSelectedEvent>? get onSelected => null;
}

/// A column that combines the filter conditions of its [children] with a logical
/// operator ([LogicMode]). Unlike leaf columns it has no value of its own; it
/// renders a pass/fail (✓/✗) cell for each row reflecting the combined condition.
///
/// Children are nested [ColumnSpec]s injected via drag & drop. A logic column can
/// itself be a child of another logic column, forming an arbitrary tree. The grid
/// builder ([_buildGrid] in loader.dart) walks the tree directly for efficiency;
/// [parse]/[evaluate] here provide a correct stand-alone fallback.
@MappableClass(discriminatorValue: 'LogicColumnSpec')
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

  LogicColumnSpec({
    required this.id,
    required this.title,
    required this.logic,
    this.children = const [],
    this.hidden = false,
  });

  @override
  bool get acceptsChildren => true;

  /// NOT accepts a single input; AND/OR accept any number.
  @override
  bool get acceptsMoreChildren => logic.isMultiInput || children.isEmpty;

  @override
  LogicColumnSpec withChildren(List<ColumnSpec> children) => copyWith(children: children);

  @override
  LogicColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  LogicColumnSpec copyWith({String? id, String? title, LogicMode? logic, List<ColumnSpec>? children, bool? hidden}) {
    return LogicColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      logic: logic ?? this.logic,
      children: children ?? this.children,
      hidden: hidden ?? this.hidden,
    );
  }

  /// Combine per-child condition lists ([childConditions], each one bool per row)
  /// into a single per-row condition according to [logic]. With no children the
  /// column folds to the operator's identity (empty OR/XOR/NAND = false,
  /// empty AND/NOR/XNOR/NOT = true).
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
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      enableEditingMode: false,
      readOnly: true,
      renderer: (TrinaColumnRendererContext context) {
        final data = context.cell.getUserData<LogicCellData>()!;
        return Icon(data.passed ? Icons.check : Icons.close, color: data.passed ? Colors.green : Colors.red, size: 18);
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
    return LogicColumnSpec(id: const Uuid().v4(), title: title, logic: logic, hidden: true);
  }
}
