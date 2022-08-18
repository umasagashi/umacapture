import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

// ignore: constant_identifier_names
const tr_character = "pages.chara_detail.column_predicate.character";

@jsonSerializable
class CharacterCardPredicate {
  final Set<int> rejects;

  CharacterCardPredicate({
    required this.rejects,
  });

  CharacterCardPredicate.any() : rejects = {};

  bool apply(int value) {
    return !rejects.contains(value);
  }
}

class CharacterCardCellData implements Exportable {
  final String name;

  CharacterCardCellData(this.name);

  @override
  String get csv => name;
}

@jsonSerializable
@Json(discriminatorValue: ColumnSpecType.characterCard)
class CharacterCardColumnSpec extends ColumnSpec<int> {
  final Parser parser;
  final CharacterCardPredicate predicate;

  @override
  ColumnSpecType get type => ColumnSpecType.characterCard;

  @override
  final String id;

  @override
  final String title;

  CharacterCardColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
  });

  CharacterCardColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    CharacterCardPredicate? predicate,
  }) {
    return CharacterCardColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  List<int> parse(BuildResource resource, List<CharaDetailRecord> records) {
    return List<int>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(BuildResource resource, List<int> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(BuildResource resource, int value) {
    final card = resource.charaCardInfo[value];
    return PlutoCell(value: card.sortKey)..setUserData(CharacterCardCellData(card.names.first));
  }

  @override
  PlutoColumn plutoColumn(BuildResource resource) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.number(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        final record = context.row.getUserData<CharaDetailRecord>()!;
        return Image.file((resource.recordRootDir.filePath(record.traineeIconPath)).toFile());
      },
    );
  }

  @override
  String tooltip(BuildResource resource) {
    final cards = resource.charaCardInfo.sortedBy<num>((e) => e.sortKey);
    const sep = "\n";
    if (predicate.rejects.isEmpty) {
      return "Any";
    } else if (predicate.rejects.length > cards.length / 2) {
      final accepted = cards.where((e) => !predicate.rejects.contains(e.sid));
      return "${"$tr_character.tooltip.accept".tr()}:$sep${accepted.map((e) => e.names.first).join(sep)}";
    } else {
      final rejected = cards.where((e) => predicate.rejects.contains(e.sid));
      return "${"$tr_character.tooltip.reject".tr()}:$sep${rejected.map((e) => e.names.first).join(sep)}";
    }
  }

  @override
  Widget tag(BuildResource resource) => Text(title);

  @override
  Widget selector() => CharacterCardColumnSelector(specId: id);
}

final _clonedSpecProvider = SpecProviderAccessor<CharacterCardColumnSpec>();

class _CharaCardChip extends ConsumerWidget {
  final String specId;
  final AvailableCharaCardInfo card;
  final bool selected;

  const _CharaCardChip({
    required this.specId,
    required this.card,
    required this.selected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: FilterChip(
            label: Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Text(card.cardInfo.names.first),
            ),
            backgroundColor: selected ? null : theme.colorScheme.surfaceVariant,
            showCheckmark: false,
            selected: selected,
            onSelected: (selected) {
              _clonedSpecProvider.update(ref, specId, (spec) {
                return spec.copyWith(
                  predicate: CharacterCardPredicate(
                    rejects: Set.from(spec.predicate.rejects)..toggle(card.cardInfo.sid, shouldExists: selected),
                  ),
                );
              });
            },
          ),
        ),
        IgnorePointer(
          child: CircleAvatar(
            backgroundColor: theme.chipTheme.selectedColor ?? theme.colorScheme.primaryContainer,
            radius: 24,
            child: ClipOval(
              child: Align(
                alignment: Alignment.bottomCenter,
                widthFactor: 0.9,
                heightFactor: 0.9,
                child: Image.file(card.iconPath.toFile()),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CharacterCardSelector extends ConsumerWidget {
  final String specId;

  const _CharacterCardSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charaCards = ref.watch(availableCharaCardsProvider);
    final rejected = _clonedSpecProvider.watch(ref, specId).predicate.rejects;
    return FormGroup(
      title: Text("$tr_character.selection.label".tr()),
      description: Text("$tr_character.selection.description".tr()),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final card in charaCards)
                  _CharaCardChip(
                    specId: specId,
                    card: card,
                    selected: !rejected.contains(card.cardInfo.sid),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotationSelector extends ConsumerWidget {
  final String specId;

  const _NotationSelector({
    required this.specId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_character.notation.label".tr()),
      description: Text("$tr_character.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_character.notation.title.label".tr()),
          children: [
            DenseTextField(
              initialText: spec.title,
              onChanged: (value) {
                _clonedSpecProvider.update(ref, specId, (spec) {
                  return spec.copyWith(title: value);
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}

class CharacterCardColumnSelector extends ConsumerWidget {
  final String specId;

  const CharacterCardColumnSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _CharacterCardSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId),
      ],
    );
  }
}

class CharacterCardColumnBuilder implements ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  bool get isFilterColumn => false;

  CharacterCardColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
  });

  @override
  CharacterCardColumnSpec build() {
    return CharacterCardColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: CharacterCardPredicate.any(),
    );
  }
}
