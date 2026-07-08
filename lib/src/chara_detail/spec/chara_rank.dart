import 'package:dart_mappable/dart_mappable.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/spec/ranged_label.dart';
import '/src/core/utils.dart';

part 'chara_rank.mapper.dart';

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

@MappableClass(discriminatorValue: 'CharaRankColumnSpec', ignoreNull: true)
class CharaRankColumnSpec extends RangedLabelColumnSpec with CharaRankColumnSpecMappable {
  CharaRankColumnSpec({
    required super.id,
    required super.title,
    required super.parser,
    required super.labelKey,
    required super.predicate,
    super.hidden,
    super.description,
    super.width,
    super.builderId,
  });

  @override
  List<int> parse(RefBase ref, List<CharaDetailRecord> records) {
    final charaRankBorder = ref.watch(charaRankBorderProvider);
    return List<int>.from(
      records.map(parser.parse).map((evaluation) {
        // Records with no evaluation value (inheritance-only / friend-inheritance)
        // have no rank either: pass the sentinel through so plutoCell renders an
        // empty cell instead of the lowest rank.
        if (evaluation == evaluationValueAbsent) {
          return evaluationValueAbsent;
        }
        // indexWhere returns -1 when the evaluation exceeds every border, i.e. the
        // top-most bucket. Map it to the last rank index instead so the highest rank
        // (e.g. LS24) stays reachable for both display and filtering.
        final index = charaRankBorder.indexWhere((border) => border > evaluation);
        return index < 0 ? charaRankBorder.length : index;
      }),
    );
  }

  @override
  TrinaCell plutoCell(RefBase ref, int value) {
    // The rank sentinel is not a valid label index, so it must not reach the base
    // `labels[value]` lookup (which would throw). Render an empty cell instead.
    if (value == evaluationValueAbsent) {
      return TrinaCell(value: value)..setUserData(RangedLabelCellData(absentValueLabel));
    }
    return super.plutoCell(ref, value);
  }

  @override
  CharaRankColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    String? labelKey,
    IsInRangeIntegerPredicate? predicate,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
    String? builderId,
  }) {
    return CharaRankColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      labelKey: labelKey ?? this.labelKey,
      predicate: predicate ?? this.predicate,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
      builderId: builderId ?? this.builderId,
    );
  }
}

class CharaRankColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final int? min;
  final int? max;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  @override
  final String? builderId;

  CharaRankColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.min,
    this.max,
    this.builderId,
  }) : type = (min != null || max != null) ? ColumnBuilderType.filter : ColumnBuilderType.normal;

  @override
  CharaRankColumnSpec build(RefBase ref) {
    return CharaRankColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      labelKey: LabelKeys.charaRank,
      builderId: builderId,
      predicate: IsInRangeIntegerPredicate(min: min, max: max),
    );
  }
}
