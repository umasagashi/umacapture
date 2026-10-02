import 'package:collection/collection.dart';
import 'package:csv/csv.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:recase/recase.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/item_cell.dart';
import '/src/chara_detail/spec/item_display.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

part 'factor.mapper.dart';

// ignore: constant_identifier_names
const tr_factor = "pages.chara_detail.column_predicate.factor";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

@MappableEnum()
enum FactorSetLogicMode { anyOf, allOf, mixed }

@MappableEnum()
enum FactorSearchSubjectMode { trainee, family }

@MappableEnum()
enum FactorSearchElementMode { starOnly, countOnly, starAndCount }

@MappableClass()
class FactorSearchElement with FactorSearchElementMappable {
  final FactorSearchElementMode mode;
  final int star;
  final int count;

  FactorSearchElement({required this.mode, required this.star, required this.count});

  FactorSearchElement copyWith({FactorSearchElementMode? mode, int? star, int? count}) {
    return FactorSearchElement(mode: mode ?? this.mode, star: star ?? this.star, count: count ?? this.count);
  }
}

/// What quantity a factor cell renders: the star rating, or the possession
/// count that ignores the star rating (presence-only).
enum FactorNotationMetric { star, count }

/// How the three lineage slots (self / parent1 / parent2) are laid out: summed
/// into a single number, or shown as separate per-slot segments.
enum FactorNotationGranularity { total, individual }

/// The content shown in a factor cell.
///
/// Decomposes into three orthogonal aspects — [showsName], [metric], and
/// [granularity] — but is stored as a single value so the cell renders from one
/// user choice. [nameOnly] shows just the factor names; its [metric] and
/// [granularity] are irrelevant (defaulted for completeness).
@MappableEnum()
enum FactorNotationMode {
  nameOnly,
  nameStarTotal,
  nameStarEach,
  nameCountTotal,
  nameCountEach,
  starTotal,
  starEach,
  countTotal,
  countEach,
}

extension FactorNotationModeProperties on FactorNotationMode {
  /// Whether the factor name is rendered before the value.
  bool get showsName {
    switch (this) {
      case FactorNotationMode.nameOnly:
      case FactorNotationMode.nameStarTotal:
      case FactorNotationMode.nameStarEach:
      case FactorNotationMode.nameCountTotal:
      case FactorNotationMode.nameCountEach:
        return true;
      case FactorNotationMode.starTotal:
      case FactorNotationMode.starEach:
      case FactorNotationMode.countTotal:
      case FactorNotationMode.countEach:
        return false;
    }
  }

  /// This mode if it shows the name, otherwise the named mode with the same
  /// [metric] and [granularity]. A highlighted item needs its name drawn.
  FactorNotationMode get named {
    if (showsName) {
      return this;
    }
    return switch ((metric, granularity)) {
      (FactorNotationMetric.star, FactorNotationGranularity.total) => FactorNotationMode.nameStarTotal,
      (FactorNotationMetric.star, FactorNotationGranularity.individual) => FactorNotationMode.nameStarEach,
      (FactorNotationMetric.count, FactorNotationGranularity.total) => FactorNotationMode.nameCountTotal,
      (FactorNotationMetric.count, FactorNotationGranularity.individual) => FactorNotationMode.nameCountEach,
    };
  }

  /// Whether a value (as opposed to only the name) is rendered.
  bool get showsValue => this != FactorNotationMode.nameOnly;

  FactorNotationMetric get metric {
    switch (this) {
      case FactorNotationMode.nameCountTotal:
      case FactorNotationMode.nameCountEach:
      case FactorNotationMode.countTotal:
      case FactorNotationMode.countEach:
        return FactorNotationMetric.count;
      case FactorNotationMode.nameOnly:
      case FactorNotationMode.nameStarTotal:
      case FactorNotationMode.nameStarEach:
      case FactorNotationMode.starTotal:
      case FactorNotationMode.starEach:
        return FactorNotationMetric.star;
    }
  }

  FactorNotationGranularity get granularity {
    switch (this) {
      case FactorNotationMode.nameStarEach:
      case FactorNotationMode.nameCountEach:
      case FactorNotationMode.starEach:
      case FactorNotationMode.countEach:
        return FactorNotationGranularity.individual;
      case FactorNotationMode.nameOnly:
      case FactorNotationMode.nameStarTotal:
      case FactorNotationMode.nameCountTotal:
      case FactorNotationMode.starTotal:
      case FactorNotationMode.countTotal:
        return FactorNotationGranularity.total;
    }
  }
}

@MappableClass()
class FactorNotation with FactorNotationMappable {
  final FactorNotationMode mode;

  FactorNotation({required this.mode});

  FactorNotation copyWith({FactorNotationMode? mode}) {
    return FactorNotation(mode: mode ?? this.mode);
  }
}

class QueriedFactor {
  final int id;
  final int self;
  final int parent1;
  final int parent2;

  bool get isEmpty => self == 0 && parent1 == 0 && parent2 == 0;

  int count({int min = 0}) {
    return (self >= min ? 1 : 0) + (parent1 >= min ? 1 : 0) + (parent2 >= min ? 1 : 0);
  }

  int sum() {
    return self + parent1 + parent2;
  }

  QueriedFactor({required this.id, required this.self, required this.parent1, required this.parent2});

  static List<QueriedFactor> extract(Iterable<int> targetIds, FactorSet factorSet, bool traineeOnly) {
    assert(targetIds.isNotEmpty);
    return targetIds.map((id) {
      return QueriedFactor(
        id: id,
        self: factorSet.self.firstWhereOrNull((e) => e.id == id)?.star ?? 0,
        parent1: traineeOnly ? 0 : factorSet.parent1.firstWhereOrNull((e) => e.id == id)?.star ?? 0,
        parent2: traineeOnly ? 0 : factorSet.parent2.firstWhereOrNull((e) => e.id == id)?.star ?? 0,
      );
    }).toList();
  }

  /// Renders the value of a single factor (this one) for the given [metric] and
  /// [granularity]. Shorthand for [notationOf] over `[this]`.
  String notation(FactorNotationMetric metric, FactorNotationGranularity granularity, {int width = 1}) {
    return notationOf([this], metric, granularity, width: width);
  }

  /// Per-slot value of a factor under [metric]: the raw star for `star`, or a
  /// presence flag (1 when the slot holds the factor, else 0) for `count`.
  static int _slotValue(int star, FactorNotationMetric metric) {
    return metric == FactorNotationMetric.count ? (star >= 1 ? 1 : 0) : star;
  }

  /// Renders the aggregate value of [factors] for the given [metric] and
  /// [granularity].
  ///
  /// Each slot is summed across [factors] using [_slotValue], so `count` is
  /// evaluated per factor before summing (summing stars first and thresholding
  /// afterwards would miscount factors that share a slot). With
  /// [FactorNotationGranularity.total] the three slots collapse to one segment;
  /// with [FactorNotationGranularity.individual] they stay as self / parent1 /
  /// parent2.
  static String notationOf(
    List<QueriedFactor> factors,
    FactorNotationMetric metric,
    FactorNotationGranularity granularity, {
    int width = 1,
  }) {
    final self = factors.map((e) => _slotValue(e.self, metric)).sum;
    final parent1 = factors.map((e) => _slotValue(e.parent1, metric)).sum;
    final parent2 = factors.map((e) => _slotValue(e.parent2, metric)).sum;
    final segments = switch (granularity) {
      FactorNotationGranularity.total => [self + parent1 + parent2],
      FactorNotationGranularity.individual => [self, parent1, parent2],
    };
    return segments.map((e) => e.toString().padLeft(width, "0")).join("/");
  }
}

@MappableClass()
class AggregateFactorSetPredicate with AggregateFactorSetPredicateMappable {
  final Set<int> query;
  final FactorSetLogicMode logic;
  final FactorSearchSubjectMode subject;
  final FactorSearchElement element;
  final FactorNotation notation;
  final Set<String> factorTags;
  final Set<String> skillTags;

  /// Whether the count-based element modes ([FactorSearchElementMode.countOnly]
  /// and [FactorSearchElementMode.starAndCount]) are selectable. Counting only
  /// exceeds one when there are multiple slots (family) or multiple factors
  /// (mixed), so a single-factor trainee search is restricted to star sum.
  bool get isCountModeAllowed {
    return logic == FactorSetLogicMode.mixed || subject == FactorSearchSubjectMode.family;
  }

  int get starMaxLimit {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return 3;
    } else {
      final maxPerFactor = subject == FactorSearchSubjectMode.trainee ? 3 : 9;
      return logic == FactorSetLogicMode.mixed ? Math.max(1, query.length) * maxPerFactor : maxPerFactor;
    }
  }

  int get countMaxLimit {
    if (element.mode == FactorSearchElementMode.starOnly) {
      return 1;
    } else {
      final maxPerFactor = subject == FactorSearchSubjectMode.trainee ? 1 : 3;
      return logic == FactorSetLogicMode.mixed ? Math.max(1, query.length) * maxPerFactor : maxPerFactor;
    }
  }

  AggregateFactorSetPredicate({
    this.query = const {},
    this.logic = FactorSetLogicMode.anyOf,
    this.subject = FactorSearchSubjectMode.family,
    required this.element,
    required this.notation,
    this.factorTags = const {},
    this.skillTags = const {},
  });

  AggregateFactorSetPredicate.any()
    : query = {},
      logic = FactorSetLogicMode.anyOf,
      subject = FactorSearchSubjectMode.family,
      element = FactorSearchElement(mode: FactorSearchElementMode.starOnly, star: 1, count: 1),
      notation = FactorNotation(mode: FactorNotationMode.nameStarTotal),
      factorTags = {},
      skillTags = {};

  AggregateFactorSetPredicate checked() {
    return AggregateFactorSetPredicate(
      query: query,
      logic: logic,
      subject: subject,
      element: isCountModeAllowed ? element : element.copyWith(mode: FactorSearchElementMode.starOnly),
      notation: notation,
      factorTags: factorTags,
      skillTags: skillTags,
    );
  }

  AggregateFactorSetPredicate copyWith({
    Set<int>? query,
    FactorSetLogicMode? logic,
    FactorSearchSubjectMode? subject,
    FactorSearchElement? element,
    FactorNotation? notation,
    Set<String>? factorTags,
    Set<String>? skillTags,
  }) {
    return AggregateFactorSetPredicate(
      query: query ?? this.query,
      logic: logic ?? this.logic,
      subject: subject ?? this.subject,
      element: element ?? this.element,
      notation: notation ?? this.notation,
      factorTags: factorTags ?? this.factorTags,
      skillTags: skillTags ?? this.skillTags,
    ).checked();
  }

  /// Whether one factor passes the per-factor threshold of [element]: the test
  /// [apply] runs per factor under anyOf / allOf, and a column that marks missing
  /// factors runs to mark a held factor short.
  bool acceptsItem(QueriedFactor factor) {
    switch (element.mode) {
      case FactorSearchElementMode.starOnly:
        return factor.sum() >= element.star;
      case FactorSearchElementMode.countOnly:
        return factor.count(min: 1) >= element.count;
      case FactorSearchElementMode.starAndCount:
        return factor.count(min: element.star) >= element.count;
    }
  }

  bool _isMixedAcceptable(List<QueriedFactor> factors) {
    switch (element.mode) {
      case FactorSearchElementMode.starOnly:
        return factors.map((e) => e.sum()).sum >= element.star;
      case FactorSearchElementMode.countOnly:
        return factors.map((e) => e.count(min: 1)).sum >= element.count;
      case FactorSearchElementMode.starAndCount:
        return factors.map((e) => e.count(min: element.star)).sum >= element.count;
    }
  }

  bool apply(FactorSet value) {
    if (query.isEmpty) {
      return true;
    }
    final foundFactors = QueriedFactor.extract(query, value, subject == FactorSearchSubjectMode.trainee);
    switch (logic) {
      case FactorSetLogicMode.anyOf:
        return foundFactors.any((e) => acceptsItem(e));
      case FactorSetLogicMode.allOf:
        return foundFactors.every((e) => acceptsItem(e));
      case FactorSetLogicMode.mixed:
        return _isMixedAcceptable(foundFactors);
    }
  }
}

@MappableEnum()
enum FactorDialogElements { selectionList, selectionTags, modeLogic }

/// Capability of a column whose items are factors: the factor selection (hand-picked or by tag, on the factor
/// and the linked skill axes), its resolution against the current factor master, the comparison scope
/// ([subject]), the factors a record holds within them, and the text a factor is drawn with.
mixin FactorItemsColumnSpec on ItemColumnSpec<FactorSet> {
  /// The hand-picked factors. Ignored while [selectByTag].
  Set<int> get selectedFactorIds;

  /// The factor tags that, with [skillTags], define the selection while [selectByTag].
  Set<String> get factorTags;

  /// The tags the factor's linked skill must carry while [selectByTag].
  Set<String> get skillTags;

  /// When true, the selection is defined by [factorTags] and [skillTags] rather than [selectedFactorIds]: it is
  /// resolved live against the current factor master, so newly tagged factors are included automatically.
  bool get selectByTag;

  bool get showAvailableOnly;

  /// Whether an empty selection shows every factor a record holds, rather than none.
  bool get showAllWhenQueryIsEmpty;

  Set<FactorDialogElements> get hiddenElements;

  /// Whose factors are compared: the trainee's alone, or the whole family.
  FactorSearchSubjectMode get subject;

  String get labelKey;

  /// This column with its hand-picked factors or either tag axis replaced.
  FactorItemsColumnSpec withFactorSelection({Set<int>? ids, Set<String>? factorTags, Set<String>? skillTags});

  FactorItemsColumnSpec withSubject(FactorSearchSubjectMode subject);

  /// The selected factor ids: the two tag axes resolved against the current factor master while [selectByTag],
  /// the hand-picked ones otherwise.
  Set<int> resolvedFactorIds(RefBase ref) {
    if (!selectByTag) {
      return selectedFactorIds;
    }
    return ref.read(_factorTagQueryProvider(_factorTagsKey(factorTags, skillTags)));
  }

  /// The factors [factorSet] holds within the subject: the selected ones, or for an empty selection every factor
  /// of the three slots when [showAllWhenQueryIsEmpty].
  ///
  /// Under the trainee subject a factor only a parent holds extracts as an all-zero entry; it is not held, so it
  /// is dropped here, for every display alike.
  List<QueriedFactor> heldFactors(RefBase ref, FactorSet factorSet) {
    final query = resolvedFactorIds(ref);
    final traineeOnly = subject == FactorSearchSubjectMode.trainee;
    if (query.isEmpty && !showAllWhenQueryIsEmpty) {
      return [];
    }
    final ids = query.isNotEmpty ? query : factorSet.uniqueIds;
    return QueriedFactor.extract(ids, factorSet, traineeOnly).where((e) => !e.isEmpty).toList();
  }

  /// The order the cell lists factors in: the selection's order first, then the master's.
  ItemOrder itemOrder(RefBase ref) =>
      ItemOrder(query: resolvedFactorIds(ref), masterRank: ref.watch(factorMasterRankProvider));

  /// The text of [factor] named [name] in [mode]: the name, followed by the value when [mode] shows one.
  static String itemText(QueriedFactor factor, String name, FactorNotationMode mode) =>
      mode.showsValue ? "$name(${factor.notation(mode.metric, mode.granularity)})" : name;

  /// The text of a factor a record lacks: drawn in [mode] with every slot 0, so that it takes the shape of a held
  /// factor.
  String placeholderText(RefBase ref, int id, FactorNotationMode mode) {
    final name = ref.watch(labelMapProvider)[labelKey]!.getOrNull(id) ?? id.toString();
    return itemText(QueriedFactor(id: id, self: 0, parent1: 0, parent2: 0), name, mode);
  }

  @override
  @override
  Map<int, int> heldItemStrengths(RefBase ref, FactorSet value) => {
    for (final factor in heldFactors(ref, value)) factor.id: factor.sum(),
  };
}

@MappableClass(discriminatorValue: 'FactorColumnSpec', ignoreNull: true)
class FactorColumnSpec extends ColumnSpec<FactorSet>
    with FactorColumnSpecMappable, ItemColumnSpec<FactorSet>, FactorItemsColumnSpec, QueryItemColumnSpec<FactorSet> {
  final Parser parser;
  @override
  final String labelKey = LabelKeys.factor;
  final AggregateFactorSetPredicate predicate;

  @override
  final bool showAllWhenQueryIsEmpty;
  @override
  final bool showAvailableOnly;
  @override
  final Set<FactorDialogElements> hiddenElements;

  /// When true, the column is defined by its tags rather than hand-picked factors:
  /// the query is resolved live from `predicate.factorTags`/`skillTags` against the
  /// current factor master at evaluation time (so newly tagged factors are included
  /// automatically), and the individual factor list is hidden in the dialog.
  @override
  final bool selectByTag;

  @override
  Set<int> get selectedFactorIds => predicate.query;

  @override
  Set<String> get factorTags => predicate.factorTags;

  @override
  Set<String> get skillTags => predicate.skillTags;

  @override
  FactorSearchSubjectMode get subject => predicate.subject;

  @override
  FactorColumnSpec withFactorSelection({Set<int>? ids, Set<String>? factorTags, Set<String>? skillTags}) => copyWith(
    predicate: predicate.copyWith(query: ids, factorTags: factorTags, skillTags: skillTags),
  );

  // The predicate's copyWith re-checks the element mode against the new subject.
  @override
  FactorColumnSpec withSubject(FactorSearchSubjectMode subject) =>
      copyWith(predicate: predicate.copyWith(subject: subject));

  @override
  final UnmetRows unmetRows;

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

  @override
  final String? builderId;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openFactorPreview;

  FactorColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    this.showAllWhenQueryIsEmpty = true,
    this.showAvailableOnly = true,
    this.hiddenElements = const {},
    this.selectByTag = false,
    this.unmetRows = UnmetRows.filterOut,
    this.hidden = false,
    this.description,
    this.width,
    this.builderId,
  });

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: selectByTag);

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  bool get offersMarkMissing => !selectByTag;

  @override
  FactorColumnSpec withUnmetRows(UnmetRows value) => copyWith(unmetRows: value);

  /// Whether the threshold (the element mode and the lower bounds) is judged per factor rather than against the
  /// query as a whole, as it is under mixed.
  bool get judgesEachItem => predicate.logic != FactorSetLogicMode.mixed;

  /// Whether a marked cell judges each factor against the threshold. Under mixed the threshold applies to the query
  /// as a whole, so no single factor is short of it; an empty query accepts every record, so no factor is short of
  /// it either.
  bool get marksShortItems => predicate.query.isNotEmpty && judgesEachItem;

  /// Whether the element mode and the lower bounds apply: while marking missing factors they decide which factors
  /// are short, which only [marksShortItems] does.
  bool get usesPerItemThreshold => !marksMissing || marksShortItems;

  @override
  bool get hasFilter => true;

  @override
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) =>
      (defaultSpec is FactorColumnSpec
              // Keep selectByTag consistent with the adopted predicate (see SkillColumnSpec).
              ? copyWith(predicate: defaultSpec.predicate, selectByTag: defaultSpec.selectByTag)
              : copyWith(predicate: AggregateFactorSetPredicate.any(), selectByTag: false))
          ._withOfferedUnmetRows();

  // Falls back to filtering when the reset landed on a column that no longer offers
  // marking (a tag-driven column).
  FactorColumnSpec _withOfferedUnmetRows() =>
      !offersMarkMissing && marksMissing ? copyWith(unmetRows: UnmetRows.filterOut) : this;

  FactorColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateFactorSetPredicate? predicate,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableOnly,
    Set<FactorDialogElements>? hiddenElements,
    bool? selectByTag,
    UnmetRows? unmetRows,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
    String? builderId,
  }) {
    return FactorColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      showAllWhenQueryIsEmpty: showAllWhenQueryIsEmpty ?? this.showAllWhenQueryIsEmpty,
      showAvailableOnly: showAvailableOnly ?? this.showAvailableOnly,
      hiddenElements: hiddenElements ?? this.hiddenElements,
      selectByTag: selectByTag ?? this.selectByTag,
      unmetRows: unmetRows ?? this.unmetRows,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
      builderId: builderId ?? this.builderId,
    );
  }

  @override
  List<FactorSet> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<FactorSet>.from(records.map(parser.parse));
  }

  /// The predicate to evaluate/render with. For a tag-driven column ([selectByTag]),
  /// the query is resolved live from the current factor master so newly tagged
  /// factors are picked up automatically; otherwise the stored predicate is used.
  AggregateFactorSetPredicate _resolved(RefBase ref) {
    if (!selectByTag) {
      return predicate;
    }
    return predicate.copyWith(query: resolvedFactorIds(ref));
  }

  @override
  List<bool> evaluate(RefBase ref, List<FactorSet> values) {
    final resolved = _resolved(ref);
    if (selectByTag && resolved.query.isEmpty && (predicate.factorTags.isNotEmpty || predicate.skillTags.isNotEmpty)) {
      // Tags are selected but resolve to no factor in the current master (e.g. the
      // "gold skill" tag, which has no inheritable factor): nothing can match, so
      // every row is filtered out instead of falling through to apply()'s
      // empty-query "Any".
      return List<bool>.filled(values.length, false);
    }
    return values.map((e) => resolved.apply(e)).toList();
  }

  @override
  bool get notatesValueOnly => !predicate.notation.mode.showsName;

  @override
  TrinaCell plutoCell(RefBase ref, FactorSet value) {
    final predicate = _resolved(ref);
    final mode = predicate.notation.mode;
    final order = itemOrder(ref);
    final factors = order.sort(heldFactors(ref, value), (e) => e.id);

    // Value-only modes render a single aggregate value across all factors, with
    // no factor names.
    if (notatesValueOnly) {
      final display = QueriedFactor.notationOf(factors, mode.metric, mode.granularity, width: 3);
      final summary = "(${QueriedFactor.notationOf(factors, mode.metric, mode.granularity)})";
      if (drawsSummary) {
        return TrinaCell(value: display)..setUserData(ItemCellData(items: const [], summary: summary, csv: summary));
      }
      // While marking missing factors they are drawn named, since a red mark belongs to an item; the value
      // (sorting) and the CSV stay those of the value-only notation.
      return TrinaCell(value: display)..setUserData(_markedCell(ref, predicate, order, value, csv: summary));
    }

    final labels = ref.watch(labelMapProvider)[labelKey]!;
    // A factor id beyond a lagging module label list would throw out of plutoCell into _buildGrid and
    // blank every column; degrade to the raw id for that cell instead.
    final notations = factors
        .map((q) => FactorItemsColumnSpec.itemText(q, labels.getOrNull(q.id) ?? q.id.toString(), mode))
        .toList();
    final desc = notations.join(", ");
    final csv = const CsvEncoder().convert([notations]);
    final data = marksMissing
        ? _markedCell(ref, predicate, order, value, csv: csv)
        : ItemCellData.listing(
            [for (final text in notations) CellItem(text, ItemState.normal)],
            hideCommon: false,
            csv: csv,
          );
    return TrinaCell(value: desc)..setUserData(data);
  }

  /// A cell that marks the missing factors: the factors held within the subject, drawn in the named counterpart
  /// of the stored notation, and the placeholders of the queried factors the record lacks, drawn in the same
  /// notation with every slot 0 so that a placeholder takes the shape of a held factor.
  ItemCellData _markedCell(
    RefBase ref,
    AggregateFactorSetPredicate predicate,
    ItemOrder order,
    FactorSet factorSet, {
    required String csv,
  }) {
    final labels = ref.watch(labelMapProvider)[labelKey]!;
    String nameOf(int id) => labels.getOrNull(id) ?? id.toString();
    final mode = predicate.notation.mode.named;
    String placeholderOf(int id) => placeholderText(ref, id, mode);
    final perItemThreshold = marksShortItems;
    final own = [
      for (final factor in heldFactors(ref, factorSet))
        OwnItem(
          factor.id,
          FactorItemsColumnSpec.itemText(factor, nameOf(factor.id), mode),
          meetsQuery: !perItemThreshold || predicate.acceptsItem(factor),
          strength: factor.sum(),
        ),
    ];
    final items = missingMarkedItems(own, predicate.query, placeholderOf, order, perItemThreshold: perItemThreshold);
    return ItemCellData.listing(items, hideCommon: false, csv: csv);
  }

  @override
  String tooltip(RefBase ref) {
    final predicate = _resolved(ref);
    if (predicate.query.isEmpty) {
      return "Any";
    }

    const sep = "\n";
    String modeText = "$sep${"-" * 10}";

    if (predicate.query.length >= 2) {
      final selection = "$tr_factor.mode.logic.${predicate.logic.name.snakeCase}.label".tr();
      modeText += "$sep${"$tr_factor.mode.logic.label".tr()}: $selection";
    }

    final subject = "$tr_factor.mode.subject.${predicate.subject.name.snakeCase}.label".tr();
    modeText += "$sep${"$tr_factor.mode.subject.label".tr()}: $subject";

    // While marking missing factors under mixed, the element mode and the lower bounds are not used, so their
    // lines are left out.
    if (!usesPerItemThreshold) {
      return "${_queryNames(ref, predicate)}$modeText";
    }

    if (predicate.query.length >= 2) {
      final count = "$tr_factor.mode.element.${predicate.element.mode.name.snakeCase}.label".tr();
      modeText += "$sep${"$tr_factor.mode.element.label".tr()}: $count";
    }

    if (predicate.element.mode != FactorSearchElementMode.countOnly) {
      modeText += "$sep${"$tr_factor.mode.element.value.star.label".tr()}: ${predicate.element.star}";
    }

    if (predicate.element.mode != FactorSearchElementMode.starOnly) {
      modeText += "$sep${"$tr_factor.mode.element.value.count.label".tr()}: ${predicate.element.count}";
    }

    return "${_queryNames(ref, predicate)}$modeText";
  }

  /// The queried factors' names, one per line, cut after 30 with a count of the rest.
  String _queryNames(RefBase ref, AggregateFactorSetPredicate predicate) {
    const sep = "\n";
    final labels = ref.watch(labelMapProvider)[labelKey]!;
    final names = predicate.query.map((e) => labels.getOrNull(e) ?? e.toString()).toList();
    const limit = 30;
    final ellipsis = names.length > limit ? "$sep- ${names.length - limit} more" : "";
    return "${names.partial(0, limit).join(sep)}$ellipsis";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return FactorColumnSelector(specId: id, onDecided: onDecided);
  }
}

// Canonical, order-independent key for the two tag axes so the family provider
// below caches by content (a Set's `==` is identity, not value equality). Tag ids
// are snake_case identifiers ([a-z0-9_]+), so the comma/semicolon separators can
// never collide.
String _factorTagsKey(Set<String> factorTags, Set<String> skillTags) {
  final f = (factorTags.toList()..sort()).join(',');
  final s = (skillTags.toList()..sort()).join(',');
  return '$f;$s';
}

// Resolves the two tag axes to the sids of every factor in the current master that
// carries all selected factor tags and whose skill carries all selected skill tags
// (AND). Memoized per tag-key and recomputed when [factorInfoProvider] changes, so a
// tag-driven column automatically follows game-data updates.
final _factorTagQueryProvider = Provider.family<Set<int>, String>((ref, key) {
  final parts = key.split(';');
  final factorTags = parts[0].isEmpty ? <String>{} : parts[0].split(',').toSet();
  final skillTags = parts.length < 2 || parts[1].isEmpty ? <String>{} : parts[1].split(',').toSet();
  if (factorTags.isEmpty && skillTags.isEmpty) {
    return const <int>{};
  }
  return ref
      .watch(factorInfoProvider)
      .where((e) {
        final factorContains = e.tags.containsAll(factorTags);
        final skillContains = e.skillInfo?.tags.containsAll(skillTags) ?? skillTags.isEmpty;
        return factorContains && skillContains;
      })
      .map((e) => e.sid)
      .toSet();
});

final _clonedSpecProvider = SpecProviderAccessor<FactorColumnSpec>();
final _selectionSpecProvider = SpecProviderAccessor<FactorItemsColumnSpec>();

class _SelectedSkillTags extends TagSelectionNotifier {
  _SelectedSkillTags(this.specId);

  final String specId;

  @override
  Set<String> build() {
    final spec = ref.read(specCloneProvider(specId)) as FactorItemsColumnSpec;
    return Set.from(spec.skillTags);
  }

  @override
  void toggle(String tag, {bool? shouldExists}) {
    super.toggle(tag, shouldExists: shouldExists);
    final spec = ref.read(specCloneProvider(specId)) as FactorItemsColumnSpec;
    if (!spec.selectByTag) {
      return;
    }
    // Tag-driven column: persist the chosen skill tags into the spec. The query is
    // not stored — it is resolved live from the tags at evaluation time (see
    // [_resolved]). Only this axis is touched; the factor axis keeps its value.
    ref
        .read(specCloneProvider(specId).notifier)
        .update((s) => (s as FactorItemsColumnSpec).withFactorSelection(skillTags: state));
  }
}

final _selectedSkillTagsProvider = NotifierProvider.autoDispose.family<TagSelectionNotifier, Set<String>, String>(
  _SelectedSkillTags.new,
);

class _SelectedFactorTags extends TagSelectionNotifier {
  _SelectedFactorTags(this.specId);

  final String specId;

  @override
  Set<String> build() {
    final spec = ref.read(specCloneProvider(specId)) as FactorItemsColumnSpec;
    return Set.from(spec.factorTags);
  }

  @override
  void toggle(String tag, {bool? shouldExists}) {
    super.toggle(tag, shouldExists: shouldExists);
    final spec = ref.read(specCloneProvider(specId)) as FactorItemsColumnSpec;
    if (!spec.selectByTag) {
      return;
    }
    // Tag-driven column: persist the chosen factor tags into the spec. The query is
    // not stored — it is resolved live from the tags at evaluation time (see
    // [_resolved]). Only this axis is touched; the skill axis keeps its value.
    ref
        .read(specCloneProvider(specId).notifier)
        .update((s) => (s as FactorItemsColumnSpec).withFactorSelection(factorTags: state));
  }
}

final _selectedFactorTagsProvider = NotifierProvider.autoDispose.family<TagSelectionNotifier, Set<String>, String>(
  _SelectedFactorTags.new,
);

/// The factor selection group of a column's dialog: the factor and skill tag chips and, unless hidden, the
/// individual factor list. Reads and writes the column only through [FactorItemsColumnSpec].
class FactorSelectionGroup extends ConsumerStatefulWidget {
  final String specId;

  const FactorSelectionGroup({super.key, required this.specId});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FactorSelectionGroupState();
}

class _FactorSelectionGroupState extends ConsumerState<FactorSelectionGroup> {
  String textQuery = "";

  List<FactorInfo> _watchCandidateFactors(String specId) {
    final spec = _selectionSpecProvider.watch(ref, specId);
    final info = ref.watch(spec.showAvailableOnly ? availableFactorInfoProvider : factorInfoProvider);
    final selectedFactorTags = ref.watch(_selectedFactorTagsProvider(specId)).toSet();
    final selectedSkillTags = ref.watch(_selectedSkillTagsProvider(specId)).toSet();
    final normalizedQuery = textQuery.toLowerCase().trim();
    if (selectedFactorTags.isEmpty && selectedSkillTags.isEmpty && normalizedQuery.isEmpty) {
      return info;
    }
    return info.where((factor) {
      final factorContains = factor.tags.containsAll(selectedFactorTags);
      final skillContains = factor.skillInfo?.tags.containsAll(selectedSkillTags) ?? selectedSkillTags.isEmpty;
      final queryContains = factor.names.any((name) => name.toLowerCase().contains(normalizedQuery));
      return factorContains && skillContains && queryContains;
    }).toList();
  }

  Widget tagsWidget() {
    final selectors = [
      TagSelector(
        candidateTagsProvider: factorTagProvider,
        selectedTagsProvider: _selectedFactorTagsProvider(widget.specId),
      ),
      Row(
        children: [
          const Expanded(child: Divider()),
          Padding(padding: const EdgeInsets.all(8), child: Text("$tr_factor.selection.tags.skill_tags.label".tr())),
          const Expanded(child: Divider()),
        ],
      ),
      TagSelector(
        candidateTagsProvider: skillTagProvider,
        selectedTagsProvider: _selectedSkillTagsProvider(widget.specId),
      ),
    ];
    // A tag-driven column shows the chips without the NoteCard frame, and its tags
    // define the column (so a dedicated description); a normal column keeps them
    // inside the bordered note alongside the individual factor list.
    if (_selectionSpecProvider.watch(ref, widget.specId).selectByTag) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text("$tr_factor.selection.tags.tag_driven_description".tr()),
            ),
            const SizedBox(height: 12),
            ...selectors,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: NoteCard(description: Text("$tr_factor.selection.tags.description".tr()), children: selectors),
    );
  }

  Widget selectorWidget(BuildContext context) {
    final selected = _selectionSpecProvider.watch(ref, widget.specId).selectedFactorIds.toSet();
    final candidates = _watchCandidateFactors(widget.specId);
    return SelectorWidget<FactorInfo>(
      description: Text("$tr_factor.selection.description".tr()),
      candidates: candidates,
      selected: selected,
      onSelected: (newSelected) {
        _selectionSpecProvider.update(ref, widget.specId, (spec) => spec.withFactorSelection(ids: newSelected));
      },
      onTextQueryChanged: (query) => setState(() => textQuery = query),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = _selectionSpecProvider.watch(ref, widget.specId);
    return FormGroup(
      title: Text("$tr_factor.selection.label".tr()),
      children: [
        if (!spec.hiddenElements.contains(FactorDialogElements.selectionTags)) tagsWidget(),
        if (!spec.hiddenElements.contains(FactorDialogElements.selectionList)) selectorWidget(context),
      ],
    );
  }
}

/// The choice of whose factors a column compares ([FactorItemsColumnSpec.subject]).
class FactorSubjectChoice extends ConsumerWidget {
  final String specId;

  const FactorSubjectChoice({super.key, required this.specId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ChoiceFormLine<FactorSearchSubjectMode>(
      title: Text("$tr_factor.mode.subject.label".tr()),
      description: Text("$tr_factor.mode.subject.description".tr()),
      prefix: "$tr_factor.mode.subject",
      tooltip: false,
      values: FactorSearchSubjectMode.values,
      selected: _selectionSpecProvider.watch(ref, specId).subject,
      onSelected: (value) => _selectionSpecProvider.update(ref, specId, (spec) => spec.withSubject(value)),
    );
  }
}

class _ModeSelector extends ConsumerWidget {
  final String specId;

  const _ModeSelector({required this.specId});

  Widget descriptionWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    final selection = "$tr_factor.mode.logic.${predicate.logic.name.snakeCase}.description".tr();
    final subject = "$tr_factor.mode.subject.${predicate.subject.name.snakeCase}.description".tr();
    final count = "$tr_factor.mode.element.${predicate.element.mode.name.snakeCase}.description".tr(
      namedArgs: {"star": predicate.element.star.toString(), "count": predicate.element.count.toString()},
    );
    return NoteCard(
      description: Text(
        "$tr_factor.mode.template".tr(namedArgs: {"selection": selection, "subject": subject, "count": count}),
      ),
    );
  }

  Widget logicChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<FactorSetLogicMode>(
      title: Text("$tr_factor.mode.logic.label".tr()),
      description: Text("$tr_factor.mode.logic.description".tr()),
      prefix: "$tr_factor.mode.logic",
      tooltip: false,
      values: FactorSetLogicMode.values,
      selected: predicate.logic,
      disabled: predicate.query.length <= 1 ? FactorSetLogicMode.values.toSet() : null,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(predicate: spec.predicate.copyWith(logic: value));
        });
      },
    );
  }

  Widget elementChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<FactorSearchElementMode>(
      title: Text("$tr_factor.mode.element.label".tr()),
      description: Text("$tr_factor.mode.element.description".tr()),
      prefix: "$tr_factor.mode.element",
      tooltip: false,
      values: FactorSearchElementMode.values,
      selected: predicate.element.mode,
      disabled: predicate.isCountModeAllowed
          ? const {}
          : {FactorSearchElementMode.countOnly, FactorSearchElementMode.starAndCount},
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(mode: value)),
          );
        });
      },
    );
  }

  Widget elementStarWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormTile(
      title: Text("$tr_factor.mode.element.value.star.label".tr()),
      description: Text("$tr_factor.mode.element.value.star.description".tr()),
      trailing: Disabled(
        disabled: predicate.element.mode == FactorSearchElementMode.countOnly,
        tooltip: "$tr_factor.mode.element.value.star.disabled_tooltip".tr(),
        child: IntStepperField(
          min: 0,
          max: predicate.starMaxLimit,
          value: predicate.element.star,
          onChanged: (value) {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(star: value)),
              );
            });
          },
        ),
      ),
    );
  }

  Widget elementCountWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormTile(
      title: Text("$tr_factor.mode.element.value.count.label".tr()),
      description: Text("$tr_factor.mode.element.value.count.description".tr()),
      trailing: Disabled(
        disabled: predicate.element.mode == FactorSearchElementMode.starOnly,
        tooltip: "$tr_factor.mode.element.value.count.disabled_tooltip".tr(),
        child: IntStepperField(
          min: 0,
          max: predicate.countMaxLimit,
          value: predicate.element.count,
          onChanged: (value) {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(count: value)),
              );
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_common.condition.label".tr()),
      description: descriptionWidget(context, ref),
      children: [
        if (!spec.hiddenElements.contains(FactorDialogElements.modeLogic)) logicChoiceWidget(context, ref),
        FactorSubjectChoice(specId: specId),
        UnusedWhileMarking(
          unused: !spec.usesPerItemThreshold,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              elementChoiceWidget(context, ref),
              elementStarWidget(context, ref),
              elementCountWidget(context, ref),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _NotationSelector({required this.specId, required this.onDecided});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;
  late final VoidCallback _commitTitle;

  @override
  void initState() {
    super.initState();
    title = _clonedSpecProvider.read(ref, widget.specId).title;
    _commitTitle = () {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });
    };
    widget.onDecided.addListener(_commitTitle);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitTitle);
    super.dispose();
  }

  /// Whether the column marks missing factors, which names every factor whatever notation mode is stored.
  bool _namesItems(WidgetRef ref) => _clonedSpecProvider.watch(ref, widget.specId).marksMissing;

  Widget notationChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return ChoiceFormLine<FactorNotationMode>(
      title: Text("$tr_factor.notation.mode.label".tr()),
      description: Text("$tr_factor.notation.mode.description".tr()),
      prefix: "$tr_factor.notation.mode",
      values: FactorNotationMode.values,
      selected: predicate.notation.mode,
      disabled: _namesItems(ref) ? FactorNotationMode.values.where((e) => !e.showsName).toSet() : null,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, widget.specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(notation: spec.predicate.notation.copyWith(mode: value)),
          );
        });
      },
    );
  }

  Widget notationTitleWidget(WidgetRef ref) {
    return FormTile(
      title: Text("$tr_common.notation.title.label".tr()),
      description: Text("$tr_common.notation.title.description".tr()),
      trailing: DenseTextField(
        initialText: title,
        minWidth: 140,
        onChanged: (value) {
          title = value;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_common.notation.label".tr()),
      description: Text("$tr_common.notation.description".tr()),
      children: [
        notationChoiceWidget(context, ref),
        notationTitleWidget(ref),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class FactorColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const FactorColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        FactorSelectionGroup(specId: specId),
        const SizedBox(height: 32),
        _ModeSelector(specId: specId),
        const SizedBox(height: 32),
        UnmetRowsGroup(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class FactorColumnBuilder extends ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  FactorColumnBuilder({required this.title, required this.category, required this.parser});

  /// Whether the columns this builder creates select their factors by tag. [typeDescription] and [build] both read it,
  /// so the description always matches the column that gets built.
  static const _selectByTag = false;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: _selectByTag);

  @override
  ColumnSpec<FactorSet> build(RefBase ref) {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: AggregateFactorSetPredicate.any(),
      selectByTag: _selectByTag,
    );
  }
}

class FilteredFactorColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final Set<String> initialFactorTags;
  final Set<String> initialSkillTags;
  final Set<int> initialIds;
  final int initialStar;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  @override
  final String? builderId;

  @override
  final String? presetDescription;

  FilteredFactorColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    bool isFilterColumn = true,
    this.initialFactorTags = const {},
    this.initialSkillTags = const {},
    required this.initialIds,
    required this.initialStar,
    this.builderId,
    this.presetDescription,
  }) : type = isFilterColumn ? ColumnBuilderType.filter : ColumnBuilderType.normal;

  /// Whether the columns this builder creates select their factors by tag. [typeDescription] and [build] both read it,
  /// so the description always matches the column that gets built.
  static const _selectByTag = false;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: _selectByTag);

  @override
  ColumnSpec<FactorSet> build(RefBase ref) {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      builderId: builderId,
      predicate: AggregateFactorSetPredicate(
        query: initialIds,
        logic: FactorSetLogicMode.mixed,
        subject: FactorSearchSubjectMode.family,
        element: FactorSearchElement(mode: FactorSearchElementMode.starOnly, star: initialStar, count: 1),
        notation: FactorNotation(mode: FactorNotationMode.nameStarTotal),
        factorTags: initialFactorTags,
        skillTags: initialSkillTags,
      ),
      selectByTag: _selectByTag,
      hiddenElements: {FactorDialogElements.selectionTags, FactorDialogElements.modeLogic},
      showAllWhenQueryIsEmpty: false,
      showAvailableOnly: false,
    );
  }
}

/// Builds a factor column the user defines purely by tag: the dialog shows the
/// factor/skill tag selectors and hides the individual factor list and logic mode.
/// Selecting a tag freezes the query to the matching factors (see
/// [FactorColumnSpec.selectByTag]).
class TagDrivenFactorColumnBuilder extends ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  @override
  final String? builderId;

  @override
  final String? presetDescription;

  TagDrivenFactorColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.builderId,
    this.presetDescription,
    this.type = ColumnBuilderType.normal,
  });

  /// Whether the columns this builder creates select their factors by tag. [typeDescription] and [build] both read it,
  /// so the description always matches the column that gets built.
  static const _selectByTag = true;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: _selectByTag);

  @override
  ColumnSpec<FactorSet> build(RefBase ref) {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      builderId: builderId,
      predicate: AggregateFactorSetPredicate(
        logic: FactorSetLogicMode.mixed,
        subject: FactorSearchSubjectMode.family,
        element: FactorSearchElement(mode: FactorSearchElementMode.starOnly, star: 1, count: 1),
        notation: FactorNotation(mode: FactorNotationMode.nameStarTotal),
      ),
      selectByTag: _selectByTag,
      hiddenElements: {FactorDialogElements.selectionList, FactorDialogElements.modeLogic},
      showAllWhenQueryIsEmpty: false,
      showAvailableOnly: false,
    );
  }
}

/// [ColumnSpec.typeDescription] of a factor column and [ColumnBuilder.typeDescription] of its builders: whether it
/// selects its factors by tag is all that tells them apart.
ColumnDescription _typeDescription({required bool selectByTag}) => (
  text: (selectByTag ? "$tr_columns.factor.tag_driven.description" : "$tr_columns.factor.description").tr(),
  truthTable: null,
);
