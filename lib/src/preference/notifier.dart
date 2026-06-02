import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

typedef ExclusiveItemsNotifierProvider<T> = NotifierProvider<ExclusiveItemsNotifier<T>, T>;

class ExclusiveItemsNotifier<T> extends Notifier<T> {
  // values and indices should be immutable since notifier does not work for them.
  final List<T> values;
  final List<int> indices;
  final T _defaultValue;
  final String? _entryKey;

  StorageEntry<T>? _entry;

  ExclusiveItemsNotifier({required Iterable<T> values, required T defaultValue, String? entryKey})
    : values = List.unmodifiable(values),
      indices = List.unmodifiable(List.generate(values.length, (i) => i)),
      _defaultValue = defaultValue,
      _entryKey = entryKey;

  @override
  T build() {
    final key = _entryKey;
    _entry = key == null ? null : StorageEntry<T>(box: ref.watch(storageBoxProvider), key: key);
    return _entry?.pull() ?? _defaultValue;
  }

  int get length => values.length;

  void setValue(T value) {
    if (!values.contains(value)) {
      throw ArgumentError.value(value);
    }

    state = value;
    _entry?.push(value);
  }

  void setIndex(int value) {
    if (!indices.contains(value)) {
      throw ArgumentError.value(value);
    }

    setValue(values[value]);
  }

  void next() {
    setIndex((values.indexOf(state) + 1) % values.length);
  }
}

typedef BooleanNotifierProvider = NotifierProvider<BooleanNotifier, bool>;

class BooleanNotifier extends Notifier<bool> {
  final bool _defaultValue;
  final String? _entryKey;

  StorageEntry<bool>? _entry;

  BooleanNotifier({required bool defaultValue, String? entryKey}) : _defaultValue = defaultValue, _entryKey = entryKey;

  @override
  bool build() {
    final key = _entryKey;
    _entry = key == null ? null : StorageEntry<bool>(box: ref.watch(storageBoxProvider), key: key);
    return _entry?.pull() ?? _defaultValue;
  }

  void set(bool value) {
    state = value;
    _entry?.push(value);
  }

  void toggle() {
    set(!state);
  }
}
