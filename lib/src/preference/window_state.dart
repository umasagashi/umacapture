import 'dart:ui';

import 'storage_box.dart';

enum _WindowStateEntryKey {
  windowSize,
  windowOffset,
}

class WindowStateBox {
  final StorageBox _box;

  WindowStateBox() : _box = StorageBox(StorageBoxKey.windowState);

  Size? getSize() => _box.pull<Size>(_WindowStateEntryKey.windowSize.name);

  void setSize(Size size) => _box.push(_WindowStateEntryKey.windowSize.name, size);

  Offset? getOffset() => _box.pull<Offset>(_WindowStateEntryKey.windowOffset.name);

  void setOffset(Offset offset) => _box.push(_WindowStateEntryKey.windowOffset.name, offset);
}
