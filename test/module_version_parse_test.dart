// A module whose version dates cannot be read must not answer a ModuleVersion.
//
// `recognizer_version` and `minimum_version` are the two reference points every
// stored record is compared against: the first decides which records are
// "obsoleted" and re-recognised without asking, the second is the only thing
// that keeps a record too old for the current models out of that batch. When an
// unreadable field parsed to a stand-in date far in the past, both comparisons
// answered as though the requirement were met -- every record obsolete, every
// record supported -- so a mistyped date in a published version_info.json would
// have overwritten a whole library with degraded recognition, silently.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';

const _goodRecognizer = "2026-08-14T11:00:00+0900";
const _goodMinimum = "2025-08-24T11:00:00+0900";

ModuleVersionRawData _raw({String recognizer = _goodRecognizer, String minimum = _goodMinimum}) {
  return ModuleVersionRawData("1.0.0", "JPN", recognizer, minimum, "0.0.0", false);
}

void main() {
  group("ModuleVersionRawData.toModuleVersion", () {
    test("answers the parsed dates when both fields are readable", () {
      final version = _raw().toModuleVersion();
      expect(version, isNotNull);
      expect(version?.recognizerVersion, DateTime.parse(_goodRecognizer));
      expect(version?.minimumVersion, DateTime.parse(_goodMinimum));
    });

    test("answers null when recognizer_version cannot be read", () {
      expect(_raw(recognizer: "2026-08-14 11:00 JST").toModuleVersion(), isNull);
    });

    test("answers null when minimum_version cannot be read", () {
      expect(_raw(minimum: "").toModuleVersion(), isNull);
    });

    test("answers null when neither field can be read", () {
      expect(_raw(recognizer: "latest", minimum: "n/a").toModuleVersion(), isNull);
    });

    // Null is the value the surrounding code already means by "no module version
    // available": the providers that carry this are typed ModuleVersion?, the
    // re-recognition check returns early on null, and the data table raises the
    // noVersionAvailable toast. Nothing new has to interpret it.
    test("null is the same outcome as a module that is not installed at all", () {
      final unreadable = _raw(recognizer: "not a date").toModuleVersion();
      expect(unreadable, isNull);
    });
  });

  // Contrast, kept to record what the pre-fix shape could and could not say.
  // The sentinel conversion still answers a value for the same input, and that
  // value is older than every real module date -- so a test written against it
  // stays green no matter how broken the field is, which is precisely why the
  // defect was invisible.
  group("contrast: the sentinel conversion", () {
    test("answers a date for an input that is not one", () {
      expect("not a date".toDateTime(), DateTime(1999, 12, 31));
      expect("".toDateTime(), DateTime(1999, 12, 31));
    });

    test("answers a date older than any real module version, so every gate reads as met", () {
      expect("not a date".toDateTime().isBefore(DateTime.parse(_goodMinimum)), isTrue);
    });
  });
}
