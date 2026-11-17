import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/reader/manga_reader_settings.dart';
import 'package:triomi/features/reader/manga_zoom_view.dart';
import 'package:triomi/features/reader/reader_settings.dart';

void main() {
  group('缩放边界', () {
    test('原始大小不允许平移，避免把整页拖出画面', () {
      expect(
        mangaClampOffset(const Offset(80, 40), 1, const Size(400, 800)),
        Offset.zero,
      );
    });

    test('放大后只在真正可移动的范围内平移', () {
      // 2 倍：每侧最多移动半个视图宽/高。
      expect(
        mangaClampOffset(const Offset(999, -999), 2, const Size(400, 800)),
        const Offset(200, -400),
      );
      expect(
        mangaClampOffset(const Offset(-50, 30), 2, const Size(400, 800)),
        const Offset(-50, 30),
      );
      // 3 倍：可移动范围随倍数增长。
      expect(
        mangaClampOffset(const Offset(999, 0), 3, const Size(400, 800)).dx,
        400,
      );
    });

    test('双击在原始大小和设定倍数之间切换', () {
      expect(mangaDoubleTapTarget(1, 2, MangaZoomView.maxScale), 2);
      // 已放大：下一次双击回到原始大小。
      expect(mangaDoubleTapTarget(2, 2, MangaZoomView.maxScale), 1);
      expect(mangaDoubleTapTarget(4.9, 2, MangaZoomView.maxScale), 1);
    });

    test('双击倍数被限制在可放大范围内', () {
      expect(mangaDoubleTapTarget(1, 9, MangaZoomView.maxScale), 5);
      expect(
        mangaDoubleTapTarget(1, .5, MangaZoomView.maxScale),
        greaterThan(1),
      );
    });

    test('捏合保持焦点：缩放焦点下的内容点缩放后仍在同一屏幕位置', () {
      // 焦点在中心下方 100、右侧 50；缩放后该点下的内容应留在原处。
      const anchor = Offset(50, 100);
      const fromScale = 1.0, toScale = 2.0;
      final next = mangaAnchorOffset(
        anchor: anchor,
        offset: Offset.zero,
        fromScale: fromScale,
        toScale: toScale,
      );
      // 屏幕位置 = 倍数 * 内容点 + 偏移；解出焦点下的内容点再回代。
      final content = anchor / fromScale;
      final restored = content * toScale + next;
      expect(restored.dx, closeTo(anchor.dx, 1e-9));
      expect(restored.dy, closeTo(anchor.dy, 1e-9));
      // 确实发生了放大，而不是只是平移。
      expect(next, isNot(Offset.zero));
    });
  });

  group('夜间模式', () {
    test('关闭时不压暗，即使亮度值很低', () {
      expect(const MangaNightMode().scrimAlpha, 0);
      expect(const MangaNightMode(enabled: false, brightness: 5).scrimAlpha, 0);
    });

    test('开启后覆盖层随亮度下降而加深，并限制在可辨识范围内', () {
      expect(
        const MangaNightMode(enabled: true, brightness: 100).scrimAlpha,
        0,
      );
      expect(
        const MangaNightMode(enabled: true, brightness: 60).scrimAlpha,
        closeTo(.4, 1e-9),
      );
      expect(
        const MangaNightMode(enabled: true, brightness: 5).scrimAlpha,
        closeTo(.95, 1e-9),
      );
    });

    test('越界亮度被夹住，不会出现全黑或负透明度', () {
      expect(
        const MangaNightMode(enabled: true, brightness: 0).scrimAlpha,
        closeTo(.95, 1e-9),
      );
      expect(
        const MangaNightMode(enabled: true, brightness: 400).scrimAlpha,
        0,
      );
    });
  });

  group('设置解析', () {
    test('未存过设置时默认允许放大与双击，夜间模式关闭', () {
      final view = MangaViewSettings.from(const ReaderSettings(), const {});
      expect(view.zoom, isTrue);
      expect(view.doubleTapZoom, isTrue);
      expect(view.doubleTapScale, 2);
      expect(view.zoomDuration, ZoomDurationPreset.normal);
      expect(view.night.enabled, isFalse);
    });

    test('关闭放大与双击后保持关闭，并读回倍率/动画/夜间亮度', () {
      final view = MangaViewSettings.from(const ReaderSettings(), const {
        'zoom': false,
        'doubleTapZoom': false,
        'doubleTapScale': 3.5,
        'zoomDuration': 'slow',
        'nightMode': true,
        'nightBrightness': 15,
      });
      expect(view.zoom, isFalse);
      expect(view.doubleTapZoom, isFalse);
      expect(view.doubleTapScale, 3.5);
      expect(view.zoomDuration, ZoomDurationPreset.slow);
      expect(view.night.enabled, isTrue);
      expect(view.night.brightness, 15);
      expect(view.night.scrimAlpha, closeTo(.85, 1e-9));
    });

    test('非法倍率/亮度被夹到安全范围，未知动画名回落到标准', () {
      final view = MangaViewSettings.from(const ReaderSettings(), const {
        'doubleTapScale': 40,
        'zoomDuration': 'turbo',
        'nightMode': true,
        'nightBrightness': -20,
      });
      expect(view.doubleTapScale, 4);
      expect(view.zoomDuration, ZoomDurationPreset.normal);
      expect(view.night.brightness, 5);
    });
  });

  Future<void> doubleTap(WidgetTester tester) async {
    await tester.tap(find.byType(MangaZoomView));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(MangaZoomView));
    // 双击识别器要等超时才落定，先跨过它再断言，避免测试结束时残留计时器。
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('缩放层手势', () {
    Widget host({
      int resetToken = 0,
      bool enabled = true,
      bool doubleTapZoom = true,
      ValueChanged<TapUpDetails>? onTapUp,
      ValueChanged<bool>? onZoomChanged,
    }) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 400,
            child: MangaZoomView(
              enabled: enabled,
              doubleTapZoom: doubleTapZoom,
              doubleTapScale: 2,
              duration: ZoomDurationPreset.none,
              resetToken: resetToken,
              onTapUp: onTapUp,
              onZoomChanged: onZoomChanged,
              child: const ColoredBox(color: Colors.grey),
            ),
          ),
        ),
      ),
    );

    testWidgets('双击放大到设定倍数，再双击回到原始大小', (tester) async {
      await tester.pumpWidget(host());
      final state = tester.state<MangaZoomViewState>(
        find.byType(MangaZoomView),
      );
      expect(state.debugScale, 1);

      await doubleTap(tester);
      expect(state.debugScale, 2);

      await doubleTap(tester);
      expect(state.debugScale, 1);
    });

    testWidgets('放大后单指拖动是平移图片，不触发点击翻页', (tester) async {
      final taps = <TapUpDetails>[];
      await tester.pumpWidget(host(onTapUp: taps.add));
      final state = tester.state<MangaZoomViewState>(
        find.byType(MangaZoomView),
      );
      await doubleTap(tester);
      expect(state.debugScale, 2);
      expect(state.debugMaxPanX, closeTo(150, 1e-9));

      await tester.drag(find.byType(MangaZoomView), const Offset(-120, 0));
      // 拖动落点也会让双击识别器起一个短计时，跨过它避免测试结束时报残留。
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.debugScale, 2);
      expect(taps, isEmpty);
    });

    testWidgets('点击边界后平移到头返回 false，交给翻页', (tester) async {
      await tester.pumpWidget(host());
      final state = tester.state<MangaZoomViewState>(
        find.byType(MangaZoomView),
      );
      // 未放大：不抢占翻页。
      expect(state.panBy(-120), isFalse);

      await doubleTap(tester);
      expect(state.panBy(-120), isTrue);
      // 一直平移到右边界后不再消费点击。
      var guard = 0;
      while (state.panBy(-120) && guard < 20) {
        guard++;
      }
      expect(state.panBy(-120), isFalse);
      expect(guard, lessThan(20));
    });

    testWidgets('关闭放大后双击与捏合都不改变画面', (tester) async {
      await tester.pumpWidget(host(enabled: false));
      final state = tester.state<MangaZoomViewState>(
        find.byType(MangaZoomView),
      );
      await doubleTap(tester);
      expect(state.debugScale, 1);
      expect(state.panBy(-120), isFalse);
    });

    testWidgets('resetToken 变化把放大状态复位', (tester) async {
      await tester.pumpWidget(host());
      final state = tester.state<MangaZoomViewState>(
        find.byType(MangaZoomView),
      );
      await doubleTap(tester);
      expect(state.debugScale, 2);

      await tester.pumpWidget(host(resetToken: 1));
      await tester.pump();
      expect(state.debugScale, 1);
    });

    testWidgets('双击后点击左右区域先平移画面', (tester) async {
      final taps = <TapUpDetails>[];
      await tester.pumpWidget(host(onTapUp: taps.add));
      final state = tester.state<MangaZoomViewState>(
        find.byType(MangaZoomView),
      );
      await doubleTap(tester);
      expect(state.debugScale, 2);
      expect(state.panBy(-120), isTrue);
    });
  });
}
