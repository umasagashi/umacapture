import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

StreamController<PathEntity> _recordExportEventController = StreamController();
final recordExportEventProvider = StreamProvider<PathEntity>((ref) {
  if (_recordExportEventController.hasListener) {
    _recordExportEventController = StreamController();
  }
  return _recordExportEventController.stream;
});

class CharaDetailExportButton extends ConsumerWidget {
  const CharaDetailExportButton({Key? key}) : super(key: key);

  Widget menu({
    required double height,
    required String tooltip,
    required String label,
    required TextStyle? style,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        height: height,
        child: Center(
          child: Text(
            label,
            style: style,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge;
    const menuHeight = 40.0;
    const buttonSize = 30.0;
    final exporting = ref.watch(exportingStateProvider);
    return SizedBox(
      height: buttonSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Disabled(
            disabled: exporting,
            tooltip: "$tr_chara_detail.export.disabled_tooltip".tr(),
            child: PopupMenuButton<int>(
              enabled: ref.watch(charaDetailRecordStorageProvider).isNotEmpty,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.download),
              tooltip: "$tr_chara_detail.export.button_tooltip".tr(),
              splashRadius: 24,
              position: PopupMenuPosition.under,
              shape: RoundedRectangleBorder(
                side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(8),
              ),
              itemBuilder: (BuildContext context) {
                final title = "$tr_chara_detail.export.dialog_title".tr();
                return [
                  PopupMenuItem(
                    height: menuHeight,
                    onTap: () {
                      CsvExporter(title, "records.csv", ref, CharCodec.shiftJis).export(onSuccess: (path) {
                        _recordExportEventController.sink.add(path);
                      });
                    },
                    padding: EdgeInsets.zero,
                    child: menu(
                      height: menuHeight,
                      tooltip: "$tr_chara_detail.export.csv.tooltip".tr(),
                      label: "$tr_chara_detail.export.csv.label".tr(),
                      style: style,
                    ),
                  ),
                  PopupMenuItem(
                    height: menuHeight,
                    onTap: () {
                      CsvExporter(title, "records.csv", ref, CharCodec.utf8Bom).export(onSuccess: (path) {
                        _recordExportEventController.sink.add(path);
                      });
                    },
                    padding: EdgeInsets.zero,
                    child: menu(
                      height: menuHeight,
                      tooltip: "$tr_chara_detail.export.csv_utf.tooltip".tr(),
                      label: "$tr_chara_detail.export.csv_utf.label".tr(),
                      style: style,
                    ),
                  ),
                  PopupMenuItem(
                    height: menuHeight,
                    onTap: () {
                      JsonExporter(title, "records.json", ref).export(onSuccess: (path) {
                        _recordExportEventController.sink.add(path);
                      });
                    },
                    padding: EdgeInsets.zero,
                    child: menu(
                      height: menuHeight,
                      tooltip: "$tr_chara_detail.export.json.tooltip".tr(),
                      label: "$tr_chara_detail.export.json.label".tr(),
                      style: style,
                    ),
                  ),
                  PopupMenuItem(
                    height: menuHeight,
                    onTap: () {
                      ZipExporter(title, "records.zip", ref).export(onSuccess: (path) {
                        _recordExportEventController.sink.add(path);
                      });
                    },
                    padding: EdgeInsets.zero,
                    child: menu(
                      height: menuHeight,
                      tooltip: "$tr_chara_detail.export.zip.tooltip".tr(),
                      label: "$tr_chara_detail.export.zip.label".tr(),
                      style: style,
                    ),
                  ),
                ];
              },
            ),
          ),
          if (exporting)
            const IgnorePointer(
              child: SizedBox(
                width: buttonSize,
                height: buttonSize,
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}
