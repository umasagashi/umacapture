import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/spec/ranged_label.dart';
import '/src/core/utils.dart';

@jsonSerializable
@Json(discriminatorValue: "CharaRankColumnSpec")
class CharaRankColumnSpec extends RangedLabelColumnSpec {
  CharaRankColumnSpec({
    required super.id,
    required super.title,
    required super.parser,
    required super.labelKey,
    required super.predicate,
  });

  @override
  List<int> parse(RefBase ref, List<CharaDetailRecord> records) {
    final charaRankBorder = ref.watch(charaRankBorderProvider);
    return List<int>.from(
        records.map(parser.parse).map((evaluation) => charaRankBorder.indexWhere((border) => border >= evaluation)));
  }

  @override
  CharaRankColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    String? labelKey,
    IsInRangeIntegerPredicate? predicate,
  }) {
    return CharaRankColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      labelKey: labelKey ?? this.labelKey,
      predicate: predicate ?? this.predicate,
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

  CharaRankColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.min,
    this.max,
  }) : type = (min != null || max != null) ? ColumnBuilderType.filter : ColumnBuilderType.normal;

  @override
  CharaRankColumnSpec build() {
    return CharaRankColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      labelKey: LabelKeys.charaRank,
      predicate: IsInRangeIntegerPredicate(
        min: min,
        max: max,
      ),
    );
  }
}
