import '/src/chara_detail/spec/base.dart';

/// Pure, side-effect-free operations over a forest of [ColumnSpec]s.
///
/// The column selection is a forest: top-level specs may be container columns
/// (logic columns) whose [ColumnSpec.children] are themselves specs, recursively.
/// These helpers operate on a list of roots and return freshly built lists so the
/// caller never aliases a live backing list. Every walk stops at the first id
/// match — ids are unique within the forest, and short-circuiting guarantees a
/// stray duplicate can never strip or rewrite two subtrees.
///
/// Kept free of Flutter/Riverpod state (only [ColumnSpec] is referenced) so both
/// [ColumnSpecSelection] and the reorder-slot geometry share one implementation.

/// Returns the spec with [id] anywhere in the forest, or null when absent.
ColumnSpec? findInForest(List<ColumnSpec> list, String id) {
  for (final spec in list) {
    if (spec.id == id) return spec;
    final found = findInForest(spec.children, id);
    if (found != null) return found;
  }
  return null;
}

/// Removes [id] from anywhere in the forest, returning `(newForest, removed)`.
/// [removed] is null (and the forest returned unchanged) when [id] is absent.
(List<ColumnSpec>, ColumnSpec?) detachFromForest(List<ColumnSpec> list, String id) {
  final result = <ColumnSpec>[];
  ColumnSpec? removed;
  for (final spec in list) {
    if (removed != null) {
      result.add(spec);
      continue;
    }
    if (spec.id == id) {
      removed = spec;
      continue;
    }
    final (newChildren, childRemoved) = detachFromForest(spec.children, id);
    if (childRemoved != null) {
      removed = childRemoved;
      result.add(spec.withChildren(newChildren));
    } else {
      result.add(spec);
    }
  }
  return (result, removed);
}

/// Inserts [child] at [index] within [targetId]'s children, or into the
/// top-level list when [targetId] is null. [index] is clamped to the valid range.
/// Only the affected sibling list is rebuilt; unmatched branches are reused.
List<ColumnSpec> insertIntoForest(List<ColumnSpec> list, String? targetId, int index, ColumnSpec child) {
  if (targetId == null) {
    final result = [...list];
    result.insert(index.clamp(0, result.length), child);
    return result;
  }
  return list.map((spec) {
    if (spec.id == targetId) {
      final children = [...spec.children];
      children.insert(index.clamp(0, children.length), child);
      return spec.withChildren(children);
    }
    return spec.withChildren(insertIntoForest(spec.children, targetId, index, child));
  }).toList();
}

/// Removes [id] and lifts its children into the slot it occupied (a logic column
/// dissolves back into normal columns). Returns null when [id] is not found.
List<ColumnSpec>? removeLifting(List<ColumnSpec> list, String id) {
  for (var i = 0; i < list.length; i++) {
    final spec = list[i];
    if (spec.id == id) {
      return [...list.sublist(0, i), ...spec.children, ...list.sublist(i + 1)];
    }
    final newChildren = removeLifting(spec.children, id);
    if (newChildren != null) {
      return [...list.sublist(0, i), spec.withChildren(newChildren), ...list.sublist(i + 1)];
    }
  }
  return null;
}

/// Replaces the spec sharing [replacement]'s id, anywhere in the forest. Returns
/// null when no spec with that id exists.
List<ColumnSpec>? replaceInForest(List<ColumnSpec> list, ColumnSpec replacement) {
  for (var i = 0; i < list.length; i++) {
    final spec = list[i];
    if (spec.id == replacement.id) {
      return [...list.sublist(0, i), replacement, ...list.sublist(i + 1)];
    }
    final newChildren = replaceInForest(spec.children, replacement);
    if (newChildren != null) {
      return [...list.sublist(0, i), spec.withChildren(newChildren), ...list.sublist(i + 1)];
    }
  }
  return null;
}

/// Depth-first flatten of the forest into display order: a parent (container) is
/// immediately followed by its children, recursively.
List<ColumnSpec> flattenForest(List<ColumnSpec> specs) {
  final result = <ColumnSpec>[];
  for (final spec in specs) {
    result.add(spec);
    result.addAll(flattenForest(spec.children));
  }
  return result;
}
