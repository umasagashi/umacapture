import 'package:flutter/material.dart';

import '/src/core/path_entity.dart';

typedef Callback<T> = void Function(T);
typedef StringCallback = Callback<String>;
typedef PathEntityCallback = Callback<PathEntity>;

extension CallbackExtension<T> on Callback<T> {
  VoidCallback bind(T value) {
    return () => this(value);
  }
}
