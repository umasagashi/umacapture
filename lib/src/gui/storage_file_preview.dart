/// The storage view's file preview surface (stage 4b).
///
/// **Why a dialog and not a pane.** The view *is* one `ListView.builder` whose
/// rows are recycled (`storage_tree.dart`), and the three shapes a preview could
/// take were decided by that plus the two standing constraints:
///
///  * A **side-by-side pane** cannot hold: this app collapses its navigation
///    into a drawer at narrow widths, so the view is routinely the whole window
///    and splitting it would leave two unusable columns.
///  * An **inline panel** would have to be another row in the flattened list, so
///    the image and the text area would size themselves inside a recycled list
///    item, and there would be nowhere to put a standing action bar.
///  * The house **`CardDialog`** ([DialogLayer], `common.dart`) is an overlay
///    over the whole scaffold — it is therefore already above the drawer layout
///    and identical on both platforms — and it carries a `bottom` bar, which is
///    where the file's size is stated for every kind, including the ones this
///    surface declines to decode. It also touches the tree not at all, so the
///    lazy-listing contract is unaffected: opening a preview issues no
///    listing.
///
/// **This surface previews, and does nothing else.** Copying a file out and
/// saving it used to sit in that bottom bar as well, and they are now
/// on the row's context menu (`storage_tree.dart`, `_EntryTile._showRowMenu`)
/// — the same two actions on two surfaces. They were taken off *this* one: the
/// menu is the surface both kinds of row have and reaches a file without opening
/// anything, whereas the bar could only ever serve the file already open. So the
/// bar states the size and holds no control at all, and the way to get a file out
/// of the app — including one this surface refuses to render, such as an image
/// past [imagePreviewByteLimit] — is a secondary press on its row.
///
/// Nothing here decides *whether* a file may be read. That is
/// `file_preview.dart`, reached through [storageFilePreviewProvider]; this
/// library only renders what comes back. Reading a file directly from here would
/// re-introduce exactly the defect that layer exists to prevent (a `.onnx` or the
/// font cache pulled into memory only to be refused), which is why the widget
/// holds no path-to-bytes call of its own.
library;

import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/json_format.dart';
import '/src/core/path_entity.dart';
import '/src/core/storage/byte_size_format.dart';
import '/src/core/storage/display_text.dart';
import '/src/core/storage/file_preview.dart';
import '/src/core/storage/file_preview_source.dart';
import '/src/core/storage/settings_boxes.dart';
import '/src/core/storage/settings_value_render.dart';
import '/src/core/utils.dart';
import '/src/preference/hive_adapter.dart';
import '/src/preference/storage_box.dart';
import '/src/gui/chara_detail/code_highlight_field.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/storage_status.dart';

/// What may be shown for the file at this path.
///
/// `autoDispose` because a text preview holds up to [textPreviewByteLimit] of
/// decoded string per file, and the view is a browser: keeping every file the
/// user glanced at alive for the session would accumulate exactly the memory the
/// cap exists to bound.
final storageFilePreviewProvider = FutureProvider.autoDispose.family<FilePreview, String>((ref, path) {
  return resolveFilePreview(name: FilePath(path).name, source: FsBackendPreviewSource(path));
});

/// Addresses the preview body, whatever kind it turned out to be.
const Key storageFilePreviewBodyKey = ValueKey('storage-file-preview-body');

/// Addresses the text area of a text or JSON preview.
const Key storageFilePreviewTextKey = ValueKey('storage-file-preview-text');

/// Addresses the notice shown when only the head of a long file was read.
const Key storageFilePreviewTruncatedKey = ValueKey('storage-file-preview-truncated');

/// Addresses the panel shown for an image past [imagePreviewByteLimit].
///
/// Its own key, as it is its own sentence: the two are different decisions --
/// one is taken before a byte is read, the other after a decode was attempted --
/// and a panel that could not be told from the other would pass a test while the
/// bound did nothing.
const Key storageFilePreviewImageTooLargeKey = ValueKey('storage-file-preview-image-too-large');

/// Addresses the panel shown for a file whose content is not displayable.
const Key storageFilePreviewUnsupportedKey = ValueKey('storage-file-preview-unsupported');

/// Addresses the footer that states the previewed file's size.
///
/// Named for what it is rather than for actions: the two actions it used to
/// carry now live on the row's context menu alone (see the library doc). A key
/// still called "actions" would have kept sending the next reader here to add
/// the third one.
const Key storageFilePreviewFooterKey = ValueKey('storage-file-preview-footer');

/// Opens the preview for [file] over the storage view.
///
/// `over: true` because the storage view is itself a dialog: replacing it would
/// unmount the tree this preview was opened from, so closing the preview would
/// leave the settings page rather than the row the user tapped, and looking at a
/// second file would mean re-entering the view and re-walking the store.
///
/// Takes no group. It used to, because the download button had to know who must
/// be out of the way while the file is read; with that button gone, this
/// surface reads nothing but the file it is previewing, and the group is the
/// caller's business.
void showStorageFilePreview(WidgetRef ref, FilePath file) {
  CardDialog.show(ref.base, (_) => StorageFilePreviewDialog(file: file), over: true);
}

class StorageFilePreviewDialog extends ConsumerWidget {
  const StorageFilePreviewDialog({super.key, required this.file});

  final FilePath file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(storageFilePreviewProvider(file.path));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
      child: CardDialog(
        dialogTitle: file.name,
        closeButtonTooltip: 'pages.storage.preview.close_tooltip'.tr(),
        // The body decides its own scrolling per kind (a text area scrolls, an
        // image is fitted), so neither of `CardDialog`'s own scroll wrappers
        // applies; the body is placed directly and takes the remaining height.
        usePageView: false,
        content: Expanded(
          child: Padding(padding: const EdgeInsets.all(8), child: _body(preview)),
        ),
        bottom: _footer(context, preview),
      ),
    );
  }

  Widget _body(AsyncValue<FilePreview> preview) {
    return switch (preview) {
      AsyncData(:final value) => _PreviewBody(key: storageFilePreviewBodyKey, file: file, preview: value),
      // The exception's text is deliberately not on screen: an English
      // exception in a Japanese UI is what this view's outage work removed.
      AsyncError() => _PreviewMessage(
        key: storageFilePreviewBodyKey,
        glyph: const Icon(Symbols.error_rounded),
        message: 'pages.storage.preview.unreadable'.tr(),
      ),
      // The read is still running. A spinner on its own would leave a screen
      // reader — and a user who has not learned this view's iconography — with
      // nothing at all, which is the same silence `storage_status.dart` was
      // extracted to end; the sentence is the view's own, so the wait reads the
      // same here as it does in the tree.
      _ => _PreviewMessage(
        key: storageFilePreviewBodyKey,
        glyph: storageStatusSpinner(size: _messageGlyphSize),
        message: 'pages.storage.status.loading'.tr(),
      ),
    };
  }

  /// The footer: the file's size, and nothing else.
  ///
  /// It exists because the size is the one thing this view shows for *every* kind,
  /// including the ones it refuses to decode. It is deliberately **not** a place
  /// to put a control: this dialog previews and does nothing else (see the
  /// library doc), so the copy and save actions that used to stand here are
  /// reached from the row's context menu instead. Note what the removal cost —
  /// the two blocker readings (the delete/extraction exclusion) went with the buttons, because
  /// showing a size reads no bytes and there is nothing left here to withhold.
  Widget _footer(BuildContext context, AsyncValue<FilePreview> preview) {
    final theme = Theme.of(context);
    return Row(
      key: storageFilePreviewFooterKey,
      children: [
        Text(switch (preview) {
          AsyncData(:final value) => formatByteSize(value.byteLength),
          _ => unknownSizeLabel,
        }, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// What one settings store holds, as the dialog below shows it (stage 4e).
///
/// A `FutureProvider` although the read is synchronous, for two reasons that
/// outlast the read's cost. `Hive.box(name)` throws when the box is not open —
/// which is exactly the record-store outage this view has to stay usable in — and a synchronous `Provider` has
/// nowhere to put that but an exception thrown during a widget build; the
/// `AsyncError` arm is what lets the dialog say so in Japanese instead. And the
/// view's other levels are already futures, so the three states the dialog handles
/// are the three every other level of the tree handles.
///
/// `autoDispose` for the reason [storageFilePreviewProvider] is: `column_spec`
/// alone is ~18 KB of JSON on a real installation, and a browser is not somewhere
/// to keep every store the user glanced at.
final storageSettingsBoxEntriesProvider = FutureProvider.autoDispose.family<List<SettingsBoxEntry>, String>((
  ref,
  name,
) async {
  final key = storageBoxKeyOfName(name);
  if (key == null) {
    // Not an empty list: a name with no key is a bug in the caller (the tree
    // derives its rows from the same enum), and an empty store is a thing the
    // user may legitimately see. Conflating them would hide the bug behind a
    // plausible screen.
    throw ArgumentError.value(name, 'name', 'no settings store is stored under this name');
  }
  return StorageBox(key).entries();
});

/// Addresses the settings-store dialog's body, whatever state it is in.
const Key storageSettingsBoxBodyKey = ValueKey('storage-settings-box-body');

/// Addresses the notice shown for a store that holds nothing.
const Key storageSettingsBoxEmptyKey = ValueKey('storage-settings-box-empty');

/// Addresses one key's row in the settings-store dialog.
Key storageSettingsBoxKeyLabelKey(String key) => ValueKey('storage-settings-box-key:$key');

/// Addresses the text area holding one key's value.
///
/// Keyed per key rather than by type: a store has as many of these as it has
/// keys, so `find.byType(TextField)` cannot say which value it found, and two
/// keys may legitimately hold the same text.
Key storageSettingsBoxValueKey(String key) => ValueKey('storage-settings-box-value:$key');

/// Opens the contents of the settings store called [name] over the storage view.
///
/// `over: true` for the reason [showStorageFilePreview] states: this is the same
/// gesture — a row of the tree opened to be looked at — on the rows whose
/// contents are a Hive store rather than a file.
void showStorageSettingsBoxPreview(WidgetRef ref, String name) {
  CardDialog.show(ref.base, (_) => StorageSettingsBoxDialog(name: name), over: true);
}

/// The settings group's leaf view: one store's keys and values.
///
/// It shares this library with the file preview rather than starting one of its
/// own because it is the same surface — the same `CardDialog`, the same read-only
/// highlighted field, and the same control-free footer. What
/// it deliberately does *not* share is the path: a store has no file identity on
/// web, so nothing here goes through `FilePath`.
class StorageSettingsBoxDialog extends ConsumerWidget {
  const StorageSettingsBoxDialog({super.key, required this.name});

  /// The store's name as the tree shows it (`column_spec`, `window_state`, …).
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(storageSettingsBoxEntriesProvider(name));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
      child: CardDialog(
        dialogTitle: _title(),
        closeButtonTooltip: 'pages.storage.preview.close_tooltip'.tr(),
        usePageView: false,
        content: Expanded(
          child: Padding(padding: const EdgeInsets.all(8), child: _body(entries)),
        ),
      ),
    );
  }

  /// The store's Japanese name, matching the row that opened this dialog.
  ///
  /// The row already refuses to put `column_spec` on screen; a title that still
  /// did would put it back one tap later, which is the same hole in the same
  /// screen. Falls back to [name] only for a name that is not a store at all —
  /// the caller bug `storageSettingsBoxEntriesProvider` throws on, whose body is
  /// the "could not be read" notice and whose title has nothing better to say.
  /// That branch is not the "a ninth store was added" case: a ninth store has a
  /// [StorageBoxKey], and `storageBoxLabelKey`'s switch would then refuse to
  /// compile rather than land here.
  String _title() {
    final key = storageBoxKeyOfName(name);
    return key == null ? name : storageBoxLabelKey(key).tr();
  }

  Widget _body(AsyncValue<List<SettingsBoxEntry>> entries) {
    return switch (entries) {
      AsyncData(:final value) when value.isEmpty => _PreviewMessage(
        key: storageSettingsBoxBodyKey,
        glyph: const Icon(Symbols.inbox_rounded),
        message: 'pages.storage.store.empty'.tr(),
      ),
      AsyncData(:final value) => ListView.separated(
        key: storageSettingsBoxBodyKey,
        itemCount: value.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _SettingsEntryTile(entry: value[index]),
      ),
      // Same reasoning as the file preview's: the exception's English text stays
      // off a Japanese screen.
      AsyncError() => _PreviewMessage(
        key: storageSettingsBoxBodyKey,
        glyph: const Icon(Symbols.error_rounded),
        message: 'pages.storage.store.unreadable'.tr(),
      ),
      // Same sentence and same reason as the file preview's wait: the store is
      // being opened, and a bare spinner says that to nobody.
      _ => _PreviewMessage(
        key: storageSettingsBoxBodyKey,
        glyph: storageStatusSpinner(size: _messageGlyphSize),
        message: 'pages.storage.status.loading'.tr(),
      ),
    };
  }
}

/// One key of a settings store, with its value rendered by [renderSettingsValue]'s
/// three tiers.
class _SettingsEntryTile extends StatelessWidget {
  const _SettingsEntryTile({required this.entry});

  final SettingsBoxEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The tier decision itself lives in `settings_value_render.dart` and knows
    // nothing about Flutter; this passes it the one thing only the app can
    // supply, which is which types the app persists through `dart_mappable`.
    final view = renderSettingsValue(entry.value, encodeRegistered: encodeRegisteredHiveValue);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          entry.key,
          key: storageSettingsBoxKeyLabelKey(entry.key),
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        _HighlightedField(
          fieldKey: storageSettingsBoxValueKey(entry.key),
          text: view.text,
          isJson: view.isJson,
          // The list is the scrollable, so each value takes the height its own
          // text needs; a filled field inside an unbounded-height list item has
          // nothing to fill and asserts.
          fill: false,
        ),
      ],
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({super.key, required this.file, required this.preview});

  final FilePath file;
  final FilePreview preview;

  @override
  Widget build(BuildContext context) {
    return switch (preview) {
      TextFilePreview() => _TextPreview(preview: preview as TextFilePreview),
      // The decode bound is resolved here and not inside [RecordImage] because
      // it is a property of *this* surface: the box the picture is painted into,
      // in device pixels. See [_decodeBox].
      ImageFilePreview() => LayoutBuilder(
        builder: (context, constraints) => Center(
          child: RecordImage(
            file,
            fit: BoxFit.contain,
            maxDecodePixels: _decodeBox(context, constraints),
            // The third of the preview's safety devices. A file whose extension says image but
            // whose bytes do not decode is an ordinary thing to find in a folder
            // the user may have dropped files into, so it declines rather than
            // showing the framework's red error box.
            errorBuilder: (context, error, stackTrace) => _PreviewMessage(
              glyph: const Icon(Symbols.broken_image_rounded),
              message: 'pages.storage.preview.image_unavailable'.tr(),
            ),
          ),
        ),
      ),
      // Refused before any byte was read (the read cap, `imagePreviewByteLimit`).
      // The size the refusal is about is already on screen -- the footer shows
      // `byteLength` for every kind, including the ones it declines. The way out
      // is *not* on this surface: a file this dialog will not render is still one
      // the user may want out of the app, and both ways of taking it out (copy,
      // save) are on the row's context menu, which needs no preview to have
      // resolved because it never opened one.
      OversizeImageFilePreview() => _PreviewMessage(
        key: storageFilePreviewImageTooLargeKey,
        glyph: const Icon(Symbols.broken_image_rounded),
        // Its own sentence and not `image_unavailable`: a picture that is too
        // big to open and one whose bytes do not decode are different facts
        // about the file, and only the first names something the user chose.
        message: 'pages.storage.preview.image_too_large'.tr(),
      ),
      // One sentence, and deliberately no second line under it. There used to be
      // a `preview.unsupported_detail` explaining that the file was 「アプリが
      // 内部で使う形式」, which was a guess the decision never made: the refusal
      // means a NUL byte in the head, and the file may just as well be something
      // the user put there themselves. The heading says what is true -- the
      // content cannot be shown -- and stops.
      BinaryFilePreview() => _PreviewMessage(
        key: storageFilePreviewUnsupportedKey,
        glyph: const Icon(Symbols.unknown_document_rounded),
        message: 'pages.storage.preview.unsupported'.tr(),
      ),
    };
  }

  /// The most pixels worth decoding for this body, in device pixels.
  ///
  /// **Derived, never written down.** The picture is painted `BoxFit.contain`
  /// into the box this builder was handed, so anything decoded beyond that box
  /// times the device pixel ratio is thrown away by the resampler — while being
  /// paid for in full, at four bytes per pixel, in the heap of a browser tab.
  /// A constant here would be a guess about a window this code cannot see, and
  /// it would be wrong on the first high-DPI display.
  ///
  /// The [MediaQuery] fallback is for an unbounded axis: a `Center` inside this
  /// dialog is bounded on both, but the widget is not entitled to assume the
  /// layout it happens to sit in today. Falling back to the *window* is still a
  /// measured bound, just a looser one.
  ///
  /// The measurement is quantised before the density is applied, never after:
  /// see [_decodeBoxStep] for why it is quantised at all, and [_quantised] for
  /// why the ratio stays outside it.
  static Size _decodeBox(BuildContext context, BoxConstraints constraints) {
    final window = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : window.width;
    final height = constraints.maxHeight.isFinite ? constraints.maxHeight : window.height;
    return Size(_quantised(width) * ratio, _quantised(height) * ratio);
  }

  /// The step a decode box is rounded up to, in logical pixels.
  ///
  /// A layout moves by one pixel whenever the window does, and this box ends up
  /// on the decode cache's key (`boundedRecordImageProvider` builds a
  /// [ResizeImage], and `ResizeImageKey` carries the box). Handing the raw
  /// measurement over would therefore miss the cache on *every pixel* of a
  /// window drag: the whole file is decoded again, and because `gaplessPlayback`
  /// is off on purpose — `RecordImage.preload` says why — the picture is gone
  /// for the frame in between. Rounding up makes the key change a handful of
  /// times across the whole range a window can be dragged through, instead of
  /// once per pixel.
  ///
  /// 64 is chosen against the range that is actually reachable rather than as a
  /// round number. `main.dart` asks for `WindowOptions(minimumSize: Size(600,
  /// 400))`, so the window can be dragged down to 600 logical pixels wide; this
  /// dialog stops widening its box at 784 (past that the surrounding
  /// `ConstrainedBox` caps it), so those 185 widths are the entire reachable
  /// span. At 64 they collapse to three boxes, and the widest of them is exactly
  /// the box a maximised window settles on — so the rounding costs a wide window
  /// nothing at all. What it costs a narrow one is decoding at most one step
  /// more than is painted, which the `fit`/`allowUpscaling: false` ceiling then
  /// resamples away: under an eighth of the smallest reachable box on either
  /// axis, against a full re-decode of the file per pixel dragged.
  static const double _decodeBoxStep = 64;

  /// [extent] rounded up to a whole [_decodeBoxStep], and never to nothing.
  ///
  /// Logical pixels, deliberately: the density is a fixed property of the
  /// display and never churns, so quantising the *measurement* and leaving the
  /// conversion exact keeps `bound == box * ratio` true — a denser screen still
  /// asks for proportionally more pixels, tolerance included. Quantising the
  /// device-pixel product instead would round the two apart for no gain.
  ///
  /// The floor is one step rather than one pixel, for the degenerate first pass
  /// where a constraint is zero: a zero-pixel decode is not askable, and a
  /// one-pixel one would only be a fourth key that no frame ever paints.
  static double _quantised(double extent) {
    return math.max(1, (extent / _decodeBoxStep).ceil()) * _decodeBoxStep;
  }
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.preview});

  final TextFilePreview preview;

  /// Re-indents JSON, and falls back to the bytes as read when [reindentJson]
  /// declines.
  ///
  /// Not re-indenting is an ordinary outcome rather than an error, and it has
  /// more than one cause. A file past [textPreviewByteLimit] is cut
  /// mid-structure *by the cap itself*, so the head of a perfectly valid file
  /// does not parse; a file the user put here can be malformed on its own; and
  /// one that is valid can still be past the bounds `reindentJson` formats
  /// within. In every one of those the raw text is the honest answer — this is a
  /// viewer, so indenting is decoration. Only the first of them is explained on
  /// screen, by the truncation notice above.
  ///
  /// "As read" is about the *content*: the field this feeds normalises line
  /// terminators before laying the string out (`textForDisplay`), so a CRLF file
  /// is shown with the same lines and not the same bytes.
  ({String text, bool isJson}) get _shown {
    if (!preview.isJson) {
      // The language is `json` only where the content is JSON. `highlight`'s
      // Dart grammar applied to a `.log` would colour words that mean nothing
      // in it.
      return (text: preview.text, isJson: false);
    }
    final formatted = reindentJson(preview.text);
    if (formatted == null) {
      return (text: preview.text, isJson: false);
    }
    return (text: formatted, isJson: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (preview.truncated)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'pages.storage.preview.truncated'.tr(),
              key: storageFilePreviewTruncatedKey,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: _HighlightedField(
            fieldKey: storageFilePreviewTextKey,
            text: shown.text,
            isJson: shown.isJson,
            fill: true,
          ),
        ),
      ],
    );
  }
}

/// A read-only, selectable text area with the code highlighter behind it.
///
/// Shared by the file preview and the settings-store dialog rather than
/// duplicated, because the highlighting *controller* is the part with a lifetime:
/// it has to be built once, rebuilt when the text changes, and disposed. Two
/// copies of that would be two chances to leak one.
class _HighlightedField extends StatefulWidget {
  const _HighlightedField({required this.fieldKey, required this.text, required this.isJson, required this.fill});

  final Key fieldKey;
  final String text;
  final bool isJson;

  /// Whether the field takes the height it is given (a file preview, which owns
  /// the dialog body) or the height its content needs (one value among many in a
  /// scrolling list, where a filled field would have no bounded height to fill).
  final bool fill;

  @override
  State<_HighlightedField> createState() => _HighlightedFieldState();
}

class _HighlightedFieldState extends State<_HighlightedField> {
  late CodeHighlightController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  @override
  void didUpdateWidget(_HighlightedField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.isJson != widget.isJson) {
      _controller.dispose();
      _controller = _buildController();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Decides the grammar once, here, rather than inside the controller.
  ///
  /// `buildTextSpan` runs during layout and runs more than once, so a decision
  /// taken there would be retaken on every layout pass of a field the budget has
  /// already judged too costly to colour. Taking it where the controller's
  /// lifetime already is makes the decision state, computed exactly when the text
  /// it is about changes.
  ///
  /// The cost is one extra `highlight.parse` (31–73 ms across this view's whole
  /// size range) on the path that would otherwise have spent seconds. When the
  /// answer is "too costly", the two parses the controller then runs are
  /// `plaintext` ones, which are free.
  CodeHighlightController _buildController() {
    // The one place a preview string becomes a laid-out one, which is why the
    // line-terminator normalisation is here and not in either caller: the file
    // preview and the settings-store dialog both arrive through this widget, and
    // a `\r` left in the text costs `n²` to lay out (see `textForDisplay`).
    // Normalised before the budget is measured, not after, so the span/character
    // product is taken over the string the field will actually build.
    final text = textForDisplay(widget.text);
    final coloured = widget.isJson && codeHighlightFitsBudget(text, 'json');
    return CodeHighlightController(text: text, language: coloured ? 'json' : 'plaintext');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      key: widget.fieldKey,
      controller: _controller,
      // Read-only and not disabled: this view offers no write operation, while the
      // text still has to be selectable so a user can copy a line out of
      // it. A disabled field is neither editable nor selectable.
      readOnly: true,
      maxLines: null,
      expands: widget.fill,
      textAlignVertical: TextAlignVertical.top,
      style: theme.textTheme.bodySmall,
      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
    );
  }
}

/// The panel-sized form of `storage_status.dart`'s rule: a glyph, and the
/// sentence that says what it means.
///
/// Shared so that the states this dialog can be in — unreadable, undecodable
/// image, not displayable, empty, and *still being read* — cannot drift into
/// different-looking panels for what is, to the reader, one kind of answer. The
/// wait belongs in that list: it was the one state here that had a glyph and no
/// sentence.
///
/// **The glyph is a widget, not an [IconData].** A spinner is not an icon, and
/// giving the pending state its own centred `CircularProgressIndicator` beside
/// this class is exactly how it came to have no words in the first place. Size
/// and colour are handed down through [IconTheme] so an `Icon` still looks the
/// way it did, and so a glyph that is not an icon is free to ignore them.
class _PreviewMessage extends StatelessWidget {
  const _PreviewMessage({super.key, required this.glyph, required this.message});

  final Widget glyph;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTheme.merge(
            data: IconThemeData(size: _messageGlyphSize, color: theme.colorScheme.onSurfaceVariant),
            child: glyph,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// The height of a panel glyph, shared by the icons and the spinner so the body
/// does not jump when a wait resolves into an answer.
const double _messageGlyphSize = 40;
