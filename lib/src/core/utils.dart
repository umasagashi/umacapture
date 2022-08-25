import 'dart:async';
import 'dart:math' as math;

import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:quiver/iterables.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tuple/tuple.dart';

final logger = Logger(
  level: (kDebugMode) ? Level.verbose : Level.info,
  filter: ProductionFilter(),
  printer: PrettyPrinter(
    printEmojis: false,
    printTime: true,
    lineLength: 80,
    colors: false,
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
    logger.v(
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

  void toggle(T value, {bool? shouldExists}) {
    final exists = contains(value);
    if (shouldExists != null && shouldExists != exists) {
      throw Exception("value=$value, shouldExists=$shouldExists");
    }
    if (exists) {
      remove(value);
    } else {
      add(value);
    }
  }
}

extension ListExtension<T> on List<T> {
  List<T> partial(int start, int end) {
    return sublist(start, math.min(length, end));
  }

  List<T> truncated(int n) {
    return sublist(0, length - n);
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

  void toggle(T value, {bool? shouldExists}) {
    final exists = contains(value);
    if (shouldExists != null && shouldExists != exists) {
      throw Exception("value=$value, shouldExists=$shouldExists");
    }
    if (exists) {
      remove(value);
    } else {
      add(value);
    }
  }

  int? indexOfOrNull(T element) {
    final index = indexOf(element);
    return index == -1 ? null : index;
  }
}

@jsonSerializable
class Range<T extends dynamic> {
  final T min;
  final T max;

  Range({
    required this.min,
    required this.max,
  });

  Range<double> toDouble() {
    return Range<double>(
      min: min.toDouble(),
      max: max.toDouble(),
    );
  }
}

extension DynamicTypeListExtension<T extends dynamic> on List<T> {
  Range<T> range() {
    T min = first;
    T max = first;
    for (final T value in this) {
      if (value.compareTo(min) == -1) {
        min = value;
      }
      if (value.compareTo(max) == 1) {
        max = value;
      }
    }
    return Range<T>(min: min, max: max);
  }
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

extension DateTimeExtension on DateTime {
  bool operator <=(DateTime other) {
    return compareTo(other) != 1;
  }

  String toDateString() => toString().substring(0, 10);

  DateTime asLocal() => DateTime(year, month, day, hour, minute, second, microsecond);
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

class Progress {
  final int total;
  final int count;

  Progress({this.count = 0, required this.total});

  static Progress get none => Progress(count: 0, total: 0);

  double get progress => count / total;

  int get percent => (progress * 100).toInt();

  bool get isEmpty => total == 0;

  bool get isCompleted => count >= total;

  Progress increment() {
    return Progress(count: count + 1, total: total);
  }
}

class Math {
  static T min<T extends num>(T a, T b) => math.min(a, b);

  static T max<T extends num>(T a, T b) => math.max(a, b);
}

class RefBase {
  final dynamic _ref;

  RefBase(ref) : _ref = ref;

  T read<T>(ProviderBase<T> provider) => _ref.read(provider);

  T watch<T>(ProviderBase<T> provider) => _ref.watch(provider);
}

abstract class StateProviderLike<T> {
  ProviderListenable<T> get listenable;

  ProviderBase<StateController<T>> get notifier;
}

class AutoDisposeStateProviderLike<T> extends StateProviderLike<T> {
  final AutoDisposeStateProvider<T> provider;

  AutoDisposeStateProviderLike(this.provider);

  @override
  ProviderListenable<T> get listenable => provider;

  @override
  ProviderBase<StateController<T>> get notifier => provider.notifier;
}

bool isSentryAvailable() {
  return HubAdapter().isEnabled;
}

FutureOr<void> captureException(exception, stackTrace) {
  if (isSentryAvailable()) {
    Sentry.captureException(exception, stackTrace: stackTrace);
  }
}
