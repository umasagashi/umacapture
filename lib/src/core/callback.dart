import 'package:flutter/material.dart';

typedef Callback<T> = void Function(T);
typedef StringCallback = Callback<String>;

extension CallbackExtension<T> on Callback<T> {
  VoidCallback bind(T value) {
    return () => this(value);
  }
}
