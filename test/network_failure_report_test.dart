// WHAT A FAILED NETWORK REQUEST TELLS THE DEVELOPER -- and the keys that used to tell them nothing.
// Run: .fvm/flutter_sdk/bin/flutter test test/network_failure_report_test.dart
//
// `_networkExceptionContext` published nine keys that can be null (`url`, `host`, `scheme`,
// `dio_type`, `http_status`, `inner_error_type`, `inner_error`, `os_version`, `locale`). A
// null-valued context key does not survive the trip: Sentry's normalisation drops it, measured on a
// stored event where every null-valued key of a report built the same way was absent while an empty
// string arrived intact. So the reader of an update-check failure received a context that was
// silently shorter than the code says it is, and could not tell "this was not an HTTP response"
// from "this side never read the status".
//
// The repair is `statedReportContext` -- the same sweep the video-import report uses -- and the
// point of this file is that it is checked by WALKING the published context rather than by listing
// the keys. A list in a test omits the next key as quietly as a list in the code does; the shapes
// below are walked to their leaves, so a leg added later that publishes a null is red without
// anybody remembering to add it here.
//
// The tags are the opposite case and are pinned as such: a `not stated` tag would be a filter over
// a state a request can never be in, so a tag is omitted where the context states.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

/// The keys of the `network_failure` context that describe something this side may have been
/// unable to measure. Used only to name them in a failure message -- what makes the guard hold is
/// the walk below, not this list.
const _unstatableKeys = [
  'url',
  'host',
  'scheme',
  'dio_type',
  'http_status',
  'inner_error_type',
  'inner_error',
  'os_version',
  'locale',
];

/// Every path in [context] whose value is null, at any depth.
///
/// The guard is a walk and not a per-key assertion for the same reason the fix is a sweep: the
/// defect is a value going missing in silence, and both a table in the code and a table in the test
/// fail by not mentioning the newest key.
List<String> nullPathsIn(Object? node, [String path = '']) {
  if (node == null) {
    return [path];
  }
  if (node is Map) {
    return [
      for (final entry in node.entries)
        ...nullPathsIn(entry.value, path.isEmpty ? '${entry.key}' : '$path.${entry.key}'),
    ];
  }
  if (node is List) {
    return [for (var i = 0; i < node.length; i++) ...nullPathsIn(node[i], '$path[$i]')];
  }
  return const [];
}

/// Every leaf path in [context], null or not. Its count is the anti-vacuity floor: a walk over an
/// empty map finds no nulls too.
List<String> leafPathsIn(Object? node, [String path = '']) {
  if (node is Map) {
    return [
      for (final entry in node.entries)
        ...leafPathsIn(entry.value, path.isEmpty ? '${entry.key}' : '$path.${entry.key}'),
    ];
  }
  if (node is List) {
    return [for (var i = 0; i < node.length; i++) ...leafPathsIn(node[i], '$path[$i]')];
  }
  return [path];
}

/// One published context, with a name so a failure says which shape produced it.
typedef _Shape = ({String name, Map<String, dynamic> context});

/// A response that came back, so `http_status` is a number rather than an absence.
DioException _refusedByServer() {
  final options = RequestOptions(path: 'https://example.invalid/modules.zip');
  return DioException(
    requestOptions: options,
    response: Response<void>(requestOptions: options, statusCode: 503),
    type: DioExceptionType.badResponse,
  );
}

/// A TLS failure: no response, but an inner error and a host.
DioException _handshakeFailure() {
  final options = RequestOptions(path: 'https://example.invalid/version_info.json');
  return DioException(requestOptions: options, error: const _FakeHandshake(), type: DioExceptionType.connectionError);
}

class _FakeHandshake {
  const _FakeHandshake();

  @override
  String toString() => 'HandshakeException: certificate verify failed';
}

/// Every shape the two producers and the two platforms can build.
List<_Shape> _everyShapeOfFailure() {
  final shapes = <_Shape>[];
  for (final isWeb in [false, true]) {
    final suffix = isWeb ? 'web' : 'io';
    shapes.add((
      name: 'refused-by-server/$suffix',
      context: networkFailureContext(operation: 'download_modules', exception: _refusedByServer(), isWeb: isWeb),
    ));
    shapes.add((
      name: 'handshake/$suffix',
      context: networkFailureContext(
        operation: 'check_latest_module_version',
        exception: _handshakeFailure(),
        isWeb: isWeb,
      ),
    ));
    shapes.add((
      name: 'not-a-dio-failure-with-url/$suffix',
      context: networkFailureContext(
        operation: 'bootstrap_web_module',
        exception: StateError('offline'),
        url: 'https://example.invalid/modules.zip',
        isWeb: isWeb,
      ),
    ));
    shapes.add((
      name: 'nothing-known/$suffix',
      context: networkFailureContext(
        operation: 'check_latest_app_version',
        exception: StateError('offline'),
        isWeb: isWeb,
      ),
    ));
  }
  return shapes;
}

void main() {
  group('what a network-failure report carries', () {
    test('nothing anywhere in the context is null, whichever failure built it', () {
      for (final shape in _everyShapeOfFailure()) {
        expect(
          nullPathsIn(shape.context),
          isEmpty,
          reason:
              '${shape.name}: a null-valued context key is dropped by Sentry, so these keys reach the reader as '
              'nothing at all. Publish $reportValueNotStated instead -- '
              'lib/src/core/version_check.dart, networkFailureContext.',
        );
        expect(
          leafPathsIn(shape.context),
          hasLength(greaterThanOrEqualTo(12)),
          reason: '${shape.name}: the walk must have something to walk, or finding no nulls proves nothing',
        );
      }
    });

    test('the walker would find a null if the context published one', () {
      // The guard above is a search. A search that cannot find anything passes on every input, so
      // this is its control.
      expect(
        nullPathsIn(<String, dynamic>{
          'frame': <String, dynamic>{'width': null},
        }),
        ['frame.width'],
      );
      expect(
        nullPathsIn(<String, dynamic>{
          'items': [1, null],
        }),
        ['items[1]'],
      );
      expect(
        leafPathsIn(<String, dynamic>{
          'a': 1,
          'b': <String, dynamic>{'c': 2},
        }),
        ['a', 'b.c'],
      );
    });

    test('a failure that could measure none of the nine says so, rather than dropping the keys', () {
      // Nothing to go on: not a Dio failure, no url, and the platform that cannot answer the last
      // two. This is the shape whose context arrived at Sentry six keys short.
      final context = networkFailureContext(
        operation: 'bootstrap_web_module',
        exception: StateError('offline'),
        isWeb: true,
      );

      for (final key in _unstatableKeys) {
        expect(context.containsKey(key), isTrue, reason: '$key: still published; the key is not the thing that moved');
        expect(context[key], reportValueNotStated, reason: '$key: unstated, and the reader has to be able to see that');
      }
      expect(context['operation'], 'bootstrap_web_module', reason: 'the one thing the caller always knows');
      expect(context['is_handshake_error'], isFalse);
      expect(context['os'], 'web');
    });

    test('a value the platform did state arrives as itself, not as the stand-in', () {
      final context = networkFailureContext(operation: 'download_modules', exception: _refusedByServer(), isWeb: false);

      expect(context['url'], 'https://example.invalid/modules.zip');
      expect(context['host'], 'example.invalid');
      expect(context['scheme'], 'https');
      expect(context['http_status'], 503);
      expect(context['dio_type'], isNot(reportValueNotStated));
      expect(context['os'], isNot(reportValueNotStated));
      expect(context['os_version'], isNot(reportValueNotStated));
      expect(context['locale'], isNot(reportValueNotStated));
    });

    test('the two keys web cannot answer are really unanswerable there, and answerable here', () {
      // Otherwise `isWeb: true` above would be a parameter that changes nothing, and every case
      // that leans on it would be measuring the desktop shape twice.
      expect(platformDescription(isWeb: true)['os_version'], isNull);
      expect(platformDescription(isWeb: true)['locale'], isNull);
      expect(platformDescription(isWeb: true)['os'], 'web');
      expect(platformDescription(isWeb: false)['os_version'], isNotNull);
      expect(platformDescription(isWeb: false)['locale'], isNotNull);
    });
  });

  group('the tags of a network failure', () {
    test('a value the context states as unstated is left off the tags entirely', () {
      // A tag is a filter over an issue list. An absent tag narrows nothing; a `not stated` bucket
      // invites filtering on a state a request can never be in.
      final context = networkFailureContext(
        operation: 'bootstrap_web_module',
        exception: StateError('offline'),
        isWeb: true,
      );
      final tags = networkFailureTags(context);

      expect(tags, {'network.operation': 'bootstrap_web_module'});
      expect(tags.values, isNot(contains(reportValueNotStated)), reason: 'the stand-in is a context value, not a tag');
    });

    test('a host the request did have is still tagged', () {
      final context = networkFailureContext(operation: 'download_modules', exception: _refusedByServer(), isWeb: false);

      expect(networkFailureTags(context)['network.host'], 'example.invalid');
    });

    test('the probe outcome is tagged when there is one and omitted when it is unstated', () {
      final context = networkFailureContext(operation: 'download_modules', exception: _refusedByServer(), isWeb: false);

      expect(
        networkFailureTags(context, probe: {'probe_outcome': 'probe_failure'})['network.tls_probe'],
        'probe_failure',
      );
      expect(networkFailureTags(context, probe: null).containsKey('network.tls_probe'), isFalse);
      expect(
        networkFailureTags(context, probe: {'probe_outcome': reportValueNotStated}).containsKey('network.tls_probe'),
        isFalse,
        reason: 'a swept probe block states its silence; the tag must not bucket it',
      );
    });
  });
}
