// Shared Riverpod test helpers.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umacapture/src/core/utils.dart';

/// Exposes a [RefBase] from a container so functions and runners that take a
/// [RefBase] (rather than a [ProviderContainer]) can be exercised in tests:
/// `container.read(refBaseProvider)`.
final refBaseProvider = Provider<RefBase>((ref) => ref.base);
