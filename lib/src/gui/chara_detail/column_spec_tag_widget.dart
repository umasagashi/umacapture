import 'package:badges/badges.dart' as badges;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/reorder_slots.dart';
import '/src/chara_detail/spec/spec_tree.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_builder_dialog.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

// Horizontal gap between chips. Applied as trailing padding per chip rather than
// via Wrap.spacing, so the collapsed dragged chip (rendered without it) leaves
// no stray gap behind in the flow.
const double _chipGap = 4;

// Deadband (in pixels) around a chip's centre within which the placeholder does
// not switch sides, so it doesn't flicker when the pointer hovers right on the
// boundary.
const double _slotSwitchMargin = 6;

// How long a chip takes to slide from its old slot to its new one while
// reordering. Short enough to feel responsive, long enough to read as a slide.
const Duration _reorderSlideDuration = Duration(milliseconds: 160);

// A chip the pointer can hover to choose a drop slot. The pointer crossing the
// chip's centre flips the target between [before] (its left half) and [after]
// (its right half). For a logic column the header maps before-the-group / into
// its front, while the box (only reachable over its padding) maps around the
// whole group.
class _HitTarget {
  final GlobalKey key;
  final ReorderSlot before;
  final ReorderSlot after;

  const _HitTarget(this.key, this.before, this.after);
}

class ColumnSpecTagWidget extends ConsumerStatefulWidget {
  const ColumnSpecTagWidget({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColumnSpecTagWidgetState();
}

// Renders the column chips as a live-reorderable forest. Dragging a chip does
// not float it on the cursor and inserts no gaps: the dragged chip collapses in
// place and a placeholder copy appears at the drop location, so the row always
// looks like the normal run of chips with the order rearranging as the pointer
// moves. The drop slot is chosen geometrically — the placeholder hops to the
// nearest legal slot (see reorder_slots.dart) under the pointer — and the same
// gesture moves a column between siblings, into a logic column and back out.
// The tree is mutated once, on drop, via ColumnSpecSelection.moveToSlot.
//
// The dragged chip stays mounted at its own position in the tree for the whole
// gesture (only collapsed) — it is never reparented, because a Draggable hosts
// its drag avatar in an OverlayPortal and moving it across the tree mid-drag
// crashes layout. The tree is left untouched until drop for the same reason.
class _ColumnSpecTagWidgetState extends ConsumerState<ColumnSpecTagWidget> {
  // Id of the chip currently being dragged, or null when idle.
  String? _draggingId;

  // The spec being dragged, derived from [_draggingId]. The tree is left untouched
  // for the whole gesture, so a live lookup always finds the dragged spec; keeping
  // it as a getter avoids a second field that must be kept in sync by hand.
  ColumnSpec? get _draggedSpec =>
      _draggingId == null ? null : findInForest(ref.read(currentColumnSpecsProvider), _draggingId!);

  // Slot the placeholder currently occupies (where a drop would land).
  ReorderSlot? _currentSlot;

  // Legal drop slots for the active drag, computed over the tree with the
  // dragged subtree removed. The single source of truth for reachable slots.
  Set<ReorderSlot> _legalSlots = const {};

  // Hoverable chips for the active drag, rebuilt every build and hit-tested in
  // [_onMove] to pick the drop slot from the chip under (or nearest) the pointer.
  List<_HitTarget> _hitTargets = [];

  // Stable key on the placeholder, so [_onMove] can ignore hovers over it
  // (it carries no slot of its own) instead of wandering to a neighbour.
  final GlobalKey _placeholderKey = GlobalKey();

  // Stable keys per spec id so chip rectangles can be measured during a drag.
  // [_outerKeys] mark a chip (or a logic container's outer box) at its sibling
  // level; [_headerKeys] mark a container's header chip (the left neighbour of
  // its first inner slot).
  final Map<String, GlobalKey> _outerKeys = {};
  final Map<String, GlobalKey> _headerKeys = {};

  // Stable keys for the dashed empty slot an empty logic container shows, so its
  // (id, 0) drop target can be measured during a drag.
  final Map<String, GlobalKey> _emptySlotKeys = {};

  // Per-build snapshot of the data the chips need, so the recursive helpers
  // don't each re-read the providers.
  Map<String, int> _counts = const {};
  int _recordCount = 0;
  Set<String> _brokenIds = const {};

  GlobalKey _outerKeyFor(String id) => _outerKeys.putIfAbsent(id, () => GlobalKey());

  GlobalKey _headerKeyFor(String id) => _headerKeys.putIfAbsent(id, () => GlobalKey());

  GlobalKey _emptySlotKeyFor(String id) => _emptySlotKeys.putIfAbsent(id, () => GlobalKey());

  // Wraps a chip with the trailing gap that stands in for Wrap.spacing. Used
  // only for the placeholder's own static contents, which carry no keys.
  Widget _spaced(Widget child) => Padding(
    padding: const EdgeInsets.only(right: _chipGap),
    child: child,
  );

  // A keyed, padded slot for a live (reorderable) chip. Keying every Wrap child
  // keeps reconciliation from reparenting the dragged chip's Draggable — whose
  // OverlayPortal drag avatar would otherwise crash layout — as the placeholder
  // shuffles the siblings. The dragged chip reuses the same slot with no gap, so
  // it collapses without leaving a stray space and without changing structure.
  //
  // The child is wrapped in a [_FlipMover] so that, while a drag is in progress,
  // a chip whose slot changed slides from its old position to its new one
  // instead of jumping. The key on this Padding keeps the mover's Element (and
  // thus its remembered position) stable as the slot moves within the Wrap.
  Widget _slot(Key key, Widget child, {bool gap = true}) => Padding(
    key: key,
    padding: EdgeInsets.only(right: gap ? _chipGap : 0),
    child: _FlipMover(animate: _draggingId != null, child: child),
  );

  // Wraps [child] in the pass-count badge shared by every chip: it shows how many
  // records pass this column's condition, and stays hidden when every record
  // passes (i.e. the column filters nothing).
  Widget _countBadge(BuildContext context, ColumnSpec spec, Widget child) {
    final theme = Theme.of(context);
    final passed = _counts[spec.id];
    final count = passed == null || passed == _recordCount ? null : passed;
    return badges.Badge(
      showBadge: count != null,
      position: badges.BadgePosition.topEnd(top: -8, end: -8),
      badgeStyle: badges.BadgeStyle(
        badgeColor: theme.chipTheme.selectedColor ?? theme.colorScheme.primaryContainer,
        shape: badges.BadgeShape.square,
        borderRadius: BorderRadius.circular(8),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      ignorePointer: true,
      badgeContent: Text("$count", style: theme.textTheme.labelSmall, textAlign: TextAlign.center),
      child: child,
    );
  }

  // The interactive chip for a leaf column (badge + action chip). When
  // [highlight] is set (the dragged placeholder copy) the chip is tinted and
  // bordered with the accent colour so it stands out while dragging. Logic
  // columns render their operator name with [_logicLabel] instead.
  Widget _actionChip(BuildContext context, ColumnSpec spec, {bool highlight = false}) {
    final theme = Theme.of(context);
    final broken = _brokenIds.contains(spec.id);
    return _countBadge(
      context,
      spec,
      GestureDetector(
        onSecondaryTap: () => ref.read(currentColumnSpecsLoaderProvider.notifier).removeIfExists(spec.id),
        child: ActionChip(
          avatar: broken ? Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer) : null,
          label: spec.label(),
          tooltip: broken ? "$tr_chara_detail.column_predicate.broken.tooltip".tr() : spec.tooltip(ref.base),
          backgroundColor: highlight
              ? theme.colorScheme.secondaryContainer
              : (broken ? theme.colorScheme.errorContainer : null),
          onPressed: () {
            ColumnSpecDialog.show(ref.base, spec);
          },
        ),
      ),
    );
  }

  // The logic column's operator name, rendered as plain text fused into the
  // container's left edge — no chip decoration — instead of an action chip. It
  // keeps the chip's behaviours: tap edits the notation, secondary-tap removes
  // the column, the pass-count badge is shown, and a broken column is flagged
  // with a warning icon and the error colour. When [highlight] is set (the
  // dragged placeholder copy) the text takes the accent colour.
  Widget _logicLabel(BuildContext context, ColumnSpec spec, {bool highlight = false}) {
    final theme = Theme.of(context);
    final broken = _brokenIds.contains(spec.id);
    final color = highlight
        ? theme.colorScheme.primary
        : (broken ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant);
    return _countBadge(
      context,
      spec,
      Tooltip(
        message: broken ? "$tr_chara_detail.column_predicate.broken.tooltip".tr() : spec.tooltip(ref.base),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => ColumnSpecDialog.show(ref.base, spec),
            onSecondaryTap: () => ref.read(currentColumnSpecsLoaderProvider.notifier).removeIfExists(spec.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (broken) ...[Icon(Icons.warning_amber_rounded, size: 16, color: color), const SizedBox(width: 2)],
                  DefaultTextStyle.merge(
                    style: theme.textTheme.labelLarge!.copyWith(color: color, fontWeight: FontWeight.w600),
                    child: spec.label(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The bordered container shared by the live and placeholder renderings of a
  // logic column. [inner] is the laid-out, already-spaced header + children
  // (+ placeholder). Uses padding-based gaps, so Wrap.spacing stays 0. When
  // [highlight] is set the border switches to the accent colour to match the
  // dragged placeholder's emphasis.
  Widget _logicContainer(BuildContext context, List<Widget> inner, {bool highlight = false}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: highlight ? theme.colorScheme.primary : theme.colorScheme.primaryContainer),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: inner),
    );
  }

  // The visual body of a draggable chip (no Draggable wrapper). Logic columns
  // recurse through [_buildSiblings] so their children participate in the same
  // slot layout; leaf columns are a single action chip.
  Widget _chipContent(BuildContext context, ColumnSpec spec) {
    if (!spec.acceptsChildren) {
      return _actionChip(context, spec);
    }
    final header = _slot(_headerKeyFor(spec.id), _logicLabel(context, spec));
    // A container counts as empty the moment its only child is the one being
    // dragged out: the tree is left untouched until drop, so that child is still
    // listed, but it renders collapsed and the dashed drop slot should already
    // show — both to read as empty and so the child can be dropped back in. The
    // dragged child keeps its own slot (same key) so its Draggable is never
    // reparented mid-gesture.
    final hasLiveChild = spec.children.any((c) => c.id != _draggingId);
    final inner = hasLiveChild
        ? _buildSiblings(context, spec.children, parentId: spec.id)
        : [
            for (final child in spec.children)
              if (child.id == _draggingId) _slot(_outerKeyFor(child.id), _dragChip(context, child), gap: false),
            _emptyDropSlot(context, spec),
          ];
    return _logicContainer(context, [header, ...inner]);
  }

  // The single inner slot an empty logic container shows: a dashed, rounded
  // placeholder box. The text-only header alone is too small to aim at, so this
  // gives a comfortably sized drop target for the container's only inner
  // position, (id, 0), and reads as "empty" even when not dragging. While a drag
  // can legally land here it registers a hit target spanning the whole box, and
  // once selected it shows the dragged chip's placeholder copy just like the
  // sibling slots do.
  Widget _emptyDropSlot(BuildContext context, ColumnSpec spec) {
    final theme = Theme.of(context);
    final slot = ReorderSlot(spec.id, 0);
    final key = _emptySlotKeyFor(spec.id);
    final active = _draggingId != null && _legalSlots.contains(slot);
    if (active) {
      _hitTargets.add(_HitTarget(key, slot, slot));
    }
    final selected = active && _currentSlot == slot;
    return _slot(
      key,
      CustomPaint(
        painter: _DashedRRectPainter(color: theme.colorScheme.primary),
        child: selected
            ? IgnorePointer(child: _staticContent(context, _draggedSpec!, highlight: true))
            : const SizedBox(width: 40, height: 32),
      ),
      gap: false,
    );
  }

  // A non-interactive, key-free copy of a chip, used to render the placeholder
  // (and the dragged subtree it stands in for) without disturbing the keys or
  // drag targets of the live chips.
  Widget _staticContent(BuildContext context, ColumnSpec spec, {bool highlight = false}) {
    if (!spec.acceptsChildren) {
      return _actionChip(context, spec, highlight: highlight);
    }
    return _logicContainer(context, [
      _spaced(_logicLabel(context, spec, highlight: highlight)),
      for (final child in spec.children) _spaced(_staticContent(context, child, highlight: highlight)),
    ], highlight: highlight);
  }

  // Wraps [spec]'s content in a Draggable. The dragged chip collapses (empty
  // feedback and childWhenDragging) so nothing floats on the cursor and it takes
  // no space, leaving the working tree the placeholder is numbered against. The
  // chip stays mounted at its own tree position, so the active drag is never
  // reparented mid-gesture.
  Widget _dragChip(BuildContext context, ColumnSpec spec) {
    return Draggable<ColumnSpec>(
      data: spec,
      // Anchor the (invisible) feedback to the pointer so DragTargetDetails.offset
      // is the true cursor position, not the cursor minus the grab offset within
      // the chip — which would shift the swap boundary toward the chip's edge.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: const SizedBox.shrink(),
      childWhenDragging: const SizedBox.shrink(),
      onDragStarted: () => _onDragStarted(spec),
      onDragEnd: (_) => _onDragEnded(),
      child: _chipContent(context, spec),
    );
  }

  // Lays out one sibling level: the chips of [children] with the placeholder
  // spliced in at the current slot, and a hit target registered per chip so
  // [_onMove] can pick a slot by which chip's centre the pointer has crossed.
  // The dragged chip is rendered collapsed and gap-less in place — contributing
  // neither a slot, an index, nor any spacing.
  List<Widget> _buildSiblings(BuildContext context, List<ColumnSpec> children, {required String? parentId}) {
    final widgets = <Widget>[];
    var workingIndex = 0;
    for (final child in children) {
      final outerKey = _outerKeyFor(child.id);
      if (child.id == _draggingId) {
        widgets.add(_slot(outerKey, _dragChip(context, child), gap: false));
        continue;
      }
      _maybePlaceholder(context, widgets, ReorderSlot(parentId, workingIndex));
      _addHitTargets(child, parentId, workingIndex);
      widgets.add(_slot(outerKey, _dragChip(context, child)));
      workingIndex++;
    }
    _maybePlaceholder(context, widgets, ReorderSlot(parentId, workingIndex));
    return widgets;
  }

  // Registers the chip's hoverable halves. A leaf swaps before/after itself; a
  // logic column's header swaps before the group / into its front, and its box
  // (only the deepest match wins, so this is reached over the padding) swaps
  // around the whole group.
  void _addHitTargets(ColumnSpec child, String? parentId, int index) {
    final outerKey = _outerKeyFor(child.id);
    final before = ReorderSlot(parentId, index);
    final after = ReorderSlot(parentId, index + 1);
    if (child.acceptsChildren) {
      _hitTargets.add(_HitTarget(_headerKeyFor(child.id), before, ReorderSlot(child.id, 0)));
      _hitTargets.add(_HitTarget(outerKey, before, after));
    } else {
      _hitTargets.add(_HitTarget(outerKey, before, after));
    }
  }

  // Splices the placeholder here when [slot] is the current drop target. The
  // dragged copy is rendered at full opacity with an accent tint and a soft
  // glow so it reads clearly as the chip being moved. The accent outline is
  // drawn on the wrapper (a foreground decoration for leaves; logic containers
  // already carry their own bordered box) so the chip's size never changes —
  // matching the leaf's stadium / the container's rounded-rect shape.
  void _maybePlaceholder(BuildContext context, List<Widget> widgets, ReorderSlot slot) {
    if (slot != _currentSlot) {
      return;
    }
    final theme = Theme.of(context);
    final isContainer = _draggedSpec!.acceptsChildren;
    final ShapeBorder shape = isContainer
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
        : const StadiumBorder();
    widgets.add(
      _slot(
        _placeholderKey,
        IgnorePointer(
          child: Container(
            decoration: ShapeDecoration(
              shape: shape,
              shadows: [BoxShadow(color: theme.colorScheme.primary.withValues(alpha: 0.45), blurRadius: 12)],
            ),
            foregroundDecoration: isContainer
                ? null
                : ShapeDecoration(
                    shape: StadiumBorder(side: BorderSide(color: theme.colorScheme.primary, width: 1.5)),
                  ),
            child: _staticContent(context, _draggedSpec!, highlight: true),
          ),
        ),
      ),
    );
  }

  Rect? _rectOf(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // While dragging, move the placeholder to the legal slot whose anchor is
  // nearest the pointer, with hysteresis so a marginally closer rival doesn't
  // cause flicker at a boundary.
  void _onMove(Offset pointer) {
    if (_draggingId == null) {
      return;
    }
    // Hovering the placeholder itself carries no slot — leave it where it is.
    final placeholder = _rectOf(_placeholderKey);
    if (placeholder != null && placeholder.contains(pointer)) {
      return;
    }
    // Prefer the deepest (smallest) chip under the pointer; otherwise fall back
    // to the nearest one, so a hover in a gap still resolves. The winning rect is
    // carried alongside the target so it never has to be measured a second time.
    _HitTarget? containing;
    Rect? containingRect;
    var containingArea = double.infinity;
    _HitTarget? nearest;
    Rect? nearestRect;
    var nearestDistance = double.infinity;
    for (final target in _hitTargets) {
      final rect = _rectOf(target.key);
      if (rect == null) {
        continue;
      }
      if (rect.contains(pointer)) {
        final area = rect.width * rect.height;
        if (area < containingArea) {
          containingArea = area;
          containing = target;
          containingRect = rect;
        }
      } else {
        final distance = (rect.center - pointer).distanceSquared;
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearest = target;
          nearestRect = rect;
        }
      }
    }
    final target = containing ?? nearest;
    final rect = containing != null ? containingRect : nearestRect;
    if (target == null || rect == null) {
      return;
    }
    // Cross the chip's centre to flip sides; a deadband around the centre keeps
    // the placeholder from flickering when the pointer hovers on the boundary.
    final offset = pointer.dx - rect.center.dx;
    if (offset.abs() < _slotSwitchMargin && (_currentSlot == target.before || _currentSlot == target.after)) {
      return;
    }
    var slot = offset < 0 ? target.before : target.after;
    if (!_legalSlots.contains(slot)) {
      final other = offset < 0 ? target.after : target.before;
      if (!_legalSlots.contains(other)) {
        return;
      }
      slot = other;
    }
    if (slot != _currentSlot) {
      setState(() => _currentSlot = slot);
    }
  }

  void _onDragStarted(ColumnSpec spec) {
    final specs = ref.read(currentColumnSpecsProvider);
    setState(() {
      _draggingId = spec.id;
      _legalSlots = computeReorderSlots(specs, spec.id).toSet();
      _currentSlot = _locate(specs, spec.id);
    });
  }

  void _onDragEnded() {
    final id = _draggingId;
    final slot = _currentSlot;
    setState(() {
      _draggingId = null;
      _currentSlot = null;
      _legalSlots = const {};
      _hitTargets = [];
    });
    if (id != null && slot != null) {
      ref.read(currentColumnSpecsLoaderProvider.notifier).moveToSlot(id, slot.parentId, slot.index);
    }
  }

  // The slot a spec currently occupies, used as the initial placeholder
  // position so the drag begins exactly where the chip was.
  ReorderSlot? _locate(List<ColumnSpec> list, String id, [String? parentId]) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == id) {
        return ReorderSlot(parentId, i);
      }
      final nested = _locate(list[i].children, id, list[i].id);
      if (nested != null) {
        return nested;
      }
    }
    return null;
  }

  Widget addButton(ThemeData theme) {
    return ActionChip(
      avatar: Icon(Icons.add, color: theme.colorScheme.onPrimary),
      label: const Text(""),
      tooltip: "$tr_chara_detail.add_column_button.tooltip".tr(),
      backgroundColor: theme.colorScheme.primary,
      shape: const CircleBorder().copyWith(side: theme.chipTheme.shape?.side),
      side: BorderSide.none,
      labelPadding: EdgeInsets.zero,
      onPressed: () {
        ColumnBuilderDialog.show(ref.base);
      },
    );
  }

  Widget addButtonWithLabel(ThemeData theme) {
    return ActionChip(
      avatar: Icon(Icons.add, color: theme.colorScheme.onPrimary),
      label: Text(
        "$tr_chara_detail.add_column_button.label".tr(),
        style: theme.textTheme.labelLarge!.copyWith(color: theme.colorScheme.onPrimary),
      ),
      tooltip: "$tr_chara_detail.add_column_button.tooltip".tr(),
      backgroundColor: theme.colorScheme.primary,
      side: BorderSide.none,
      onPressed: () {
        ColumnBuilderDialog.show(ref.base);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _recordCount = ref.watch(charaDetailRecordStorageProvider).length;
    final specs = ref.watch(currentColumnSpecsProvider);
    _counts = ref.watch(currentGridProvider).filteredCounts;
    _brokenIds = ref.watch(currentColumnSpecBrokenIdsProvider);
    _hitTargets = [];

    final children = <Widget>[
      ..._buildSiblings(context, specs, parentId: null),
      _slot(const ValueKey('add-button'), specs.isEmpty ? addButtonWithLabel(theme) : addButton(theme)),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Align(
        alignment: Alignment.topLeft,
        // One drop target spans the whole tag area; the live slot is picked
        // geometrically in _onMove rather than per-chip, so no gaps appear.
        child: DragTarget<ColumnSpec>(
          onWillAcceptWithDetails: (_) => _draggingId != null,
          onMove: (details) => _onMove(details.offset),
          builder: (context, candidateData, rejectedData) {
            return Wrap(runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: children);
          },
        ),
      ),
    );
  }
}

// Slides its child from its previous layout position to its current one using a
// paint-only [Transform.translate], so reordering the chips animates instead of
// jumping. This is a FLIP (First-Last-Invert-Play): each frame it measures where
// the child landed, and if that moved it offsets the child back to where it was
// and animates that offset to zero.
//
// The translate is paint-only, so layout (and therefore the slot rectangles the
// drag hit-test measures via the parent's GlobalKey) is never disturbed — the
// effect is purely cosmetic. When [animate] is false the mover snaps to the new
// position, which keeps non-drag rebuilds (drop settle, add/remove via dialogs)
// behaving exactly as before.
class _FlipMover extends StatefulWidget {
  const _FlipMover({required this.child, required this.animate});

  final Widget child;
  final bool animate;

  @override
  State<_FlipMover> createState() => _FlipMoverState();
}

class _FlipMoverState extends State<_FlipMover> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: _reorderSlideDuration)
    ..addListener(_tick);

  // The child's settled layout position, measured after each frame. A move is
  // detected by comparing the fresh measurement against this.
  Offset? _lastPosition;

  // The offset the slide started from; the painted offset is this lerped to zero
  // by the controller, so [_paintedOffset] reads the current visual delta.
  Offset _fromOffset = Offset.zero;

  Offset get _paintedOffset => Offset.lerp(_fromOffset, Offset.zero, _controller.value) ?? Offset.zero;

  void _tick() => setState(() {});

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterLayout());
    return Transform.translate(offset: _paintedOffset, child: widget.child);
  }

  void _afterLayout() {
    if (!mounted) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return;
    }
    // localToGlobal on the Transform's render object ignores its own paint
    // transform, so this is the settled layout position regardless of any slide.
    final newPosition = box.localToGlobal(Offset.zero);
    final previous = _lastPosition;
    _lastPosition = newPosition;
    if (previous == null || previous == newPosition) {
      return;
    }
    if (!widget.animate) {
      // Snap: cancel any slide and sit at the new position.
      _controller.stop();
      _controller.value = 1;
      _fromOffset = Offset.zero;
      return;
    }
    // Re-target: carry the in-flight visual offset so an interrupted slide stays
    // continuous, then animate the combined delta back to zero.
    _fromOffset = (previous - newPosition) + _paintedOffset;
    _controller.forward(from: 0);
  }
}

// Strokes a rounded rectangle with a dashed outline. Used for the empty logic
// container's drop slot; kept here so the feature needs no extra dependency.
class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color});

  final Color color;

  static const double _radius = 12;
  static const double _dash = 4;
  static const double _gap = 3;
  static const double _strokeWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(_radius));
    final outline = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    for (final metric in outline.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) => old.color != color;
}
