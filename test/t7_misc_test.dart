import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/schedule/data/bangumi_schedule_client.dart';
import 'package:triomi/features/schedule/schedule_page.dart';

void main() {
  group('T7-1 追番条目 → 订阅导航参数', () {
    test('映射 sourceId / remoteId / url（对齐 bangumi-anime 规则 detail）', () {
      final item = scheduleEntryToItem(
        ScheduleEntry(id: '345678', title: '测试番剧'),
      );

      expect(item.sourceId, 'bangumi-anime');
      expect(item.remoteId, '345678');
      expect(item.type, MediaType.anime);
      expect(item.title, '测试番剧');
      // 规则 detail 的 url 模板是 /v0/subjects/{id}，baseUrl 是 api.bgm.tv。
      expect(item.url, 'https://api.bgm.tv/v0/subjects/345678');
    });

    test('条目自带 url 时优先使用', () {
      final item = scheduleEntryToItem(
        ScheduleEntry(
          id: '42',
          title: '另一部',
          url: 'https://api.bgm.tv/v0/subjects/42',
        ),
      );

      expect(item.url, 'https://api.bgm.tv/v0/subjects/42');
    });

    test('封面走解析（resolveScheduleCover）', () {
      final item = scheduleEntryToItem(
        ScheduleEntry(id: '1', title: 'x', coverUrl: '/r/400/pic/1.jpg'),
      );

      // 夹具/解析函数对相对路径补全；这里只保证透传链路不断。
      expect(item.coverUrl, isNotNull);
    });
  });
}
