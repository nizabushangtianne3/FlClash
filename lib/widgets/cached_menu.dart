import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

/// Holds the menu a row's [ContextMenuRegion] takes until what the menu reads
/// changes: a table row rebuilds whenever its counters move, which the menu
/// does not read.
class CachedMenu extends StatefulWidget {
  const CachedMenu({
    super.key,
    required this.inputs,
    required this.menuItemsOf,
    required this.child,
  });

  /// What the menu reads. A change to any of them builds a new menu.
  final List<Object?> inputs;
  final List<PopupMenuItem> Function() menuItemsOf;
  final Widget child;

  @override
  State<CachedMenu> createState() => _CachedMenuState();
}

class _CachedMenuState extends State<CachedMenu> {
  late List<PopupMenuItem> _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The labels come from the localizations, which this build depends on.
    _items = widget.menuItemsOf();
  }

  @override
  void didUpdateWidget(CachedMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.inputs, widget.inputs)) {
      _items = widget.menuItemsOf();
    }
  }

  @override
  Widget build(BuildContext context) =>
      ContextMenuRegion(menuItems: _items, child: widget.child);
}
