import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/preference/storage_box.dart';

typedef ExclusiveItemsNotifierProvider<T> = StateNotifierProvider<ExclusiveItemsNotifier<T>, T>;

class ExclusiveItemsNotifier<T> extends StateNotifier<T> {
  final StorageEntry? _entry;

  // values and indices should be immutable since notifier does not work for them.
  final List<T> values;
  final List<int> indices;

  ExclusiveItemsNotifier({
    required Iterable<T> values,
    required T defaultValue,
    StorageEntry? entry,
  })  : _entry = entry,
        values = List.unmodifiable(values),
        indices = List.unmodifiable(List.generate(values.length, (i) => i)),
        super(entry?.pull() ?? defaultValue);

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

typedef BooleanNotifierProvider = StateNotifierProvider<BooleanNotifier, bool>;

class BooleanNotifier extends StateNotifier<bool> {
  final StorageEntry? _entry;

  BooleanNotifier({
    required bool defaultValue,
    StorageEntry? entry,
  })  : _entry = entry,
        super(entry?.pull() ?? defaultValue);

  void set(bool value) {
    state = value;
    _entry?.push(value);
  }

  void toggle() {
    set(!state);
  }
}
