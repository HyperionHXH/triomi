import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'fixtures/ios_test_binding.dart';
import 'ios_acceptance_test.dart' as acceptance;

/// USB acceptance runs in a separately installed app identity. The host pushes
/// existing fixture_media files into its Documents/fixture_media directory;
/// fixtures never become assets of the production application.
void main() {
  initializeIosIntegrationBinding();
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpServer? server;
  String? runId;
  final errors = <Map<String, String>>[];
  final originalReporter = reportTestException;
  reportTestException = (details, description) {
    errors.add({
      'test': description,
      'exception': details.exceptionAsString(),
      'stack': '${details.stack}',
    });
    originalReporter(details, description);
  };
  setUpAll(() async {
    expect(Platform.isIOS, isTrue);
    final documents = await getApplicationDocumentsDirectory();
    runId = await File('${documents.path}/device-run-id.txt').readAsString();
    final root = Directory('${documents.path}/fixture_media');
    expect(
      await File('${root.path}/sample.mp4').exists(),
      isTrue,
      reason: 'Push tools/fixture_media through USB before launch',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 48198);
    server!.listen((request) async {
      try {
        if (request.method != 'GET' && request.method != 'HEAD') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        } else if (request.uri.path.startsWith('/danmaku/')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'code': 0,
              'comments': [
                for (var index = 1; index <= 40; index++)
                  {
                    'p': '${index * .75},1,16777215,100',
                    'm': 'USB fixture $index',
                  },
              ],
            }),
          );
        } else if (RegExp(r'^/video/sample(?:\.mp4|\.m3u8|-\d+\.ts)$')
            .hasMatch(request.uri.path)) {
          final file = File('${root.path}/${request.uri.path.split('/').last}');
          final length = await file.length();
          var start = 0;
          var end = length - 1;
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range != null) {
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
            if (match == null) {
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              await request.response.close();
              return;
            }
            start = int.parse(match[1]!);
            end = match[2]!.isEmpty ? end : int.parse(match[2]!).clamp(0, end);
            if (start > end) {
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              await request.response.close();
              return;
            }
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/$length',
            );
          }
          request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          request.response.headers.contentType =
              request.uri.path.endsWith('.m3u8')
              ? ContentType('application', 'vnd.apple.mpegurl')
              : ContentType(
                  'video',
                  request.uri.path.endsWith('.ts') ? 'mp2t' : 'mp4',
                );
          request.response.contentLength = end - start + 1;
          if (request.method == 'GET') {
            await request.response.addStream(file.openRead(start, end + 1));
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      } on IOException {
        // Native AVPlayer may cancel a range after a seek/episode replacement.
        await request.response.close();
      }
    });
  });

  acceptance.main();

  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final documents = await getApplicationDocumentsDirectory();
      final report = {
        'runId': runId,
        'passed': passed,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
        'results': binding.results.map(
          (name, result) => MapEntry(name, '$result'),
        ),
        'failures': [
          for (final failure in binding.failureMethodsDetails)
            {'test': failure.methodName, 'details': failure.details},
        ],
        'diagnostics': errors,
      };
      await File('${documents.path}/device-acceptance.json')
          .writeAsString(jsonEncode(report), flush: true);
      await server?.close(force: true);
      runApp(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text(
                'USB iOS acceptance: ${passed ? "PASS" : "FAIL"}\n'
                '${binding.results.length} scenarios; ${binding.failureMethodsDetails.length} failures',
              ),
            ),
          ),
        ),
      );
    }),
  );
}
