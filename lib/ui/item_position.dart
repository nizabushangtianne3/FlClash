enum ItemPosition {
  start,
  middle,
  end,
  startAndEnd;

  bool get isStart => this == start || this == startAndEnd;

  bool get isEnd => this == end || this == startAndEnd;

  static ItemPosition get(int index, int length) {
    ItemPosition position = ItemPosition.middle;
    if (length == 1) {
      position = ItemPosition.startAndEnd;
    } else if (index == length - 1) {
      position = ItemPosition.end;
    } else if (index == 0) {
      position = ItemPosition.start;
    }
    return position;
  }
}
