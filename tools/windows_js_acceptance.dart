// Direct root entrypoint: Flutter's integration_test wrapper exposes only main.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:triomi/main.dart' as app;

import '../integration_test/support/js_process_cases.dart';

@pragma('vm:entry-point')
Future<void> jsWorker([List<String> args = const []]) => app.jsWorker(args);

Future<void> main(List<String> args) async {
  if (args.length == 3 && args.first == '--triomi-js-worker') {
    await jsWorker(args);
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('Triomi JS process acceptance')),
    ),
  );
  final output = Platform.environment['TRIOMI_JS_ACCEPTANCE_OUTPUT'];
  if (output == null) exit(2);
  Map<String, Object?> progress = {};
  try {
    final record = await runProcessJsAcceptance(
      onProgress: (record) {
        progress = Map.of(record);
        File(output).writeAsStringSync(jsonEncode(progress), flush: true);
      },
    );
    await File(output).writeAsString(jsonEncode(record), flush: true);
    exit(0);
  } catch (error) {
    await File(output).writeAsString(
      jsonEncode({
        ...progress,
        'status': 'failed',
        'errorType': error.runtimeType.toString(),
      }),
      flush: true,
    );
    exit(1);
  }
}
