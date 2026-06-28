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
    return Future.wait([
      ref.watch(labelMapLoader.future),
      ref.watch(charaDetailRecordStorageLoaderProvider.future),
      ref.watch(factorInfoLoader.future),
      ref.watch(charaRankBorderLoader.future),
    ]);
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
  friend,
  user;

  /// The original four-way split (all / trained / inheritance / friend).
  static const fourWay = [
    _RecordCategory.all,
    _RecordCategory.trained,
    _RecordCategory.inheritance,
    _RecordCategory.friend,
  ];

  /// Owner-oriented split (all / player / friend), used by the factor and ranking
  /// tiles where only the player-vs-friend distinction matters.
  static const ownerWay = [_RecordCategory.all, _RecordCategory.user, _RecordCategory.friend];

  /// Localized label, read from the shared `statistics.category` block.
  String get label => switch (this) {
    _RecordCategory.all => "$tr_statistics.category.all".tr(),
    _RecordCategory.trained => "$tr_statistics.category.trained".tr(),
    _RecordCategory.inheritance => "$tr_statistics.category.inheritance".tr(),
    _RecordCategory.friend => "$tr_statistics.category.friend".tr(),
    _RecordCategory.user => "$tr_statistics.category.user".tr(),
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
      _RecordCategory.user => !record.isFriend,
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
        options: _RecordCategory.fourWay,
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

int _evaluationValueOf(CharaDetailRecord record) => record.evaluationValue;

int _skillCountOf(CharaDetailRecord record) => record.skills.length;

/// Total factor count across the whole family, stars ignored and not deduplicated
/// (the same factor in self and a parent counts twice).
int _factorCountOf(CharaDetailRecord record) =>
    record.factors.self.length + record.factors.parent1.length + record.factors.parent2.length;

/// Localized chara-rank label for a record's evaluation value, derived from the
/// rank borders the same way as the chara-detail rank column.
String _rankLabelOf(WidgetRef ref, CharaDetailRecord record) {
  final borders = ref.watch(charaRankBorderProvider);
  final labels = ref.watch(labelMapProvider)[LabelKeys.charaRank]!;
  final index = borders.indexWhere((border) => border > record.evaluationValue);
  return labels[index < 0 ? borders.length : index];
}

/// One row of a ranking tile: rank, trainee icon (rental banner for friends),
/// value, and an optional trailing label (e.g. the chara rank).
class _RankingEntry extends StatelessWidget {
  final int rank;
  final Widget icon;
  final bool isFriend;
  final String valueLabel;
  final String? secondaryLabel;
  final double iconValueGap;

  const _RankingEntry({
    required this.rank,
    required this.icon,
    required this.isFriend,
    required this.valueLabel,
    this.secondaryLabel,
    this.iconValueGap = 10,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text("$rank", style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
          ),
          const SizedBox(width: 4),
          isFriend ? SizedBox.square(dimension: 42, child: FriendMarkedIcon(icon: icon)) : icon,
          SizedBox(width: iconValueGap),
          Expanded(
            child: Text(valueLabel, style: theme.textTheme.titleLarge, textAlign: TextAlign.end),
          ),
          if (secondaryLabel != null) ...[
            const SizedBox(width: 6),
            Text(
              secondaryLabel!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// Top-3 ranking tile shared by the evaluation / skill-count / factor-count tiles.
class _RankingStatisticWidget extends ConsumerStatefulWidget {
  final String titleKey;
  final List<_RecordCategory> options;
  final int Function(CharaDetailRecord) valueOf;

  /// Optional trailing label per record (e.g. the chara rank for evaluation).
  final String Function(WidgetRef, CharaDetailRecord)? secondaryLabelOf;

  /// Gap between the trainee icon and the value column.
  final double iconValueGap;

  const _RankingStatisticWidget({
    required this.titleKey,
    required this.options,
    required this.valueOf,
    this.secondaryLabelOf,
    this.iconValueGap = 10,
  });

  @override
  ConsumerState<_RankingStatisticWidget> createState() => _RankingStatisticWidgetState();
}

class _RankingStatisticWidgetState extends ConsumerState<_RankingStatisticWidget> {
  _RecordCategory category = _RecordCategory.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text(widget.titleKey.tr()),
      bottom: _CategorySwitcher(
        options: widget.options,
        selected: category,
        onChanged: (value) => setState(() => category = value),
      ),
      builder: () {
        final records = ref.watch(charaDetailRecordStorageProvider).where(category.matches).toList();
        if (records.isEmpty) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
        records.sort((a, b) => widget.valueOf(b).compareTo(widget.valueOf(a)));
        final top = records.take(3).toList();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          // IntrinsicWidth sizes every row to the widest one, so the centered
          // block keeps the right-aligned values lined up across rows.
          child: IntrinsicWidth(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in top.indexed)
                  _RankingEntry(
                    rank: entry.$1 + 1,
                    icon: Image.file(storage.traineeIconPathOf(entry.$2).toFile(), height: 42),
                    isFriend: entry.$2.isFriend,
                    valueLabel: widget.valueOf(entry.$2).toNumberString(),
                    secondaryLabel: widget.secondaryLabelOf?.call(ref, entry.$2),
                    iconValueGap: widget.iconValueGap,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class EvaluationRankingStatisticWidget {
  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: _RankingStatisticWidget(
        titleKey: "$tr_statistics.evaluation_value.title",
        options: _RecordCategory.ownerWay,
        valueOf: _evaluationValueOf,
        secondaryLabelOf: _rankLabelOf,
      ),
    );
  }
}

class SkillCountRankingStatisticWidget {
  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: _RankingStatisticWidget(
        titleKey: "$tr_statistics.count_skill.title",
        options: _RecordCategory.ownerWay,
        valueOf: _skillCountOf,
        iconValueGap: 22,
      ),
    );
  }
}

class FactorCountRankingStatisticWidget {
  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: _RankingStatisticWidget(
        titleKey: "$tr_statistics.count_factor.title",
        options: _RecordCategory.ownerWay,
        valueOf: _factorCountOf,
        iconValueGap: 22,
      ),
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
        color: theme.chart.series,
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
    // Records back both the footer (month bounds) and the chart body, so gate the
    // whole tile on the initial loader instead of reading the storage provider —
    // which throws while still loading — directly in build.
    return ref.watch(statisticsInitialLoader).guarded((_) {
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
    });
  }
}

/// Shared "count per category" bar chart: one labelled bar per [counts] entry,
/// with the value drawn on top. Used by the aptitude-S and factor tiles.
BarChart _buildCountBarChart(ThemeData theme, List<int> counts, List<String> labels) {
  final noTitle = AxisTitles(sideTitles: SideTitles(showTitles: false));

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
              color: theme.chart.series,
              borderRadius: const BorderRadius.all(Radius.circular(2)),
            ),
          ],
          showingTooltipIndicators: [0],
        ),
    ],
    gridData: FlGridData(show: false),
    alignment: BarChartAlignment.spaceAround,
    maxY: counts.max.toDouble(),
  );

  return BarChart(barChartData, duration: Duration.zero);
}

class CountSRankChartData {
  final List<CharaDetailRecord> records;

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

  BarChart build(ThemeData theme) => _buildCountBarChart(theme, parse(), labels);
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
        options: _RecordCategory.fourWay,
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
        options: _RecordCategory.fourWay,
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

/// Counts records by the family-wide star sum (self + both parents, type-ignored)
/// of the factors tagged [tag], bucketed into exactly 3..9.
class _FactorStarSumChartData {
  static const buckets = [3, 4, 5, 6, 7, 8, 9];

  final List<CharaDetailRecord> records;
  final Set<int> ids;

  _FactorStarSumChartData({required this.records, required this.ids});

  List<int> parse() {
    final counts = List.filled(buckets.length, 0);
    for (final record in records.where((e) => e.metadata.stage == RecordStage.active)) {
      var sum = 0;
      for (final factor in record.factors.flattened) {
        if (ids.contains(factor.id)) {
          sum += factor.star;
        }
      }
      final index = buckets.indexOf(sum);
      if (index >= 0) {
        counts[index]++;
      }
    }
    return counts;
  }

  BarChart build(ThemeData theme) => _buildCountBarChart(theme, parse(), const ["3", "4", "5", "6", "7", "8", "9"]);
}

class _FactorStarSumStatisticWidget extends ConsumerStatefulWidget {
  final String titleKey;
  final String tag;

  const _FactorStarSumStatisticWidget({required this.titleKey, required this.tag});

  @override
  ConsumerState<_FactorStarSumStatisticWidget> createState() => _FactorStarSumStatisticWidgetState();
}

class _FactorStarSumStatisticWidgetState extends ConsumerState<_FactorStarSumStatisticWidget> {
  _RecordCategory category = _RecordCategory.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text(widget.titleKey.tr()),
      bottom: _CategorySwitcher(
        options: _RecordCategory.ownerWay,
        selected: category,
        onChanged: (value) => setState(() => category = value),
      ),
      builder: () {
        final ids = ref.watch(factorInfoProvider).where((e) => e.tags.contains(widget.tag)).map((e) => e.sid).toSet();
        final records = ref.watch(charaDetailRecordStorageProvider).where(category.matches).toList();
        final chart = _FactorStarSumChartData(records: records, ids: ids);
        if (chart.parse().sum == 0) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        return Padding(padding: const EdgeInsets.only(top: 36, bottom: 4), child: chart.build(theme));
      },
    );
  }
}

class CountBlueFactorStatisticWidget {
  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: _FactorStarSumStatisticWidget(titleKey: "$tr_statistics.count_blue_factor.title", tag: "factor_status"),
    );
  }
}

class CountRedFactorStatisticWidget {
  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 1,
      mainAxisCellCount: 1,
      child: _FactorStarSumStatisticWidget(titleKey: "$tr_statistics.count_red_factor.title", tag: "factor_aptitude"),
    );
  }
}

/// All-time scatter of every player (non-friend) record's evaluation value,
/// the X axis laid out in fractional months from the oldest record.
class _EvaluationScatterChartData {
  final List<CharaDetailRecord> records;

  final noTitle = AxisTitles(sideTitles: SideTitles(showTitles: false));

  /// Trained (own) records only: friend records are not the player's own runs,
  /// and inheritance-only records carry no evaluation value.
  _EvaluationScatterChartData(List<CharaDetailRecord> records)
    : records = records
          .where((record) => (record.metadata.recordType ?? RecordType.standard) == RecordType.standard)
          .toList();

  double _monthOffset(DateTime date, DateTime start) {
    final months = (date.year - start.year) * 12 + (date.month - start.month);
    return months + (date.day - 1) / date.daysInMonth;
  }

  ScatterChart build(ThemeData theme) {
    final dates = records.map((e) => e.trainedDateAsDateTime);
    final oldest = dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final latest = dates.reduce((a, b) => a.isAfter(b) ? a : b);
    final start = DateTime(oldest.year, oldest.month);
    // Anchor month labels to the latest record so its month is always the last
    // label; extend the axis a month past it for right-side margin.
    final lastMonth = (latest.year - start.year) * 12 + (latest.month - start.month);
    final latestOffset = _monthOffset(latest, start);
    // Mirror the Y axis: leave a little headroom past the newest point so its
    // month label sits inside the axis (the boundary tick beyond it is hidden).
    final maxX = Math.max(1.0, latestOffset * 1.03);
    // Same headroom on the left so the oldest point isn't flush against the edge.
    final minX = -(maxX - latestOffset);
    final monthStep = Math.max(1, (lastMonth / 5).ceil());
    final maxValue = records.map((e) => e.evaluationValue).max;
    // Keep headroom above the highest point, but suppress the top-most axis label
    // (it would sit above the real maximum) so no inflated number is shown.
    final maxY = Math.max(1.0, (maxValue * 1.1).ceilToDouble());
    final horizontalInterval = Math.max(1.0, (maxValue / 5).toDouble());

    return ScatterChart(
      ScatterChartData(
        scatterSpots: [
          for (final record in records)
            ScatterSpot(
              _monthOffset(record.trainedDateAsDateTime, start),
              record.evaluationValue.toDouble(),
              dotPainter: FlDotCirclePainter(color: theme.chart.series, radius: 3),
            ),
        ],
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        scatterTouchData: ScatterTouchData(enabled: false),
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: horizontalInterval,
          getDrawingHorizontalLine: (value) => FlLine(strokeWidth: 0.2),
        ),
        titlesData: FlTitlesData(
          // Small reserved strip so the last month label never clips at the edge.
          rightTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 14,
              getTitlesWidget: (value, meta) => const SizedBox.shrink(),
            ),
          ),
          topTitles: noTitle,
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 70,
              interval: horizontalInterval,
              getTitlesWidget: (value, meta) => value > maxValue + 0.5
                  ? const SizedBox.shrink()
                  : SideTitleWidget(meta: meta, space: 8, child: Text(value.toInt().toNumberString())),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 1,
              // Label months counting back from the latest record so its month is
              // the last label; the right margin past it stays unlabelled.
              getTitlesWidget: (value, meta) {
                final month = value.round();
                if (month < 0 || month > lastMonth || (lastMonth - month) % monthStep != 0) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  space: 8,
                  child: Text(DateTime(start.year, start.month + month).toMonthString()),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(border: Border.all(width: 0.5)),
      ),
      duration: Duration.zero,
    );
  }
}

class EvaluationTrendStatisticWidget extends ConsumerWidget {
  const EvaluationTrendStatisticWidget({super.key});

  static StaggeredGridTile asTile() {
    return const StaggeredGridTile.count(
      crossAxisCellCount: 2,
      mainAxisCellCount: 1,
      child: EvaluationTrendStatisticWidget(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _StatisticTile(
      title: Text("$tr_statistics.evaluation_trend.title".tr()),
      bottom: const SizedBox.shrink(),
      builder: () {
        final chart = _EvaluationScatterChartData(ref.watch(charaDetailRecordStorageProvider));
        if (chart.records.isEmpty) {
          return Text("-", style: theme.textTheme.headlineLarge);
        }
        return Padding(padding: const EdgeInsets.only(top: 16, right: 16, bottom: 8), child: chart.build(theme));
      },
    );
  }
}
