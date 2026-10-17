import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/novel/novel_collection_button.dart';

const _book = MediaItem(sourceId: 'site', remoteId: 'one', title: 'Book', type: MediaType.novel);
class _Shelf implements RemoteShelfProvider {
  bool loggedIn = true, member = true, failWrite = false, failRead = false, expireOnWrite = false;
  final writes = <bool>[];
  Completer<List<MediaItem>>? pending;
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(id: 'site', name: 'Site',
    type: MediaType.novel, kind: SourceKind.builtin,
    capabilities: {SourceCapability.account, SourceCapability.remoteShelf});
  @override
  bool get isReady => true;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  Future<void> restoreSession() async {}
  @override
  Future<void> login(String account, String password) async => loggedIn = true;
  @override
  Future<void> logout() async => loggedIn = false;
  @override
  Future<Map<String, int>> remoteUnreadCounts() async => {};
  @override
  Future<List<MediaItem>> remoteShelf() async {
    if (failRead) throw StateError('read unavailable');
    return pending?.future ?? (member ? [_book] : []);
  }
  @override
  Future<void> setInRemoteShelf(MediaItem item, bool add) async {
    writes.add(add);
    if (expireOnWrite) { loggedIn = false; throw StateError('session expired'); }
    if (failWrite) throw StateError('write failed');
    member = add;
  }
}
class _Registry extends SourceRegistryController {
  _Registry(this.source, {this.enabled = true});
  final _Shelf source;
  final bool enabled;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(entries: [
    SourceEntry(descriptor: source.descriptor, source: source, enabled: enabled)], failures: []);
}
void main() {
  testWidgets('site-only collection reads remote state and cancel/failure never removes it', (tester) async {
    final source = _Shelf();
    await tester.pumpWidget(ProviderScope(overrides: [sourcesProvider.overrideWith(() => _Registry(source))],
      child: const MaterialApp(home: Scaffold(body: NovelCollectionButton(item: _book)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已在站点收藏 · 移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(source.writes, isEmpty);
    source.failWrite = true;
    await tester.tap(find.text('已在站点收藏 · 移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(source.member, isTrue);
    expect(find.text('已在站点收藏 · 移除'), findsOneWidget);
    source.failWrite = false;
    await tester.tap(find.text('已在站点收藏 · 移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(source.member, isFalse);
    expect(find.text('加入站点收藏'), findsOneWidget);
    await tester.tap(find.text('加入站点收藏'));
    await tester.pumpAndSettle();
    expect(source.member, isTrue);
    expect(source.writes, [false, false, true]);
  });
  testWidgets('disabled source cannot issue a remote write', (tester) async {
    final source = _Shelf();
    final container = ProviderContainer(overrides: [sourcesProvider.overrideWith(() => _Registry(source, enabled: false))]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: Scaffold(body: NovelCollectionButton(item: _book)))));
    await tester.pumpAndSettle();
    expect(find.text('加入站点收藏'), findsNothing);
    expect(source.writes, isEmpty);
  });
  testWidgets('failed reads retry actual membership and expired writes expose login instead of spinning', (tester) async {
    final source = _Shelf()..failRead = true;
    await tester.pumpWidget(ProviderScope(overrides: [sourcesProvider.overrideWith(() => _Registry(source))],
      child: const MaterialApp(home: Scaffold(body: NovelCollectionButton(item: _book)))));
    await tester.pumpAndSettle();
    expect(source.writes, isEmpty);
    source.failRead = false;
    await tester.tap(find.text('站点收藏读取失败 · 重试'));
    await tester.pumpAndSettle();
    expect(find.text('已在站点收藏 · 移除'), findsOneWidget);
    source.expireOnWrite = true;
    await tester.tap(find.text('已在站点收藏 · 移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('登录后使用站点收藏'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('registry account refresh invalidates an already open remove confirmation', (tester) async {
    final source = _Shelf();
    final container = ProviderContainer(overrides: [sourcesProvider.overrideWith(() => _Registry(source))]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: Scaffold(body: NovelCollectionButton(item: _book)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已在站点收藏 · 移除'));
    await tester.pumpAndSettle();
    container.invalidate(sourcesProvider);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(source.writes, isEmpty);
    expect(source.member, isTrue);
  });
}
