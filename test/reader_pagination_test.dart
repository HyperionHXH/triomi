import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/novel/reader/novel_reader_settings.dart';

/// 长段落：够长到「每行少放一两个字」就会多出一行，用来暴露字距差异。
final String longParagraph = List<String>.filled(
  40,
  '快乐的暑假结束，学园生活再度开始。要说发生什么，'
  '也就路厅王国送来感谢状和金银财宝当作报答，甚至还王族全家都跑来道谢。'
  '霸凌魔物是这世界少数的娱乐，要是被拿走我可是会无聊死的。',
).join();

void main() {
  group('分页测量与渲染必须是同一份样式', () {
    testWidgets('Text 的渲染高度与分页 TextPainter 量出的高度一致', (tester) async {
      const settings = NovelReaderSettings();
      const width = 1040.0;
      // 视口要够高，否则 Text 会被约束截断，量不出真实高度。
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late double renderedHeight;
      late double measuredHeight;
      late double mergedHeight;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final ambient = DefaultTextStyle.of(context).style;
                final base = settings.paragraphStyle(context);
                final style = readerTextStyle(base, null);

                double measure(TextStyle candidate) => (TextPainter(
                  text: TextSpan(text: longParagraph, style: candidate),
                  textDirection: TextDirection.ltr,
                  textScaler: TextScaler.noScaling,
                )..layout(maxWidth: width)).height;

                measuredHeight = measure(style);
                // 修复前的样式（`Text` 会把环境 DefaultTextStyle 合并进来，
                // Material 的 bodyMedium 带 letterSpacing）量出的高度确实不同——
                // 这条断言保证下面那条不是「碰巧相等」。
                mergedHeight = measure(ambient.merge(base));

                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: Text(longParagraph, style: style),
                  ),
                );
              },
            ),
          ),
        ),
      );

      renderedHeight = tester.getSize(find.byType(Text)).height;

      expect(mergedHeight, isNot(measuredHeight), reason: '环境字距应当真的会改变换行');
      expect(renderedHeight, measuredHeight);
    });

    testWidgets('来源字体覆盖 + 不合并环境样式', (tester) async {
      const settings = NovelReaderSettings(fontFamily: '用户字体');
      late TextStyle paragraph;
      late TextStyle heading;
      late TextStyle ambientStyle;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ambientStyle = DefaultTextStyle.of(context).style;
                paragraph = readerTextStyle(
                  settings.paragraphStyle(context),
                  'triomi-lns-abc',
                );
                heading = readerTextStyle(
                  settings.headingStyle(context),
                  'triomi-lns-abc',
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      // 环境样式本来会带字距（否则本测试无意义）。
      expect(ambientStyle.letterSpacing, isNotNull);

      for (final style in <TextStyle>[paragraph, heading]) {
        expect(style.inherit, isFalse);
        // 合并后仍然是自己（`TextStyle.merge` 对 inherit: false 直接返回入参）。
        expect(ambientStyle.merge(style).letterSpacing, style.letterSpacing);
        expect(
          ambientStyle.merge(style).leadingDistribution,
          style.leadingDistribution,
        );
        // 来源字体优先于用户设置。
        expect(style.fontFamily, 'triomi-lns-abc');
      }
      // 行高与字号来自阅读设置本身。
      expect(paragraph.height, settings.lineHeight);
      expect(paragraph.fontSize, settings.fontSize);
      expect(heading.fontSize, settings.fontSize * 1.25);
    });
  });
}
