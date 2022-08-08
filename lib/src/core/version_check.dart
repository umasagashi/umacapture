import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/core/utils.dart';

class VersionCheckResult {
  final Version? local;
  final Version? latest;

  VersionCheckResult({this.local, this.latest});

  bool get isValid => local != null && latest != null;

  bool get isLatest => isValid && local! == latest!;

  bool get isUpdatable => isValid && local! != latest!;
}

class VersionChecker extends StateNotifier<VersionCheckResult?> {
  VersionChecker() : super(null);
}

final appVersionCheckController = StateNotifierProvider<VersionChecker, VersionCheckResult?>((ref) {
  return VersionChecker();
});

final appVersionCheckLoader = FutureProvider<VersionCheckResult>((ref) async {
  final currentVersion = await rootBundle
      .loadString("assets/version_info.json")
      .then((info) => Version.parse(jsonDecode(info)['version']));

  late final Version? latestVersion;
  try {
    latestVersion = await Dio()
        .get(Const.appVersionInfoUrl)
        .then((response) => Version.parse(jsonDecode(response.toString())['version']));
  } catch (e) {
    logger.w(e);
    latestVersion = null;
  }

  return VersionCheckResult(local: currentVersion, latest: latestVersion);
});
