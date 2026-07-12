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
  final int max;

  FactorNotation({required this.mode, required this.max});

  FactorNotation copyWith({FactorNotationMode? mode, int? max}) {
    return FactorNotation(mode: mode ?? this.mode, max: max ?? this.max);
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
      notation = FactorNotation(mode: FactorNotationMode.nameStarTotal, max: 3),
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

  bool _isAcceptable(QueriedFactor factor) {
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
        return foundFactors.any((e) => _isAcceptable(e));
      case FactorSetLogicMode.allOf:
        return foundFactors.every((e) => _isAcceptable(e));
      case FactorSetLogicMode.mixed:
        return _isMixedAcceptable(foundFactors);
    }
  }
}

class FactorCellData implements CellData {
  final String label;

  @override
  final String csv;

  FactorCellData(this.label, {String? csv}) : csv = (csv ?? label);

  @override
  CellSelectedCallback? get onSelected => null;
}

@MappableEnum()
enum FactorDialogElements { selectionList, selectionTags, modeLogic }

@MappableClass(discriminatorValue: 'FactorColumnSpec', ignoreNull: true)
class FactorColumnSpec extends ColumnSpec<FactorSet> with FactorColumnSpecMappable {
  final Parser parser;
  final String labelKey = LabelKeys.factor;
  final AggregateFactorSetPredicate predicate;

  final bool showAllWhenQueryIsEmpty;
  final bool showAvailableOnly;
  final Set<FactorDialogElements> hiddenElements;

  /// When true, the column is defined by its tags rather than hand-picked factors:
  /// the query is resolved live from `predicate.factorTags`/`skillTags` against the
  /// current factor master at evaluation time (so newly tagged factors are included
  /// automatically), and the individual factor list is hidden in the dialog.
  final bool selectByTag;

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
    this.hidden = false,
    this.description,
    this.width,
    this.builderId,
  });

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  bool get hasFilter => true;

  @override
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => defaultSpec is FactorColumnSpec
      // Keep selectByTag consistent with the adopted predicate (see SkillColumnSpec).
      ? copyWith(predicate: defaultSpec.predicate, selectByTag: defaultSpec.selectByTag)
      : copyWith(predicate: AggregateFactorSetPredicate.any(), selectByTag: false);

  FactorColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateFactorSetPredicate? predicate,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableOnly,
    Set<FactorDialogElements>? hiddenElements,
    bool? selectByTag,
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
    final query = ref.read(_factorTagQueryProvider(_factorTagsKey(predicate.factorTags, predicate.skillTags)));
    return predicate.copyWith(query: query);
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

  List<QueriedFactor> _extract(AggregateFactorSetPredicate predicate, FactorSet factorSet) {
    final traineeOnly = predicate.subject == FactorSearchSubjectMode.trainee;
    if (predicate.query.isEmpty) {
      if (!showAllWhenQueryIsEmpty) {
        return [];
      } else {
        return QueriedFactor.extract(factorSet.uniqueIds, factorSet, traineeOnly);
      }
    } else {
      final factorOrder = factorSet.uniqueIds.toList();
      final found = QueriedFactor.extract(predicate.query, factorSet, traineeOnly).where((e) => !e.isEmpty).toList();
      // Since found is in query order, sort in order of appearance.
      return found.sortedBy<num>((e) => factorOrder.indexOfOrNull(e.id) ?? found.length).toList();
    }
  }

  @override
  TrinaCell plutoCell(RefBase ref, FactorSet value) {
    final predicate = _resolved(ref);
    final mode = predicate.notation.mode;
    final factors = _extract(predicate, value);

    // Value-only modes render a single aggregate value across all factors, with
    // no factor names, so the display-count limit does not apply.
    if (!mode.showsName) {
      final display = QueriedFactor.notationOf(factors, mode.metric, mode.granularity, width: 3);
      final csv = QueriedFactor.notationOf(factors, mode.metric, mode.granularity);
      return TrinaCell(value: display)..setUserData(FactorCellData("($csv)"));
    }

    final labels = ref.watch(labelMapProvider)[labelKey]!;
    // A factor id beyond a lagging module label list would throw out of plutoCell into _buildGrid and
    // blank every column; degrade to the raw id for that cell instead.
    final notations = factors.map((q) {
      final name = labels.getOrNull(q.id) ?? q.id;
      return mode.showsValue ? "$name(${q.notation(mode.metric, mode.granularity)})" : "$name";
    }).toList();
    final desc = notations.partial(0, predicate.notation.max).join(", ");
    return TrinaCell(value: desc)..setUserData(FactorCellData(desc, csv: const CsvEncoder().convert([notations])));
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.text(),
      width: width ?? TrinaGridSettings.columnWidth,
      enableContextMenu: false,
      enableDropToResize: true,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (TrinaColumnRendererContext context) {
        final data = context.cell.getUserData<FactorCellData>()!;
        return CellText(data.label);
      },
    )..setUserData(this);
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

    final labels = ref.watch(labelMapProvider)[labelKey]!;
    final factors = predicate.query.map((e) => labels.getOrNull(e) ?? e.toString()).toList();
    const limit = 30;
    final ellipsis = factors.length > limit ? "$sep- ${factors.length - limit} more" : "";
    return "${factors.partial(0, limit).join(sep)}$ellipsis$modeText";
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

class _SelectedSkillTags extends TagSelectionNotifier {
  _SelectedSkillTags(this.specId);

  final String specId;

  @override
  Set<String> build() {
    final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
    return Set.from(spec.predicate.skillTags);
  }

  @override
  void toggle(String tag, {bool? shouldExists}) {
    super.toggle(tag, shouldExists: shouldExists);
    final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
    if (!spec.selectByTag) {
      return;
    }
    // Tag-driven column: persist the chosen skill tags into the spec. The query is
    // not stored — it is resolved live from the tags at evaluation time (see
    // [_resolved]). Only this axis is touched; the factor axis keeps its value.
    ref
        .read(specCloneProvider(specId).notifier)
        .update((s) => (s as FactorColumnSpec).copyWith(predicate: s.predicate.copyWith(skillTags: state)));
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
    final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
    return Set.from(spec.predicate.factorTags);
  }

  @override
  void toggle(String tag, {bool? shouldExists}) {
    super.toggle(tag, shouldExists: shouldExists);
    final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
    if (!spec.selectByTag) {
      return;
    }
    // Tag-driven column: persist the chosen factor tags into the spec. The query is
    // not stored — it is resolved live from the tags at evaluation time (see
    // [_resolved]). Only this axis is touched; the skill axis keeps its value.
    ref
        .read(specCloneProvider(specId).notifier)
        .update((s) => (s as FactorColumnSpec).copyWith(predicate: s.predicate.copyWith(factorTags: state)));
  }
}

final _selectedFactorTagsProvider = NotifierProvider.autoDispose.family<TagSelectionNotifier, Set<String>, String>(
  _SelectedFactorTags.new,
);

class _SelectionSelector extends ConsumerStatefulWidget {
  final String specId;

  const _SelectionSelector({required this.specId});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SelectionSelectorState();
}

class _SelectionSelectorState extends ConsumerState<_SelectionSelector> {
  String textQuery = "";

  List<FactorInfo> _watchCandidateFactors(String specId) {
    final spec = _clonedSpecProvider.watch(ref, specId);
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
    if (_clonedSpecProvider.watch(ref, widget.specId).selectByTag) {
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
    final selected = _clonedSpecProvider.watch(ref, widget.specId).predicate.query.toSet();
    final candidates = _watchCandidateFactors(widget.specId);
    return SelectorWidget<FactorInfo>(
      description: Text("$tr_factor.selection.description".tr()),
      candidates: candidates,
      selected: selected,
      onSelected: (newSelected) {
        _clonedSpecProvider.update(ref, widget.specId, (spec) {
          return spec.copyWith(predicate: spec.predicate.copyWith(query: newSelected));
        });
      },
      onTextQueryChanged: (query) => setState(() => textQuery = query),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = _clonedSpecProvider.watch(ref, widget.specId);
    return FormGroup(
      title: Text("$tr_factor.selection.label".tr()),
      children: [
        if (!spec.hiddenElements.contains(FactorDialogElements.selectionTags)) tagsWidget(),
        if (!spec.hiddenElements.contains(FactorDialogElements.selectionList)) selectorWidget(context),
      ],
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

  Widget subjectChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<FactorSearchSubjectMode>(
      title: Text("$tr_factor.mode.subject.label".tr()),
      description: Text("$tr_factor.mode.subject.description".tr()),
      prefix: "$tr_factor.mode.subject",
      tooltip: false,
      values: FactorSearchSubjectMode.values,
      selected: predicate.subject,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(predicate: spec.predicate.copyWith(subject: value));
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
      title: Text("$tr_factor.mode.label".tr()),
      description: descriptionWidget(context, ref),
      children: [
        if (!spec.hiddenElements.contains(FactorDialogElements.modeLogic)) logicChoiceWidget(context, ref),
        subjectChoiceWidget(context, ref),
        elementChoiceWidget(context, ref),
        elementStarWidget(context, ref),
        elementCountWidget(context, ref),
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

  Widget notationChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return ChoiceFormLine<FactorNotationMode>(
      title: Text("$tr_factor.notation.mode.label".tr()),
      description: Text("$tr_factor.notation.mode.description".tr()),
      prefix: "$tr_factor.notation.mode",
      values: FactorNotationMode.values,
      selected: predicate.notation.mode,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, widget.specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(notation: spec.predicate.notation.copyWith(mode: value)),
          );
        });
      },
    );
  }

  Widget notationMaxWidget(WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return FormTile(
      title: Text("$tr_factor.notation.max.label".tr()),
      description: Text("$tr_factor.notation.max.description".tr()),
      trailing: Disabled(
        // Value-only modes render a single aggregate cell, so the per-cell
        // factor limit has no effect and is disabled.
        disabled: !predicate.notation.mode.showsName,
        tooltip: "$tr_factor.notation.max.disabled_tooltip".tr(),
        child: IntStepperField(
          min: 1,
          max: 100,
          value: predicate.notation.max,
          onChanged: (value) {
            _clonedSpecProvider.update(ref, widget.specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(notation: spec.predicate.notation.copyWith(max: value)),
              );
            });
          },
        ),
      ),
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
        notationMaxWidget(ref),
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
        _SelectionSelector(specId: specId),
        const SizedBox(height: 32),
        _ModeSelector(specId: specId),
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

  @override
  ColumnSpec<FactorSet> build(RefBase ref) {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: AggregateFactorSetPredicate.any(),
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
  }) : type = isFilterColumn ? ColumnBuilderType.filter : ColumnBuilderType.normal;

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
        notation: FactorNotation(mode: FactorNotationMode.nameStarTotal, max: 3),
        factorTags: initialFactorTags,
        skillTags: initialSkillTags,
      ),
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

  TagDrivenFactorColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.builderId,
    this.type = ColumnBuilderType.normal,
  });

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
        notation: FactorNotation(mode: FactorNotationMode.nameStarTotal, max: 3),
      ),
      selectByTag: true,
      hiddenElements: {FactorDialogElements.selectionList, FactorDialogElements.modeLogic},
      showAllWhenQueryIsEmpty: false,
      showAvailableOnly: false,
    );
  }
}
