import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/path_entity.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/report_record_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_preview = "pages.chara_detail.preview";

@jsonSerializable
class Anchor {
  final String h;
  final String v;

  Anchor(this.h, this.v);
}

@jsonSerializable
class Point {
  final int x;
  final int y;
  final Anchor anchor;

  Point(this.x, this.y, this.anchor);
}

@jsonSerializable
class Rect {
  final Point topLeft;
  final Point bottomRight;

  int get width => bottomRight.x - topLeft.x;

  int get height => bottomRight.y - topLeft.y;

  Size get size => Size(width.toDouble(), height.toDouble());

  Rect(this.topLeft, this.bottomRight);
}

@jsonSerializable
class Prediction {
  final double confidence;
  final dynamic label;

  Prediction(this.confidence, this.label);
}

@jsonSerializable
class PredictionData {
  final String model;
  final Rect rect;
  final Prediction prediction;

  PredictionData(this.model, this.rect, this.prediction);

  String toFormatString(LabelMap labelMap) {
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
      if (m.containsKey("chara")) {
        final rental = (m["rental"] ? " (${"$tr_preview.rental".tr()})" : "");
        return labelMap["$model.card"]![m["card"]!.toInt()] + rental;
      } else if (m.containsKey("place")) {
        final place = labelMap["$model.place"]![m["place"]!.toInt()];
        final ground = labelMap["$model.ground"]![m["ground"]!.toInt()];
        final distance = labelMap["$model.distance"]![m["distance"]!.toInt()];
        final variation = labelMap["$model.variation"]![m["variation"]!.toInt()];
        return "$place $ground $distance $variation";
      }
      throw UnsupportedError(toString());
    }
    throw UnsupportedError(toString());
  }
}

@jsonSerializable
class PredictionContainer {
  final List<PredictionData> statusHeader;
  final List<PredictionData> skillTab;
  final List<PredictionData> factorTab;
  final List<PredictionData> campaignTab;

  PredictionContainer(this.statusHeader, this.skillTab, this.factorTab, this.campaignTab);

  static PredictionContainer? load(DirectoryPath recordDir) {
    const options = DeserializationOptions(caseStyle: CaseStyle.snake);
    return JsonMapper.deserialize<PredictionContainer>(
      recordDir.filePath("prediction.json").readAsStringSync(),
      options,
    );
  }
}

@jsonSerializable
class ImageSizeInfo {
  final Rect intersection;

  ImageSizeInfo(this.intersection);
}

class ImageSizeContainer {
  final ImageSizeInfo skill;
  final ImageSizeInfo factor;
  final ImageSizeInfo campaign;

  ImageSizeContainer({
    required this.skill,
    required this.factor,
    required this.campaign,
  });

  static ImageSizeContainer? load(DirectoryPath recordDir) {
    return ImageSizeContainer(
      skill: recordDir.filePath("skill.json").deserializeSync<ImageSizeInfo>()!,
      factor: recordDir.filePath("factor.json").deserializeSync<ImageSizeInfo>()!,
      campaign: recordDir.filePath("campaign.json").deserializeSync<ImageSizeInfo>()!,
    );
  }
}

class _ImageViewer extends ConsumerStatefulWidget {
  final DirectoryPath recordDir;
  final ImageSizeContainer imageSize;
  final Size viewportSize;
  final bool overlay;

  const _ImageViewer({
    Key? key,
    required this.recordDir,
    required this.imageSize,
    required this.viewportSize,
    required this.overlay,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ViewerState();
}

class _ViewerState extends ConsumerState<_ImageViewer> {
  late TransformationController transformationController;
  late final double maxScale;

  // TODO: This should be async.
  late final PredictionContainer? prediction = PredictionContainer.load(widget.recordDir);

  @override
  void initState() {
    super.initState();
    final imageWidth = [
      widget.imageSize.skill.intersection.width,
      widget.imageSize.factor.intersection.width,
      widget.imageSize.campaign.intersection.width,
    ].sum;
    final scale = widget.viewportSize.width / imageWidth;
    maxScale = Math.max(scale, 3);
    transformationController = TransformationController(Matrix4.identity()..scale(Math.max(0.5, scale)));
  }

  Widget predictionTabOverlay(FilePath imagePath, ImageSizeInfo sizeInfo, List<PredictionData>? predictions) {
    final labelMap = ref.watch(labelMapProvider);
    final textStyle = TextStyle(
      color: Colors.black,
      backgroundColor: Colors.white.withOpacity(0.5),
      fontSize: 12,
    );
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
                    // color: Colors.grey,
                    borderRadius: BorderRadius.zero,
                    border: Border.all(color: Colors.black.withOpacity(0.5)),
                  ),
                ),
                SizedBox(
                  width: data.rect.width.toDouble() + (sizeInfo.intersection.width * 0.04),
                  child: Text(
                    data.toFormatString(labelMap),
                    style: textStyle,
                  ),
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
      maxScale: maxScale,
      panEnabled: true,
      scaleEnabled: true,
      constrained: false,
      transformationController: transformationController,
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
              !widget.overlay ? null : [...(prediction?.statusHeader ?? []), ...(prediction?.skillTab ?? [])],
            ),
            predictionTabOverlay(
              widget.recordDir.filePath("factor.png"),
              widget.imageSize.factor,
              !widget.overlay ? null : prediction?.factorTab,
            ),
            predictionTabOverlay(
              widget.recordDir.filePath("campaign.png"),
              widget.imageSize.campaign,
              !widget.overlay ? null : prediction?.campaignTab,
            ),
          ],
        ),
      ),
    );
  }
}

class CharaDetailPreviewDialog extends ConsumerStatefulWidget {
  final DirectoryPath recordDir;
  final ImageSizeContainer imageSize;

  const CharaDetailPreviewDialog({
    Key? key,
    required this.recordDir,
    required this.imageSize,
  }) : super(key: key);

  static void show(RefBase ref, DirectoryPath recordDir) {
    final imageSize = ImageSizeContainer.load(recordDir);
    CardDialog.show(ref, (_) => CharaDetailPreviewDialog(recordDir: recordDir, imageSize: imageSize!));
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharaDetailPreviewDialogState();
}

class _CharaDetailPreviewDialogState extends ConsumerState<CharaDetailPreviewDialog> {
  late bool overlay;

  @override
  void initState() {
    super.initState();
    overlay = false;
  }

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
                return _ImageViewer(
                  recordDir: widget.recordDir,
                  imageSize: widget.imageSize,
                  viewportSize: Size(constraints.maxWidth, constraints.maxHeight),
                  overlay: overlay,
                );
              },
            ),
          ),
        ),
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Tooltip(
            message: "$tr_preview.dialog.visualize_prediction.$overlay.tooltip".tr(),
            child: OutlinedButton.icon(
              icon: Icon(overlay ? Icons.subtitles_off_outlined : Icons.subtitles_outlined),
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
                icon: const Icon(Icons.report_outlined),
                label: Text("$tr_preview.dialog.report_button.label".tr()),
                onPressed: () {
                  CardDialog.dismiss(ref.base);
                  ReportRecordDialog.show(ref.base, widget.recordDir);
                },
              ),
            ),
          ],
          const Spacer(),
          Tooltip(
            message: "$tr_preview.dialog.close_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_preview.dialog.close_button.label".tr()),
              onPressed: () {
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
        ],
      ),
    );
  }
}
