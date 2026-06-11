import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';

part 'preset.mapper.dart';

/// A single named column preset. The columns themselves live in the
/// `column_spec` Hive box under the entry [specEntryKey], so an entry only needs
/// to carry its identity and display title.
@MappableClass()
class ColumnPresetEntry with ColumnPresetEntryMappable {
  /// Stable identifier, also used to derive the spec storage entry key.
  final String key;

  /// User-facing preset name shown in the selector.
  final String title;

  const ColumnPresetEntry({required this.key, required this.title});

  ColumnPresetEntry copyWith({String? key, String? title}) {
    return ColumnPresetEntry(key: key ?? this.key, title: title ?? this.title);
  }
}

/// Ordered list of column presets plus the one currently applied.
///
/// Persisted verbatim (as JSON) to the `column_spec` box; the per-preset column
/// specs are stored separately, one entry per [ColumnPresetEntry.key].
@MappableClass()
class ColumnPresetIndex with ColumnPresetIndexMappable {
  final List<ColumnPresetEntry> presets;
  final String selectedKey;

  const ColumnPresetIndex({required this.presets, required this.selectedKey});

  ColumnPresetIndex copyWith({List<ColumnPresetEntry>? presets, String? selectedKey}) {
    return ColumnPresetIndex(presets: presets ?? this.presets, selectedKey: selectedKey ?? this.selectedKey);
  }

  /// The selected entry, or null if [selectedKey] does not resolve (defensive;
  /// the notifier keeps the invariant that it always points at a present entry).
  ColumnPresetEntry? get selected => presets.firstWhereOrNull((e) => e.key == selectedKey);

  /// Hive entry key holding the column specs for the preset identified by [key].
  static String specEntryKey(String key) => "specs_$key";
}
