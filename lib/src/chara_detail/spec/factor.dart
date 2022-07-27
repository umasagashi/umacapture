import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:quiver/iterables.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/utils.dart';

@jsonSerializable
enum FactorSelection { anyOf, allOf, sumOf }

@jsonSerializable
enum FactorSubject { trainee, family }

@jsonSerializable
class FactorCriteria {
  int star;
  int? count;

  FactorCriteria({required this.star, this.count});
}

class FactorCellData<T> implements Exportable<List<String>> {
  final List<String> factors;
  final T label;

  FactorCellData(this.factors, this.label);

  @override
  List<String> get csv => factors;
}

int _extractStar(List<Factor> factors, Factor query) {
  return factors.firstWhere((e) => e.id == query.id, orElse: () => const Factor(0, 0)).star;
}

List<int> _extractStarSet(FactorSet factorSet, Factor query, bool traineeOnly) {
  return [
    _extractStar(factorSet.self, query),
    if (!traineeOnly) ...[
      _extractStar(factorSet.parent1, query),
      _extractStar(factorSet.parent2, query),
    ],
  ];
}

bool _isSatisfy(List<int> stars, FactorCriteria criteria) {
  if (criteria.count != null) {
    return stars.map((e) => e >= criteria.star).countTrue() >= criteria.count!;
  } else {
    return stars.sum() >= criteria.star;
  }
}

bool _isSumSatisfy(Iterable<List<int>> starSet, FactorCriteria criteria) {
  if (criteria.count != null) {
    return starSet.map((e) => e.sum() >= criteria.star).countTrue() >= criteria.count!;
  } else {
    return starSet.expand((e) => e).sum() >= criteria.star;
  }
}

@jsonSerializable
class AggregateFactorSetPredicate extends Predicate<FactorSet> {
  List<Factor> query;
  FactorSelection selectionMode;
  FactorSubject countMode;
  FactorCriteria criteria;

  AggregateFactorSetPredicate({
    required this.query,
    required this.selectionMode,
    required this.countMode,
    required this.criteria,
  });

  AggregateFactorSetPredicate.any()
      : query = [],
        selectionMode = FactorSelection.allOf,
        countMode = FactorSubject.family,
        criteria = FactorCriteria(star: 0);

  @override
  bool apply(FactorSet value) {
    if (query.isEmpty) {
      return true;
    }
    final starSet = query.map((e) => _extractStarSet(value, e, countMode == FactorSubject.trainee));
    switch (selectionMode) {
      case FactorSelection.anyOf:
        return starSet.any((e) => _isSatisfy(e, criteria));
      case FactorSelection.allOf:
        return starSet.every((e) => _isSatisfy(e, criteria));
      case FactorSelection.sumOf:
        return _isSumSatisfy(starSet, criteria);
    }
  }
}

@jsonSerializable
class FactorColumnSpec extends ColumnSpec<FactorSet> {
  final Parser<FactorSet> parser;
  final String labelKey = "factor.name";
  final AggregateFactorSetPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final String description;

  FactorColumnSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.parser,
    required this.predicate,
  });

  @override
  List<FactorSet> parse(List<CharaDetailRecord> records) {
    return records.map(parser.parse).toList();
  }

  @override
  List<bool> evaluate(List<FactorSet> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(BuildResource resource, FactorSet value) {
    final labels = resource.labelMap[labelKey]!;
    final factorNames = concat([value.self, value.parent1, value.parent2]).map((e) => labels[e.id]).toList();
    final desc = factorNames.partial(0, 3).join(", ");
    return PlutoCellWithUserData.create(
      // Since autoFitColumn is not accurate, reserve few characters larger.
      value: "$desc${"M" * (desc.length * 0.15).toInt()}",
      data: FactorCellData(factorNames, desc),
    );
  }

  @override
  PlutoColumn plutoColumn(BuildResource resource) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.text(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        final data = context.cell.getUserData<FactorCellData>()!;
        return Text(data.label);
      },
    );
  }

  @override
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector({required BuildResource resource, required OnSpecChanged onChanged}) {
    return FactorColumnSelector(spec: this);
  }
}

class FactorColumnSelector extends ConsumerStatefulWidget {
  final FactorColumnSpec spec;

  const FactorColumnSelector({Key? key, required this.spec}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => FactorColumnSelectorState();
}

class FactorColumnSelectorState extends ConsumerState<FactorColumnSelector> {
  @override
  Widget build(BuildContext context) {
    return const Text("Under Construction");
  }
}

class FactorColumnBuilder implements ColumnBuilder {
  final FactorSetParser parser;

  @override
  final String title;

  @override
  final String description;

  @override
  final ColumnCategory category;

  FactorColumnBuilder({
    required this.title,
    required this.description,
    required this.category,
    required this.parser,
  });

  @override
  ColumnSpec<FactorSet> build() {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      description: description,
      parser: parser,
      predicate: AggregateFactorSetPredicate.any(),
    );
  }
}
