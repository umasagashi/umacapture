import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// riverpod 3 moved ProviderListenable out of the default export surface.
import 'package:flutter_riverpod/misc.dart';

import '/src/core/app_logger.dart';

export '/src/core/app_logger.dart' show logger, AppLogger, ProviderLogger;

part 'utils.mapper.dart';

/// Decodes a persisted JSON-array string into a list of [T], skipping any single
/// entry that fails to decode so one corrupt row cannot blank the whole list. A
/// corrupt or non-array top level falls back to an empty list (with nothing to
/// hand to [onBroken] — no rows exist at that point). [label] names the data in
/// log messages.
///
/// [onBroken] receives each entry that failed to decode, as the raw decoded JSON
/// value (an `Object?`, not a map — a non-map row is itself a failure mode), so
/// a caller can preserve it verbatim instead of losing it on the next save.
///
/// Shared by the addon notifiers (task definitions / execution history) which
/// both persist a single JSON array and must survive a partial/corrupt write —
/// see the data-loss note in `task_definitions.dart`.
List<T> decodeJsonList<T>(
  String? raw,
  T Function(Map<String, dynamic> map) fromMap, {
  required String label,
  void Function(Object? raw)? onBroken,
}) {
  if (raw == null) {
    return const [];
  }
  final List<dynamic> data;
  try {
    data = jsonDecode(raw) as List<dynamic>;
  } catch (e) {
    logger.w("Failed to decode $label: $e");
    return const [];
  }
  final result = <T>[];
  for (final d in data) {
    try {
      result.add(fromMap((d as Map).cast<String, dynamic>()));
    } catch (e) {
      logger.w("Failed to deserialize a $label entry; skipping: error=$e, data=$d");
      onBroken?.call(d);
    }
  }
  return result;
}

class NumberFormatter {
  static final number = NumberFormat("#,###", "en_US");
  static final numberCompactIso = NumberFormat.compact(locale: "en_US");
  static final numberCompactLocal = NumberFormat.compact();
}

extension NumExtension on num {
  String toNumberString() => NumberFormatter.number.format(this);

  String toCompactNumberString() => NumberFormatter.numberCompactIso.format(this);

  String toLocalCompactNumberString() {
    final raw = NumberFormatter.numberCompactLocal.format(this);
    final unit = raw.last; // Assuming unit is a single character.
    if (unit.isNumber) {
      return raw;
    } else {
      return "${raw.truncated(1)} $unit";
    }
  }
}

extension IntExtension on int {
  Iterable<int> range() sync* {
    for (int i = 0; i < this; i++) {
      yield i;
    }
  }

  int get digits => toString().length;

  int roundTopmost([int division = 1]) {
    final r = math.pow(10, digits - 1) / division;
    return ((this / r).round() * r).toInt();
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
    if (index != null && index >= 0 && index < length) {
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

@MappableClass()
class Range<T extends dynamic> with RangeMappable<T> {
  final T min;
  final T max;

  Range({required this.min, required this.max});

  Range<double> toDouble() {
    return Range<double>(min: min.toDouble(), max: max.toDouble());
  }
}

extension DynamicTypeListExtension<T extends dynamic> on List<T> {
  Range<T> range() {
    if (isEmpty) {
      throw Exception("Cannot determine range of an empty list.");
    }
    T min = first;
    T max = first;
    for (final T value in this) {
      // Compare on sign only: the Comparable contract guarantees the sign, not a ±1 magnitude.
      if (value.compareTo(min) < 0) {
        min = value;
      }
      if (value.compareTo(max) > 0) {
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
    return d1.range().map((i1) => d0.range().map((i0) => this[i0][i1]).toList()).toList();
  }
}

extension DateTimeExtension on DateTime {
  bool operator <=(DateTime other) {
    return compareTo(other) != 1;
  }

  Duration operator -(DateTime other) {
    return difference(other);
  }

  bool isInRange(DateTime start, DateTime end) {
    return start <= this && this <= end;
  }

  bool hasExpired(Duration duration) {
    return add(duration) <= DateTime.now();
  }

  String toDateString() => toString().substring(0, 10);

  String toMonthString() => toString().substring(0, 7);

  DateTime asLocal() => DateTime(year, month, day, hour, minute, second, microsecond);

  DateTime lastMonth() {
    if (month == 1) {
      return DateTime(year - 1, 12);
    } else {
      return DateTime(year, month - 1);
    }
  }

  DateTime nextMonth() {
    if (month == 12) {
      return DateTime(year + 1, 1);
    } else {
      return DateTime(year, month + 1);
    }
  }

  bool isSameMonth(DateTime other) => year == other.year && month == other.month;

  int get inDays => (this - DateTime(0, 1, 1)).inDays;

  // Day 0 of the next month rolls back to the last day of this month.
  int get daysInMonth => DateTime(year, month + 1, 0).day;

  static DateTime earlier(DateTime a, DateTime b) => b.isAfter(a) ? a : b;

  static DateTime later(DateTime a, DateTime b) => b.isBefore(a) ? a : b;
}

extension StringExtension on String {
  String joinLines([String sep = ""]) {
    return replaceAll("\n", sep);
  }

  String truncated(int n) => substring(0, length - n);

  String get last => this[length - 1];

  String get first => this[0];

  bool get isNumber => num.tryParse(this) != null;

  DateTime toDateTime() {
    try {
      return DateTime.parse(this);
    } catch (error, stackTrace) {
      logger.e("Failed to parse DateTime: value=$this", error, stackTrace);
      // Since it gets sent every time the table is displayed, temporarily disabled.
      // captureException(error, stackTrace);

      // The date has no particular meaning, but having the first digit different improves readability.
      return DateTime(1999, 12, 31);
    }
  }

  /// Parses a date string, answering `null` when it is not one.
  ///
  /// The date counterpart of `toVersionOrNull` in `version_check.dart`, and for
  /// the same reason: where the parsed value is a reference point something else
  /// is compared against, "could not be read" has to stay distinguishable from
  /// "read, and very old". [toDateTime]'s stand-in is smaller than every real
  /// date, so a comparison against it answers as though the reference point were
  /// met -- which is the opposite of what an unreadable one has shown.
  ///
  /// [toDateTime] is deliberately left as it is rather than routed through this:
  /// its remaining callers display or sort the value, and a row that shows
  /// `1999-12-31` and sinks to the bottom of the table is on screen, where the
  /// user can act on it. Only the callers that *decide* something need the null.
  ///
  /// No `captureException` here either. The empty string is a routine input --
  /// the recognizer leaves `trained_date` empty when it could not read the date
  /// off the screen, measured at ~2% of captured records -- so reporting it as
  /// an exception would fire once per such record every time a view is built.
  /// The `logger.e` line is still a Sentry breadcrumb, so the failure is not
  /// silent; it is just not an issue of its own.
  DateTime? toDateTimeOrNull() {
    try {
      return DateTime.parse(this);
    } catch (error, stackTrace) {
      logger.e("Failed to parse DateTime: value=$this", error, stackTrace);
      return null;
    }
  }
}

Iterable<(T1, T2)> zip2<T1, T2>(Iterable<T1> it1, Iterable<T2> it2) sync* {
  for (final e in IterableZip([it1, it2])) {
    yield (e[0] as T1, e[1] as T2);
  }
}

Iterable<(T1, T2, T3)> zip3<T1, T2, T3>(Iterable<T1> it1, Iterable<T2> it2, Iterable<T3> it3) sync* {
  for (final e in IterableZip([it1, it2, it3])) {
    yield (e[0] as T1, e[1] as T2, e[2] as T3);
  }
}

class Progress {
  final int total;
  final int count;

  /// Whether the work cannot report a percentage and should show a spinning
  /// (indeterminate) indicator rather than a determinate ring frozen at [count].
  final bool indeterminate;

  Progress({this.count = 0, required this.total, this.indeterminate = false});

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

  static T clamp<T extends num>(T lower, T src, T upper) => Math.max(Math.min(src, upper), lower);
}

extension WidgetRefExtension on WidgetRef {
  RefBase get base => RefBase._(this);
}

extension RefExtension on Ref {
  RefBase get base => RefBase._(this);
}

class RefBase {
  final dynamic _ref;

  /// When true, [watch] delegates to [read], so reading through this ref
  /// registers no provider dependency. Used to build a grid snapshot that must
  /// not rebuild while a bulk selection is in progress (see [readOnly]).
  final bool _readOnly;

  RefBase._(this._ref, [this._readOnly = false]);

  T read<T>(ProviderListenable<T> provider) => _ref.read(provider);

  T watch<T>(ProviderListenable<T> provider) => _readOnly ? _ref.read(provider) : _ref.watch(provider);

  /// Discards [provider]'s state so the next read rebuilds it.
  ///
  /// Here for the same reason [read] is: a [RefBase] stands in for either a `Ref`
  /// or a `WidgetRef`, and both declare this. Passing a *family* rather than one
  /// of its instances invalidates every instance, which is what a delete that
  /// removed a whole directory of keyed files needs — the keys it held are no
  /// longer readable from anywhere.
  ///
  /// Not gated on [_readOnly]: that flag is about not registering a dependency
  /// while reading, and this neither reads nor subscribes.
  void invalidate(ProviderOrFamily provider) => _ref.invalidate(provider);

  /// A view of this ref whose [watch] behaves like [read], so code that watches
  /// providers through it registers no dependencies and will not be rebuilt.
  RefBase get readOnly => RefBase._(_ref, true);
}

// Base class for the tag-selector providers (skill/factor tag filters in the
// column dialogs). Replaces the legacy StateProvider<Set<String>> + the
// StateProviderLike indirection. Subclasses only override [build] to seed the
// initial selection; mutation goes through [toggle], which assigns a NEW set so
// Riverpod's ==-based filtering fires a rebuild.
abstract class TagSelectionNotifier extends Notifier<Set<String>> {
  void toggle(String tag, {bool? shouldExists}) {
    state = {...state}..toggle(tag, shouldExists: shouldExists);
  }
}

extension AsyncValueExtension<T> on AsyncValue<T> {
  Widget guarded(Widget Function(T) data) {
    return when(loading: () => const CircularProgressIndicator(), error: (e, _) => Text("ERROR: $e"), data: data);
  }
}

extension BuildContextExtension on BuildContext {
  List<Element> getAncestorElements(int depth) {
    final List<Element> elements = [];
    visitAncestorElements((e) {
      elements.add(e);
      return elements.length < depth;
    });
    return elements;
  }
}
