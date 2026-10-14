import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/icons/icons.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/views/dashboard/widget_metrics.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _minSpeedScale = 8 * 1024.0;

class NetworkSpeed extends StatelessWidget {
  const NetworkSpeed({super.key});

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final color = context.colorScheme.onSurfaceVariant.opacity80;
    return SizedBox(
      height: DashboardWidgetMetrics.heightOf(context, 2),
      child: RepaintBoundary(
        child: CommonCard(
          radius: DashboardWidgetMetrics.radiusOf(context),
          onPressed: () {},
          child: Column(
            children: [
              Padding(
                padding: DashboardWidgetMetrics.paddingOf(
                  context,
                ).copyWith(bottom: 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: InfoHeader(
                        padding: EdgeInsets.zero,
                        info: Info(
                          label: appLocalizations.networkSpeed,
                          glyph: AppGlyphs.speed,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SpeedText(color: color),
                  ],
                ),
              ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.all(
                    16,
                  ).copyWith(bottom: 0, left: 0, right: 0),
                  child: const _SpeedChart(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedText extends ConsumerWidget {
  const _SpeedText({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traffic = ref.watch(
      trafficsProvider.select((state) => state.list.safeLast(const Traffic())),
    );
    return Text(
      traffic.speedText,
      style: context.textTheme.bodySmall?.copyWith(color: color),
    );
  }
}

class _SpeedChart extends ConsumerWidget {
  const _SpeedChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traffics = ref.watch(trafficsProvider);
    return LineChart(
      values: [for (final traffic in traffics.list) traffic.speed.toDouble()],
      revision: traffics.revision,
      capacity: traffics.maxLength,
      minScale: _minSpeedScale,
      color: context.colorScheme.primary,
    );
  }
}
