// The storage view's preview surface (stage 4b) -- what is put on screen for each
// kind of file, and what is *not read* to put it there.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_file_preview_view_test.dart
//
// The suite is written around one property that no rendered result can show on
// its own: the panel for a refused file looks exactly the same whether or not
// the megabytes were fetched and thrown away first. So every case here runs on
// `WebLikeFsBackend`, which counts the reads, and the refusal cases assert the
// counts rather than the pixels. An implementation that reached past
// `file_preview.dart` and read the file itself would render identically and fail
// here.
//
// The wordings are read out of the shipped `ja.json` as literals
// (`appSentenceAt`): `.tr()` renders an unresolved key *as the key*, so
// `expect(shown, key.tr())` is key-equals-key and passes with the key deleted.
//
// WHAT THIS SUITE DOES NOT REACH. It runs on the io backend behind
// `WebLikeFsBackend`, so the async semantics are io's and not OPFS's. A bounded
// image resolves through `Image.memory` on this platform too (`RecordImage.build`
// says why), so what a VM build cannot reach is the *unbounded* web branch: the
// OPFS read behind it is reachable only in a browser. Nothing here says anything about how a browser lays the dialog out at
// a narrow width.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/json_format.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/byte_size_format.dart';
import 'package:umacapture/src/core/storage/file_preview.dart';
import 'package:umacapture/src/gui/chara_detail/code_highlight_field.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/record_image.dart';
import 'package:umacapture/src/gui/storage_file_preview.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/code_highlight_colour.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/settling.dart';
import 'support/web_like_fs_backend.dart';

late Directory _root;
late PathInfo _info;
late WebLikeFsBackend _backend;
late FsBackend _originalBackend;

/// A one-pixel PNG, so the image branch has something that genuinely decodes.
const _pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

File _file(String relative) => File('${_root.path}${Platform.pathSeparator}$relative');

void _writeText(String relative, String contents) {
  final file = _file(relative);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void _writeBytes(String relative, List<int> bytes) {
  final file = _file(relative);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

FilePath _path(String relative) => FilePath(_file(relative).path);

ProviderContainer _container() {
  return ProviderContainer(
    // The app's own policy (`lib/main.dart`): riverpod 3 otherwise retries a
    // failed provider ten times with backoff, so a file that cannot be read
    // never settles into `AsyncError` within a test's patience and the failure
    // reads as a hang rather than as the error it is.
    retry: (_, _) => null,
    overrides: [pathLayoutLoader.overrideWith((ref) async => _info)],
  );
}

/// Pumps the preview dialog for one file.
///
/// The dialog is pumped directly rather than through `DialogLayer`: what is
/// under test is what the surface shows, and the route from a tapped row to this
/// widget is asserted separately (and is the only thing that assertion is
/// about).
/// [settle] is false for the one case that is about the moment *before* the file
/// has been read: waiting for the body to resolve would destroy the state it
/// asserts on.
/// [devicePixelRatio] scales the physical size with it, so the *logical* window
/// is the same 1000x1200 at every density: a case about the decode bound has to
/// move one variable, and a denser screen of the same physical size would move
/// the layout box as well.
Future<void> _pumpPreview(
  WidgetTester tester,
  ProviderContainer container,
  FilePath file, {
  bool settle = true,
  double devicePixelRatio = 1.0,
}) async {
  tester.view.physicalSize = Size(1000 * devicePixelRatio, 1200 * devicePixelRatio);
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);
  await pumpWithContainer(
    tester,
    container,
    MaterialApp(
      // The same code-highlight tokens `app_widget.dart` installs;
      // `CodeHighlightController.buildTextSpan` asserts the extension is there.
      theme: ThemeData(extensions: <ThemeExtension<dynamic>>[CodeHighlightColors.light()]),
      home: Scaffold(
        body: Center(child: StorageFilePreviewDialog(file: file)),
      ),
    ),
  );
  if (!settle) {
    return;
  }
  await settleUntil(
    tester,
    () => find.byKey(storageFilePreviewBodyKey).evaluate().isNotEmpty && !_isPending(),
    describe: 'the preview decision to resolve and render',
  );
}

/// Waits for the image branch to have finished with the file.
///
/// The body resolving is not the end of the read: `FilePreview` comes back
/// before the image provider has opened anything, so a test that stopped there
/// would leave a file handle open and the tear-down's recursive delete would fail
/// on Windows. For bytes that do not decode, the failure notice is the observable
/// end of that read (the byte cache is filled either way, so
/// [_settleImageBytes] would do as well; this one also pins the notice).
Future<void> _settleImageOutcome(WidgetTester tester) {
  return settleUntil(
    tester,
    () => find.text(appSentenceAt('pages.storage.preview.image_unavailable')).evaluate().isNotEmpty,
    describe: 'the image read to finish',
  );
}

/// Waits for the bounded image branch to have finished reading [file].
///
/// A bounded [RecordImage] pulls the bytes through `fsBackend` on *both*
/// platforms, and that read outlives the `FilePreview` the body settles on. Left
/// in flight, it holds a handle the tear-down's recursive delete trips over on
/// Windows -- so the observable end of the read is what these cases wait for.
Future<void> _settleImageBytes(WidgetTester tester, FilePath file) {
  return settleUntil(
    tester,
    () => RecordImageByteCache.instance.get(file.path) != null,
    describe: 'the image bytes to be read',
  );
}

/// The step `storage_file_preview.dart` rounds a decode box up to, in logical
/// pixels.
///
/// Private over there, restated here on purpose: the number is a shipped
/// trade-off (how coarse the decode boxes are against how often one is rebuilt),
/// so moving it should take a deliberate edit on both sides rather than sliding
/// through under a test that reads it back out of the code under test.
const double _decodeBoxStep = 64;

/// The width of the box the picture is painted into, which is what the decode
/// bound is derived from.
double _paintedBoxWidth(WidgetTester tester) {
  return tester.getSize(find.ancestor(of: find.byType(RecordImage), matching: find.byType(Center)).first).width;
}

/// Whether the surface is currently painting no picture at all.
///
/// `gaplessPlayback` is off by design (`RecordImage.preload` says why), so a
/// decode under a *new* key first replaces the resolved image with null and only
/// then paints the new one. That gap is the visible half of the churn defect,
/// and it is observable from here without a screen.
bool _pictureIsBlank() {
  final painted = find.byType(RawImage).evaluate();
  return painted.isEmpty || (painted.single.widget as RawImage).image == null;
}

/// Resizes the window to each of [widths] in turn, reporting per step how many
/// entries the decode cache gained and whether the picture went blank.
///
/// The blank is read on the frame the resize produced — the gap lasts only until
/// the replacement decode lands, so polling for it would poll for something that
/// is on its way out. The decode count is read after waiting for the picture
/// back, because a decode that has been asked for has not yet been counted.
Future<({List<int> decodes, List<bool> blanked})> _walkWindowWidths(WidgetTester tester, List<int> widths) async {
  final cache = PaintingBinding.instance.imageCache;
  final decodes = <int>[];
  final blanked = <bool>[];
  for (final width in widths) {
    final before = cache.currentSize;
    tester.view.physicalSize = Size(width.toDouble(), 1200);
    await tester.pump();
    blanked.add(_pictureIsBlank());
    await settleUntil(tester, () => !_pictureIsBlank(), describe: 'the picture to be back at width $width');
    decodes.add(cache.currentSize - before);
  }
  return (decodes: decodes, blanked: blanked);
}

bool _isPending() {
  return find
      .descendant(of: find.byKey(storageFilePreviewBodyKey), matching: find.byType(CircularProgressIndicator))
      .evaluate()
      .isNotEmpty;
}

/// The controller behind the preview's text area, which is where both the
/// re-indentation and the chosen grammar are observable.
CodeHighlightController _previewController() {
  final field = find.byKey(storageFilePreviewTextKey).evaluate().single.widget as TextField;
  return field.controller! as CodeHighlightController;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_file_preview_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _originalBackend = fsBackend;
    _backend = WebLikeFsBackend(_originalBackend);
    fsBackend = _backend;
  });

  tearDown(() {
    fsBackend = _originalBackend;
    _root.deleteSync(recursive: true);
  });

  group('the content is shown, and the kind decides how', () {
    testWidgets('the wait before a file is read is said in words, not only spun', (tester) async {
      _writeText('documents/umacapture/short.log', 'x');
      // Not settled: this is the one state that stops existing once the read
      // returns, so it has to be asserted on the first frame.
      await _pumpPreview(tester, _container(), _path('documents/umacapture/short.log'), settle: false);

      expect(_isPending(), isTrue, reason: 'the file had already been read, so this is not the pending state');
      // The view's own sentence, read out of the shipped `ja.json`: a bare
      // spinner reaches neither a screen reader nor a user who has not learned
      // this view's iconography.
      expect(find.text(appSentenceAt('pages.storage.status.loading')), findsOneWidget);

      await settleUntil(tester, () => !_isPending(), describe: 'the preview decision to resolve');
    });

    testWidgets('a record.json is re-indented and highlighted as JSON', (tester) async {
      // Deliberately written on one line with no spaces, so "re-indented" is a
      // difference this test can see: a preview that showed the bytes as read
      // would render a string that is not `prettyPrintJson`'s output.
      const source = '{"trainee":{"name":"サンプル","speed":1200},"skills":["先行","逃げ"],"ok":true}';
      _writeText('documents/umacapture/storage/chara_detail/active/rec1/record.json', source);
      final container = _container();

      await _pumpPreview(tester, container, _path('documents/umacapture/storage/chara_detail/active/rec1/record.json'));

      final controller = _previewController();
      expect(controller.text, prettyPrintJson(source));
      expect(controller.text, isNot(source), reason: 'the raw bytes would not be re-indented');
      // The language is the half `code_highlight_field_test` cannot see from
      // here: with `'dart'` (the controller's default) the field still colours
      // something, so only the parameter itself distinguishes the two.
      expect(controller.language, 'json');
    });

    testWidgets('a png is handed to the widget that decodes it on both platforms', (tester) async {
      _writeBytes('documents/umacapture/storage/chara_detail/active/rec1/campaign.png', base64Decode(_pngBase64));
      final container = _container();
      final path = _path('documents/umacapture/storage/chara_detail/active/rec1/campaign.png');

      await _pumpPreview(tester, container, path);
      await _settleImageBytes(tester, path);

      final image = find.byType(RecordImage).evaluate().single.widget as RecordImage;
      expect(image.path.path, path.path);
      // Not merely "an image widget is there": the failure path has to be wired
      // at the same time, or an undecodable file shows the framework's red box.
      expect(image.errorBuilder, isNotNull);
      expect(find.byKey(storageFilePreviewUnsupportedKey), findsNothing);
    });

    // THE SUITE'S BOUND-INDEPENDENT CONTROL. Every other image case here waits
    // through `_settleImageBytes`, which only completes because the surface asks
    // for a decode bound -- so when those go red together they cannot say whether
    // the bound broke or the image branch did. This one waits on the decode
    // landing in the shared `ImageCache`, which a bounded and an unbounded
    // provider both do, and it must stay green when the bound is removed.
    testWidgets('a decodable png is shown, and that does not depend on any decode bound', (tester) async {
      _writeBytes('documents/umacapture/unclassified/plain.png', base64Decode(_pngBase64));
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      addTearDown(() {
        cache.clear();
        cache.clearLiveImages();
      });

      await _pumpPreview(tester, _container(), _path('documents/umacapture/unclassified/plain.png'));
      await settleUntil(tester, () => cache.currentSize > 0, describe: 'the picture to be decoded and cached');

      expect(find.byType(RecordImage), findsOneWidget);
      expect(find.text(appSentenceAt('pages.storage.preview.image_unavailable')), findsNothing);
      expect(find.byKey(storageFilePreviewUnsupportedKey), findsNothing);
    });

    testWidgets('a png whose bytes are not an image falls back to the "cannot be shown" line', (tester) async {
      // The extension claims an image and the decoder disagrees -- the case
      // the preview's third safety device exists for: an image that fails to
      // decode falls back to a sentence instead of an error. The head holds no
      // NUL, so the
      // decision layer has nothing to object to either.
      _writeText('documents/umacapture/storage/chara_detail/active/rec1/broken.png', 'not really a png at all');
      final container = _container();

      await _pumpPreview(tester, container, _path('documents/umacapture/storage/chara_detail/active/rec1/broken.png'));
      await settleUntil(
        tester,
        () => find.text(appSentenceAt('pages.storage.preview.image_unavailable')).evaluate().isNotEmpty,
        describe: 'the failed decode to fall back to the unavailable notice',
      );
    });

    // Two bounds, because a picture costs memory twice and neither cost
    // predicts the other: `imagePreviewByteLimit` bounds what is copied into the
    // heap, and the decode box bounds what `dart:ui` allocates from it. Measured
    // on this installation, a 5,194,128 B `campaign.png` is 1080x9513 px and
    // therefore 41 MB of RGBA; a crafted 8000x8000 PNG is ~2 MB of file and
    // ~256 MB decoded, which the byte bound alone would wave through.
    testWidgets('an image past the byte cap is declined without being read', (tester) async {
      // One byte past the cap, so the refusal is the cap's doing and not the
      // fixture's size. `Uint8List` and not `List<int>.filled`: the latter is
      // eight bytes an element and would allocate 128 MB to describe 16.
      _writeBytes('documents/umacapture/unclassified/huge.png', Uint8List(imagePreviewByteLimit + 1));
      final container = _container();
      _backend.resetCallCounts();

      await _pumpPreview(tester, container, _path('documents/umacapture/unclassified/huge.png'));

      expect(find.byKey(storageFilePreviewImageTooLargeKey), findsOneWidget);
      expect(find.byType(RecordImage), findsNothing, reason: 'nothing may be handed to a decoder');
      // The same claim the refused-file case makes, on the kind that used to be
      // exempt from it.
      expect(_backend.readBytesCalls, 0, reason: 'the 16 MiB must not be copied into the heap to be refused');
      expect(_backend.readHeadBounds, isEmpty);
      expect(_backend.lengthCalls, 1, reason: 'the size is metadata, and is what the decision is taken on');
      // What the refusal tells the user: the size it is about is on screen,
      // because the footer shows `byteLength` for every kind including the ones
      // it declines. The way out is *not* here: this dialog previews and hosts no
      // action, so a file it refuses to render is taken out of the app from its
      // row's context menu (`storage_tree_context_menu_test.dart` asserts that
      // the two actions are on a file row's menu and that the save one runs).
      // Asserted rather than assumed, because a surface that refuses a file and
      // silently keeps the only way out would be the defect this case is about.
      expect(find.text(formatByteSize(imagePreviewByteLimit + 1)), findsOneWidget);
      // One pressable widget, and it is `CardDialog`'s close button: the surface
      // has no action of its own to reach the file with.
      expect(find.bySubtype<ButtonStyleButton>(), findsOneWidget);
      expect(find.byTooltip(appSentenceAt('pages.storage.preview.close_tooltip')), findsOneWidget);
      // The sentence itself, read out of the shipped `ja.json`: it names the
      // *cause*, which is the one thing the reader can act on, and it is not the
      // undecodable-image line -- those are different facts about the file.
      expect(find.text(appSentenceAt('pages.storage.preview.image_too_large')), findsOneWidget);
      expect(find.text(appSentenceAt('pages.storage.preview.image_unavailable')), findsNothing);
    });

    testWidgets('an image within the cap is decoded to the box it is painted into, rounded up a step', (tester) async {
      _writeBytes('documents/umacapture/unclassified/small.png', base64Decode(_pngBase64));
      final container = _container();

      final small = _path('documents/umacapture/unclassified/small.png');
      await _pumpPreview(tester, container, small);
      await _settleImageBytes(tester, small);

      final image = find.byType(RecordImage).evaluate().single.widget as RecordImage;
      final bound = image.maxDecodePixels;
      expect(bound, isNotNull, reason: 'an unbounded decode is the defect this case exists for');
      // Derived from the layout, not written down: the box the picture is
      // painted into, rounded up to a whole quantisation step and then times the
      // device pixel ratio `_pumpPreview` installed. The step is private to the
      // view on purpose -- what is asserted here is the shipped number, so
      // changing it has to be a deliberate edit in two places.
      final box = tester.getSize(find.ancestor(of: find.byType(RecordImage), matching: find.byType(Center)).first);
      expect(bound!.width, greaterThanOrEqualTo(box.width), reason: 'a bound under the box would resample upwards');
      expect(bound.height, greaterThanOrEqualTo(box.height), reason: 'a bound under the box would resample upwards');
      expect(bound.width, lessThan(box.width + _decodeBoxStep), reason: 'the overshoot is one step, not unbounded');
      expect(bound.height, lessThan(box.height + _decodeBoxStep), reason: 'the overshoot is one step, not unbounded');
      expect(bound.width % _decodeBoxStep, 0);
      expect(bound.height % _decodeBoxStep, 0);
      // And it reaches the provider, which is the half a parameter alone does
      // not prove: `cacheWidth`/`cacheHeight` would squash the picture into the
      // box, so the policy is part of the claim.
      final provider = (find.byType(Image).evaluate().single.widget as Image).image as ResizeImage;
      expect(provider.policy, ResizeImagePolicy.fit);
      expect(provider.allowUpscaling, isFalse, reason: 'the bound is a ceiling, not a target');
      expect(provider.width, bound.width.ceil());
      expect(provider.height, bound.height.ceil());
    });

    // The defect this pair exists for: the decode box was handed to `ResizeImage`
    // exactly as the layout measured it, so every pixel of a window drag was a
    // fresh cache key -- a full re-decode of the file, and (`gaplessPlayback` is
    // off on purpose) a frame with no picture at all in between. It is reachable
    // wherever the box is not yet saturated, which `main.dart`'s
    // `minimumSize: Size(600, 400)` puts squarely inside what a user can drag to.
    testWidgets('narrowing the window one pixel at a time does not decode the picture again', (tester) async {
      _writeBytes('documents/umacapture/unclassified/small.png', base64Decode(_pngBase64));
      final container = _container();

      final small = _path('documents/umacapture/unclassified/small.png');
      await _pumpPreview(tester, container, small);
      await _settleImageBytes(tester, small);
      await settleUntil(tester, () => !_pictureIsBlank(), describe: 'the first decode to be painted');

      // Negative control, and the reason the positive half is not vacuous: above
      // the width where the surrounding `ConstrainedBox` caps the box, a pixel of
      // window is not a pixel of box, so nothing was ever going to churn here.
      // This half passed before the box was quantised too.
      final wide = await _walkWindowWidths(tester, const [1000, 999, 998]);
      expect(wide.decodes, [0, 0, 0], reason: 'a saturated box does not move with the window');
      expect(wide.blanked, [false, false, false]);

      // Below that cap the box tracks the window pixel for pixel, and this is the
      // range the defect lived in. Asserted at both ends rather than assumed: a
      // layout change that moved this walk back under the cap would otherwise
      // leave it stepping through pixels that were never going to move anything.
      // (The widths are this harness's, which pumps the dialog without
      // `DialogLayer`'s outer inset -- the shipped surface saturates 64 logical
      // pixels wider. What is under test is the rounding, not the inset.)
      tester.view.physicalSize = const Size(719, 1200);
      await tester.pump();
      expect(_paintedBoxWidth(tester), 703, reason: 'this walk has to start below the width where the box caps');

      final narrow = await _walkWindowWidths(tester, const [718, 717, 716]);
      expect(_paintedBoxWidth(tester), 700, reason: 'and the box has to have followed the window down');
      expect(narrow.decodes, [0, 0, 0], reason: 'a pixel of drag inside one step is not a new decode');
      expect(narrow.blanked, [false, false, false], reason: 'and so the picture is never replaced by nothing');

      // The other half of the control: the counters above are live. Cross a whole
      // step and the box does change, which is the one thing quantising is
      // allowed to cost.
      final crossed = await _walkWindowWidths(tester, const [650]);
      expect(crossed.decodes, [1], reason: 'crossing a step is a new box, so the instruments can move');
    });

    testWidgets('the decode bound tracks the device pixel ratio rather than a constant', (tester) async {
      // The same window at twice the density asks for twice the pixels. A
      // hardcoded box would answer the same number to both, which is what makes
      // this the case that distinguishes "derived" from "written down".
      // Bytes that do not decode, on purpose: the bound is a parameter of the
      // widget and is resolved before any decode, while two successful decodes
      // of the same file in one test leave Windows handles open that the
      // tear-down's recursive delete then trips over.
      _writeText('documents/umacapture/unclassified/undecodable.png', 'not really a png at all');
      final path = _path('documents/umacapture/unclassified/undecodable.png');

      await _pumpPreview(tester, _container(), path);
      await _settleImageOutcome(tester);
      final atOne = (find.byType(RecordImage).evaluate().single.widget as RecordImage).maxDecodePixels;

      await _pumpPreview(tester, _container(), path, devicePixelRatio: 2.0);
      await _settleImageOutcome(tester);
      final atTwo = (find.byType(RecordImage).evaluate().single.widget as RecordImage).maxDecodePixels;

      expect(atTwo!.width, atOne!.width * 2);
      expect(atTwo.height, atOne.height * 2);
    });

    testWidgets('an .onnx says it cannot be shown, in words with no jargon in them', (tester) async {
      _writeBytes('support/modules/model.onnx', List<int>.filled(4096, 0));
      final container = _container();

      await _pumpPreview(tester, container, _path('support/modules/model.onnx'));

      expect(find.byKey(storageFilePreviewUnsupportedKey), findsOneWidget);
      expect(find.text(appSentenceAt('pages.storage.preview.unsupported')), findsOneWidget);
      expect(find.byKey(storageFilePreviewTextKey), findsNothing);
      // The preview shows the size even for the kinds it refuses to decode, and the
      // footer it is shown on holds nothing else.
      expect(
        find.descendant(of: find.byKey(storageFilePreviewFooterKey), matching: find.text(formatByteSize(4096))),
        findsOneWidget,
      );
    });

    testWidgets('a file that cannot be read at all says so, in Japanese and without the exception', (tester) async {
      // Nothing was written at this path. The alternative to a sentence here is
      // the framework's red box or an English exception in a Japanese UI.
      final container = _container();

      await _pumpPreview(tester, container, _path('documents/umacapture/not-there.json'));

      expect(find.text(appSentenceAt('pages.storage.preview.unreadable')), findsOneWidget);
      expect(find.byKey(storageFilePreviewTextKey), findsNothing);
    });

    testWidgets('a .ttf reaches the same panel, so the answer is the kind and not one extension', (tester) async {
      // A real `.ttf` head, 0x00010000: the refusal is now the NUL in it, not
      // the name, so a fixture of printable bytes would be shown as text.
      _writeBytes('support/MPLUS1Code_regular_x.ttf', [0x00, 0x01, 0x00, 0x00, ...List<int>.filled(2044, 0x41)]);
      final container = _container();

      await _pumpPreview(tester, container, _path('support/MPLUS1Code_regular_x.ttf'));

      expect(find.byKey(storageFilePreviewUnsupportedKey), findsOneWidget);
    });

    testWidgets('a tapped file row opens the preview; a tapped directory row still expands', (tester) async {
      _writeText('support/modules/version_info.json', '{"a":1}');
      // A directory *entry row* as well as a file one. The group row above them
      // has its own, older `onTap`, so tapping that would leave the directory
      // arm of the row's new choice unexercised.
      _writeText('support/modules/sub/inner.json', '{"b":2}');
      final container = _container();
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
      await settleUntil(
        tester,
        () => find.text(appSentenceAt('pages.storage.group.modules.label')).evaluate().isNotEmpty,
        describe: 'the group rows to appear',
      );

      // The directory row's own behaviour, asserted in the same test as the
      // file's: the change under test replaced one `onTap` with a choice, and a
      // test of only the new arm would not notice the old one being dropped.
      await tester.tap(find.text(appSentenceAt('pages.storage.group.modules.label')));
      await settleUntil(
        tester,
        () => find.text('version_info.json').evaluate().isNotEmpty,
        describe: 'the tapped group to expand',
      );
      expect(container.read(storageTreeExpansionProvider), isNotEmpty);
      expect(container.read(dialogBuilderProvider), isNull, reason: 'expanding is not previewing');

      await tester.tap(find.text('sub'));
      await settleUntil(
        tester,
        () => find.text('inner.json').evaluate().isNotEmpty,
        describe: 'the tapped directory row to expand',
      );
      expect(container.read(dialogBuilderProvider), isNull, reason: 'a directory row opens no preview');

      await tester.tap(find.text('version_info.json'));
      await tester.pump();
      expect(container.read(dialogBuilderProvider), isNotNull, reason: 'a tapped file opens the preview dialog');
    });
  });

  group('what is read to produce each of those', () {
    testWidgets('a refused file is read no further than the sniff window', (tester) async {
      _writeBytes('support/modules/model.onnx', List<int>.filled(4096, 0));
      final container = _container();
      _backend.resetCallCounts();

      await _pumpPreview(tester, container, _path('support/modules/model.onnx'));

      expect(find.byKey(storageFilePreviewUnsupportedKey), findsOneWidget);
      // The whole point of the suite. These four are what a preview that reached
      // around `resolveFilePreview` and read the file itself would break, while
      // rendering exactly the same panel.
      expect(_backend.readBytesCalls, 0, reason: 'the bytes must not be read');
      expect(_backend.readStringCalls, 0, reason: 'nor decoded through readString');
      expect(_backend.readHeadBounds, [4096], reason: 'the sniff window, not the 256 KiB preview cap');
      expect(_backend.lengthCalls, 1, reason: 'the size is metadata and is still shown');
    });

    testWidgets('a text file over the cap shows its head, says so, and reads no more than the cap', (tester) async {
      // One byte past the cap, so the truncation is the cap's doing and not the
      // fixture's size.
      final source = 'a' * (textPreviewByteLimit + 1);
      _writeText('documents/umacapture/log.log', source);
      final container = _container();
      _backend.resetCallCounts();

      await _pumpPreview(tester, container, _path('documents/umacapture/log.log'));

      expect(find.byKey(storageFilePreviewTruncatedKey), findsOneWidget);
      expect(find.text(appSentenceAt('pages.storage.preview.truncated')), findsOneWidget);
      expect(_previewController().text.length, textPreviewByteLimit);
      expect(_backend.readHeadBounds, [textPreviewByteLimit], reason: 'one bounded read, at the cap');
      expect(_backend.readBytesCalls, 0);
      expect(_backend.readStringCalls, 0);
    });

    testWidgets('a text file under the cap is shown whole, with no notice', (tester) async {
      // The negative half of the pair: without it, a preview that showed the
      // notice unconditionally would pass the test above.
      _writeText('documents/umacapture/short.log', 'one line\ntwo lines\n');
      final container = _container();
      _backend.resetCallCounts();

      await _pumpPreview(tester, container, _path('documents/umacapture/short.log'));

      expect(find.byKey(storageFilePreviewTruncatedKey), findsNothing);
      expect(_previewController().text, 'one line\ntwo lines\n');
      expect(_backend.readHeadBounds, [19], reason: 'the bound is the file size, not the cap');
    });

    testWidgets('a .json holding binary bytes is refused after the head, not decoded', (tester) async {
      // The second classification stage: the name claims JSON, the head holds a
      // NUL. Reaching `readString` here both reads the file and throws.
      _writeBytes('documents/umacapture/storage/chara_detail/active/rec1/record.json', [0x7b, 0x00, 0x7d]);
      final container = _container();
      _backend.resetCallCounts();

      await _pumpPreview(tester, container, _path('documents/umacapture/storage/chara_detail/active/rec1/record.json'));

      expect(find.byKey(storageFilePreviewUnsupportedKey), findsOneWidget);
      expect(_backend.readStringCalls, 0);
      expect(_backend.readBytesCalls, 0);
      expect(_backend.readHeadBounds, hasLength(1), reason: 'the head is read once; the rest of the file is not');
    });

    testWidgets('a truncated JSON head is shown as it was read rather than refused', (tester) async {
      // `prettyPrintJson` throws on this, and the fall-back is what keeps the
      // head of a large table readable instead of turning the cap into an error.
      final source = '{"rows":[${'{"a":1},' * 40000}';
      _writeText('support/modules/skill_info.json', source);
      final container = _container();

      await _pumpPreview(tester, container, _path('support/modules/skill_info.json'));

      expect(find.byKey(storageFilePreviewTruncatedKey), findsOneWidget);
      final controller = _previewController();
      expect(controller.text, source.substring(0, textPreviewByteLimit));
      expect(controller.language, 'plaintext', reason: 'an unparsed head is not JSON to highlight');
    });
  });

  group('a valid JSON the formatter cannot re-indent is shown, not turned into an error', () {
    // The failure these two are about is not a wrong rendering but an escaped
    // throw: `_shown` runs inside `build()`, so anything it lets out replaces
    // the whole panel with the framework's `ErrorWidget` -- a red box in debug,
    // and in every build a dialog with a title, a size, and no content. Both
    // inputs parse; it is the re-serialisation that fails, and it fails with an
    // `Error` rather than the `FormatException` the fall-back used to catch.
    testWidgets('a number that overflows to infinity', (tester) async {
      // `1e400` has no `double` to be, so `jsonDecode` yields `Infinity` and
      // `JsonEncoder` refuses to write it (`JsonUnsupportedObjectError`).
      const source = '{"a": 1e400}';
      _writeText('documents/umacapture/storage/chara_detail/quarantine/rec1/record.json', source);
      final container = _container();

      await _pumpPreview(
        tester,
        container,
        _path('documents/umacapture/storage/chara_detail/quarantine/rec1/record.json'),
      );

      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.byKey(storageFilePreviewTextKey), findsOneWidget);
      final controller = _previewController();
      expect(controller.text, source, reason: 'the bytes as read, since they could not be re-indented');
      expect(controller.language, 'plaintext');
      expect(find.byKey(storageFilePreviewTruncatedKey), findsNothing, reason: 'the cap is not what happened here');
      expect(tester.takeException(), isNull);
    });

    testWidgets('nesting deeper than the formatter goes', (tester) async {
      // Valid, complete, and small (under 10 KB): neither the cap nor a parse
      // failure can account for the raw rendering. 5000 levels is past what
      // `JsonEncoder` can walk without overrunning the stack, and well past
      // `jsonFormatMaxDepth`, which is what actually declines it.
      final source = '${'[' * 5000}${']' * 5000}';
      _writeText('documents/umacapture/storage/chara_detail/quarantine/rec1/deep.json', source);
      final container = _container();

      await _pumpPreview(
        tester,
        container,
        _path('documents/umacapture/storage/chara_detail/quarantine/rec1/deep.json'),
      );

      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.byKey(storageFilePreviewTextKey), findsOneWidget);
      final controller = _previewController();
      expect(controller.text, source, reason: 'the bytes as read, since they could not be re-indented');
      expect(controller.language, 'plaintext');
      expect(tester.takeException(), isNull);
    });
  });

  group('a JSON too costly to colour is shown without it', () {
    testWidgets('a large JSON is rendered without a single coloured span', (tester) async {
      // Sized past `codeHighlightSpanCharBudget` and nothing else: it is valid
      // JSON well under `textPreviewByteLimit`, so neither the cap nor a failed
      // parse can account for the plain rendering.
      final source = '{"rows":[${List<String>.filled(2600, '{"a":1,"b":"xy"}').join(',')}]}';
      _writeText('documents/umacapture/storage/chara_detail/active/rec1/prediction.json', source);
      final container = _container();

      await _pumpPreview(
        tester,
        container,
        _path('documents/umacapture/storage/chara_detail/active/rec1/prediction.json'),
      );

      final controller = _previewController();
      expect(
        controller.text,
        prettyPrintJson(source),
        reason: 'the content itself is unaffected: only the colour goes',
      );
      expect(codeHighlightSpanCharCost(controller.text, 'json'), greaterThan(codeHighlightSpanCharBudget));
      expect(controller.language, 'plaintext');
      expect(find.byKey(storageFilePreviewTruncatedKey), findsNothing, reason: 'the cap is not what happened here');
      // The property, asserted where it is visible. `language` above is the
      // input to the decision echoed back; this is what the reader gets — not
      // one span on the screen carries a colour of its own, so the text is
      // uniform. Nothing announces the drop: the wording review took that
      // sentence out because a reader can see there is no colour.
      expect(colouredSpanCount(tester, storageFilePreviewTextKey), 0);
    });

    testWidgets('a JSON within the budget still gets its colour', (tester) async {
      // The control. Without it, an implementation that dropped colour from
      // every file would pass the test above, and the fix would have been
      // indistinguishable from deleting the highlighting outright.
      const source = '{"trainee":{"name":"サンプル","speed":1200},"skills":["先行","逃げ"],"ok":true}';
      _writeText('documents/umacapture/storage/chara_detail/active/rec2/record.json', source);
      final container = _container();

      await _pumpPreview(tester, container, _path('documents/umacapture/storage/chara_detail/active/rec2/record.json'));

      final controller = _previewController();
      expect(codeHighlightSpanCharCost(controller.text, 'json'), lessThan(codeHighlightSpanCharBudget));
      expect(controller.language, 'json');
      expect(colouredSpanCount(tester, storageFilePreviewTextKey), greaterThan(0));
    });

    testWidgets('a large plain text file is left alone by the budget', (tester) async {
      // The budget is about a product, not about a size. A `.log` at the very
      // cap is one span and lays out in about a tenth of a second; it was never
      // on offer for colouring, so there is nothing here for the budget to take
      // away and nothing to distinguish it from a JSON the budget refused.
      _writeText('documents/umacapture/big.log', 'x' * (textPreviewByteLimit - 1));
      final container = _container();

      await _pumpPreview(tester, container, _path('documents/umacapture/big.log'));

      expect(_previewController().language, 'plaintext');
      expect(colouredSpanCount(tester, storageFilePreviewTextKey), 0);
    });
  });

  // A `TextField` whose text still holds `\r` lays out in about `n²`: in a
  // profile build of the real app one 172,670-character `prediction.json` took
  // 45,000 ms to open with its CRLF intact and 100 ms without it. **That
  // duration is not reproducible here** -- the same CRLF string laid out in 58 ms
  // under `flutter_test` -- so the assertions below are about the *string* the
  // field is handed, which is the property that does carry over. A timing
  // assertion in this file would pass on a build that stalls for two minutes.
  //
  // Every fixture's CRLF is verified in bytes (`_crlfCount`) rather than assumed:
  // the sweep that first measured this defect was fed LF-only input, which is why
  // nobody saw it, and `grep -c $'\r'` does not detect a CR under git-bash either.
  group('no carriage return is ever laid out', () {
    testWidgets('a JSON head cut by the cap is shown with its CRLF converted', (tester) async {
      // The path the real defect was on: past the cap, so the head stops
      // mid-structure, `prettyPrintJson` throws, and the raw head -- terminators
      // and all -- used to go straight into the field.
      final source = '{"rows":[\r\n${'  {"a":1},\r\n' * 30000}';
      _writeText('documents/umacapture/storage/chara_detail/active/rec1/prediction.json', source);
      expect(source.length, greaterThan(textPreviewByteLimit), reason: 'this case is the over-the-cap one');
      expect(
        _crlfCount('documents/umacapture/storage/chara_detail/active/rec1/prediction.json'),
        greaterThan(0),
        reason: 'the fixture must really be CRLF on disk, or this test asserts nothing',
      );
      final container = _container();

      await _pumpPreview(
        tester,
        container,
        _path('documents/umacapture/storage/chara_detail/active/rec1/prediction.json'),
      );

      final shown = _previewController().text;
      expect(find.byKey(storageFilePreviewTruncatedKey), findsOneWidget, reason: 'the cap is what happened here');
      expect(shown, isNot(contains('\r')));
      // The content itself is otherwise untouched: only the terminator changed.
      expect(shown, source.substring(0, textPreviewByteLimit).replaceAll('\r\n', '\n'));
    });

    testWidgets('a .log under the cap is shown with its CRLF converted, and keeps its line count', (tester) async {
      // The other half of the pair. Nothing about the cap decides this: a
      // non-JSON file never goes near `prettyPrintJson`, so its terminators reach
      // the field whatever its size. The lone `\r` in the middle is what makes
      // "convert" and "delete" different answers -- deleting would join two of
      // the file's lines into one and the count below would be 4.
      const source = 'first\r\nsecond\r\nthird\rfourth\r\n';
      _writeText('documents/umacapture/crlf.log', source);
      expect(source.length, lessThan(textPreviewByteLimit), reason: 'this case is the under-the-cap one');
      expect(_crlfCount('documents/umacapture/crlf.log'), 3, reason: 'the fixture must really be CRLF on disk');
      final container = _container();

      await _pumpPreview(tester, container, _path('documents/umacapture/crlf.log'));

      final shown = _previewController().text;
      expect(shown, isNot(contains('\r')));
      expect(shown, 'first\nsecond\nthird\nfourth\n');
      expect('\n'.allMatches(shown).length, 4, reason: 'a lone CR is a line terminator, not a character to drop');
    });

    testWidgets('a JSON small enough to re-indent was already clean, and stays clean', (tester) async {
      // The control for the claim this fix rests on: `JsonEncoder` writes a
      // carriage return inside a string as the two characters `\r`, never as a
      // raw one, so this path never had the defect. Without this case, a fix that
      // stripped CR *everywhere* -- including out of the escaped form, corrupting
      // the value -- would look identical to this one.
      const source = '{"note":"one\\r\\ntwo",\r\n"ok":true}';
      _writeText('documents/umacapture/storage/chara_detail/active/rec2/record.json', source);
      expect(_crlfCount('documents/umacapture/storage/chara_detail/active/rec2/record.json'), 1);
      final container = _container();

      await _pumpPreview(tester, container, _path('documents/umacapture/storage/chara_detail/active/rec2/record.json'));

      final shown = _previewController().text;
      expect(shown, isNot(contains('\r')));
      expect(shown, prettyPrintJson(source), reason: 'the re-indented form is unchanged by the normalisation');
      expect(shown, contains(r'\r\n'), reason: 'a CR inside a JSON string value is escaped, and must stay escaped');
    });
  });
}

/// How many CRLF pairs the fixture at [relative] holds **in bytes**.
///
/// Counted off the file rather than off the Dart literal that wrote it, because
/// the thing that has to be true is a property of the bytes the preview reads.
int _crlfCount(String relative) {
  final bytes = _file(relative).readAsBytesSync();
  var count = 0;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0x0d && bytes[i + 1] == 0x0a) {
      count++;
    }
  }
  return count;
}
