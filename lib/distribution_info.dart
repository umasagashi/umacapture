// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:dart_pubspec_licenses/dart_pubspec_licenses.dart';
import 'package:path/path.dart' as path;
import 'package:version/version.dart';
import 'package:yaml/yaml.dart';

Builder distributionInfoBuilder(BuilderOptions options) {
  return DistributionInfoBuilder();
}

class DistributionInfoBuilder implements Builder {
  final JsonEncoder jsonEncoder = JsonEncoder.withIndent(" " * 4);

  FutureOr<String> _buildLicenseInfo(String inputPath) async {
    final lock = path.join(File(inputPath).parent.path, "pubspec.lock");
    final license = jsonEncoder.convert(await generateLicenseInfo(pubspecLockPath: lock));

    final context = license.toLowerCase();
    final rejects = [
      "GENERAL PUBLIC LICENSE",
      "EUROPEAN UNION PUBLIC LICENCE",
      "Mozilla Public License",
    ];
    for (final key in rejects) {
      if (context.contains(key.toLowerCase())) {
        throw Exception("Rejected key found: $key");
      }
    }

    return license;
  }

  String _getLicenseFile(String directory) {
    final licensePattern = RegExp("LICENSE.*", caseSensitive: false);
    return Directory(directory)
        .listSync(recursive: false, followLinks: false)
        .firstWhere((e) => licensePattern.hasMatch(path.basename(e.path)))
        .path;
  }

  FutureOr<String> _buildAdditionalLicenseInfo() async {
    final packages = {
      // TODO: This should be separated by OS.
      "opencv": _getLicenseFile("windows/opencv"),
      "onnxruntime": _getLicenseFile("windows/onnxruntime"),
      "clip": _getLicenseFile("windows/clip"),
      for (final dir in Directory("native/vendor").listSync(recursive: false, followLinks: false))
        path.basename(dir.path): _getLicenseFile(dir.path),
    };

    const outputDir = "assets/license";
    for (final entry in packages.entries) {
      File(entry.value).copy("$outputDir/${entry.key}.txt");
    }

    final info = {
      "google_fonts": "assets/license/google_fonts.txt",
      "ZapSplat": "assets/license/ZapSplat.txt",
      ...packages.map((key, _) => MapEntry(key, "$outputDir/$key.txt")),
    };
    return jsonEncoder.convert(info);
  }

  FutureOr<String> _buildVersionInfo(String inputPath) async {
    final pubspec = loadYaml(File(inputPath).readAsStringSync());
    final String version = pubspec['version'];

    final parsed = Version.parse(version).toString();
    if (version != parsed) {
      throw FormatException("Illegal version string. pubspec=$version, parsed=$parsed");
    }

    final info = {
      "version": version,
    };
    return jsonEncoder.convert(info);
  }

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    if (buildStep.inputId.pathSegments.last != "pubspec.yaml") {
      throw ArgumentError.value(buildStep.inputId.toString());
    }
    for (final output in buildStep.allowedOutputs) {
      if (output.pathSegments.last == "version_info.json") {
        buildStep.writeAsString(output, _buildVersionInfo(buildStep.inputId.path));
      } else if (output.pathSegments.last == "license_info.json") {
        buildStep.writeAsString(output, _buildLicenseInfo(buildStep.inputId.path));
      } else if (output.pathSegments.last == "additional_license_info.json") {
        buildStep.writeAsString(output, _buildAdditionalLicenseInfo());
      } else {
        throw ArgumentError.value(output.toString());
      }
    }
  }

  @override
  Map<String, List<String>> get buildExtensions {
    return {
      "pubspec.yaml": [
        "assets/version_info.json",
        "assets/license_info.json",
        "assets/additional_license_info.json",
      ],
    };
  }
}
