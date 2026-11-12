import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/login_receiver.dart';
import 'package:umacapture/src/core/login_receiver_io.dart' as io;

const _h = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherH = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _proof = 'proof-SECRET-1234567890';

Future<(int, String)> _get(int port, String pathAndQuery) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$pathAndQuery'));
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}

Future<void> _expectRefused(int port) async {
  await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
}

void main() {
  late List<String> logged;
  late BreadcrumbSink realSink;
  setUp(() {
    logged = [];
    realSink = debugBreadcrumbSink;
    debugBreadcrumbSink = (Level level, String message, dynamic error) => logged.add('$message $error');
  });
  tearDown(() => debugBreadcrumbSink = realSink);

  test('binds a loopback port the start page accepts, before any request', () async {
    final listener = (await io.bindLoginListener(h: _h))!;
    addTearDown(listener.close);
    expect(listener.port, inInclusiveRange(1024, 65535));
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
    expect(socket.remoteAddress.isLoopback, isTrue);
    socket.destroy();
    // Not reachable through this machine's own non-loopback addresses.
    final outward = [
      for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) ...interface.addresses,
    ].where((address) => !address.isLoopback);
    for (final address in outward) {
      await expectLater(Socket.connect(address, listener.port), throwsA(isA<SocketException>()));
    }
  });

  test('ignores another login, completes on its own and releases the port after answering', () async {
    final listener = (await io.bindLoginListener(h: _h))!;
    addTearDown(listener.close);
    var done = false;
    unawaited(listener.code.then((_) => done = true));

    expect((await _get(listener.port, '/cb?h=$_otherH&code=$_proof')).$1, 404);
    expect((await _get(listener.port, '/other?h=$_h&code=$_proof')).$1, 404);
    expect(done, isFalse);

    final (status, body) = await _get(listener.port, '/cb?h=$_h&code=$_proof');
    expect(status, 200);
    expect(body, isNot(contains(_proof)));
    expect(await listener.code, _proof);
    await _expectRefused(listener.port);
    expect(logged.join('\n'), isNot(contains(_proof)));
  });

  test('close() cancels the wait and releases the port', () async {
    final listener = (await io.bindLoginListener(h: _h))!;
    final port = listener.port;
    final code = expectLater(
      listener.code,
      throwsA(isA<LoginListenClosed>().having((e) => e.timedOut, 'timedOut', false)),
    );
    await listener.close();
    await code;
    await _expectRefused(port);
  });

  test('closes by itself after loginListenSeconds', () async {
    Duration? asked;
    void Function()? fire;
    final listener = (await io.bindLoginListener(
      h: _h,
      startTimer: (duration, callback) {
        asked = duration;
        fire = callback;
        return Timer(const Duration(days: 1), () {});
      },
    ))!;
    final port = listener.port;
    expect(asked, const Duration(seconds: 600));
    final code = expectLater(
      listener.code,
      throwsA(isA<LoginListenClosed>().having((e) => e.timedOut, 'timedOut', true)),
    );
    fire!();
    await code;
    await _expectRefused(port);
  });
}
