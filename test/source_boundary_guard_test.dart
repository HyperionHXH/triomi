import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

/// D75：来源能力矩阵与生产/夹具边界守卫。
///
/// 矩阵本体见 `docs/SOURCE_CAPABILITY_MATRIX.md`；本测试把每条边界钉住，
/// 防止夹具被误当成真实内容、Bangumi 被误加播放能力、release 包夹带夹具。
void main() {
  final ruleDir = Directory('assets/rules');
  final ruleFiles =
      (ruleDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)));

  Map<String, Object?> payloadOf(File file) =>
      jsonDecode(utf8.decode(file.readAsBytesSync())) as Map<String, Object?>;

  test('全部随包规则可通过规则 schema 校验（UTF-8 读取）', () {
    expect(ruleFiles, isNotEmpty);
    for (final file in ruleFiles) {
      final text = utf8.decode(file.readAsBytesSync());
      final descriptor = KazumiRule.recognizes(text)
          ? KazumiRule.parse(text).descriptor
          : SourceRule.parseJson(text).descriptor;
      expect(descriptor.id, isNotEmpty, reason: '${file.path} 缺 id');
    }
  });

  test('Bangumi 是资料源：capabilities 不含 content（无播放线路）', () {
    final payload = payloadOf(File('assets/rules/bangumi-anime.json'));
    final capabilities = <String>[
      ...(payload['capabilities'] as List<Object?>? ?? <Object?>[]).cast(),
    ];
    expect(
      capabilities,
      isNot(contains('content')),
      reason:
          'Bangumi 只做资料/追踪；播放地址必须来自显式声明的合法 provider，'
          '不得从 Bangumi 推导（D79/D80 边界）',
    );
    expect(payload['type'], 'anime');
  });

  test('夹具资产命名自证身份：id 前缀 + 名称标注', () {
    final fixtureFiles = ruleFiles
        .where(
          (file) =>
              File(file.path).uri.pathSegments.last.startsWith('local-fixture'),
        )
        .toList();
    expect(fixtureFiles, hasLength(4), reason: '夹具规则集合变化时同步本守卫与矩阵文档');

    for (final file in fixtureFiles) {
      final payload = payloadOf(file);
      final id = '${payload['id']}';
      final name = '${payload['name']}';
      expect(id, startsWith('local-fixture'), reason: file.path);
      expect(name, contains('夹具'), reason: '$file.path 的名称必须自证是夹具');
      expect(
        name,
        anyOf(contains('调试'), contains('仅'), contains('测试')),
        reason: '$file.path 的名称必须表明仅调试用途',
      );
    }
  });

  test('夹具 baseUrl 只指向本地服务器（10.0.2.2 / 127.0.0.1 / localhost）', () {
    for (final file in ruleFiles) {
      if (!file.uri.pathSegments.last.startsWith('local-fixture')) continue;
      final payload = payloadOf(file);
      final baseUrl = '${payload['baseUrl']}';
      final host = Uri.tryParse(baseUrl)?.host ?? '';
      expect(
        <String>{'10.0.2.2', '127.0.0.1', 'localhost'}.contains(host),
        isTrue,
        reason: '$file.path 的 baseUrl 必须指向本地夹具服务器，不得指向真实站点',
      );
    }
  });

  test('夹具播种必须显式开发开关，debug交付默认不显示夹具', () {
    final registrySource = File('lib/core/source/source_registry.dart')
        .readAsStringSync();
    final getterStart = registrySource.indexOf(
      'static List<String> get builtinRuleAssets',
    );
    final getterEnd = registrySource.indexOf('];', getterStart);
    expect(getterStart, greaterThan(0));
    expect(getterEnd, greaterThan(getterStart));

    final body = registrySource.substring(getterStart, getterEnd);
    final debugGuardAt = body.indexOf('if (developmentSourcesEnabled)');
    expect(debugGuardAt, greaterThan(0), reason: '夹具资产必须在显式开发开关之内');
    expect(
      registrySource,
      contains("bool.fromEnvironment('TRIOMI_DEV_FIXTURES')"),
    );
    expect(registrySource, contains('developmentSourcesEnabled ='));

    for (final line in body.split('\n')) {
      if (line.contains('local-fixture')) {
        final lineOffset = body.indexOf(line);
        expect(
          lineOffset,
          greaterThan(debugGuardAt),
          reason: '夹具资产必须位于 kDebugMode 分支之后（release 不播种夹具）：$line',
        );
      }
    }
    // 生产资产（Bangumi）在门卫之前。
    final bangumiAt = body.indexOf('bangumi-anime.json');
    expect(bangumiAt, lessThan(debugGuardAt));
  });

  test('夹具来源声明了完整闭环能力（发现/搜索/详情/正文）', () {
    // 夹具的价值是验证规则引擎全链路；能力缺失会让 debug 闭环静默变窄。
    for (final name in <String>[
      'local-fixture.json',
      'local-fixture-anime.json',
      'local-fixture-novel.json',
    ]) {
      final payload = payloadOf(File('assets/rules/$name'));
      final capabilities = <String>[
        ...(payload['capabilities'] as List<Object?>? ?? <Object?>[]).cast(),
      ];
      expect(
        capabilities,
        containsAll(<String>['discover', 'search', 'detail', 'content']),
        reason: '$name 必须声明完整闭环能力',
      );
    }
  });
}
