// What the TLS diagnostics publish about a certificate.
// Run: .fvm/flutter_sdk/bin/flutter test test/sentry_certificate_context_test.dart
//
// The context is built on the one path that fires when a middlebox re-issues our certificate, i.e.
// under a corporate/school TLS-intercepting proxy or a security suite's HTTPS scanning. The
// interceptor's private CA names the organisation in its `CN`/`O`, so publishing the DNs would ship
// the user's employer and their security product to the developer's Sentry — from a user who
// enabled error reporting and has no way to see this leaving. `scrubUserPathsFromEvent` does not
// help: it states that it removes filesystem paths only.
//
// Deliberately checked as "no name survives, whatever the key is called" rather than "the two keys
// named subject and issuer are absent": a later key that pastes a DN somewhere else is the same
// defect, and an absence test would not see it.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/sentry_util.dart';

/// The distinguishing words of an intercepting CA, each of which is the whole harm on its own.
const _organisation = 'Contoso Manufacturing K.K.';
const _department = 'Information Security Division';
const _product = 'ESET SSL Filter CA';

const _interceptedSubject = '/C=JP/O=$_organisation/OU=$_department/CN=data.umacapture.com';
const _interceptorIssuer = '/C=JP/O=$_organisation/OU=$_department/CN=$_product';

/// A certificate with no bytes: every member the context reads is a name or a date, and `der`/`pem`/
/// `sha1` are never touched by it — which is itself part of what this pins.
class _FakeCertificate implements X509Certificate {
  @override
  final String subject;

  @override
  final String issuer;

  @override
  final DateTime startValidity;

  @override
  final DateTime endValidity;

  _FakeCertificate({required this.subject, required this.issuer, DateTime? startValidity, DateTime? endValidity})
    : startValidity = startValidity ?? DateTime.utc(2026, 1, 1),
      endValidity = endValidity ?? DateTime.utc(2027, 1, 1);

  @override
  Uint8List get der => throw UnimplementedError('the context must not read the certificate bytes');

  @override
  String get pem => throw UnimplementedError('the context must not read the certificate bytes');

  @override
  Uint8List get sha1 => throw UnimplementedError('the context must not read the certificate bytes');
}

/// Every string the context carries, at any depth, keys included.
List<String> _stringsIn(dynamic value) => switch (value) {
  final String text => [text],
  final Map<dynamic, dynamic> map => [...map.keys.expand(_stringsIn), ...map.values.expand(_stringsIn)],
  final Iterable<dynamic> list => list.expand(_stringsIn).toList(),
  _ => [value.toString()],
};

void main() {
  test('an intercepted certificate publishes no name from either DN', () {
    final certificate = _FakeCertificate(subject: _interceptedSubject, issuer: _interceptorIssuer);

    final context = debugCertificateContext(certificate, 'data.umacapture.com', 443);

    final published = _stringsIn(context).join(' ');
    for (final identifying in const [_organisation, _department, _product, 'O=', 'OU=', 'CN=']) {
      expect(
        published,
        isNot(contains(identifying)),
        reason: 'a distinguished name reached the context as "$identifying"',
      );
    }
  });

  test('the host we asked for is still reported, because it is ours and not the user\'s', () {
    // The counterweight to the case above: de-identifying must not empty the context out. The host
    // and port are the endpoint the app itself chose, and the validity window is a property of a
    // certificate served to everyone, so all three stay.
    final certificate = _FakeCertificate(
      subject: _interceptedSubject,
      issuer: _interceptorIssuer,
      startValidity: DateTime.utc(2026, 3, 4, 5, 6, 7),
      endValidity: DateTime.utc(2026, 6, 2, 1, 2, 3),
    );

    final context = debugCertificateContext(certificate, 'data.umacapture.com', 8443);

    expect(context['host'], 'data.umacapture.com');
    expect(context['port'], 8443);
    expect(context['start_validity'], '2026-03-04T05:06:07.000Z');
    expect(context['end_validity'], '2026-06-02T01:02:03.000Z');
  });

  test('self_issued is a boolean derived from the two names, and is what replaces them', () {
    final reissued = _FakeCertificate(subject: _interceptedSubject, issuer: _interceptorIssuer);
    final selfSigned = _FakeCertificate(subject: _interceptorIssuer, issuer: _interceptorIssuer);

    expect(debugCertificateContext(reissued, 'data.umacapture.com', 443)[selfIssuedKey], isFalse);
    expect(debugCertificateContext(selfSigned, 'data.umacapture.com', 443)[selfIssuedKey], isTrue);
  });
}
