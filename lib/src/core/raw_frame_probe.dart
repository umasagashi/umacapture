import 'dart:typed_data';

/// A downloadable bundle produced by the raw-frame probe: one unshaped screen-share
/// still plus the metadata needed to interpret its geometry.
///
/// The bytes are handed to the browser's download path as-is ([fileName] is only a
/// suggestion the user can change in the save dialog).
class RawFrameBundle {
  /// Suggested download name, carrying the capture timestamp so a set of bundles
  /// collected in one sitting stays ordered and traceable.
  final String fileName;

  /// The bundle itself (a zip holding `frame.png` and `meta.json`).
  final Uint8List bytes;

  const RawFrameBundle({required this.fileName, required this.bytes});
}

bool _rawFrameProbeEnabled = false;

/// Whether the diagnostic raw-frame probe is exposed in the settings page.
///
/// Off unless the app was launched with `?rawframe=1`, so ordinary users never see the
/// entry. A URL switch rather than a `kDebugMode` gate because the material has to be
/// collected from the release web build users actually run.
bool get rawFrameProbeEnabled => _rawFrameProbeEnabled;

/// Reads the `?rawframe=1` switch out of the launch URL exactly once.
///
/// Must run from `main()` before the app starts routing: auto_route rewrites the browser
/// location as the user navigates, so a lazily evaluated read of `Uri.base` could observe
/// a URL that has already lost the query the app was launched with. On non-web platforms
/// `Uri.base` is the working directory and carries no query, so this leaves the probe off.
void initRawFrameProbeFlag() {
  _rawFrameProbeEnabled = Uri.base.queryParameters['rawframe'] == '1';
}
