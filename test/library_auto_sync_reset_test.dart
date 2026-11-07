import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/library/data/library_auto_sync.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/profile/data/sync_providers.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _chapter = Chapter(
  sourceId: 'manga-a',
  remoteId: 'chapter',
  title: 'Unopened',
);
const _item = MediaItem(
  sourceId: 'manga-a',
  remoteId: 'work',
  type: MediaType.manga,
  title: 'Reset-only work',
);
const _config = WebDavConfig(
  baseUrl: 'https://dav.fixture.test',
  username: 'fixture',
  password: 'fixture-only',
);

// Drift and the controller can complete work in the zone that registered their
// listeners. Never await that work inside runAsync: only pump can drain the
// FakeAsync callbacks, while runAsync yields to real SQLite work between pumps.
Future<T> _finishOwned<T>(
  WidgetTester tester,
  Future<T> pending, {
  required String reason,
}) async {
  var finished = false;
  late T result;
  Object? failure;
  StackTrace? trace;
  unawaited(
    pending.then(
      (value) {
        result = value;
        finished = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        finished = true;
      },
    ),
  );
  for (var i = 0; i < 300 && !finished; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(finished, isTrue, reason: reason);
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result;
}

void main() {
  for (final pauseFlush in [false, true]) {
    testWidgets(
      'real reset-only runtime changes trigger ${pauseFlush ? 'pause flush' : 'debounced sync'}',
      (tester) async {
        final db = openTestDatabase();
        final library = LibraryRepository(db);
        final preferences = memoryPreferences();
        final secure = MemorySecureStore();
        final dataContainer = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(preferences),
            secureStoreProvider.overrideWithValue(secure),
            sourceHttpClientProvider.overrideWithValue(
              FakeHttpClient(
                (_) async => throw StateError('unexpected real network'),
              ),
            ),
          ],
        );
        final actual = dataContainer.read(libraryAutoSyncRuntimeProvider);
        var uploads = 0;
        final controllerContainer = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            secureStoreProvider.overrideWithValue(secure),
            libraryAutoSyncRuntimeProvider.overrideWithValue(
              LibraryAutoSyncRuntime(
                changes: actual.changes,
                revision: actual.revision,
                check: (_) async {},
                syncDav: () async {
                  uploads++;
                  return actual.revision();
                },
                syncBangumi: () async => throw StateError('unexpected Bangumi'),
                cancel: () {},
              ),
            ),
          ],
        );
        Completer<void>? nextPass;
        final subscription = controllerContainer.listen(
          libraryAutoSyncProvider,
          (_, state) {
            if (!state.pending && !state.syncing && !state.checking) {
              nextPass?.complete();
              nextPass = null;
            }
          },
        );
        Completer<void>? nextChange;
        final changeSubscription = actual.changes.listen((_) {
          nextChange?.complete();
          nextChange = null;
        });
        try {
          await _finishOwned(tester, () async {
            await library.cacheItem(_item);
            await library.saveChapters(
              itemSourceId: _item.sourceId,
              itemRemoteId: _item.remoteId,
              chapters: [_chapter],
            );
            await controllerContainer
                .read(webDavConfigProvider.notifier)
                .update(_config);
          }(), reason: 'Fixture writes and configuration must finish');
          final controller = controllerContainer.read(
            libraryAutoSyncProvider.notifier,
          );
          await _finishOwned(
            tester,
            controller.syncNow(),
            reason: 'Initial sync must establish the real revision',
          );
          var previousRevision = await _finishOwned(
            tester,
            actual.revision(),
            reason: 'Initial revision query must finish',
          );
          for (var reset = 1; reset <= 2; reset++) {
            if (pauseFlush && reset > 1) {
              controller.onResumed();
              await _finishOwned(
                tester,
                controller.syncNow(),
                reason: 'Resumed sync must finish before the second reset',
              );
            }
            final uploadsBeforeReset = uploads;
            final changed = nextChange = Completer<void>();
            // The second action advances only an existing reset clock. Neither
            // action has a history or library membership row to notify instead.
            await _finishOwned(
              tester,
              () async {
                await library.setChapterRead(
                  sourceId: _item.sourceId,
                  itemRemoteId: _item.remoteId,
                  chapters: [_chapter],
                  read: false,
                );
                await changed.future;
                expectSync(await db.select(db.histories).get(), isEmpty);
                expectSync(await db.select(db.libraryEntries).get(), isEmpty);
                final revision = await actual.revision();
                expectSync(revision, isNot(previousRevision));
                previousRevision = revision;
              }(),
              reason:
                  'Reset $reset must emit a real change and advance its revision',
            );
            expect(
              controllerContainer.read(libraryAutoSyncProvider).pending,
              isTrue,
            );
            final pass = nextPass = Completer<void>();
            if (pauseFlush) {
              controller.onPaused();
            } else {
              await tester.pump(LibraryAutoSyncController.debounce);
            }
            await _finishOwned(
              tester,
              pass.future,
              reason: 'Reset $reset must complete its automatic sync',
            );
            expect(uploads, uploadsBeforeReset + 1);
            expect(
              controllerContainer.read(libraryAutoSyncProvider).pending,
              isFalse,
            );
          }
          if (pauseFlush) {
            controller.onResumed();
            await _finishOwned(
              tester,
              controller.syncNow(),
              reason: 'Resume must finish before testing bookmark-only changes',
            );
          }
          final uploadsBeforeBookmark = uploads;
          final changed = nextChange = Completer<void>();
          await _finishOwned(
            tester,
            () async {
              final beforeBookmark = await actual.revision();
              await library.setChapterBookmarked(
                sourceId: _item.sourceId,
                itemRemoteId: _item.remoteId,
                chapters: [_chapter],
                bookmarked: true,
              );
              await changed.future;
              expectSync(
                await actual.revision(),
                beforeBookmark,
                reason: 'bookmark flags and their flag clock are not DAV reset data',
              );
            }(),
            reason: 'Bookmark must emit a real change without changing the revision',
          );
          expect(
            controllerContainer.read(libraryAutoSyncProvider).pending,
            isTrue,
          );
          final bookmarkPass = nextPass = Completer<void>();
          await tester.pump(LibraryAutoSyncController.debounce);
          await _finishOwned(
            tester,
            bookmarkPass.future,
            reason:
                'Bookmark-only scheduling must finish its revision comparison',
          );
          expect(
            uploads,
            uploadsBeforeBookmark,
            reason: 'An unchanged DAV revision must not upload bookmark-only changes',
          );
          expect(
            controllerContainer.read(libraryAutoSyncProvider).pending,
            isFalse,
          );
        } finally {
          // Cancel provider-owned listeners and drain their FakeAsync removals
          // before closing Drift, rather than leaving this to final unmount.
          subscription.close();
          controllerContainer.dispose();
          dataContainer.dispose();
          final cancelled = changeSubscription.cancel();
          await _finishOwned(
            tester,
            cancelled,
            reason:
                'The real change listener must cancel before database close',
          );
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 1));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 1)),
            );
          }
          await _finishOwned(
            tester,
            db.close(),
            reason: 'Database shutdown must finish after provider disposal',
          );
        }
      },
    );
  }
}
