import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ConnectionsView extends ConsumerStatefulWidget {
  final ScrollController? scrollController;
  final Future<ConnectionDelta> Function({bool resync})? connectionsReader;

  const ConnectionsView({
    super.key,
    this.scrollController,
    @visibleForTesting this.connectionsReader,
  });

  @override
  ConsumerState<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends ConsumerState<ConnectionsView>
    with
        WidgetsBindingObserver,
        ActivePollingMixin<ConnectionsView>,
        RouteMotionHoldMixin<ConnectionsView> {
  CoreController get _core => ref.read(coreHandlerProvider);

  final _listController = TrackerInfoListController();
  final _speedRanker = TrackerSpeedRanker();
  late final ScrollController _scrollController;
  var _loaded = false;
  ProviderSubscription<ConnectionsSnapshot>? _connections;

  @override
  void initState() {
    super.initState();
    _scrollController =
        widget.scrollController ?? sheetScrollController(context);
    _connections = ref.listenManual(
      connectionsProvider,
      (_, snapshot) => _showConnections(snapshot),
    );
    ref.read(connectionsProvider.notifier).useReader(widget.connectionsReader);
  }

  @override
  Duration get pollInterval => const Duration(seconds: 1);

  List<IconButtonData> _buildActions() {
    return [
      IconButtonData(
        glyph: AppGlyphs.clearAll,
        tooltip: context.appLocalizations.closeConnections,
        onPressed: () async {
          unawaited(_core.closeConnections());
          await _refreshConnections();
        },
      ),
    ];
  }

  @override
  Future<void> poll(PollGuard isCurrent) async {
    await ref.read(connectionsProvider.notifier).refresh();
    if (!isCurrent()) {
      return;
    }
    _showConnections(ref.read(connectionsProvider));
  }

  Future<void> _refreshConnections() async {
    if (!mounted) {
      return;
    }
    await ref.read(connectionsProvider.notifier).refresh();
    if (!mounted) {
      return;
    }
    _showConnections(ref.read(connectionsProvider));
  }

  void _showConnections(ConnectionsSnapshot snapshot) {
    final readAt = DateTime.now();
    if (!_loaded) {
      setState(() => _loaded = true);
      _applyConnections(snapshot.connections, readAt);
      return;
    }
    updateWhenRouteSettled(
      () => _applyConnections(snapshot.connections, readAt),
    );
  }

  void _applyConnections(List<TrackerInfo> trackerInfos, DateTime readAt) {
    _listController.setTrackerInfos(_speedRanker.rank(trackerInfos, readAt));
  }

  Future<void> _handleBlockConnection(String id) async {
    await _core.closeConnection(id);
    await _refreshConnections();
  }

  @override
  void dispose() {
    _connections?.close();
    _listController.dispose();
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      title: PageLabel.connections.label,
      onKeywordsUpdate: _listController.updateKeywords,
      searchState: AppBarSearchState(onSearch: _listController.search),
      iconActions: _buildActions(),
      body: ValueListenableBuilder<TrackerInfosState>(
        valueListenable: _listController,
        builder: (context, state, _) {
          final connections = state.list;
          Widget buildAction(TrackerInfo trackerInfo) {
            return _BlockConnectionButton(
              onPressed: () {
                _handleBlockConnection(trackerInfo.id);
              },
            );
          }

          return NullStatusSwitcher(
            isLoading: !_loaded,
            isEmpty: connections.isEmpty,
            isSearching: state.isSearching,
            nullStatus: NullStatus(
              label: appLocalizations.nullTip(appLocalizations.connections),
              illustration: NullStatusIllustration.connections,
            ),
            child: RecordTableFrame<TrackerInfo>(
              tableId: 'connections',
              items: connections,
              columnsOf: (width) => trackerInfoColumns(
                context,
                width: width,
                isLive: true,
                now: DateTime.now(),
                actionBuilder: buildAction,
              ),
              builder: (context, table, connections) => TrackerInfoAnimatedList(
                controller: _scrollController,
                padding: EdgeInsets.only(
                  top: context.contentTopPadding,
                  bottom: 16 + context.bottomInset,
                ),
                trackerInfos: connections,
                table: table,
                detailTitle: appLocalizations.details(
                  appLocalizations.connection,
                ),
                actionBuilder: buildAction,
              ),
            ),
          );
        },
      ),
    );
  }
}

// One per live row: an IconButton would add a theme animation to each.
class _BlockConnectionButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _BlockConnectionButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.appLocalizations.blockConnection,
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onPressed,
          customBorder: AppShape.circle,
          child: SizedBox.square(
            dimension: 28,
            child: Center(
              child: GlyphIcon(
                AppGlyphs.block,
                size: 16,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
