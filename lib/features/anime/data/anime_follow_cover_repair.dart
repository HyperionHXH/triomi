import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/http_client.dart';
import '../../detail/anime_info_repository.dart';
import '../../library/data/library_providers.dart';
import '../../library/data/library_repository.dart';

/// One bounded repair pass per page attachment or explicit missing-cover retry.
/// Playback-site identities must never be guessed from a title or remote ID.
final animeFollowCoverRepairProvider = Provider.autoDispose<void>((ref) {
  final attempted = <(String, String)>{};
  final owner = SourceRequestCancellation();
  var disposed = false, running = false;
  ref.onDispose(() {
    disposed = true;
    owner.cancel();
  });
  final pending = <String>[];
  Future<void> drain() async {
    if (running) return;
    running = true;
    try {
      while (!disposed && pending.isNotEmpty) {
        final ids = pending.take(3).toList(growable: false);
        pending.removeRange(0, ids.length);
        await Future.wait([
          for (final id in ids)
            () async {
              try {
                await owner.run(
                  () =>
                      ref.read(animeInfoRepositoryProvider).section(id, 'info'),
                );
              } catch (_) {
                // Keep the persisted shelf on metadata failure. The shelf's
                // explicit retry starts a new bounded pass.
              }
            }(),
        ]);
      }
    } finally {
      running = false;
    }
  }

  ref.listen(animeFollowsProvider, (_, next) {
    for (final row in next.asData?.value ?? const <LibraryItemView>[]) {
      final item = row.item;
      if (item.sourceId != 'bangumi-anime' ||
          (int.tryParse(item.remoteId) ?? 0) <= 0 ||
          (item.coverUrl?.trim().isNotEmpty ?? false)) {
        continue;
      }
      if (attempted.add((item.sourceId, item.remoteId))) {
        pending.add(item.remoteId);
      }
    }
    unawaited(drain());
  }, fireImmediately: true);
});
