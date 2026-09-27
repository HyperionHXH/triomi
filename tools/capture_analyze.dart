// 临时工具：在独立 console 下跑 analyze 并把输出写文件（宿主管道绕行）。
import 'dart:io';

Future<void> main() async {
  final result = await Process.run(Platform.resolvedExecutable, <String>[
    'analyze',
    '--format',
    'machine',
  ], stdoutEncoding: utf8, stderrEncoding: utf8);
  File(r'D:/noval_and_manga/_cap_analyze.txt').writeAsStringSync(
    'exit=${result.exitCode}\n${result.stdout}\nSTDERR:/n${result.stderr}',
  );
}
