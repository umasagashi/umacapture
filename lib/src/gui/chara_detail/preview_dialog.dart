import 'package:easy_localization/easy_localization.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

class CharaDetailPreviewDialog extends ConsumerStatefulWidget {
  final CharaDetailRecord record;
  final int initialPage;

  const CharaDetailPreviewDialog({
    Key? key,
    required this.record,
    required this.initialPage,
  }) : super(key: key);

  static void show(WidgetRef ref, CharaDetailRecord record, int initialPage) {
    CardDialog.show(ref, (_) => CharaDetailPreviewDialog(record: record, initialPage: initialPage));
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharaDetailPreviewDialogState();
}

class _CharaDetailPreviewDialogState extends ConsumerState<CharaDetailPreviewDialog> {
  late ExtendedPageController controller;

  int get page => controller.page!.round();

  void moveTo(int page) {
    controller.animateToPage(page, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
  }

  void prev() {
    if (page > 0) {
      moveTo(page - 1);
    }
  }

  void next() {
    if (page < 2) {
      moveTo(page + 1);
    }
  }

  @override
  void initState() {
    super.initState();
    setState(() {
      controller = ExtendedPageController(initialPage: widget.initialPage);
    });
  }

  @override
  Widget build(BuildContext context) {
    return CardDialog(
      dialogTitle: "$tr_chara_detail.preview.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.preview.dialog.close_button.tooltip".tr(),
      usePageView: false,
      content: Expanded(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: ExtendedImageGesturePageView.builder(
                itemCount: 3,
                controller: controller,
                scrollDirection: Axis.horizontal,
                canScrollPage: (_) => true,
                itemBuilder: (BuildContext context, int index) {
                  final storage = ref.read(charaDetailRecordStorageProvider.notifier);
                  final imageMode = CharaDetailRecordImageMode.values[index + 1];
                  return LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      return GestureDetector(
                        onSecondaryTap: () {
                          CardDialog.dismiss(ref);
                        },
                        child: ExtendedImage.file(
                          storage.imagePathOf(widget.record, imageMode).toFile(),
                          filterQuality: FilterQuality.medium,
                          fit: BoxFit.contain,
                          mode: ExtendedImageMode.gesture,
                          onDoubleTap: (_) => storage.copyToClipboard(widget.record, imageMode),
                          initGestureConfigHandler: (ExtendedImageState state) {
                            final h = state.extendedImageInfo!.image.width / constraints.maxWidth;
                            final v = state.extendedImageInfo!.image.height / constraints.maxHeight;
                            final r = Math.max(h, v);
                            const f = 0.95;
                            return GestureConfig(
                              maxScale: Math.max(((r / h) * f), r),
                              initialScale: r,
                              minScale: Math.min(f, r * f),
                              initialAlignment: InitialAlignment.topCenter,
                              reverseMousePointerScrollDirection: true,
                            );
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_left),
                  splashColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  onPressed: prev,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_right),
                  splashColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  onPressed: next,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
