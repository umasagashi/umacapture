import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:quiver/iterables.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

// ignore: constant_identifier_names
const tr_simple_label = "pages.chara_detail.column_predicate.simple_label";

@jsonSerializable
class SimpleLabelPredicate {
  final Set<int> rejects;

  SimpleLabelPredicate({
    required this.rejects,
  });

  SimpleLabelPredicate.any() : rejects = {};

  bool apply(int value) {
    return !rejects.contains(value);
  }
}

class SimpleLabelCellData implements CellData {
  final String label;

  SimpleLabelCellData(this.label);

  @override
  String get csv => label;

  @override
  Predicate<PlutoGridOnSelectedEvent>? get onSelected => null;
}

@jsonSerializable
@Json(discriminatorValue: "SimpleLabelColumnSpec")
class SimpleLabelColumnSpec extends ColumnSpec<int> {
  final Parser parser;
  final String labelKey;
  SimpleLabelPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final int tabIdx;

  SimpleLabelColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.labelKey,
    required this.predicate,
    int? tabIdx,
  }) : tabIdx = tabIdx ?? 0;

  SimpleLabelColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    String? labelKey,
    SimpleLabelPredicate? predicate,
  }) {
    return SimpleLabelColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      labelKey: labelKey ?? this.labelKey,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  List<int> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<int>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(RefBase ref, List<int> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(RefBase ref, int value) {
    final label = ref.read(labelMapProvider)[labelKey]![value];
    return PlutoCell(
      value: label,
    )..setUserData(SimpleLabelCellData(label));
  }

  @override
  PlutoColumn plutoColumn(RefBase ref) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.text(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        final data = context.cell.getUserData<SimpleLabelCellData>()!;
        return Text(
          data.label,
          textAlign: TextAlign.center,
        );
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    final labels = ref.read(labelMapProvider)[labelKey]!;
    final indices = range(labels.length).map((e) => e.toInt()).toList();
    const sep = "\n";
    if (predicate.rejects.isEmpty) {
      return "Any";
    } else if (predicate.rejects.length >= labels.length / 2) {
      final accepted = indices.where((e) => !predicate.rejects.contains(e));
      return "${"$tr_simple_label.tooltip.accept".tr()}:$sep${accepted.map((e) => labels[e].joinLines(" ")).join(sep)}";
    } else {
      final rejected = indices.where((e) => predicate.rejects.contains(e));
      return "${"$tr_simple_label.tooltip.reject".tr()}:$sep${rejected.map((e) => labels[e].joinLines(" ")).join(sep)}";
    }
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return SimpleLabelColumnSelector(
      specId: id,
      onDecided: onDecided,
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<SimpleLabelColumnSpec>();

class _SimpleLabelSelector extends ConsumerWidget {
  final String specId;

  const _SimpleLabelSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final labels = ref.watch(labelMapProvider)[spec.labelKey]!;
    final indices = range(labels.length).map((e) => e.toInt()).toList();
    final theme = Theme.of(context);
    return FormGroup(
      title: Text("$tr_simple_label.selection.label".tr()),
      description: Text("$tr_simple_label.selection.description".tr()),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final index in indices)
                  FilterChip(
                    label: Text(labels[index].joinLines(" ")),
                    backgroundColor: !spec.predicate.rejects.contains(index) ? null : theme.colorScheme.surfaceVariant,
                    showCheckmark: false,
                    selected: !spec.predicate.rejects.contains(index),
                    onSelected: (selected) {
                      _clonedSpecProvider.update(ref, specId, (spec) {
                        return spec.copyWith(
                          predicate: SimpleLabelPredicate(
                            rejects: Set.from(spec.predicate.rejects)..toggle(index, shouldExists: selected),
                          ),
                        );
                      });
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _NotationSelector({
    required this.specId,
    required this.onDecided,
  });

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
      title: Text("$tr_simple_label.notation.label".tr()),
      description: Text("$tr_simple_label.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_simple_label.notation.title.label".tr()),
          children: [
            DenseTextField(
              initialText: title,
              onChanged: (value) {
                title = value;
              },
            ),
          ],
        ),
      ],
    );
  }
}

class SimpleLabelColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const SimpleLabelColumnSelector({
    Key? key,
    required this.specId,
    required this.onDecided,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _SimpleLabelSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class SimpleLabelColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final String labelKey;
  final Set<int>? rejects;
  final int? tabIdx;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  SimpleLabelColumnBuilder({
    required this.title,
    required this.category,
    required this.labelKey,
    required this.parser,
    this.rejects,
    this.tabIdx,
  }) : type = rejects != null ? ColumnBuilderType.filter : ColumnBuilderType.normal;

  @override
  SimpleLabelColumnSpec build() {
    return SimpleLabelColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      labelKey: labelKey,
      predicate: rejects == null ? SimpleLabelPredicate.any() : SimpleLabelPredicate(rejects: rejects!),
      tabIdx: tabIdx,
    );
  }
}
