import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart' as testing;
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/js/runtime/ios_js_runtime.dart';

/// Run identical source contracts in desktop QuickJS and actual iOS WebKit.
/// Only HTTP fixtures are replaced; script evaluation and selectors are real.
void sourceRuleTest(String description, FutureOr<void> Function() body) {
  if (!Platform.isIOS) {
    testing.test(description, body);
    return;
  }
  testing.testWidgets(description, (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('Chinese source protocol acceptance'),
      ),
    );
    // Timer/concurrency cases must use real time, not await an unpumped fake clock.
    await tester.runAsync(() async => await body());
  }, timeout: const testing.Timeout(Duration(minutes: 2)));
}

Future<String> readSourceRuleAsset(String path) =>
    Platform.isIOS ? rootBundle.loadString(path) : File(path).readAsString();

JsRuntime createSourceRuleRuntime() =>
    Platform.isIOS ? IosJsRuntime() : FlutterJsRuntime();
