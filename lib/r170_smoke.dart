import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/db/app_database.dart';
import 'core/db/database_provider.dart';
import 'core/models/chapter.dart';
import 'core/models/media_item.dart';
import 'core/models/media_type.dart';
import 'core/source/http_client.dart';
import 'core/source/source_providers.dart';
import 'core/storage/preferences.dart';
import 'core/storage/secure_store.dart';
import 'core/theme/app_theme.dart';
import 'features/detail/anime_info_sheet.dart';
import 'features/detail/detail_page.dart';
import 'features/downloads/data/download_providers.dart';
import 'features/downloads/data/download_repository.dart';
import 'features/player/player_page.dart';
import 'features/tracking/data/tracking_providers.dart';
import 'features/tracking/data/tracking_models.dart';

class SmokeVideo extends DownloadRepository {
  SmokeVideo(super.db, this.path);
  final String path;
  @override
  Future<String?> localVideoPath(String sourceId, String chapterRemoteId) async => path;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final temp = await Directory.systemTemp.createTemp('triomi-r170-ui-');
  Hive.init(temp.path);
  final prefs = await Preferences.open();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  var path = 'D:/noval_and_manga/_tools/R170-interaction.mp4';
  if (Platform.isAndroid) {
    final dir = await getApplicationSupportDirectory();
    path = '${dir.path}/r170-smoke.mp4';
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('http://10.0.2.2:8170/R170-interaction.mp4'));
    final response = await request.close();
    await response.pipe(File(path).openWrite());
    client.close();
  }
  final http = DioSourceHttpClient();
  runApp(ProviderScope(overrides: [
    databaseProvider.overrideWithValue(db),
    preferencesProvider.overrideWithValue(prefs),
    secureStoreProvider.overrideWithValue(MemorySecureStore()),
    downloadRepositoryProvider.overrideWithValue(SmokeVideo(db, path)),
    sourceHttpClientProvider.overrideWithValue(http),
    trackingBaseUrlOverridesProvider.overrideWithValue(TrackingBaseUrlOverrides(bangumi: Platform.isAndroid ? 'http://10.0.2.2:8171' : 'http://127.0.0.1:8171')),
  ], child: MaterialApp(theme: AppTheme.light(), home: const SmokeHome())));
}

const subject = MediaItem(sourceId: 'bangumi-anime', remoteId: '400602', title: '葬送的芙莉莲', type: MediaType.anime, description: '真实 Bangumi 公开评论验收');
const video = MediaItem(sourceId: 'r170-smoke', remoteId: 'clip', title: '播放器真实解码交互验收', type: MediaType.anime);
const chapters = [Chapter(sourceId: 'r170-smoke', remoteId: 'ep1', title: '六分钟自建测试视频', sortIndex: 0)];
class SmokeHome extends StatelessWidget {
  const SmokeHome({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('隔离生产组件验收')), body: ListView(children: [
    ListTile(title: const Text('真实播放器'), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PlayerPage(args: PlayerArgs(item: video, chapters: chapters, initialIndex: 0))))),
    ListTile(title: const Text('普通番剧详情'), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DetailPage(item: subject)))),
    ListTile(title: const Text('公开评论'), onTap: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => const AnimeInfoSheet(id: '400602', item: subject, initialSection: 'comments'))),
    Consumer(builder: (context, ref, _) => ListTile(title: const Text('本地账号编辑验收'), onTap: () async {
      await ref.read(trackingServiceProvider).setToken(TrackingServiceKind.bangumi, 'r170-local-fixture');
      if (context.mounted) Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DetailPage(item: subject)));
    })), 
  ]));
}
