import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/profile/profile_page.dart';

void main() {
  testWidgets('我的保留单一来源入口并按本地、账号数据、设置排序', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const ProfilePage(),
    ));
    expect(find.text('管理'), findsNothing);
    expect(find.text('来源与规则管理'), findsOneWidget);
    final labels = tester.widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data)
        .toList();
    expect(labels.take(3), ['全部观看与阅读历史', '下载管理', '本地漫画库']);
    expect(labels.indexOf('轻之国度 · 账号与签到'), lessThan(labels.indexOf('云同步')));
    expect(labels.indexOf('备份与恢复'), lessThan(labels.indexOf('设置')));
    for (final title in ['轻之国度 · 消息中心', '轻书架 · 账号与签到', '远端书架', '阅读字体', '弹幕设置']) {
      expect(labels, contains(title));
    }
  });
}
