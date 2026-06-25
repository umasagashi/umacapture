import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/report_record_dialog.dart';
import '/src/gui/common.dart';

part 'preview_dialog.mapper.dart';

// ignore: constant_identifier_names
const tr_preview = "pages.chara_detail.preview";

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Anchor with AnchorMappable {
  final String h;
  final String v;

  Anchor(this.h, this.v);
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Point with PointMappable {
  final int x;
  final int y;
  final Anchor anchor;

  Point(this.x, this.y, this.anchor);
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Rect with RectMappable {
  final Point topLeft;
  final Point bottomRight;

  int get width => bottomRight.x - topLeft.x;

  int get height => bottomRight.y - topLeft.y;

  Size get size => Size(width.toDouble(), height.toDouble());

  Rect(this.topLeft, this.bottomRight);
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Prediction with PredictionMappable {
  final double confidence;
  final dynamic label;

  Prediction(this.confidence, this.label);
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class PredictionData with PredictionDataMappable {
  final String model;
  final Rect rect;
  final Prediction prediction;

  PredictionData(this.model, this.rect, this.prediction);

  String getLabelString(LabelMap labelMap) {
    if (prediction.label is String) {
      return prediction.label;
    }
    if (prediction.label is int) {
      final labels = labelMap["$model.name"];
      if (labels != null) {
        return labels[prediction.label.toInt()];
      }
      return (prediction.label as int).toNumberString();
    }
    if (prediction.label is Map) {
      final Map<String, dynamic> m = prediction.label;
      // Resolve an index against the model's label list, falling back to the
      // raw index (like the int branch) when the label map lacks the entry or
      // the index is out of range, instead of throwing during overlay render.
      String labelAt(String key, Object? index) {
        final labels = labelMap["$model.$key"];
        final i = (index as num?)?.toInt();
        if (labels != null && i != null && i >= 0 && i < labels.length) {
          return labels[i];
        }
        return "${i ?? "?"}";
      }

      if (m.containsKey("chara")) {
        final rental = (m["rental"] == true ? " (${"$tr_preview.rental".tr()})" : "");
        return labelAt("card", m["card"]) + rental;
      } else if (m.containsKey("place")) {
        final place = labelAt("place", m["place"]);
        final ground = labelAt("ground", m["ground"]);
        final distance = labelAt("distance", m["distance"]);
        final variation = labelAt("variation", m["variation"]);
        return "$place $ground $distance $variation";
      }
      throw UnsupportedError(toString());
    }
    throw UnsupportedError(toString());
  }

  String toFormatString(LabelMap labelMap) {
    return "${getLabelString(labelMap)} (${prediction.confidence.toStringAsFixed(2)})";
  }

  Color getColor() {
    const lowerThreshold = 0.8;
    final v = (1.0 - (prediction.confidence - lowerThreshold) / (1.0 - lowerThreshold)).clamp(0.0, 1.0);
    return HSVColor.fromAHSV(1.0, 0.0, 1.0, v).toColor();
  }
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class PredictionContainer with PredictionContainerMappable {
  final List<PredictionData> statusHeader;
  final List<PredictionData> skillTab;
  final List<PredictionData> factorTab;
  final List<PredictionData> campaignTab;

  PredictionContainer(this.statusHeader, this.skillTab, this.factorTab, this.campaignTab);

  static PredictionContainer? load(DirectoryPath recordDir) {
    // Optional overlay data: an older or quarantined record may lack a readable
    // prediction.json. Degrade to no overlay instead of throwing during build.
    try {
      return PredictionContainerMapper.fromJson(recordDir.filePath("prediction.json").readAsStringSync());
    } catch (e, s) {
      logger.w("Failed to load prediction.json for ${recordDir.name}: $e\n$s");
      return null;
    }
  }
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class ImageSizeInfo with ImageSizeInfoMappable {
  final Rect intersection;

  ImageSizeInfo(this.intersection);
}

class ImageSizeContainer {
  final ImageSizeInfo skill;
  final ImageSizeInfo factor;
  final ImageSizeInfo campaign;

  ImageSizeContainer({required this.skill, required this.factor, required this.campaign});

  static ImageSizeContainer? load(DirectoryPath recordDir) {
    return ImageSizeContainer(
      skill: recordDir.filePath("skill.json").deserializeSync<ImageSizeInfo>(),
      factor: recordDir.filePath("factor.json").deserializeSync<ImageSizeInfo>(),
      campaign: recordDir.filePath("campaign.json").deserializeSync<ImageSizeInfo>(),
    );
  }
}

/// Memoized, layout-independent loaders for a record's preview data, keyed by the
/// record directory's path string.
///
/// Both loaders do synchronous disk I/O, so they must not run on every layout
/// pass: the preview dialog and side panel both read them from inside a
/// `LayoutBuilder` that re-runs on resize / splitter drag / overlay toggle.
/// `autoDispose.family` keeps the result cached while continuously watched and
/// frees it a frame after the last watcher leaves (e.g. navigating to another
/// record). The key is the path string because [DirectoryPath] uses identity
/// equality (a fresh instance per build would never cache-hit).
final imageSizeContainerProvider = Provider.autoDispose.family<ImageSizeContainer?, String>((ref, path) {
  // size json may be missing or corrupt (e.g. an archived record); degrade to a
  // placeholder instead of throwing out of the watching build.
  try {
    return ImageSizeContainer.load(DirectoryPath(path));
  } catch (e, s) {
    logger.w("Failed to load image size for $path: $e\n$s");
    return null;
  }
});

final predictionContainerProvider = Provider.autoDispose.family<PredictionContainer?, String>((ref, path) {
  // PredictionContainer.load already degrades to null on a missing/unreadable
  // prediction.json.
  return PredictionContainer.load(DirectoryPath(path));
});

/// Whether a record still has its `prediction.json` (a cheap existence check, no
/// parse). Archiving drops it, so the overlay visualization is offered only when
/// this is true.
final predictionAvailableProvider = Provider.autoDispose.family<bool, String>((ref, path) {
  return DirectoryPath(path).filePath("prediction.json").existsSync();
});

class ImageViewer extends ConsumerStatefulWidget {
  final DirectoryPath recordDir;
  final ImageSizeContainer imageSize;
  final Size viewportSize;
  final Size contentSize;
  final bool overlay;
  final double initialScale;
  final double maxScale;
  final PredictionContainer? prediction;

  const ImageViewer({
    super.key,
    required this.recordDir,
    required this.imageSize,
    required this.viewportSize,
    required this.contentSize,
    required this.overlay,
    required this.initialScale,
    required this.maxScale,
    required this.prediction,
  });

  @override
  ConsumerState<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends ConsumerState<ImageViewer> {
  Widget predictionTabOverlay(FilePath? imagePath, ImageSizeInfo sizeInfo, List<PredictionData>? predictions) {
    final labelMap = ref.watch(labelMapProvider);
    final textStyle = TextStyle(color: Colors.black, backgroundColor: Colors.white.withValues(alpha: 0.5), fontSize: 9);
    // Archived records may carry no image for this tab; keep the layout slot but
    // show a placeholder instead of a broken-image box.
    if (imagePath == null) {
      return Container(
        width: sizeInfo.intersection.width.toDouble(),
        height: sizeInfo.intersection.height.toDouble(),
        color: Colors.black.withValues(alpha: 0.04),
        alignment: Alignment.center,
        child: Icon(Symbols.hide_image_rounded, color: Colors.black.withValues(alpha: 0.3)),
      );
    }
    return Stack(
      children: [
        Image.file(
          imagePath.toFile(),
          width: sizeInfo.intersection.width.toDouble(),
          height: sizeInfo.intersection.height.toDouble(),
          fit: BoxFit.none,
        ),
        ...(predictions ?? []).map((PredictionData data) {
          return Positioned(
            left: data.rect.topLeft.x.toDouble(),
            top: data.rect.topLeft.y.toDouble(),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: data.rect.width.toDouble() + 1,
                  height: data.rect.height.toDouble() + 1,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.zero,
                    border: Border.all(color: Colors.black.withValues(alpha: 0.5)),
                  ),
                ),
                SizedBox(
                  width: data.rect.width.toDouble() + (sizeInfo.intersection.width * 0.04),
                  child: Text(data.toFormatString(labelMap), style: textStyle.copyWith(color: data.getColor())),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return WheelZoomViewer(
      contentSize: widget.contentSize,
      viewportSize: widget.viewportSize,
      initialScale: widget.initialScale,
      maxScale: widget.maxScale,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          predictionTabOverlay(
            resolveImagePath(widget.recordDir, CharaDetailRecordImageMode.skillPlain),
            widget.imageSize.skill,
            !widget.overlay
                ? null
                : [...(widget.prediction?.statusHeader ?? []), ...(widget.prediction?.skillTab ?? [])],
          ),
          predictionTabOverlay(
            resolveImagePath(widget.recordDir, CharaDetailRecordImageMode.factorPlain),
            widget.imageSize.factor,
            !widget.overlay ? null : widget.prediction?.factorTab,
          ),
          predictionTabOverlay(
            resolveImagePath(widget.recordDir, CharaDetailRecordImageMode.campaignPlain),
            widget.imageSize.campaign,
            !widget.overlay ? null : widget.prediction?.campaignTab,
          ),
        ],
      ),
    );
  }
}

/// The dialog's zoomable image area: turns the already-loaded [imageSize] into a
/// fit-to-width [ImageViewer], or shows the load-error placeholder when the size
/// data is missing or degenerate.
///
/// Takes the loaded data as inputs (watched by the dialog's build) so the disk
/// reads stay out of the [LayoutBuilder], which re-runs during layout.
class _PreviewContent extends StatelessWidget {
  final DirectoryPath recordDir;
  final ImageSizeContainer? imageSize;
  final PredictionContainer? prediction;
  final bool overlay;

  const _PreviewContent({
    required this.recordDir,
    required this.imageSize,
    required this.prediction,
    required this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    final imageSize = this.imageSize;
    if (imageSize == null) {
      // The size json is gone. If the images are gone too, this is an intentional
      // image-less archive (the geometry json is dropped alongside the images), so
      // show the neutral "no image" message; otherwise it is a genuine load error.
      const modes = [
        CharaDetailRecordImageMode.skillPlain,
        CharaDetailRecordImageMode.factorPlain,
        CharaDetailRecordImageMode.campaignPlain,
      ];
      final hasAnyImage = modes.any((mode) => resolveImagePath(recordDir, mode) != null);
      return ErrorMessageWidget(message: hasAnyImage ? "$tr_preview.loading_error".tr() : "$tr_preview.no_image".tr());
    }
    final imageWidth = [
      imageSize.skill.intersection.width,
      imageSize.factor.intersection.width,
      imageSize.campaign.intersection.width,
    ].sum;
    if (imageWidth <= 0) {
      return ErrorMessageWidget(message: "$tr_preview.loading_error".tr());
    }
    // The three tabs render side by side, so the content is as wide as their
    // combined width and as tall as the tallest one.
    final maxHeight = [
      imageSize.skill.intersection.height,
      imageSize.factor.intersection.height,
      imageSize.campaign.intersection.height,
    ].reduce((a, b) => a > b ? a : b);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final scale = constraints.maxWidth / imageWidth;
        return ImageViewer(
          recordDir: recordDir,
          imageSize: imageSize,
          viewportSize: Size(constraints.maxWidth, constraints.maxHeight),
          contentSize: Size(imageWidth.toDouble(), maxHeight.toDouble()),
          overlay: overlay,
          initialScale: scale,
          maxScale: scale * 3,
          prediction: prediction,
        );
      },
    );
  }
}

class CharaDetailPreviewDialog extends ConsumerStatefulWidget {
  final List<DirectoryPath> recordDirs;
  final int initialIdx;

  const CharaDetailPreviewDialog({super.key, required this.recordDirs, required this.initialIdx});

  static void show(RefBase ref, List<DirectoryPath> recordDirs, int initialIdx) {
    CardDialog.show(ref, (_) => CharaDetailPreviewDialog(recordDirs: recordDirs, initialIdx: initialIdx));
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharaDetailPreviewDialogState();
}

class _CharaDetailPreviewDialogState extends ConsumerState<CharaDetailPreviewDialog> {
  bool overlay = false;
  late int currentIdx = widget.initialIdx;

  @override
  Widget build(BuildContext context) {
    final recordDir = widget.recordDirs[currentIdx];
    // Watch the memoized disk loads here in the build phase (not inside the
    // LayoutBuilder below, which runs during layout): re-running on resize /
    // overlay toggle reuses the cached value, so only navigating to another record
    // re-reads json. The overlay's prediction is read only while it is on.
    final imageSize = ref.watch(imageSizeContainerProvider(recordDir.path));
    // The overlay is only meaningful while prediction.json exists; archiving drops
    // it. Gate on availability so the toggle isn't a dead button on archived
    // records, but keep the user's `overlay` preference so it re-applies when
    // navigating back to a record that still has predictions.
    final predictionAvailable = ref.watch(predictionAvailableProvider(recordDir.path));
    final effectiveOverlay = overlay && predictionAvailable;
    final prediction = effectiveOverlay ? ref.watch(predictionContainerProvider(recordDir.path)) : null;
    return CardDialog(
      dialogTitle: "$tr_preview.dialog.title".tr(),
      closeButtonTooltip: "$tr_preview.dialog.close_button.tooltip".tr(),
      usePageView: false,
      content: Expanded(
        child: GestureDetector(
          onSecondaryTap: () {
            CardDialog.dismiss(ref.base);
          },
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: _PreviewContent(
              recordDir: recordDir,
              imageSize: imageSize,
              prediction: prediction,
              overlay: effectiveOverlay,
            ),
          ),
        ),
      ),
      bottom: IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (predictionAvailable)
              Tooltip(
                message: "$tr_preview.dialog.visualize_prediction.$effectiveOverlay.tooltip".tr(),
                child: OutlinedButton.icon(
                  icon: Icon(effectiveOverlay ? Symbols.subtitles_off_rounded : Symbols.subtitles_rounded),
                  label: Text("$tr_preview.dialog.visualize_prediction.$effectiveOverlay.label".tr()),
                  onPressed: () {
                    setState(() {
                      overlay = !overlay;
                    });
                  },
                ),
              ),
            if (isSentryAvailable() && effectiveOverlay) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: "$tr_preview.dialog.report_button.tooltip".tr(),
                child: OutlinedButton.icon(
                  icon: const Icon(Symbols.report_rounded),
                  label: Text("$tr_preview.dialog.report_button.label".tr()),
                  onPressed: () {
                    CardDialog.dismiss(ref.base);
                    ReportRecordDialog.show(ref.base, widget.recordDirs[currentIdx]);
                  },
                ),
              ),
            ],
            const Spacer(),
            Disabled(
              disabled: currentIdx == 0,
              child: Tooltip(
                message: "$tr_preview.dialog.up_button.tooltip".tr(),
                child: OutlinedButton(
                  child: const Icon(Symbols.arrow_upward_rounded),
                  onPressed: () {
                    setState(() {
                      currentIdx = Math.clamp(0, currentIdx - 1, widget.recordDirs.length - 1);
                    });
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            Disabled(
              disabled: currentIdx == widget.recordDirs.length - 1,
              child: Tooltip(
                message: "$tr_preview.dialog.down_button.tooltip".tr(),
                child: OutlinedButton(
                  child: const Icon(Symbols.arrow_downward_rounded),
                  onPressed: () {
                    setState(() {
                      currentIdx = Math.clamp(0, currentIdx + 1, widget.recordDirs.length - 1);
                    });
                  },
                ),
              ),
            ),
            const VerticalDivider(width: 20, indent: 8, endIndent: 8),
            Tooltip(
              message: "$tr_preview.dialog.close_button.tooltip".tr(),
              child: FilledButton.icon(
                icon: const Icon(Symbols.close_rounded),
                label: Text("$tr_preview.dialog.close_button.label".tr()),
                onPressed: () {
                  CardDialog.dismiss(ref.base);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
