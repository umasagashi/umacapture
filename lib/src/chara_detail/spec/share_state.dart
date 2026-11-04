import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_share.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'share_state.mapper.dart';

// ignore: constant_identifier_names
const tr_share_state = "pages.chara_detail.column_predicate.share_state";
// ignore: constant_identifier_names
const tr_columns_share_state = "pages.chara_detail.columns.share_state";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

/// A record's share as this device knows it: from the share notes this device keeps under the logged-in account.
///
/// [none] means this device holds no note for the record. A share the other device made is not noted here, so
/// [none] does not say the record is unshared. [loggedOut] holds for every record while there is no session: the
/// notes are dropped at logout, so nothing is known.
@MappableEnum()
enum ShareColumnState { shared, pending, none, notShareable, loggedOut }

/// The filter's choices: every state but [ShareColumnState.loggedOut], which is the session's state and not a
/// record's.
const _choices = [
  ShareColumnState.shared,
  ShareColumnState.pending,
  ShareColumnState.none,
  ShareColumnState.notShareable,
];

/// The state of each of [records], read from [notes] (the share notes by key hash) and [session].
List<ShareColumnState> shareColumnStates(
  List<CharaDetailRecord> records,
  Map<String, RecordShare> notes,
  ShareSession? session,
) {
  if (session == null) {
    return List.filled(records.length, ShareColumnState.loggedOut);
  }
  final noteByRecord = <String, RecordShare>{};
  for (final note in notes.values) {
    if (note.accountId == session.accountId) {
      noteByRecord.putIfAbsent(note.recordId, () => note);
    }
  }
  return [
    for (final record in records)
      switch (noteByRecord[record.id]?.state) {
        RecordShareState.shared => ShareColumnState.shared,
        RecordShareState.pending => ShareColumnState.pending,
        null when isNeverShareable(record) => ShareColumnState.notShareable,
        null => ShareColumnState.none,
      },
  ];
}

String _stateKey(ShareColumnState state) => switch (state) {
  ShareColumnState.shared => "shared",
  ShareColumnState.pending => "pending",
  ShareColumnState.none => "none",
  ShareColumnState.notShareable => "not_shareable",
  ShareColumnState.loggedOut => "logged_out",
};

/// The cell's text, which is also its CSV value and sort key: empty when this device holds no note.
String _stateLabel(ShareColumnState state) =>
    state == ShareColumnState.none ? "" : "$tr_columns_share_state.states.${_stateKey(state)}".tr();

/// The filter's label for a state; [ShareColumnState.none] has an empty cell, so its chip needs words.
String _choiceLabel(ShareColumnState state) =>
    state == ShareColumnState.none ? "$tr_columns_share_state.states.none".tr() : _stateLabel(state);

@MappableClass()
class ShareColumnPredicate with ShareColumnPredicateMappable {
  final Set<ShareColumnState> rejects;

  ShareColumnPredicate({this.rejects = const {}});

  ShareColumnPredicate.any() : rejects = {};

  /// A row whose state is unknown (logged out) passes only an unfiltered column: a filtered table must not list a
  /// row the filter might have meant to leave out, since the listed rows feed the bulk delete and the CSV export.
  bool apply(ShareColumnState state) =>
      state == ShareColumnState.loggedOut ? rejects.isEmpty : !rejects.contains(state);
}

class ShareColumnCellData implements CellData {
  final ShareColumnState state;

  ShareColumnCellData(this.state);

  @override
  String get csv => _stateLabel(state);

  @override
  CellSelectedCallback? get onSelected => null;
}

@MappableClass(discriminatorValue: 'ShareStateColumnSpec', ignoreNull: true)
class ShareStateColumnSpec extends ColumnSpec<ShareColumnState> with ShareStateColumnSpecMappable {
  ShareColumnPredicate predicate;

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

  ShareStateColumnSpec({
    required this.id,
    required this.title,
    required this.predicate,
    this.hidden = false,
    this.description,
    this.width,
  });

  @override
  ColumnDescription get typeDescription => _typeDescription();

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  bool get hasFilter => true;

  @override
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => copyWith(predicate: ShareColumnPredicate.any());

  ShareStateColumnSpec copyWith({
    String? id,
    String? title,
    ShareColumnPredicate? predicate,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return ShareStateColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      predicate: predicate ?? this.predicate,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  @override
  List<ShareColumnState> parse(RefBase ref, List<CharaDetailRecord> records) {
    // Watched so a share, an unshare, a refresh of the account's list, a login and a logout rebuild the table.
    return shareColumnStates(records, ref.watch(recordSharesProvider), ref.watch(recordShareSessionProvider));
  }

  @override
  List<bool> evaluate(RefBase ref, List<ShareColumnState> values) => values.map(predicate.apply).toList();

  @override
  CellBuilder<ShareColumnState> cellBuilder(RefBase ref) => CellBuilder(_cell);

  // The label doubles as the sort key and the measured text, as the family registration column's does.
  TrinaCell _cell(ShareColumnState value) =>
      TrinaCell(value: _stateLabel(value))..setUserData(ShareColumnCellData(value));

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
      readOnly: true,
      renderer: (TrinaColumnRendererContext context) {
        final state = context.cell.getUserData<ShareColumnCellData>()!.state;
        // Dimmed the way the memo column's placeholder is: the cell asks for an action, it holds no value.
        return CellText(_stateLabel(state), opacity: state == ShareColumnState.loggedOut ? 0.4 : null);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    const sep = "\n";
    if (predicate.rejects.isEmpty) {
      return "Any";
    }
    final accepted = _choices.where((e) => !predicate.rejects.contains(e));
    return "${"$tr_share_state.tooltip.accept".tr()}:$sep${accepted.map(_choiceLabel).join(sep)}";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) => ShareStateColumnSelector(specId: id, onDecided: onDecided);
}

final _clonedSpecProvider = SpecProviderAccessor<ShareStateColumnSpec>();

class _ShareStateSelector extends ConsumerWidget {
  final String specId;

  const _ShareStateSelector({required this.specId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_share_state.selection.label".tr()),
      description: Text("$tr_share_state.selection.description".tr()),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final state in _choices)
                  FilterChip(
                    label: Text(_choiceLabel(state)),
                    showCheckmark: false,
                    selected: !spec.predicate.rejects.contains(state),
                    onSelected: (selected) {
                      _clonedSpecProvider.update(ref, specId, (spec) {
                        return spec.copyWith(
                          predicate: ShareColumnPredicate(
                            rejects: Set.from(spec.predicate.rejects)..toggle(state, shouldExists: selected),
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

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_common.notation.label".tr()),
      description: Text("$tr_common.notation.description".tr()),
      children: [
        FormTile(
          title: Text("$tr_common.notation.title.label".tr()),
          description: Text("$tr_common.notation.title.description".tr()),
          trailing: DenseTextField(
            initialText: title,
            minWidth: 140,
            onChanged: (value) {
              title = value;
            },
          ),
        ),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class ShareStateColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const ShareStateColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _ShareStateSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class ShareStateColumnBuilder extends ColumnBuilder {
  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type = ColumnBuilderType.normal;

  ShareStateColumnBuilder({required this.title, required this.category});

  @override
  ColumnDescription get typeDescription => _typeDescription();

  @override
  ShareStateColumnSpec build(RefBase ref) {
    return ShareStateColumnSpec(id: const Uuid().v4(), title: title, predicate: ShareColumnPredicate.any());
  }
}

/// [ColumnSpec.typeDescription] of a share column and [ColumnBuilder.typeDescription] of its builder.
ColumnDescription _typeDescription() => (text: "$tr_columns_share_state.description".tr(), truthTable: null);
