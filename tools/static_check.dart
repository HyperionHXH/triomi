// 宿主管道故障时的同进程静态检查（绕开 dart analyze 的子进程需求）。
// 用法：dart --packages=.dart_tool/package_config.json tools/static_check.dart [目录]
// 退出码 0 = 无问题。
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/error/error.dart'
    show DiagnosticType;

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : Directory.current.path;
  final contexts = AnalysisContextCollection(includedPaths: <String>[root]);

  var issueCount = 0;
  final buffer = StringBuffer('Checking $root...\n');
  for (final context in contexts.contexts) {
    final analyzedFiles = context.contextRoot.analyzedFiles().toList()..sort();
    for (final path in analyzedFiles) {
      if (!path.endsWith('.dart')) continue;
      final result = await context.currentSession.getResolvedUnit(path);
      if (result case final AnalysisResultWithDiagnostics diagnostics) {
        final relative = path
            .substring(root.length + 1)
            .replaceAll('\\', '/');
        final lineInfo = diagnostics.lineInfo;
        for (final diagnostic in diagnostics.diagnostics) {
          final code = diagnostic.diagnosticCode;
          if (code.type == DiagnosticType.TODO) continue;
          issueCount += 1;
          final location = lineInfo.getLocation(diagnostic.offset);
          buffer.writeln(
            '${diagnostic.severity.name.toLowerCase()} - ${diagnostic.message} - '
            '$relative:${location.lineNumber}:${location.columnNumber} - '
            '${code.lowerCaseName}',
          );
        }
      }
    }
  }

  buffer.writeln('$issueCount issue${issueCount == 1 ? '' : 's'} found.');
  stdout.writeln(buffer.toString());
  exit(issueCount == 0 ? 0 : 1);
}
