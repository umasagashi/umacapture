/// Which of the user's own recordings this app will offer to open, stated **once**.
///
/// Both front ends and both features open a "choose a clip" dialog: video import and the
/// video-import error report, on Windows through `package:file_picker` and in a browser through
/// `<input type="file">`. Each of those dialogs needs the same fact in a different spelling — a list
/// of bare extensions for the Win32 filter, a comma-separated `accept` attribute for the browser —
/// and the fact itself must not differ between them. A clip the import accepted has to be a clip the
/// report can re-open, or the report is offered for files it cannot document; and a container added
/// for one front end but not the other is a difference the user experiences as the app losing a file
/// it opened yesterday.
///
/// So this file holds the list, and every spelling of it is **derived here** rather than written out
/// again at the call site. That is the point: a hand-written second spelling is the kind of table
/// that is correct until the next container is added, and the omission is silent — nothing fails to
/// compile and no test that does not already know the answer can notice.
library;

/// The containers offered in the dialog, as bare extensions without the leading dot.
///
/// `.mkv` is OBS's default container and what this project's own clips are, so a filter that omitted
/// it would hide exactly the files these features exist for. `.mp4` is what phone and console capture
/// produces, `.webm` what a browser recording produces, and `.mov` / `.m4v` what Apple hardware does.
///
/// Order is meaningful only in that both front ends show it: it is the order the Windows filter lists
/// and the order the browser's `accept` carries, because they are the same list.
const List<String> videoFileExtensions = ['mp4', 'mkv', 'webm', 'mov', 'm4v'];

/// The `accept` attribute for a browser `<input type="file">`, built from [videoFileExtensions].
///
/// **`video/*` first, then every extension, and the extensions are not optional.** A `.mkv` carries
/// no registered MIME type on every platform, so a `video/*`-only filter can hide it in the dialog —
/// the one container this project's own clips use. Listing both means a file the OS does recognise
/// is matched by type and one it does not is still matched by name.
///
/// Derived with a map over the list rather than spelled out, so adding a container to
/// [videoFileExtensions] reaches the browser dialog with nothing to remember. This is a `final` and
/// not a `const` because Dart has no const `join`; it is computed once, lazily, on first use.
final String videoFileAcceptAttribute = ['video/*', ...videoFileExtensions.map((e) => '.$e')].join(',');
