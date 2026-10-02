import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/platform/platform_channel.dart';

/// D43：`PlatformChannel.writeToTree` 的 MIME 契约。
///
/// Dart 侧负责把调用方场景映射成 SAF 的 MIME：
/// - 备份 zip：不传 mime → 默认 `application/zip`（与 Kotlin 侧缺省一致，
///   旧调用兼容）；
/// - EPUB 导出：`application/epub+zip`；
/// - TXT 导出：`text/plain`。
///
/// Kotlin 侧（MainActivity.writeToTree）的行为以静态文档为准
/// （docs/SAF_WRITE_CONTRACT.md），本测试只覆盖 Dart 通道层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final recorded = <MethodCall>[];
  Object? handlerError;

  setUp(() {
    recorded.clear();
    handlerError = null;
    const channel = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'writeToTree') return null;
          if (handlerError != null) throw handlerError!;
          recorded.add(call);
          final args = call.arguments as Map<Object?, Object?>;
          return '${args['treeUri']}/${args['fileName']}';
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });

  test('平台没有返回文件 URI 时不得误报成功', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('triomi/platform'),
          (_) async => null,
        );
    await expectLater(
      platformChannel.writeToTree('content://tree', 'book.txt', Uint8List(1)),
      throwsA(isA<PlatformException>()),
    );
  });

  test('备份旧调用（不传 mime）：通道收到缺省 application/zip', () async {
    final result = await platformChannel.writeToTree(
      'content://tree/backup',
      'triomi-2026.zip',
      Uint8List.fromList(<int>[1, 2, 3]),
    );

    expect(recorded, hasLength(1));
    expect(recorded.single.method, 'writeToTree');
    final args = recorded.single.arguments as Map<Object?, Object?>;
    expect(args['mime'], 'application/zip', reason: '备份 zip 的 SAF MIME');
    expect(args['treeUri'], 'content://tree/backup');
    expect(args['fileName'], 'triomi-2026.zip');
    expect(args['bytes'], <int>[1, 2, 3]);
    expect(result, 'content://tree/backup/triomi-2026.zip');
  });

  test('EPUB 场景：显式 application/epub+zip 原样透传', () async {
    await platformChannel.writeToTree(
      'content://tree/exports',
      '书.epub',
      Uint8List(4),
      mime: 'application/epub+zip',
    );

    final args = recorded.single.arguments as Map<Object?, Object?>;
    expect(args['mime'], 'application/epub+zip');
  });

  test('TXT 场景：显式 text/plain 原样透传', () async {
    await platformChannel.writeToTree(
      'content://tree/exports',
      '书.txt',
      Uint8List(4),
      mime: 'text/plain',
    );

    final args = recorded.single.arguments as Map<Object?, Object?>;
    expect(args['mime'], 'text/plain');
  });

  test('通道错误（SAF 写失败）向上传播，由调用方决定回退', () async {
    handlerError = PlatformException(code: 'write_failed', message: '权限被回收');

    await expectLater(
      platformChannel.writeToTree('content://broken', 'x.zip', Uint8List(2)),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'write_failed',
        ),
      ),
    );
    // 通道层不吞错：BackupService._writeOut / NovelExportService._writeOut
    // 依赖这个异常做私有目录回退。
    expect(recorded, isEmpty, reason: '抛错前不记录成功调用');
  });
}
