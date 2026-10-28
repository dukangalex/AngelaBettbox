import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NetworkSpeed extends ConsumerWidget {
  const NetworkSpeed({super.key});

  // Cache as const
  static const _initPoints = [Point(0, 0), Point(1, 0)];

  static List<Point> _getPoints(List<Traffic> traffics) {
    if (traffics.isEmpty) return _initPoints;

    // Pre-allocate array capacity
    final totalLength = traffics.length + _initPoints.length;
    final result = List<Point>.filled(totalLength, Point(0, 0));

    // Assign init points
    result[0] = _initPoints[0];
    result[1] = _initPoints[1];

    // Assign traffic points
    for (int i = 0; i < traffics.length; i++) {
      result[i + 2] = Point((i + 2).toDouble(), traffics[i].speed.toDouble());
    }

    return result;
  }

  static Traffic _getLastTraffic(List<Traffic> traffics) {
    if (traffics.isEmpty) return Traffic();
    return traffics.last;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = context.colorScheme.onSurfaceVariant.opacity80;
    final primaryColor = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: getWidgetHeight(context, 2),
      child: CommonCard(
        onPressed: () {
          globalState.openUrl('https://ptclspeed.speedtestcustom.com');
        },
        info: Info(
          label: Localizations.localeOf(context).languageCode == 'zh'
              ? '流量与网速'
              : 'Traffic and speed',
          iconData: Icons.speed_sharp,
        ),
        child: RepaintBoundary(
          child: ValueListenableBuilder<int>(
            valueListenable: dashboardRefreshManager.tick1s,
            builder: (_, _, _) {
              final traffics = ref.read(trafficsProvider).list;
              final points = _getPoints(traffics);
              final speedText = _getLastTraffic(traffics).toSpeedText();
              final total = ref.read(totalTrafficProvider);
              return Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: 84,
                        left: 0,
                        right: 0,
                        bottom: 0,
                      ),
                      child: LineChart(
                        gradient: true,
                        color: primaryColor,
                        points: points,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    left: 16,
                    right: 16,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 56,
                          height: 56,
                          child: DonutChart(
                            trackColor: context
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.35),
                            data: [
                              DonutChartData(
                                value: total.up.value.toDouble(),
                                color:
                                    globalState.theme.darken3PrimaryContainer,
                              ),
                              DonutChartData(
                                value: total.down.value.toDouble(),
                                color:
                                    globalState.theme.darken2SecondaryContainer,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${appLocalizations.upload} ↑ ${total.up}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.textTheme.bodySmall?.copyWith(
                                  color:
                                      globalState.theme.darken3PrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${appLocalizations.download} ↓ ${total.down}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.textTheme.bodySmall?.copyWith(
                                  color: globalState
                                      .theme
                                      .darken2SecondaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Transform.translate(
                      offset: const Offset(-16, -20),
                      child: Text(
                        speedText,
                        style: context.textTheme.bodySmall?.copyWith(
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
