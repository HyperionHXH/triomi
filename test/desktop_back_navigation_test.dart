import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/widgets/page_scaffold.dart';

void main() {
  testWidgets('桌面二级页面显示返回并回到原导航栈', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const PageScaffold(title: '主页面', child: Text('主页面内容')),
      ),
    );
    expect(find.byType(BackButton), findsNothing);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const PageScaffold(title: '下载管理', child: Text('下载列表')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('主页面内容'), findsOneWidget);
  });
}
