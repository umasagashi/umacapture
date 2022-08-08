// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:version/version.dart';
import 'package:yaml/yaml.dart';

Builder distributionInfoBuilder(BuilderOptions options) {
  return DistributionInfoBuilder();
}

class DistributionInfoBuilder implements Builder {
  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final pubspec = loadYaml(File(buildStep.inputId.path).readAsStringSync());
    final String version = pubspec['version'];

    final parsed = Version.parse(version).toString();
    if (version != parsed) {
      throw FormatException("Illegal version string. pubspec=$version, parsed=$parsed");
    }

    final info = {
      "version": version,
    };
    buildStep.writeAsString(buildStep.allowedOutputs.first, jsonEncode(info));
  }

  @override
  Map<String, List<String>> get buildExtensions {
    return {
      "pubspec.yaml": ["assets/version_info.json"],
    };
  }
}
