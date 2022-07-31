import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:quiver/iterables.dart';
import 'package:tuple/tuple.dart';

class CurrentPlatform {
  static bool isWindows() {
    return defaultTargetPlatform == TargetPlatform.windows;
  }

  static bool isLinux() {
    return defaultTargetPlatform == TargetPlatform.linux;
  }

  static bool isMacOS() {
    return defaultTargetPlatform == TargetPlatform.macOS;
  }

  static bool isAndroid() {
    return defaultTargetPlatform == TargetPlatform.android;
  }

  static bool isIOS() {
    return defaultTargetPlatform == TargetPlatform.iOS;
  }

  static bool isWeb() {
    return kIsWeb;
  }

  static bool isMobile() {
    return isAndroid() || isIOS();
  }

  static bool isDesktop() {
    return isWindows() || isLinux() || isMacOS();
  }

  static bool hasWindowFrame() {
    return !isWeb() && isDesktop();
  }
}

final logger = Logger(
  printer: PrettyPrinter(
    printEmojis: false,
    printTime: true,
    lineLength: 80,
  ),
);

class ProviderLogger extends ProviderObserver {
  @override
  void didUpdateProvider(
    ProviderBase provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    final String p = previousValue.toString();
    final String n = newValue.toString();
    const limit = 300;
    logger.d(
      "provider: ${provider.name ?? provider.runtimeType}, "
      "value: ${p.length < limit ? p : "${p.substring(0, limit)}..."}"
      " -> ${n.length < limit ? n : "${n.substring(0, limit)}..."}",
    );
  }
}

extension DoubleExtension on double {
  double multiply(double factor) {
    return this * factor;
  }
}

extension BoolIterableExtension on Iterable<bool> {
  int countTrue() => where((e) => e).length;

  bool anyIn() {
    return any((e) => e);
  }

  bool everyIn() {
    return every((e) => e);
  }
}

extension SetExtension<T> on Set<T> {
  bool addAllWithSizeCheck(Iterable<T> elements) {
    final previous = length;
    addAll(elements);
    return previous != length;
  }
}

extension ListExtension<T> on List<T> {
  List<T> partial(int start, int end) {
    return sublist(start, math.min(length, end));
  }

  Iterable<T> insertSeparator(T separator) sync* {
    final it = iterator;
    if (it.moveNext()) {
      yield it.current;
    }
    while (it.moveNext()) {
      yield separator;
      yield it.current;
    }
  }

  void addIfNotNull(T? value) {
    if (value != null) {
      add(value);
    }
  }

  T? getOrNull(int? index) {
    if (index != null) {
      return this[index];
    }
    return null;
  }

  Map<K, T> toMap<K>(K Function(T) key) => Map<K, T>.fromEntries(map((e) => MapEntry(key(e), e)));
}

extension List2DExtension<T> on List<List<T>> {
  List<List<T>> transpose() {
    if (isEmpty) {
      return [[]];
    }
    final d0 = length;
    final d1 = this[0].length;
    return intRange(d1).map((i1) => intRange(d0).map((i0) => this[i0][i1]).toList()).toList();
  }
}

Iterable<int> intRange(int stop) sync* {
  for (final e in range(stop)) {
    yield e as int;
  }
}

Iterable<Tuple2<T1, T2>> zip2<T1, T2>(Iterable<T1> it1, Iterable<T2> it2) sync* {
  for (final e in zip([it1, it2])) {
    yield Tuple2<T1, T2>(e[0] as T1, e[1] as T2);
  }
}

Iterable<Tuple3<T1, T2, T3>> zip3<T1, T2, T3>(Iterable<T1> it1, Iterable<T2> it2, Iterable<T3> it3) sync* {
  for (final e in zip([it1, it2, it3])) {
    yield Tuple3<T1, T2, T3>(e[0] as T1, e[1] as T2, e[2] as T3);
  }
}
