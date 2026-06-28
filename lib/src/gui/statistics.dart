import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/character.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';
import '/src/gui/theme_extensions.dart';

// ignore: constant_identifier_names
const tr_statistics = "pages.statistics";

final statisticsInitialLoader = FutureProvider((ref) async {
  return Future.wait([ref.watch(moduleVersionLoader.future)]).then((_) {
    return Future.wait([ref.watch(labelMapLoader.future), ref.watch(charaDetailRecordStorageLoaderProvider.future)]);
  });
});

class _StatisticTile extends ConsumerWidget {
  final Widget title;
  final Widget bottom;
  final InlineBuilder<Widget> builder;

  const _StatisticTile({required this.title, required this.bottom, required this.builder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        // No fill: the whole tile (title/footer strips and the transparent chart
        // body) follows the enclosing card background (cardTheme.color).
        border: Border.all(color: theme.colorScheme.primaryContainer, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.all(4), child: title),
          Expanded(
            child: Container(
              alignment: Alignment.center,
              color: Colors.transparent,
              child: ref.watch(statisticsInitialLoader).guarded((_) => builder()),
            ),
          ),
          Padding(padding: const EdgeInsets.all(4), child: bottom),
        ],
      ),
    );
  }
}

/// Record-type filter shared by the switchable statistics tiles.
enum _RecordCategory {
  all,
  trained,
  inheritance,
  friend;

  /// Localized label, read from the shared `statistics.category` block.
  String get label => switch (this) {
    _RecordCategory.all => "$tr_statistics.category.all".tr(),
    _RecordCategory.trained => "$tr_statistics.category.trained".tr(),
    _RecordCategory.inheritance => "$tr_statistics.category.inheritance".tr(),
    _RecordCategory.friend => "$tr_statistics.category.friend".tr(),
  };

  bool matches(CharaDetailRecord record) {
    // A null recordType means a legacy record captured before the type was
    // recognized; the app treats those as standard (see RecordTypeParser).
    final type = record.metadata.recordType ?? RecordType.standard;
    return switch (this) {
      _RecordCategory.all => true,
      _RecordCategory.trained => type == RecordType.standard,
      _RecordCategory.inheritance => type == RecordType.inheritanceOnly,
      _RecordCategory.friend => type == RecordType.friendStandard || type == RecordType.friendInheritance,
    };
  }
}

/// A left/right switcher over [options] driving a [_RecordCategory] selection,
/// styled like the other statistics-tile footers (arrows flanking a label).
class _CategorySwitcher extends StatelessWidget {
  final List<_RecordCategory> options;
  final _RecordCategory selected;
  final ValueChanged<_RecordCategory> onChanged;

  const _CategorySwitcher({required this.options, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final index = options.indexOf(selected);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Disabled(
          disabled: index == 0,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            splashRadius: 16,
            icon: const Icon(Symbols.keyboard_arrow_left_rounded),
            onPressed: () => onChanged(options[index - 1]),
          ),
        ),
        Text(selected.label),
        Disabled(
          disabled: index == options.length - 1,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            splashRadius: 16,
            icon: const Icon(Symbols.keyboard_arrow_right_rounded),
            onPressed: () => onChanged(options[index + 1]),
          ),
        ),
      ],
    );
  }
}

class NumberOfRecordStatisticWidget extends ConsumerStatefulWidget {
  const NumberOfRecordStatisticWidget({super.key});

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: NumberOfRecordStatisticWidget(),
    );
  }

  @override
  ConsumerState<NumberOfRecordStatisticWidget> createState() => _NumberOfRecordStatisticWidgetState();
}

class _NumberOfRecordStatisticWidgetState extends ConsumerState<NumberOfRecordStatisticWidget> {
  _RecordCategory category = _RecordCategory.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.record_count.title".tr()),
      bottom: _CategorySwitcher(
        options: _RecordCategory.values,
        selected: category,
        onChanged: (value) => setState(() => category = value),
      ),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider);
        final count = records.where(category.matches).length;
        return Text("$count", style: theme.textTheme.headlineLarge);
      },
    );
  }
}

class MaxEvaluationValueStatisticWidget extends ConsumerStatefulWidget {
  const MaxEvaluationValueStatisticWidget({super.key});

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: MaxEvaluationValueStatisticWidget(),
    );
  }

  @override
  ConsumerState<MaxEvaluationValueStatisticWidget> createState() => _MaxEvaluationValueStatisticWidgetState();
}

class _MaxEvaluationValueStatisticWidgetState extends ConsumerState<MaxEvaluationValueStatisticWidget> {
  // Inheritance-only records carry no evaluation value, so that category is omitted.
  static const _options = [_RecordCategory.all, _RecordCategory.trained, _RecordCategory.friend];

  _RecordCategory category = _RecordCategory.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.evaluation_value.title".tr()),
      bottom: _CategorySwitcher(
        options: _options,
        selected: category,
        onChanged: (value) => setState(() => category = value),
      ),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider).where(category.matches);
        if (records.isEmpty) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
        final best = records.reduce((a, b) => a.evaluationValue > b.evaluationValue ? a : b);
        final icon = Image.file(storage.traineeIconPathOf(best).toFile(), height: 56);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // A friend's (rental) record gets the same rental banner as the
            // data table's character column. The fixed box bounds the marker's
            // LayoutBuilder, which otherwise sizes off the unbounded column.
            best.isFriend ? SizedBox.square(dimension: 56, child: FriendMarkedIcon(icon: icon)) : icon,
            Text(best.evaluationValue.toNumberString(), style: theme.textTheme.headlineMedium),
          ],
        );
      },
    );
  }
}

class MonthlyFansChartData {
  final List<CharaDetailRecord> records;
  final noTitle = AxisTitles(sideTitles: SideTitles(showTitles: false));

  /// Friend (practice-partner) records are excluded: their fan counts belong to
  /// the friend's trainee, not the player's own monthly fan acquisition.
  MonthlyFansChartData(List<CharaDetailRecord> records)
    : records = records.where((record) => !record.isFriend).toList();

  List<FlSpot> parse({required DateTime start, required DateTime end}) {
    final targets = records.where((record) => record.trainedDateAsDateTime.isInRange(start, end));

    final fansPerDay = targets.groupFoldBy<int, int>(
      (record) => record.trainedDateAsDateTime.inDays,
      (previous, record) => (previous ?? 0) + record.fans,
    );

    final List<int> fans = [0];
    for (final day in ((end - start).inDays + 1).range()) {
      fans.add(fans.last + (fansPerDay[start.inDays + day] ?? 0));
    }

    return fans.indexed.skip(1).map((e) => FlSpot(e.$1.toDouble(), e.$2.toDouble())).toList();
  }

  int calcMaxValue(List<FlSpot> spots, int maxX) {
    // `.max` throws on an empty iterable and `/ spots.length` divides by zero,
    // so a month range that yields no data points must short-circuit.
    if (spots.isEmpty) {
      return 0;
    }
    final actual = spots.map((e) => e.y).max;
    final predicted = actual * maxX / spots.length;
    return (predicted * 1.2).toInt().roundTopmost(4);
  }

  LineChart build(ThemeData theme, DateTime month) {
    final start = DateTime(month.year, month.month);
    final end = start.nextMonth().subtract(const Duration(microseconds: 1));
    final now = DateTime.now();
    final List<FlSpot> spots = parse(start: start, end: end.isAfter(now) ? now : end);
    final maxValue = calcMaxValue(spots, end.day);
    final horizontalInterval = Math.max(1.0, (maxValue ~/ 10).toDouble());

    List<LineChartBarData> lineBarsData = [
      LineChartBarData(
        spots: spots,
        isCurved: false,
        barWidth: 3,
        dotData: FlDotData(
          // show: false,
          checkToShowDot: (FlSpot spot, LineChartBarData barData) {
            return spot == barData.spots.last;
          },
        ),
      ),
    ];

    LineChartData lineChartData = LineChartData(
      minX: 1,
      maxX: month.daysInMonth.toDouble(),
      minY: 0,
      maxY: maxValue.toDouble(),
      lineBarsData: lineBarsData,
      showingTooltipIndicators: [
        ShowingTooltipIndicators([LineBarSpot(lineBarsData.first, 0, spots.last)]),
      ],
      lineTouchData: LineTouchData(
        enabled: false,
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (touchedSpot) => theme.colorScheme.surfaceContainerHighest,
          tooltipBorderRadius: BorderRadius.circular(8),
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          fitInsideHorizontally: true,
          getTooltipItems: (List<LineBarSpot> lineBarsSpot) {
            return lineBarsSpot.map((lineBarSpot) {
              return LineTooltipItem(
                lineBarSpot.y.toInt().toLocalCompactNumberString(),
                theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurface),
              );
            }).toList();
          },
        ),
      ),
      gridData: FlGridData(
        drawVerticalLine: false,
        horizontalInterval: horizontalInterval,
        getDrawingHorizontalLine: (value) => FlLine(strokeWidth: 0.2),
      ),
      titlesData: FlTitlesData(
        rightTitles: noTitle,
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 70,
            interval: horizontalInterval,
            getTitlesWidget: (value, meta) =>
                SideTitleWidget(meta: meta, space: 8, child: Text(value.toLocalCompactNumberString())),
          ),
        ),
        topTitles: noTitle,
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 30,
            interval: 7,
            getTitlesWidget: (value, meta) =>
                SideTitleWidget(meta: meta, space: 8.0, child: Text(value.toLocalCompactNumberString())),
          ),
        ),
      ),
      borderData: FlBorderData(border: Border.all(width: 0.5)),
    );

    return LineChart(lineChartData, duration: Duration.zero);
  }
}

class MonthlyFansStatisticWidget extends ConsumerStatefulWidget {
  final DateTime end = DateTime.now();

  MonthlyFansStatisticWidget({super.key});

  static StaggeredGridTile asTile() {
    return StaggeredGridTile.count(crossAxisCellCount: 2, mainAxisCellCount: 2, child: MonthlyFansStatisticWidget());
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MonthlyFansStatisticWidgetState();
}

class _MonthlyFansStatisticWidgetState extends ConsumerState<MonthlyFansStatisticWidget> {
  late DateTime targetMonth;

  @override
  void initState() {
    super.initState();
    targetMonth = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = ref.watch(charaDetailRecordStorageProvider);
    // The earliest navigable month is the month of the oldest player (non-friend)
    // record; with no such record, fall back to the current month.
    final playerDates = records.where((record) => !record.isFriend).map((record) => record.trainedDateAsDateTime);
    final oldest = playerDates.isEmpty ? widget.end : playerDates.reduce((a, b) => a.isBefore(b) ? a : b);
    final start = DateTime(oldest.year, oldest.month);
    return _StatisticTile(
      title: Text("$tr_statistics.monthly_fans.title".tr()),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Disabled(
            disabled: targetMonth.isSameMonth(start),
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16,
              icon: const Icon(Symbols.keyboard_arrow_left_rounded),
              onPressed: () {
                setState(() {
                  targetMonth = DateTimeExtension.later(targetMonth.lastMonth(), start);
                });
              },
            ),
          ),
          Text(targetMonth.toMonthString()),
          Disabled(
            disabled: targetMonth.isSameMonth(widget.end),
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16,
              icon: const Icon(Symbols.keyboard_arrow_right_rounded),
              onPressed: () {
                setState(() {
                  targetMonth = DateTimeExtension.earlier(targetMonth.nextMonth(), widget.end);
                });
              },
            ),
          ),
        ],
      ),
      builder: () {
        if (records.isEmpty) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        return Padding(
          padding: const EdgeInsets.only(top: 16, right: 16, bottom: 8),
          child: MonthlyFansChartData(records).build(theme, targetMonth),
        );
      },
    );
  }
}

class CountSRankChartData {
  final List<CharaDetailRecord> records;

  final noTitle = AxisTitles(sideTitles: SideTitles(showTitles: false));

  final List<String> labels = [
    "$tr_statistics.count_s_rank.aptitude.short_range".tr(),
    "$tr_statistics.count_s_rank.aptitude.mile_range".tr(),
    "$tr_statistics.count_s_rank.aptitude.middle_range".tr(),
    "$tr_statistics.count_s_rank.aptitude.long_range".tr(),
  ];

  CountSRankChartData(this.records);

  List<int> parse() {
    const targetRank = 7;
    List<int> counts = [0, 0, 0, 0];
    for (final record in records.where((e) => e.metadata.stage == RecordStage.active)) {
      for (final i in record.aptitudes.distance.flatten.indexed) {
        if (i.$2 >= targetRank) {
          counts[i.$1]++;
        }
      }
    }
    return counts;
  }

  BarChart build(ThemeData theme) {
    final counts = parse();
    final maxValue = counts.max.toDouble();

    final barTouchData = BarTouchData(
      enabled: false,
      touchTooltipData: BarTouchTooltipData(
        getTooltipColor: (group) => Colors.transparent,
        tooltipPadding: EdgeInsets.zero,
        tooltipMargin: 0,
        getTooltipItem: (BarChartGroupData group, int groupIndex, BarChartRodData rod, int rodIndex) {
          return BarTooltipItem(rod.toY.round().toString(), theme.textTheme.titleMedium!);
        },
      ),
    );

    final titlesData = FlTitlesData(
      show: true,
      leftTitles: noTitle,
      rightTitles: noTitle,
      topTitles: noTitle,
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 30,
          getTitlesWidget: (double value, TitleMeta meta) {
            return SideTitleWidget(meta: meta, space: 4, child: Text(labels[value.toInt()]));
          },
        ),
      ),
    );

    final barChartData = BarChartData(
      barTouchData: barTouchData,
      titlesData: titlesData,
      borderData: FlBorderData(show: false),
      barGroups: [
        for (final i in counts.indexed)
          BarChartGroupData(
            x: i.$1,
            barRods: [
              BarChartRodData(
                toY: i.$2.toDouble(),
                width: 16,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ],
            showingTooltipIndicators: [0],
          ),
      ],
      gridData: FlGridData(show: false),
      alignment: BarChartAlignment.spaceAround,
      maxY: maxValue,
    );

    return BarChart(barChartData, duration: Duration.zero);
  }
}

class CountSRankStatisticWidget extends ConsumerStatefulWidget {
  const CountSRankStatisticWidget({super.key});

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: CountSRankStatisticWidget(),
    );
  }

  @override
  ConsumerState<CountSRankStatisticWidget> createState() => _CountSRankStatisticWidgetState();
}

class _CountSRankStatisticWidgetState extends ConsumerState<CountSRankStatisticWidget> {
  _RecordCategory category = _RecordCategory.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.count_s_rank.title".tr()),
      bottom: _CategorySwitcher(
        options: _RecordCategory.values,
        selected: category,
        onChanged: (value) => setState(() => category = value),
      ),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider).where(category.matches).toList();
        final chart = CountSRankChartData(records);
        // Guard against an empty/all-active-less record set: `build` derives
        // `maxY` from `counts.max`, which is 0 here and yields a degenerate axis.
        if (chart.parse().sum == 0) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        return Padding(padding: const EdgeInsets.only(top: 36, bottom: 4), child: chart.build(theme));
      },
    );
  }
}

class CountStrategyChartData {
  final List<CharaDetailRecord> records;
  final List<String> labels;
  late final List<int> counts;
  late final List<int> indices;

  final noTitle = AxisTitles(sideTitles: SideTitles(showTitles: false));

  final List<Color> colors;

  CountStrategyChartData(this.records, this.labels, this.colors) {
    counts = parse();
    indices = counts.indexed.sortedBy<num>((e) => -e.$2).map((e) => e.$1).toList();
  }

  List<int> parse() {
    List<int> d = [0, 0, 0, 0];
    for (final record in records.where((e) => e.metadata.stage == RecordStage.active)) {
      final strategy = record.metadata.strategy;
      if (strategy >= 0 && strategy < d.length) {
        d[strategy]++;
      }
    }
    return d;
  }

  PieChart build(ThemeData theme, double space) {
    final total = counts.sum;
    final pieChartData = PieChartData(
      startDegreeOffset: -90,
      sectionsSpace: 2,
      centerSpaceRadius: 0,
      sections: [
        for (final i in indices)
          PieChartSectionData(
            color: colors[i],
            value: counts[i].toDouble(),
            title: "${(100 * counts[i] / total).round().toNumberString()} %",
            radius: space / 2,
            titleStyle: TextStyle(fontWeight: FontWeight.bold, color: theme.semantic.onAccent),
            titlePositionPercentageOffset: 0.65,
          ),
      ],
    );

    return PieChart(pieChartData, duration: Duration.zero);
  }
}

class CountStrategyStatisticWidget extends ConsumerStatefulWidget {
  const CountStrategyStatisticWidget({super.key});

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: CountStrategyStatisticWidget(),
    );
  }

  @override
  ConsumerState<CountStrategyStatisticWidget> createState() => _CountStrategyStatisticWidgetState();
}

class _CountStrategyStatisticWidgetState extends ConsumerState<CountStrategyStatisticWidget> {
  _RecordCategory category = _RecordCategory.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.count_strategy.title".tr()),
      bottom: _CategorySwitcher(
        options: _RecordCategory.values,
        selected: category,
        onChanged: (value) => setState(() => category = value),
      ),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider).where(category.matches).toList();
        final labels = ref.watch(labelMapProvider)[LabelKeys.raceStrategy]!;
        final chart = CountStrategyChartData(records, labels, theme.chart.categories);
        // Guard against a non-empty record set that yields no active records:
        // `chart.build` would otherwise divide by a zero total and crash on NaN.round().
        if (chart.counts.sum == 0) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return chart.build(theme, Math.min(constraints.maxHeight, constraints.maxWidth));
                  },
                ),
              ),
              const SizedBox(width: 4),
              Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final i in chart.indices)
                    Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: chart.colors[i]),
                        ),
                        const SizedBox(width: 4),
                        Text(labels[i]),
                      ],
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
