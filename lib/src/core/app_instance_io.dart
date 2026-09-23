import 'app_instance.dart';

/// Always granted: a second native process never reaches Dart.
///
/// The runner's named mutex (`windows/runner/main.cpp`) already refused it,
/// brought the running window to the front and exited. Web diverges from this
/// because a page can do neither: it cannot focus another tab it did not open,
/// and it cannot close itself (`window.close()` is ignored for a tab the user
/// opened), so a second web tab has to stay open and show that it is waiting.
Future<AppInstanceClaim> claimAppInstance() async => (waitingFor: null);
