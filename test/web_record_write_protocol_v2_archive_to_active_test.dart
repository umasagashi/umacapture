// Protocol 2 of the write journal: the double interruptions of the `archiveToActive` layout,
// on both backends. What every case asserts is described in
// `support/web_record_write_protocol_v2.dart`.
import 'support/web_record_write_protocol_v2.dart';

void main() => protocolV2Suites((suite) => suite.doubleInterruptions(PublicationLayout.archiveToActive));
