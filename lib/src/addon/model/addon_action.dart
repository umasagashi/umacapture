import 'package:dart_mappable/dart_mappable.dart';
import 'package:path/path.dart' as p;

part 'addon_action.mapper.dart';

/// The work an addon task performs when its trigger fires.
///
/// Polymorphic root, mirroring the `ColumnSpec` pattern: the discriminator is
/// serialized under the `kind` key. All concrete actions are co-located in this
/// library so `AddonActionMapper.ensureInitialized()` cascades to every subclass
/// (cross-file subclasses are NOT auto-discovered — see `mapper_init.dart`).
@MappableClass(discriminatorKey: 'kind')
abstract class AddonAction with AddonActionMappable {
  const AddonAction();

  /// A short, human-readable summary shown on the task card. Not localized; the
  /// UI pairs this with a localized action-kind label.
  String describe();
}

/// Launches an external executable, passing event data through templated
/// command-line arguments (e.g. `{record_id}` expands to the captured record id).
@MappableClass(discriminatorValue: 'ExternalProgramAction')
class ExternalProgramAction extends AddonAction with ExternalProgramActionMappable {
  /// Default timeout (seconds) used when none is configured. The editor requires
  /// a positive timeout for external programs (a process can hang indefinitely
  /// and hold an execution slot), so this only backs legacy tasks saved before
  /// that rule and seeds the editor field for a fresh action.
  static const int defaultTimeoutSeconds = 30;

  /// Absolute path to the program to launch.
  final String programPath;

  /// Argument template. Placeholders like `{record_id}` are substituted from the
  /// event payload after the template is split into individual arguments, so a
  /// value containing spaces stays a single argument.
  final String argumentTemplate;

  /// Hard timeout in seconds, or null for no timeout.
  final int? timeoutSeconds;

  /// Whether to run through the system shell. Required for `.bat` files and shell
  /// builtins (e.g. `echo`).
  ///
  /// WARNING: with the shell enabled, substituted placeholder values are handed to
  /// the shell **unescaped**, so a value containing metacharacters (`&`, `|`, `%VAR%`,
  /// …) is interpreted by the shell. Only enable it for trusted templates. See
  /// `expandArgumentTemplate` in `external_program_runner.dart` for details.
  final bool runInShell;

  /// Working (current) directory for the launched process, or null/empty to
  /// inherit the app's directory.
  final String? workingDirectory;

  const ExternalProgramAction({
    required this.programPath,
    this.argumentTemplate = '',
    this.timeoutSeconds,
    this.runInShell = false,
    this.workingDirectory,
  });

  @override
  String describe() {
    final name = programPath.isEmpty ? '' : p.basename(programPath);
    return argumentTemplate.isEmpty ? name : '$name $argumentTemplate';
  }
}

/// Sends an HTTP request to a webhook URL, substituting event data into the URL
/// and body templates. Lets users wire Discord/Slack-style notifications without
/// writing an external program.
@MappableClass(discriminatorValue: 'WebhookAction')
class WebhookAction extends AddonAction with WebhookActionMappable {
  /// Default timeout (seconds) used when none is configured. The editor requires
  /// a positive timeout, and this backs legacy tasks and seeds the editor field.
  /// Without a bound, a blackholed host would hold an execution slot until the OS
  /// gives up.
  static const int defaultTimeoutSeconds = 30;

  /// Target URL. Placeholders like `{record_id}` are substituted from the payload.
  final String url;

  /// HTTP method, e.g. `POST` or `GET`.
  final String method;

  /// Request body template. Placeholders are substituted from the payload. Ignored
  /// for methods without a body (e.g. `GET`).
  final String bodyTemplate;

  /// How to send the body: `json` (application/json), `form`
  /// (application/x-www-form-urlencoded), or `text` (text/plain).
  final String contentType;

  /// Hard timeout in seconds, or null to apply [defaultTimeoutSeconds].
  final int? timeoutSeconds;

  const WebhookAction({
    required this.url,
    this.method = 'POST',
    this.bodyTemplate = '',
    this.contentType = 'json',
    this.timeoutSeconds,
  });

  @override
  String describe() {
    final host = Uri.tryParse(url)?.host ?? url;
    return host.isEmpty ? method : '$method $host';
  }
}

/// Runs a named built-in action from the in-app registry (see `builtin_actions.dart`).
@MappableClass(discriminatorValue: 'BuiltinAction')
class BuiltinAction extends AddonAction with BuiltinActionMappable {
  /// Registry key identifying which built-in action to run.
  final String actionKey;

  /// Optional free-form argument for actions that take one (e.g. the clipboard
  /// action's content template). Placeholders like `{record_id}` are substituted
  /// from the event payload. Null for actions that take no argument.
  final String? argument;

  const BuiltinAction({required this.actionKey, this.argument});

  @override
  String describe() => argument == null || argument!.isEmpty ? actionKey : '$actionKey: $argument';
}
