import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/icons/icons.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/connection/connections.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feed_card.dart';

class ConnectionsCard extends ConsumerStatefulWidget {
  final Future<int> Function()? countReader;

  const ConnectionsCard({super.key, @visibleForTesting this.countReader});

  @override
  ConsumerState<ConnectionsCard> createState() => _ConnectionsCardState();
}

class _ConnectionsCardState extends ConsumerState<ConnectionsCard> {
  bool _watching = false;
  Connections? _connections;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _connections ??= ref.read(connectionsProvider.notifier);
    _setWatching(PageActivityScope.isActiveOf(context));
  }

  @override
  void dispose() {
    if (_watching) {
      _connections?.detachCount();
      _watching = false;
    }
    super.dispose();
  }

  void _setWatching(bool active) {
    if (_watching == active) {
      return;
    }
    _watching = active;
    final connections = _connections;
    if (connections == null) {
      return;
    }
    if (active) {
      connections.attachCount(widget.countReader);
    } else {
      connections.detachCount();
    }
  }

  void _openConnections(BuildContext context) {
    showSnapSheet(
      context,
      builder: (_, controller) => ConnectionsView(scrollController: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FeedCard(
      label: PageLabel.connections.label,
      glyph: AppGlyphs.connections,
      onPressed: () => _openConnections(context),
      child: Consumer(
        builder: (_, ref, _) => FeedCount(
          count: ref.watch(connectionsProvider.select((state) => state.count)),
        ),
      ),
    );
  }
}
