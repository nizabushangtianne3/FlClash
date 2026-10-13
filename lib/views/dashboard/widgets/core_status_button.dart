import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/icons/icons.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CoreStatusButton extends ConsumerStatefulWidget {
  const CoreStatusButton({super.key});

  @override
  ConsumerState<CoreStatusButton> createState() => _CoreStatusButtonState();
}

class _CoreStatusButtonState extends ConsumerState<CoreStatusButton> {
  static const _holdDuration = Duration(milliseconds: 600);

  Timer? _holdTimer;
  CoreStatus _status = CoreStatus.disconnected;

  /// Repeated connecting notifications must not restart the one-shot hold.
  bool _holdUsed = false;

  @override
  void initState() {
    super.initState();
    _status = ref.read(coreStatusProvider);
    if (_status == CoreStatus.connecting) {
      _holdUsed = true;
      _holdTimer = Timer(_holdDuration, _releaseHold);
    }
    ref.listenManual(coreStatusProvider, (_, next) {
      _onStatusChanged(next);
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onStatusChanged(CoreStatus next) {
    if (next == _status && (next != CoreStatus.connecting || _holdUsed)) {
      return;
    }
    if (next == CoreStatus.connecting) {
      _holdUsed = true;
      _holdTimer ??= Timer(_holdDuration, _releaseHold);
      setState(() {
        _status = next;
      });
      return;
    }
    _holdUsed = false;
    if (next == CoreStatus.connected && _holdTimer != null) {
      _status = next;
      return;
    }
    setState(() {
      _status = next;
      if (next == CoreStatus.disconnected) {
        _holdTimer?.cancel();
        _holdTimer = null;
      }
    });
  }

  void _releaseHold() {
    if (!mounted) {
      return;
    }
    setState(() {
      _holdTimer = null;
    });
  }

  Future<void> _handleConnection() async {
    if (_holdTimer != null) {
      return;
    }
    final coreStatus = ref.read(coreStatusProvider);
    if (coreStatus == CoreStatus.connecting) {
      return;
    }
    final tip = coreStatus == CoreStatus.connected
        ? context.appLocalizations.forceRestartCoreTip
        : context.appLocalizations.restartCoreTip;
    final res = await dialogs.showMessage(message: TextSpan(text: tip));
    if (res != true) {
      return;
    }
    try {
      await ref.read(coreActionProvider.notifier).restartCore();
    } catch (error) {
      dialogs.showNotifier(error.toString(), level: MessageLevel.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coreStatus = _holdTimer != null ? CoreStatus.connecting : _status;
    final appLocalizations = context.appLocalizations;
    return Tooltip(
      message: appLocalizations.coreStatus,
      child: FadeScaleBox(
        alignment: Alignment.centerRight,
        child: coreStatus == CoreStatus.connected
            ? IconButton.filled(
                style: ElasticPress.buttonStyle.merge(
                  IconButton.styleFrom(
                    backgroundColor: context.colorScheme.success,
                    foregroundColor: switch (Theme.brightnessOf(context)) {
                      Brightness.light => context.colorScheme.onSurfaceVariant,
                      Brightness.dark =>
                        context.colorScheme.onPrimaryFixedVariant,
                    },
                  ),
                ),
                onPressed: _handleConnection,
                icon: const GlyphIcon(AppGlyphs.check, fill: 1),
              )
            : FilledButton.icon(
                key: ValueKey(coreStatus),
                onPressed: _handleConnection,
                style: ElasticPress.buttonStyle.merge(
                  FilledButton.styleFrom(
                    backgroundColor: switch (coreStatus) {
                      CoreStatus.connecting => null,
                      CoreStatus.connected => context.colorScheme.success,
                      CoreStatus.disconnected => context.colorScheme.error,
                    },
                    foregroundColor: switch (coreStatus) {
                      CoreStatus.connecting => null,
                      CoreStatus.connected => switch (Theme.brightnessOf(
                        context,
                      )) {
                        Brightness.light =>
                          context.colorScheme.onSurfaceVariant,
                        Brightness.dark => null,
                      },
                      CoreStatus.disconnected => context.colorScheme.onError,
                    },
                  ),
                ),
                icon: SizedBox(
                  height: globalState.measure.bodyMediumHeight,
                  width: globalState.measure.bodyMediumHeight,
                  child: switch (coreStatus) {
                    CoreStatus.connecting => Padding(
                      padding: const EdgeInsets.all(2),
                      child: CommonCircleLoading(
                        color: context.colorScheme.onPrimary,
                      ),
                    ),
                    CoreStatus.connected => const GlyphIcon(
                      AppGlyphs.check,
                      fill: 1,
                    ),
                    CoreStatus.disconnected => const GlyphIcon(
                      AppGlyphs.refresh,
                      fill: 1,
                    ),
                  },
                ),
                label: Text(switch (coreStatus) {
                  CoreStatus.connecting => appLocalizations.connecting,
                  CoreStatus.connected => appLocalizations.connected,
                  CoreStatus.disconnected => appLocalizations.disconnected,
                }),
              ),
      ),
    );
  }
}
