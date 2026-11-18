import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/source_providers.dart';
import '../../../core/source/source_registry.dart';
import '../../../core/storage/preferences.dart';
import 'source_diagnostics_service.dart';
import 'source_diagnostics_store.dart';

final sourceDiagnosticsStoreProvider = Provider<SourceDiagnosticsStore>(
  (ref) => SourceDiagnosticsStore(ref.watch(preferencesProvider)),
);

/// Current registry metadata for the picker. The service still loads a fresh
/// snapshot immediately before each request; this provider is display-only.
final sourceDiagnosticsSnapshotProvider =
    FutureProvider<SourceRegistrySnapshot>((ref) {
      return ref.watch(sourcesProvider.future);
    });

/// Production wiring: real registry snapshots and the real search provider.
/// No login, write, batch or invalid-rule execution is performed here.
final sourceDiagnosticsServiceProvider = Provider<SourceDiagnosticsService>(
  (ref) {
    final store = ref.watch(sourceDiagnosticsStoreProvider);
    final service = SourceDiagnosticsService(
      snapshot: () => ref.read(sourceRegistryProvider).load(),
      search: (source, keyword) => source.search(keyword),
      store: store,
    );
    ref.onDispose(service.dispose);
    return service;
  },
);