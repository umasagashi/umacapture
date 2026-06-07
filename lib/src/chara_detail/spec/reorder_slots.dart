import '/src/chara_detail/spec/base.dart';

/// A legal drop position for a dragged column during a live reorder.
///
/// Insert the dragged spec at `children[index]` of the column identified by
/// [parentId], or at `index` of the top-level forest when [parentId] is null.
/// The set of legal slots for a drag is produced by [computeReorderSlots].
class ReorderSlot {
  /// Id of the container the slot lives in, or null for the top-level forest.
  final String? parentId;

  /// Insertion index within the parent's children (or the top-level list).
  final int index;

  const ReorderSlot(this.parentId, this.index);

  @override
  bool operator ==(Object other) => other is ReorderSlot && other.parentId == parentId && other.index == index;

  @override
  int get hashCode => Object.hash(parentId, index);

  @override
  String toString() => 'ReorderSlot($parentId, $index)';
}

/// Removes [id] from anywhere in the forest, returning `(newForest, removed)`.
/// [removed] is null (and the forest unchanged) when [id] is absent. Mirrors
/// `ColumnSpecSelection._detach`; kept local so this module stays Flutter-free
/// and independently testable.
(List<ColumnSpec>, ColumnSpec?) _detach(List<ColumnSpec> list, String id) {
  final result = <ColumnSpec>[];
  ColumnSpec? removed;
  for (final spec in list) {
    if (spec.id == id) {
      removed = spec;
      continue;
    }
    final (newChildren, childRemoved) = _detach(spec.children, id);
    if (childRemoved != null) {
      removed = childRemoved;
      result.add(spec.withChildren(newChildren));
    } else {
      result.add(spec);
    }
  }
  return (result, removed);
}

/// Ordered list of legal drop positions for [draggedId], in left-to-right
/// display order.
///
/// The slots are computed over the tree with [draggedId] already detached, so
/// every [ReorderSlot.index] is valid to pass straight to
/// `ColumnSpecSelection.moveToSlot`. Returns an empty list when [draggedId] is
/// not present in [specs].
///
/// At a group boundary two adjacent slots appear naturally — e.g. "inside the
/// group, after its last child" and "top level, just after the group" — which
/// is what lets a single drag move a column in and out of a logic column. A
/// container that cannot take another child (a full NOT) contributes no inner
/// slot; the position right before a container's header is never a slot.
List<ReorderSlot> computeReorderSlots(List<ColumnSpec> specs, String draggedId) {
  final (working, removed) = _detach(specs, draggedId);
  if (removed == null) {
    return const [];
  }
  final slots = <ReorderSlot>[];
  _walk(working, null, slots);
  return slots;
}

void _walk(List<ColumnSpec> list, ColumnSpec? parent, List<ReorderSlot> slots) {
  final parentId = parent?.id;
  // The top level always accepts slots; a container only when it has room for
  // another child (so a full NOT exposes none of its inner positions).
  final canInsertHere = parent == null || (parent.acceptsChildren && parent.acceptsMoreChildren);
  for (var i = 0; i < list.length; i++) {
    if (canInsertHere) {
      slots.add(ReorderSlot(parentId, i)); // gap before list[i]
    }
    final node = list[i];
    if (node.acceptsChildren && node.children.isNotEmpty) {
      _walk(node.children, node, slots); // descend into the container's own gaps
    } else if (node.acceptsChildren && node.acceptsMoreChildren) {
      slots.add(ReorderSlot(node.id, 0)); // empty container: a single inner slot
    }
  }
  if (canInsertHere) {
    slots.add(ReorderSlot(parentId, list.length)); // trailing gap
  }
}
