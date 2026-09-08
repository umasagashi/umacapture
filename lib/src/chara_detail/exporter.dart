import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:charset/charset.dart';
import 'package:csv/csv.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_zip.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/storage/zip_own_output.dart';
import '/src/core/utils.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/toast.dart';

part 'exporter.mapper.dart';

final exportingStateProvider = settableNotifierProvider<bool>(false);

enum ExportDelivery {
  fileWritten("file_written"),
  downloadRequested("download_requested");

  final String payloadValue;

  const ExportDelivery(this.payloadValue);
}

@immutable
class ExportResult {
  final String fileName;
  final FilePath? path;
  final ExportDelivery delivery;

  const ExportResult._({required this.fileName, required this.path, required this.delivery});

  factory ExportResult.fileWritten(FilePath path) {
    return ExportResult._(fileName: path.name, path: path, delivery: ExportDelivery.fileWritten);
  }

  const ExportResult.downloadRequested(String fileName)
    : this._(fileName: fileName, path: null, delivery: ExportDelivery.downloadRequested);
}

typedef ExportResultCallback = Callback<ExportResult>;

typedef ExportSaveFile =
    Future<String?> Function({
      required String dialogTitle,
      required String fileName,
      String? initialDirectory,
      required Uint8List bytes,
      required bool lockParentWindow,
    });

Future<String?> _saveExportFile({
  required String dialogTitle,
  required String fileName,
  String? initialDirectory,
  required Uint8List bytes,
  required bool lockParentWindow,
}) {
  return FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    initialDirectory: initialDirectory,
    bytes: bytes,
    lockParentWindow: lockParentWindow,
  );
}

final exportSaveFileProvider = Provider<ExportSaveFile>((_) => _saveExportFile);
final exportInitialDirectoryProvider = Provider<Future<String?> Function()>(
  (_) =>
      () async => (await getDownloadsDirectory())?.path,
);
final exportIsWebProvider = Provider<bool>((_) => kIsWeb);

/// The gate [ZipExporter] takes the exported records' mutation locks on.
///
/// One provider for both legs, so the desktop and web zip exports cannot end up
/// locking differently. Defaults to the same platform gate every other record
/// reader and writer uses; tests override it to observe the acquisitions.
final exportRecoveryGateProvider = Provider<RecordRecoveryGate>((_) => platformRecordRecoveryGate);

/// What [ZipExporter] announces to the long-read registry while it packs.
///
/// **The record export is a long reader and now says so.** It walks every
/// selected record directory and reads each file in it — on desktop inside a
/// `compute` isolate whose handles outlive the lock, which is the window the
/// registry exists for. Until this existed, [ZipExporter]'s own comment was the
/// only statement of the problem ("Nothing in the UI prevents that overlap"),
/// and it was true of deletes as well as of writers: the record page's delete
/// dialog and the storage view both offered to remove a directory the export
/// was in the middle of reading.
///
/// One function for both legs, for the reason [exportRecoveryGateProvider] is
/// one provider for both: desktop takes the gate around its `compute`, web
/// takes it inside [RecordZipService.export], and a claim written separately at
/// those two points would be free to name different paths.
LongReadDeclaration exportLongReadDeclaration(RefBase ref, List<PathEntity> paths) {
  return LongReadDeclaration.claim(
    registry: ref.read(longReadRegistryProvider.notifier),
    kind: LongReadKind.export,
    paths: paths,
  );
}

/// The label map the desktop zip layout carries beside the records.
///
/// Named here rather than spelled at each use because three places now depend on
/// it being the same file: the worker that packs it, the claim that says the
/// export is holding it, and the dialog that asks whether somebody else is.
const exportLabelsFileName = "labels.json";

/// Every path a record export holds open for its whole run.
///
/// **One derivation, three callers**, for the reason the record-page delete
/// surfaces have one: the paths the export *claims* and the paths a surface
/// *asks about* have to be the same set, and two lists written separately are
/// free to disagree — which is how a button is offered over a folder the export
/// is reading, or a claim is taken over a folder it never opens.
///
/// **`modules/labels.json` is one of them on desktop, and this is what closes
/// the mixing the record export could produce.** `ZipExporter._run` streams that
/// file into the archive beside the record directories, and `modules` is a
/// `StorageLockScope.unlocked` group whose writers acquire nothing — so a module
/// install extracting over it while the walk runs was packed silently, with no
/// exception and an archive that opens. Naming it here puts it inside the claim
/// (so the storage view stops offering to delete or bundle it under a running
/// export) and inside the question (so the export is not offered while an
/// install is running).
///
/// **[isWeb] and not `kIsWeb`**, and it changes the answer: the web leg builds
/// the Stage-4 layout in [ZipExporter.exportBytes], which carries no
/// `labels.json` at all, so claiming it there would hold a path the export never
/// opens. That is the divergence `.claude/rules/platform-parity.md` asks to be
/// stated at the point it happens: the two legs produce different archives, and
/// the set of files each reads follows its own layout.
///
/// The format is deliberately *not* a parameter. The dialog asks this question
/// while the radio is still live and before the save dialog has run, so a
/// question narrowed to the format currently selected would be a question about
/// a decision the user has not made yet; the export's widest set is the honest
/// one to withhold a single confirm button on.
List<PathEntity> recordExportLongReadPaths({
  required PathInfo pathInfo,
  required RecordSource source,
  required Iterable<String> recordIds,
  required bool isWeb,
}) {
  return [
    for (final id in recordIds) recordDirOfId(pathInfo, source, id),
    if (!isWeb) pathInfo.modulesDir.filePath(exportLabelsFileName),
  ];
}

abstract class Exportable {
  String get csv;
}

/// Drives an [Exporter] from a container-scoped ref.
///
/// The directory picker and file write run long after the triggering widget
/// (the format-picker dialog) is gone, so the exporter must not borrow that
/// widget's `WidgetRef` — reading a disposed ref throws and the write silently
/// fails. Routing through this notifier gives the exporter a ref that lives for
/// the app's lifetime, mirroring how the archive flow uses its controller.
class ExportRunner extends Notifier<void> {
  @override
  void build() {}

  Future<void> run(Exporter Function(RefBase ref) builder, {ExportResultCallback? onSuccess}) {
    return builder(ref.base).export(onSuccess: onSuccess);
  }
}

final exportRunnerProvider = NotifierProvider<ExportRunner, void>(ExportRunner.new);

abstract class Exporter {
  final String dialogTitle;

  final String defaultFileName;

  /// Container-scoped ref (see [ExportRunner]) used to read the records, grid and
  /// path info needed by the export, and to flip [exportingStateProvider].
  final RefBase ref;

  /// Ids of the records to export. Snapshotted when the export is triggered so a
  /// later change to the live selection (e.g. leaving selection mode) cannot
  /// alter the set midway through the asynchronous export.
  final Set<String> recordIds;

  /// Record source snapshotted at trigger time. The picker and write run after
  /// the selection scrim is gone (which makes the source dropdown live again), so
  /// the exporter must not re-read [recordSourceProvider] mid-flight — otherwise a
  /// source switch could redirect the write to the other set's directories.
  final RecordSource source;

  Exporter(this.dialogTitle, this.defaultFileName, this.ref, this.recordIds, this.source);

  /// The records to export, drawn from the snapshotted [source] and filtered to
  /// [recordIds].
  ///
  /// Throws [StateError] when the source resolves to no records while ids were
  /// requested — e.g. the archive store is still loading (its read view yields an
  /// empty list), which would otherwise silently write an empty file and fire a
  /// success toast. Surfacing it routes through the export's error handler.
  List<CharaDetailRecord> resolveSelectedRecords() {
    final records = recordsForSource(ref, source).where((record) => recordIds.contains(record.id)).toList();
    if (records.isEmpty && recordIds.isNotEmpty) {
      throw StateError("No records resolved for export (source not ready or all ids missing).");
    }
    return records;
  }

  Future<void> export({ExportResultCallback? onSuccess}) async {
    // Web has no writable OS path and no native Save dialog: the browser can
    // only receive the finished bytes and offer them as a download. So on web
    // the exporter produces the whole file in memory ([exportBytes]) and hands
    // it to `saveFile(bytes:)`, bypassing the path-based desktop writers below.
    // The desktop path is left byte-identical.
    if (ref.read(exportIsWebProvider)) {
      await _exportWeb(onSuccess: onSuccess);
      return;
    }
    String? savedPath;
    try {
      final initialDirectory = await ref.read(exportInitialDirectoryProvider)();
      // Use the native Save-File dialog so the user picks the exact file name and
      // location. file_picker 12's saveFile would also write its `bytes` to the
      // chosen path, but the path-based exporters below produce the file themselves.
      // An empty byte list therefore makes it a path picker only.
      savedPath = await ref.read(exportSaveFileProvider)(
        dialogTitle: dialogTitle,
        fileName: defaultFileName,
        initialDirectory: initialDirectory,
        bytes: Uint8List(0),
        lockParentWindow: true,
      );
    } catch (e, st) {
      _reportFailure(e, st);
      return;
    }
    if (savedPath == null) {
      return;
    }
    // Asked again now the picker has returned, and this is the second of the two
    // moments the one refusal covers. `export_button.dart` asks it while it draws
    // the confirm, and that answer is a frame old by the time the user has chosen
    // a file: the native dialog locks the parent window but not the event loop, so
    // an automatic module install can register between the two — the one writer
    // the export shares a file with (`modules/labels.json`) and the one that takes
    // no lock at all. Nothing else can arrive here without a gesture, and no
    // gesture is possible while the dialog is up.
    //
    // The same derivation the button asked and the claim below takes, read rather
    // than watched: this is not a build, and the claim `_export` is about to take
    // settles the question for the rest of the run.
    //
    // The layout and not `pathInfoProvider`, the step `export_button.dart`
    // explains: an export needs to know where the store is, not that it was
    // successfully prepared. A layout the app has not resolved is nothing to ask
    // about — the claim it would be compared against is derived from that same
    // layout — so the run goes on to fail on its own terms if it is going to.
    final layout = ref.read(pathLayoutProvider);
    final blockedBy = layout == null
        ? null
        : storageDeleteBlockedBy(
            StorageDeletePathsRequest(
              recordExportLongReadPaths(
                pathInfo: layout,
                source: source,
                recordIds: recordIds,
                // The desktop leg: `_exportWeb` returned above, and web has no
                // picker window for anything to arrive through.
                isWeb: false,
              ),
            ),
            ref.read(longReadRegistryProvider).values,
          );
    if (blockedBy != null) {
      // Said and not merely declined: the user has chosen a file and pressed save,
      // so silence here reads as an export that worked. The sentence is the one
      // every withheld control in the app shows — see [longReadBusyMessage], whose
      // doc states why one sentence covers both moments — and not the failure
      // toast below, because nothing was attempted and nothing failed.
      logger.i("Declined to export ${recordIds.length} record(s): ${blockedBy.name} is holding a file it reads.");
      Toaster.show(ToastData.error(description: longReadBusyMessage()));
      return;
    }
    final path = FilePath(savedPath);
    final notifier = ref.read(exportingStateProvider.notifier);
    notifier.set(true);
    try {
      await _export(path);
      onSuccess?.call(ExportResult.fileWritten(path));
    } catch (e, st) {
      _reportFailure(e, st);
    } finally {
      notifier.set(false);
    }
  }

  Future<dynamic> _export(FilePath path);

  /// Builds the export's bytes in memory for the web download path.
  ///
  /// Every format exposed on Web implements it; the default rejects, which surfaces as an error toast rather
  /// than crashing. The desktop path never calls this.
  Future<Uint8List> exportBytes() {
    throw UnsupportedError("Web export is not implemented for this format.");
  }

  /// Web export: build the bytes, then let the browser download them.
  ///
  /// Mirrors the desktop [export] control flow (flip [exportingStateProvider],
  /// surface failures via a toast, always clear the flag) but replaces the
  /// directory-picker + path-write with `saveFile(bytes:)`, which triggers a
  /// browser download on web.
  Future<void> _exportWeb({ExportResultCallback? onSuccess}) async {
    final notifier = ref.read(exportingStateProvider.notifier);
    notifier.set(true);
    try {
      final bytes = await exportBytes();
      // file_picker's Web implementation starts an anchor download and intentionally returns null. Reaching
      // this point without an exception therefore means "download requested", not "file written to a known
      // path". Never fabricate an export_path for a browser download.
      await ref.read(exportSaveFileProvider)(
        dialogTitle: dialogTitle,
        fileName: defaultFileName,
        bytes: bytes,
        lockParentWindow: false,
      );
      onSuccess?.call(ExportResult.downloadRequested(defaultFileName));
    } catch (e, st) {
      _reportFailure(e, st);
    } finally {
      notifier.set(false);
    }
  }

  void _reportFailure(Object error, StackTrace stackTrace) {
    logger.e("Failed to export records", error, stackTrace);
    Toaster.show(ToastData.error(description: "toast.record_export_failure".tr()));
  }
}

enum CharCodec { shiftJis, utf8Bom, utf16leBom }

class CsvExporter extends Exporter {
  final CharCodec encoding;

  /// Grid snapshotted at export-trigger time. CSV exports the *displayed*
  /// columns and formatted cells (not the raw records), so it needs the grid;
  /// capturing it here keeps the same snapshot guarantee as [Exporter.source],
  /// since the picker/write run after the selection scrim makes the grid live
  /// again (and #3 freezes it only while selecting).
  final Grid grid;

  CsvExporter(
    super.dialogTitle,
    super.defaultFileName,
    super.ref,
    super.recordIds,
    super.source,
    this.encoding,
    this.grid,
  );

  /// Encodes [content] to bytes in [encoding]. Pure and platform-independent
  /// (all three codecs are in-memory `dart:convert`/`charset` converters, so
  /// this runs unchanged on web), letting the CSV byte output be verified on its
  /// own and shared by the desktop and web writers.
  static List<int> encodeCsv(String content, CharCodec encoding) {
    switch (encoding) {
      case CharCodec.shiftJis:
        return const ShiftJISEncoder().convert(content);
      case CharCodec.utf8Bom:
        return [0xEF, 0xBB, 0xBF, ...utf8.encode(content)];
      case CharCodec.utf16leBom:
        return const Utf16Encoder().encodeUtf16Le(content, true);
    }
  }

  List<int> encode(String content) => encodeCsv(content, encoding);

  /// Builds the encoded CSV bytes from the snapshotted grid and [encoding].
  ///
  /// Shared by the desktop file writer ([_export]) and the web in-memory
  /// [exportBytes] path so both emit byte-identical output. Runs synchronously
  /// (no isolate) — the CSV formatting reads the captured grid directly.
  List<int> buildBytes() {
    // Guard the same not-ready/empty case JsonExporter and ZipExporter reject:
    // surface a StateError (routed to export()'s catchError) instead of writing a
    // header-only CSV and firing a misleading success toast. CSV still formats
    // from the snapshotted grid below; this only enforces the shared guard.
    resolveSelectedRecords();
    // Drop the synthetic checkbox column injected while selecting; it carries no
    // title or exportable data and would otherwise emit a leading empty column.
    final columns = grid.columns.where((column) => column.field != checkColumnField).toList();
    final rows = grid.rows.where((row) => recordIds.contains(row.getUserData<CharaDetailRecord>()?.id));
    final table = [
      columns.map((column) => column.title).toList(),
      // A broken placeholder cell carries no Exportable userData; export it as an
      // empty field rather than crashing the whole export on a null unwrap.
      ...rows.map(
        (row) => columns.map((column) => row.cells[column.field]?.getUserData<Exportable>()?.csv ?? "").toList(),
      ),
    ];
    return encode(const CsvEncoder().convert(table));
  }

  @override
  Future<dynamic> _export(FilePath path) async {
    return path.writeAsBytes(buildBytes());
  }

  @override
  Future<Uint8List> exportBytes() async {
    // Web build: no OS path. Produce the same encoded bytes the desktop writer
    // emits and hand them to the browser download via _exportWeb.
    return Uint8List.fromList(buildBytes());
  }
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class JsonExportData with JsonExportDataMappable {
  final List<CharaDetailRecord> charaDetail;
  final LabelMap labels;

  JsonExportData(this.charaDetail, this.labels);
}

class _JsonExporterArgs {
  final FilePath path;
  final JsonExportData data;

  _JsonExporterArgs(this.path, this.data);
}

class JsonExporter extends Exporter {
  JsonExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds, super.source);

  /// Builds the pretty-printed JSON document for [data].
  ///
  /// Shared by the desktop isolate writer ([_run]) and the web in-memory
  /// [exportBytes] path so both emit byte-identical JSON. The caller must ensure
  /// the mappers are initialized (the isolate does so in [_run]; the main
  /// isolate already has them).
  static String buildJson(JsonExportData data) => const JsonEncoder.withIndent('    ').convert(data.toMap());

  static void _run(_JsonExporterArgs args) {
    initializeMappers();
    args.path.writeAsStringSync(buildJson(args.data));
  }

  @override
  Future<dynamic> _export(FilePath path) async {
    // Export only the selected rows, drawn from the snapshotted source so the
    // archive view exports its own records. async so a resolve failure rejects
    // the future (caught by export()'s catchError) rather than throwing
    // synchronously past it.
    final records = resolveSelectedRecords();
    final labelMap = ref.read(labelMapProvider);
    return compute(_run, _JsonExporterArgs(path, JsonExportData(records, labelMap)));
  }

  @override
  Future<Uint8List> exportBytes() async {
    // Web build: no isolate/OS path. Mappers are already initialized on the main
    // isolate, so build the same JSON string the desktop isolate writes and
    // UTF-8-encode it (writeAsStringSync's default encoding) for the download.
    final records = resolveSelectedRecords();
    final labelMap = ref.read(labelMapProvider);
    return Uint8List.fromList(utf8.encode(buildJson(JsonExportData(records, labelMap))));
  }
}

class _ZipExporterArgs {
  final FilePath path;
  final List<DirectoryPath> recordDirs;
  final FilePath labelsFile;

  _ZipExporterArgs(this.path, this.recordDirs, this.labelsFile);
}

class ZipExporter extends Exporter {
  ZipExporter(super.dialogTitle, super.defaultFileName, super.ref, super.recordIds, super.source);

  /// Desktop zip layout: `<uuid>/<file>` per record plus a top-level
  /// `labels.json`, i.e. the basenames `ZipFileEncoder` derives from the paths
  /// it is handed. It differs from the web/Stage-4 layout below, and it is kept
  /// as it is because it is what every already-exported archive on a user's disk
  /// looks like; `RecordZipService.import` accepts both layouts so either
  /// artefact re-imports (see that class's doc).
  /// **Built beside the destination and moved onto it, never into it.**
  ///
  /// `ZipFileEncoder.create` opens its `OutputFileStream` with `FileMode.write`,
  /// so the path it is handed is created or truncated *before* the walk begins
  /// and only gains a central directory when `close` runs. Handed the
  /// destination directly, a record file that a capture rewrites or removes part
  /// way through the walk would leave the user holding an archive no tool can
  /// open — and, because the save dialog runs with overwrite confirmation, that
  /// destination can be a zip they already had, which would already have been
  /// destroyed to produce the rubble. Building into a sibling and renaming means
  /// the destination is written exactly once, when there is a whole archive to
  /// put there.
  ///
  /// The storage view's zip (`zip_export_io.dart`'s `_buildZip`) is the same
  /// arrangement for the same reason. It is not shared code: that file is the io
  /// leg of a conditional import and cannot be reached from here, because this
  /// one also compiles for the web build's [exportBytes]. The web leg needs none
  /// of it — it has every byte in memory before the save seam is called at all,
  /// so a failure there reaches no file.
  static Future<void> _run(_ZipExporterArgs args) async {
    // A sibling, so the rename below stays on one volume and is a move rather
    // than a copy; suffixed with the microsecond clock so a concurrent export, or
    // a file the user happens to keep beside the destination, is not what gets
    // truncated and removed.
    final staging = FilePath('${args.path.path}.${DateTime.now().microsecondsSinceEpoch}.part');
    final encoder = ZipFileEncoder();
    try {
      // Inside the `try`, not before it: `create` opens the staging file with
      // `FileMode.write`, so a failure *in* it can still have brought the file
      // into existence. Left outside, that failure would leave a zero-byte
      // `.part` beside the destination that nothing ever removes. The recovery
      // below is written to tolerate an encoder that never opened.
      encoder.create(staging.path);
      // Bundle each selected record's directory (keyed by its id) plus the shared
      // label map, rather than the whole storage tree. addDirectory/addFile stream
      // the file contents asynchronously, so they (and close(), which flushes the
      // output and writes the central directory) must all be awaited: otherwise
      // endEncode() runs before any file body is written, or the isolate tears
      // down before the final flush, and the archive comes out empty/truncated.
      // The filter keeps this export's own output out of its own entries: the
      // destination can be inside one of the record directories being walked,
      // and the staging file exists before the walk starts. `zipOwnOutputFilter`
      // says why that is a filter rather than a staging file elsewhere.
      final ownOutput = zipOwnOutputFilter(stagingPath: staging.path, destinationPath: args.path.path);
      for (final dir in args.recordDirs) {
        await encoder.addDirectory(dir.toDirectory(), followLinks: false, filter: ownOutput);
      }
      await encoder.addFile(args.labelsFile.toFile());
      await encoder.close();
      // `rename` is the operating system's replace on both Windows and POSIX, so
      // there is no moment where neither file is there. It is inside the same
      // `try` as the build: a move that cannot happen — the destination is a
      // directory, the volume filled up, the path became unwritable while the
      // walk ran — would otherwise leave the staging file as exactly the rubble
      // this arrangement exists to avoid.
      await staging.rename(args.path);
    } catch (_) {
      _discardStaging(encoder, staging);
      rethrow;
    }
  }

  /// Closes [encoder] if it still holds [staging] open and removes that file, so
  /// a failed export leaves nothing behind.
  ///
  /// **What is removed is this exporter's own staging file, by the path it just
  /// created.** The destination is never deleted: a partial archive is ours, the
  /// file the user pointed at is not.
  ///
  /// Both steps are best-effort and neither may mask the original failure: this
  /// runs from a `catch` that is about to rethrow, and an error raised here would
  /// replace the one that says why the export failed. Closing first is not
  /// optional on Windows, where a file that is still open cannot be deleted.
  ///
  /// [encoder] may never have opened at all — `create` is inside the guarded
  /// region, so this is also the recovery for a `create` that threw, and then
  /// `closeSync` reaches a `late` field that was never assigned. That is what the
  /// first `catch` covers; the delete is the part that has to happen either way.
  static void _discardStaging(ZipFileEncoder encoder, FilePath staging) {
    try {
      encoder.closeSync();
    } catch (_) {
      // Already closed, closing is what failed, or the encoder never opened.
      // Either way the delete below is the part that matters.
    }
    try {
      staging.deleteSync(emptyOk: true);
    } catch (_) {
      // A staging file we cannot remove is a stray file next to the destination.
      // It is not the user's data, and it is not worth turning into the error
      // they are shown.
    }
  }

  @override
  Future<dynamic> _export(FilePath path) async {
    // async so a resolve failure rejects the future (caught by export()'s
    // catchError) rather than throwing synchronously past it.
    final info = ref.read(pathInfoProvider);
    final records = resolveSelectedRecords();
    final recordDirs = records.map((record) => recordDirOf(info, source, record)).toList();
    final labelsFile = info.modulesDir.filePath(exportLabelsFileName);
    // No early return for an empty selection. It used to take one — straight to
    // `compute`, past the gate and past the declaration — on the reasoning that
    // an export naming no record needs no record lock. But it still opens
    // `labels.json`, and the branch was therefore the "empty batch escapes the
    // claim" shape the regeneration controller was already found to have: the
    // one export that announces nothing is the one that runs unannounced.
    // `runForRecords` over an empty id list is the shared root acquisition and
    // nothing else, so the common path costs this case an acquisition nobody
    // contends for and gives it the claim over the file it does read.
    //
    // Hold every exported record's mutation lock across the walk, exactly as the
    // web leg does inside [RecordZipService.export] and as the desktop archive
    // does around its own `compute`. Reading a record directory is not exempt
    // from the exclusion its writers obey: an inheritance write-back or a
    // regeneration batch started by a capture running in another tab of the app
    // rewrites `record.json` and the images in place, and `addDirectory` walking
    // them at that moment either packs a torn file or throws on one that moved.
    // Nothing in the UI prevents that overlap -- the export button is disabled
    // only while another export runs, and the capture card's mutual exclusion
    // covers the four capture features, not exporting.
    //
    // The lock is taken here on the main isolate rather than inside `_run`, for
    // the same platform reason `archive_executor_io.dart` states: the desktop
    // lock is per-isolate state, so one taken in the spawned isolate would
    // exclude none of the writers, which all run here.
    //
    // `storageDir` is the root every other caller derives as
    // `<root>/chara_detail/{active,archive}/<id>`'s great-grandparent, so both
    // sources lock against the same recovery root.
    final gate = ref.read(exportRecoveryGateProvider);
    return gate.runForRecords(
      info.storageDir,
      records.map((record) => record.id),
      () => compute(_run, _ZipExporterArgs(path, recordDirs, labelsFile)),
      declaration: exportLongReadDeclaration(
        ref,
        recordExportLongReadPaths(
          pathInfo: info,
          source: source,
          recordIds: records.map((record) => record.id),
          isWeb: false,
        ),
      ),
    );
  }

  @override
  Future<Uint8List> exportBytes() {
    // Web build: read the selected record directories from OPFS via the async FS
    // backend and pack the Stage-4-compatible `chara_detail/active/<uuid>/<file>`
    // layout in memory. This intentionally differs from the desktop zip (which
    // uses per-id basenames plus a top-level labels.json) so the result
    // round-trips with RecordZipService.import and the Stage-4 harness.
    final info = ref.read(pathInfoProvider);
    final records = resolveSelectedRecords();
    final recordDirs = records.map((record) => recordDirOf(info, source, record)).toList();
    // Same gate as the desktop leg above, so the two zip exports are locked by
    // one decision rather than two: [RecordZipService.export] wraps its whole
    // read in it.
    return RecordZipService.export(
      recordDirs,
      recoveryGate: ref.read(exportRecoveryGateProvider),
      declaration: exportLongReadDeclaration(
        ref,
        recordExportLongReadPaths(
          pathInfo: info,
          source: source,
          recordIds: records.map((record) => record.id),
          isWeb: true,
        ),
      ),
    );
  }
}
