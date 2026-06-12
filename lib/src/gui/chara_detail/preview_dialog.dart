import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
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

class ImageViewer extends ConsumerStatefulWidget {
  final DirectoryPath recordDir;
  final ImageSizeContainer imageSize;
  final bool overlay;
  final double initialScale;
  final double maxScale;
  final PredictionContainer? prediction;

  const ImageViewer({
    super.key,
    required this.recordDir,
    required this.imageSize,
    required this.overlay,
    required this.initialScale,
    required this.maxScale,
    required this.prediction,
  });

  static ImageViewer? load({required DirectoryPath recordDir, required Size viewportSize, required bool overlay}) {
    // Runs inside LayoutBuilder during build: any failure (missing/corrupt
    // size json) must return null so the caller's `?? ErrorMessageWidget`
    // fallback engages, never throw out of the build.
    try {
      final imageSize = ImageSizeContainer.load(recordDir);
      if (imageSize == null) {
        return null;
      }
      final imageWidth = [
        imageSize.skill.intersection.width,
        imageSize.factor.intersection.width,
        imageSize.campaign.intersection.width,
      ].sum;
      final scale = viewportSize.width / imageWidth;
      // TODO: This should be async.
      final prediction = PredictionContainer.load(recordDir);
      return ImageViewer(
        recordDir: recordDir,
        imageSize: imageSize,
        overlay: overlay,
        initialScale: scale,
        maxScale: scale * 3,
        prediction: prediction,
      );
    } catch (e, s) {
      logger.w("Failed to load image viewer for $recordDir: $e\n$s");
      return null;
    }
  }

  @override
  ConsumerState<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends ConsumerState<ImageViewer> {
  late TransformationController _transformationController = _buildController();

  TransformationController _buildController() {
    final scale = widget.initialScale;
    return TransformationController(Matrix4.identity()..scaleByDouble(scale, scale, scale, 1.0));
  }

  @override
  void didUpdateWidget(ImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The fit-to-viewport transform is derived from initialScale (viewport width / image width). Re-fit with a
    // fresh controller only when that changes (a window resize or navigating to a differently-sized record).
    if (widget.initialScale != oldWidget.initialScale) {
      _transformationController.dispose();
      _transformationController = _buildController();
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  Widget predictionTabOverlay(FilePath imagePath, ImageSizeInfo sizeInfo, List<PredictionData>? predictions) {
    final labelMap = ref.watch(labelMapProvider);
    final textStyle = TextStyle(color: Colors.black, backgroundColor: Colors.white.withValues(alpha: 0.5), fontSize: 9);
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
    return InteractiveViewer(
      minScale: 0.25,
      maxScale: widget.maxScale,
      panEnabled: true,
      scaleEnabled: true,
      constrained: false,
      transformationController: _transformationController,
      child: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage("assets/image/tile_background.png"),
            repeat: ImageRepeat.repeat,
            opacity: 0.1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            predictionTabOverlay(
              widget.recordDir.filePath("skill.png"),
              widget.imageSize.skill,
              !widget.overlay
                  ? null
                  : [...(widget.prediction?.statusHeader ?? []), ...(widget.prediction?.skillTab ?? [])],
            ),
            predictionTabOverlay(
              widget.recordDir.filePath("factor.png"),
              widget.imageSize.factor,
              !widget.overlay ? null : widget.prediction?.factorTab,
            ),
            predictionTabOverlay(
              widget.recordDir.filePath("campaign.png"),
              widget.imageSize.campaign,
              !widget.overlay ? null : widget.prediction?.campaignTab,
            ),
          ],
        ),
      ),
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
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return ImageViewer.load(
                      recordDir: widget.recordDirs[currentIdx],
                      viewportSize: Size(constraints.maxWidth, constraints.maxHeight),
                      overlay: overlay,
                    ) ??
                    ErrorMessageWidget(message: "$tr_preview.dialog.loading_error".tr());
              },
            ),
          ),
        ),
      ),
      bottom: IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Tooltip(
              message: "$tr_preview.dialog.visualize_prediction.$overlay.tooltip".tr(),
              child: OutlinedButton.icon(
                icon: Icon(overlay ? Symbols.subtitles_off_rounded : Symbols.subtitles_rounded),
                label: Text("$tr_preview.dialog.visualize_prediction.$overlay.label".tr()),
                onPressed: () {
                  setState(() {
                    overlay = !overlay;
                  });
                },
              ),
            ),
            if (isSentryAvailable() && overlay) ...[
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
