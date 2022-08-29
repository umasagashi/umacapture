import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:quiver/iterables.dart';
import 'package:quiver/time.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_statistics = "pages.statistics";

final statisticsInitialLoader = FutureProvider((ref) async {
  return Future.wait([
    ref.watch(moduleVersionLoader.future),
  ]).then((_) {
    return Future.wait([
      ref.watch(labelMapLoader.future),
      ref.watch(charaDetailRecordStorageLoader.future),
    ]);
  });
});

class _StatisticTile extends ConsumerWidget {
  final Widget title;
  final Widget bottom;
  final InlineWidgetBuilder builder;

  const _StatisticTile({
    Key? key,
    required this.title,
    required this.bottom,
    required this.builder,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.primaryContainer.withOpacity(0.5),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: title,
          ),
          Expanded(
            child: Container(
              alignment: Alignment.center,
              color: theme.colorScheme.primaryContainer.withOpacity(0.2),
              child: ref.watch(statisticsInitialLoader).guarded((_) => builder()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: bottom,
          ),
        ],
      ),
    );
  }
}

class NumberOfRecordStatisticWidget extends ConsumerWidget {
  const NumberOfRecordStatisticWidget({Key? key}) : super(key: key);

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: NumberOfRecordStatisticWidget(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _StatisticTile(
      title: Text("$tr_statistics.record_count.title".tr()),
      bottom: Text("$tr_statistics.record_count.bottom".tr()),
      builder: () {
        final theme = Theme.of(context);
        final records = ref.watch(charaDetailRecordStorageProvider);
        return Text(
          "${records.length}",
          style: theme.textTheme.headlineLarge,
        );
      },
    );
  }
}

class MaxEvaluationValueStatisticWidget extends ConsumerWidget {
  const MaxEvaluationValueStatisticWidget({Key? key}) : super(key: key);

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: MaxEvaluationValueStatisticWidget(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.evaluation_value.title".tr()),
      bottom: Text("$tr_statistics.evaluation_value.bottom".tr()),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider);
        if (records.isEmpty) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        final storage = ref.read(charaDetailRecordStorageProvider.notifier);
        final best = records.reduce((a, b) => a.evaluationValue > b.evaluationValue ? a : b);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.file(
              storage.traineeIconPathOf(best).toFile(),
              height: 56,
            ),
            Text(
              best.evaluationValue.toNumberString(),
              style: theme.textTheme.headlineMedium,
            ),
          ],
        );
      },
    );
  }
}

class MonthlyFansChartData {
  final List<CharaDetailRecord> records;
  final noTitle = AxisTitles(sideTitles: SideTitles(showTitles: false));

  MonthlyFansChartData(this.records);

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

    return enumerate(fans).skip(1).map((e) => FlSpot(e.index.toDouble(), e.value.toDouble())).toList();
  }

  int calcMaxValue(List<FlSpot> spots, int maxX) {
    final actual = spots.map((e) => e.y).max;
    final predicted = actual * maxX / spots.length;
    return (predicted * 1.22).toInt().roundTopmost(4);
  }

  LineChart build(ThemeData theme, DateTime month) {
    final start = DateTime(month.year, month.month);
    final end = start.nextMonth().subtract(aMicrosecond);
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
        ShowingTooltipIndicators([
          LineBarSpot(lineBarsData.first, 0, spots.last),
        ]),
      ],
      lineTouchData: LineTouchData(
        enabled: false,
        touchTooltipData: LineTouchTooltipData(
          tooltipBgColor: theme.colorScheme.surface.blend(Colors.cyan, 50),
          tooltipRoundedRadius: 8,
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          fitInsideHorizontally: true,
          fitInsideVertically: true,
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
          drawBehindEverything: true,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 70,
            interval: horizontalInterval,
            getTitlesWidget: (value, meta) => SideTitleWidget(
              axisSide: meta.axisSide,
              space: 8,
              child: Text(value.toLocalCompactNumberString()),
            ),
          ),
        ),
        topTitles: noTitle,
        bottomTitles: AxisTitles(
          drawBehindEverything: true,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 30,
            interval: 7,
            getTitlesWidget: (value, meta) => SideTitleWidget(
              axisSide: meta.axisSide,
              space: 8.0,
              child: Text(value.toLocalCompactNumberString()),
            ),
          ),
        ),
      ),
      borderData: FlBorderData(border: Border.all(width: 0.5)),
    );

    return LineChart(
      lineChartData,
      swapAnimationDuration: Duration.zero,
    );
  }
}

class MonthlyFansStatisticWidget extends ConsumerStatefulWidget {
  final DateTime start = DateTime(2021, 2);
  final DateTime end = DateTime.now();

  MonthlyFansStatisticWidget({Key? key}) : super(key: key);

  static StaggeredGridTile asTile() {
    return StaggeredGridTile.count(
      crossAxisCellCount: 2,
      mainAxisCellCount: 2,
      child: MonthlyFansStatisticWidget(),
    );
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
    return _StatisticTile(
      title: Text("$tr_statistics.monthly_fans.title".tr()),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Disabled(
            disabled: targetMonth.isSameMonth(widget.start),
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16,
              icon: const Icon(Icons.keyboard_arrow_left),
              onPressed: () {
                setState(() {
                  targetMonth = DateTimeExtension.later(targetMonth.lastMonth(), widget.start);
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
              icon: const Icon(Icons.keyboard_arrow_right),
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
        final records = ref.watch(charaDetailRecordStorageProvider);
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
      for (final i in enumerate(record.aptitudes.distance.flatten)) {
        if (i.value >= targetRank) {
          counts[i.index]++;
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
        tooltipBgColor: Colors.transparent,
        tooltipPadding: EdgeInsets.zero,
        tooltipMargin: 0,
        getTooltipItem: (BarChartGroupData group, int groupIndex, BarChartRodData rod, int rodIndex) {
          return BarTooltipItem(
            rod.toY.round().toString(),
            theme.textTheme.titleMedium!,
          );
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
            return SideTitleWidget(
              axisSide: meta.axisSide,
              space: 4,
              child: Text(labels[value.toInt()]),
            );
          },
        ),
      ),
    );

    final barChartData = BarChartData(
      barTouchData: barTouchData,
      titlesData: titlesData,
      borderData: FlBorderData(show: false),
      barGroups: [
        for (final i in enumerate(counts))
          BarChartGroupData(
            x: i.index,
            barRods: [
              BarChartRodData(
                toY: i.value.toDouble(),
                width: 16,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              )
            ],
            showingTooltipIndicators: [0],
          ),
      ],
      gridData: FlGridData(show: false),
      alignment: BarChartAlignment.spaceAround,
      maxY: maxValue,
    );

    return BarChart(
      barChartData,
      swapAnimationDuration: Duration.zero,
    );
  }
}

class CountSRankStatisticWidget extends ConsumerWidget {
  const CountSRankStatisticWidget({Key? key}) : super(key: key);

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: CountSRankStatisticWidget(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.count_s_rank.title".tr()),
      bottom: Text("$tr_statistics.count_s_rank.bottom".tr()),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider);
        return Padding(
          padding: const EdgeInsets.only(top: 36, bottom: 4),
          child: CountSRankChartData(records).build(theme),
        );
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

  final colors = [
    const Color(0xff0293ee),
    const Color(0xfff8b250),
    const Color(0xff845bef),
    const Color(0xff13d38e),
  ];

  CountStrategyChartData(this.records, this.labels) {
    counts = parse();
    indices = enumerate(counts).sortedBy<num>((e) => -e.value).map((e) => e.index).toList();
  }

  List<int> parse() {
    List<int> d = [0, 0, 0, 0];
    for (final record in records.where((e) => e.metadata.stage == RecordStage.active)) {
      d[record.metadata.strategy]++;
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
            titleStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            titlePositionPercentageOffset: 0.65,
          )
      ],
    );

    return PieChart(
      pieChartData,
      swapAnimationDuration: Duration.zero,
    );
  }
}

class CountStrategyStatisticWidget extends ConsumerWidget {
  const CountStrategyStatisticWidget({Key? key}) : super(key: key);

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: CountStrategyStatisticWidget(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.count_strategy.title".tr()),
      bottom: Text("$tr_statistics.count_strategy.bottom".tr()),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider);
        if (records.isEmpty) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        final labels = ref.watch(labelMapProvider)[LabelKeys.raceStrategy]!;
        final chart = CountStrategyChartData(records, labels);
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
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: chart.colors[i],
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(labels[i])
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
