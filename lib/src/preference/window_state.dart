import 'dart:ui';

import 'storage_box.dart';

enum _Key {
  windowSize,
  windowOffset,
}

class WindowStateBox {
  final StorageBox _box;

  WindowStateBox() : _box = StorageBox(BoxKey.windowState);

  Size? getSize() => _box.pull<Size>(_Key.windowSize.name);

  void setSize(Size size) => _box.push(_Key.windowSize.name, size);

  Offset? getOffset() => _box.pull<Offset>(_Key.windowOffset.name);

  void setOffset(Offset offset) => _box.push(_Key.windowOffset.name, offset);
}
