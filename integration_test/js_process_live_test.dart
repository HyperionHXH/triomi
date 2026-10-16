import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/main.dart' as app;

import 'support/js_process_cases.dart';

@pragma('vm:entry-point')
Future<void> retainedWorkerEntrypoint() => app.jsWorker();
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('OS worker kill, host response and session recovery', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('JS worker host responsive'),
      ),
    );
    final record = await runProcessJsAcceptance();
    final directory = await getApplicationDocumentsDirectory();
    await File('${directory.path}/js-process-live.json')
        .writeAsString(jsonEncode(record), flush: true);
    // ignore: avoid_print
    print('JS_PROCESS_EVIDENCE ${jsonEncode(record)}');
    expect(record['status'], 'passed');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
