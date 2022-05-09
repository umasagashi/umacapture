import 'package:state_notifier/state_notifier.dart';

import '../preference/storage_box.dart';

class ExclusiveItemsNotifier<T> extends StateNotifier<T> {
  final String _boxValueKey;
  final List<T> values;
  final List<int> indices;
  final StorageBox _box;

  ExclusiveItemsNotifier({
    required String boxValueKey,
    required StorageBox box,
    required Iterable<T> values,
    required T defaultValue,
  })  : _boxValueKey = boxValueKey,
        _box = box,
        values = List.unmodifiable(values),
        indices = List.unmodifiable(List.generate(values.length, (i) => i)),
        super(box.pull<T>(boxValueKey) ?? defaultValue);

  int get length => values.length;

  int indexOf(T value) {
    return values.indexOf(value);
  }

  T get() {
    return state;
  }

  int index() {
    return indexOf(state);
  }

  List<bool> states() {
    return List.unmodifiable(values.map((e) => e == state));
  }

  void setValue(T value) {
    if (!values.contains(value)) {
      throw ArgumentError.value(value);
    }

    state = value;
    _box.push(_boxValueKey, value);
  }

  void setIndex(int value) {
    if (!indices.contains(value)) {
      throw ArgumentError.value(value);
    }

    setValue(values[value]);
  }

  void next() {
    setIndex((index() + 1) % values.length);
  }
}
