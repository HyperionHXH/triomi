import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';

/// D42：导出 / 备份 / WebDAV 错误文本的脱敏回归。
///
/// 背景：错误信息会进入 UI（snackbar/状态行）与日志。URL 是最常见的泄漏源
/// ——query 里的 token、userinfo 里的账密、fragment——`SourceException.wrap`
/// 统一在拼 URL 前脱敏（D22-1 修复）；本文件把「导出 / 备份 / WebDAV」三处
/// 错误入口的脱敏行为固化成网络层契约。
void main() {
  group('SourceException.wrap：URL 脱敏', () {
    SourceException wrapOf(String url) => SourceException.wrap(
      Exception('connection refused'),
      sourceId: 'webdav',
      url: url,
    );

    test('query 里的 token 不进入错误文本', () {
      final error = wrapOf(
        'https://dav.example.com/triomi/backup.zip?token=super-secret-token',
      );
      expect('${error.message}', isNot(contains('super-secret-token')));
      expect('${error.message}', contains('https://dav.example.com'));
      expect('${error.message}', isNot(contains('?')));
    });

    test('userinfo（user:password@）不进入错误文本', () {
      final error = wrapOf('https://user:pass123@files.example.com/dav/');
      expect('${error.message}', isNot(contains('pass123')));
      expect('${error.message}', isNot(contains('user@')));
      expect('${error.message}', contains('https://files.example.com/dav/'));
    });

    test('fragment 不进入错误文本；端口保留', () {
      final error = wrapOf(
        'https://dav.example.com:8443/dav/x.zip#section?sign=abc',
      );
      final text = '${error.message}';
      expect(text, isNot(contains('#section')));
      expect(text, isNot(contains('sign=abc')));
      expect(text, contains(':8443'), reason: '端口是连接信息的一部分，保留');
    });

    test('非标准 URL（无 scheme/host）保守取 ?/# 前的路径段', () {
      final error = wrapOf('not-a-url?token=leaky');
      expect('${error.message}', isNot(contains('leaky')));
      expect('${error.message}', contains('not-a-url'));
    });

    test('错误详情本身内嵌 URL：sanitizeMessage 同样脱敏', () {
      final error = SourceException.wrap(
        Exception('重定向到 https://api.example.com/export?session=abc123 后失败'),
        sourceId: 'backup',
      );
      expect('${error.message}', isNot(contains('session=abc123')));
      expect('${error.message}', contains('https://api.example.com/export'));
    });

    test('没有 URL 的错误保持原样（不破坏可读性）', () {
      final error = SourceException.wrap(
        Exception('没有可导出的章节（全部失败或全部为锁定章节）'),
        sourceId: 'export',
      );
      expect('${error.message}', contains('没有可导出的章节（全部失败或全部为锁定章节）'));
      expect('${error.message}', isNot(contains('http')));
    });

    test('已是 SourceException 的错误原样返回（不二次处理、不重脱敏）', () {
      const original = SourceException(
        sourceId: 'lk',
        type: SourceErrorType.auth,
        message: '请先登录轻之国度账号',
      );
      expect(
        SourceException.wrap(
          original,
          sourceId: 'other',
          url: 'https://x/?a=b',
        ),
        same(original),
      );
    });
  });

  group('真实网络层错误（dio → wrap）', () {
    test('连接失败：错误文本带 URL 但剥掉 query 凭据（127.0.0.1 拒绝端口）', () async {
      final dio = DioSourceHttpClient(timeout: const Duration(seconds: 3));
      addTearDown(dio.close);

      SourceException? caught;
      try {
        // 127.0.0.1 上的保留端口（1）：连接被立即拒绝，不触外网。
        await dio.send(
          SourceRequest(
            url: 'http://127.0.0.1:1/triomi/backup.zip?token=leaky-token',
          ),
          sourceId: 'webdav',
        );
        fail('应当抛出');
      } on SourceException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect('${caught.message}', isNot(contains('leaky-token')));
      expect('${caught.message}', contains('/triomi/backup.zip'));
      expect(caught.type, SourceErrorType.network);
    });
  });

  group('消费方错误文本契约（导出 / 备份 / WebDAV 入口）', () {
    test('WebDAV stat/upload 的失败信息不包含 Basic 凭据（凭据只在头里）', () {
      // WebDavClient 把账号密码放 Authorization 头；URL 里没有凭据，
      // 因此错误文本天然不含账密——固化该约定防止将来把凭据拼进 URL。
      const config =
          'https://user:secret@dav.example.com/dav/triomi/backup.zip';
      final error = SourceException.wrap(
        Exception('HTTP 401'),
        sourceId: 'webdav',
        url: config,
      );
      expect('${error.message}', isNot(contains('secret')));
    });

    test('导出失败的用户可见文案（userMessage）不含 URL 凭据', () {
      final error = SourceException.wrap(
        Exception('HTTP 500'),
        sourceId: 'export',
        url: 'https://api.example.com/book/1/content?key=k-123456',
      );
      expect(error.userMessage, isNot(contains('k-123456')));
      expect(error.userMessage, contains('网络'), reason: '错误分类标签在前');
    });
  });
}
