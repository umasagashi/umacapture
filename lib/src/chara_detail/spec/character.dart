import 'dart:io';

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

// ignore: constant_identifier_names
const tr_character = "pages.chara_detail.column_predicate.character";

@jsonSerializable
class CharacterCardPredicate {
  List<int> rejects;

  CharacterCardPredicate({
    required this.rejects,
  });

  CharacterCardPredicate.any() : rejects = [];

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

  @override
  final String description;

  CharacterCardColumnSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.parser,
    required this.predicate,
  });

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
        return Image.file(File("${resource.recordRootDirectory}/${record.traineeIconPath}"));
      },
    );
  }

  @override
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector({required BuildResource resource, required OnSpecChanged onChanged}) {
    return CharacterCardColumnSelector(spec: this, onChanged: onChanged);
  }

  CharacterCardColumnSpec copyWith({CharacterCardPredicate? predicate}) {
    return CharacterCardColumnSpec(
      id: id,
      title: title,
      description: description,
      parser: parser,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  String toString() {
    return "$CharacterCardColumnSpec(predicate: $predicate})";
  }
}

class CharacterCardColumnSelector extends ConsumerStatefulWidget {
  final CharacterCardColumnSpec originalSpec;
  final OnSpecChanged onChanged;

  const CharacterCardColumnSelector({Key? key, required CharacterCardColumnSpec spec, required this.onChanged})
      : originalSpec = spec,
        super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => CharacterCardColumnSelectorState();
}

class CharacterCardColumnSelectorState extends ConsumerState<CharacterCardColumnSelector> {
  late CharacterCardColumnSpec spec;

  @override
  void initState() {
    super.initState();
    setState(() {
      spec = widget.originalSpec;
    });
  }

  Widget charaChipWidget(ThemeData theme, Set<int> rejected, AvailableCharaCardInfo card) {
    final chipFrameColor = theme.chipTheme.selectedColor ?? theme.colorScheme.primaryContainer;
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
            backgroundColor: !rejected.contains(card.cardInfo.sid) ? null : theme.colorScheme.surfaceVariant,
            showCheckmark: false,
            selected: !rejected.contains(card.cardInfo.sid),
            onSelected: (selected) {
              setState(() {
                if (selected) {
                  spec.predicate.rejects.remove(card.cardInfo.sid);
                } else {
                  spec.predicate.rejects.add(card.cardInfo.sid);
                }
                spec = spec.copyWith(predicate: spec.predicate);
                widget.onChanged(spec);
              });
            },
          ),
        ),
        IgnorePointer(
          child: CircleAvatar(
            backgroundColor: chipFrameColor,
            radius: 24,
            child: ClipOval(
              child: Align(
                alignment: Alignment.bottomCenter,
                widthFactor: 0.9,
                heightFactor: 0.9,
                child: Image.file(File(card.iconPath)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget selectionWidget(BuildContext context) {
    final theme = Theme.of(context);
    final charaCards = ref.watch(availableCharaCardsProvider);
    final rejected = spec.predicate.rejects.toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
          child: Text("$tr_character.selection.description".tr()),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final card in charaCards) charaChipWidget(theme, rejected, card),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget headingWidget(String title) {
    return Row(
      children: [
        Text(title),
        const Expanded(child: Divider(indent: 8)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        headingWidget("$tr_character.selection.label".tr()),
        selectionWidget(context),
      ],
    );
  }
}

class CharacterCardColumnBuilder implements ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final String description;

  @override
  final ColumnCategory category;

  CharacterCardColumnBuilder({
    required this.title,
    required this.description,
    required this.category,
    required this.parser,
  });

  @override
  CharacterCardColumnSpec build() {
    return CharacterCardColumnSpec(
      id: const Uuid().v4(),
      title: title,
      description: description,
      parser: parser,
      predicate: CharacterCardPredicate.any(),
    );
  }
}
