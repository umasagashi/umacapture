import 'login_receiver.dart';

/// Always null: a web login is claimed with its cookie, so nothing listens.
///
/// A page cannot accept a connection, and it does not need to: the login page sets its proof as a
/// cookie of this origin, and the claim the page sends carries it.
Future<LoginListener?> bindLoginListener({required String h}) async => null;
