import 'dart:ui';

import 'storage_box.dart';

enum _StorageBoxValueKey {
  windowSize,
  windowOffset,
}

class WindowStateBox {
  final StorageBox _box;

  WindowStateBox() : _box = StorageBox(BoxKey.windowState);

  Size? getSize() => _box.pull<Size>(_StorageBoxValueKey.windowSize.name);

  void setSize(Size size) => _box.push(_StorageBoxValueKey.windowSize.name, size);

  Offset? getOffset() => _box.pull<Offset>(_StorageBoxValueKey.windowOffset.name);

  void setOffset(Offset offset) => _box.push(_StorageBoxValueKey.windowOffset.name, offset);
}
