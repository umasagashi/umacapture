import 'package:flutter/material.dart';

import '/src/core/path_entity.dart';

typedef Callback<T> = void Function(T);
typedef StringCallback = Callback<String>;
typedef IntCallback = Callback<int>;
typedef PathEntityCallback = Callback<PathEntity>;

typedef Value2Callback<T1, T2> = void Function(T1, T2);

typedef Predicate<T> = bool Function(T);

extension CallbackExtension<T> on Callback<T> {
  VoidCallback bind(T value) {
    return () => this(value);
  }
}

class PlainChangeNotifier extends ChangeNotifier {
  @override
  // ignore: unnecessary_overrides
  void notifyListeners() {
    super.notifyListeners();
  }
}
