import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/spec/ranged_label.dart';

@jsonSerializable
@Json(discriminatorValue: ColumnSpecType.characterRank)
class CharaRankColumnSpec extends RangedLabelColumnSpec {
  @override
  ColumnSpecType get type => ColumnSpecType.characterRank;

  CharaRankColumnSpec({
    required super.id,
    required super.title,
    required super.parser,
    required super.labelKey,
    required super.predicate,
  });

  @override
  List<int> parse(BuildResource resource, List<CharaDetailRecord> records) {
    return List<int>.from(records
        .map(parser.parse)
        .map((evaluation) => resource.charaRankBorder.indexWhere((border) => border >= evaluation)));
  }
}

class CharaRankColumnBuilder implements ColumnBuilder {
  final Parser parser;
  final String labelKey = "character_rank.name";
  final int? min;
  final int? max;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final bool isFilterColumn;

  CharaRankColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.min,
    this.max,
  }) : isFilterColumn = min != null || max != null;

  @override
  CharaRankColumnSpec build() {
    return CharaRankColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      labelKey: labelKey,
      predicate: IsInRangeIntegerPredicate(
        min: min,
        max: max,
      ),
    );
  }
}
