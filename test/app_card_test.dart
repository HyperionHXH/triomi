import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/widgets/app_card.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'card outline stays visible over opaque children in ${brightness.name}',
      (tester) async {
        final boundaryKey = GlobalKey();
        const childColor = Color(0xFF2367AB);
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark(),
            home: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: const SizedBox(
                  width: 120,
                  height: 80,
                  child: AppCard(
                    padding: EdgeInsets.zero,
                    child: Material(color: childColor),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final pixels = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            expect(pixels, isNotNull);
            int pixel(int x, int y) =>
                pixels!.getUint32((y * image.width + x) * 4);
            // Only the foreground outline covers the opaque child's edge.
            expect(pixel(60, 40), 0x2367ABFF);
            expect(pixel(0, 40), isNot(pixel(60, 40)));
          } finally {
            image.dispose();
          }
        });
      },
    );
  }
}
