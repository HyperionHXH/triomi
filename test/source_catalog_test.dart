import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_catalog.dart';

/// D76：插件仓库索引协议——解析、必填校验、重复项、版本比较、未知能力。
void main() {
  String indexOf(Map<String, Object?> entry) =>
      '{"sources": [${jsonEncode(entry)}]}';

  Map<String, Object?> validEntry() => <String, Object?>{
    'id': 'example-manga',
    'name': '示例漫画源',
    'type': 'manga',
    'version': '1.2.3',
    'url': 'https://raw.example.com/rules/example-manga.json',
    'hash': 'sha256:abcdef',
    'capabilities': ['discover', 'search', 'detail', 'content'],
    'license': 'GPL-3.0',
    'updatedAt': '2026-10-01T12:00:00Z',
  };

  group('解析成功路径', () {
    test('完整条目：全部字段解析正确', () {
      final entries = SourceCatalogIndex.parse(indexOf(validEntry()));
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.id, 'example-manga');
      expect(entry.name, '示例漫画源');
      expect(entry.type, MediaType.manga);
      expect(entry.version, const CatalogVersion(1, 2, 3));
      expect(entry.url, 'https://raw.example.com/rules/example-manga.json');
      expect(entry.hash, 'sha256:abcdef');
      expect(
        entry.capabilities,
        containsAll(<SourceCapability>[
          SourceCapability.discover,
          SourceCapability.search,
          SourceCapability.detail,
          SourceCapability.content,
        ]),
      );
      expect(entry.license, 'GPL-3.0');
      expect(entry.updatedAt, DateTime.parse('2026-10-01T12:00:00Z'));
    });

    test('裸数组与 {"sources": []} 两种形状都支持；可选字段缺省为 null', () {
      final bare = SourceCatalogIndex.parse('[]');
      expect(bare, isEmpty);

      final minimal = SourceCatalogIndex.parse(
        '{"sources": [{"id": "a", "name": "甲", "type": "anime", '
        '"version": "0.1.0", "url": "https://r.example.com/a.json", '
        '"capabilities": ["search"]}]}',
      );
      expect(minimal, hasLength(1));
      expect(minimal.single.hash, isNull);
      expect(minimal.single.license, isNull);
      expect(minimal.single.updatedAt, isNull);
      expect(minimal.single.capabilities, <SourceCapability>{
        SourceCapability.search,
      });
    });
  });

  group('解析失败路径（一次报出全部问题）', () {
    void expectProblems(String text, List<String> fragments) {
      try {
        SourceCatalogIndex.parse(text);
        fail('应当抛出');
      } on SourceCatalogParseException catch (error) {
        for (final fragment in fragments) {
          expect(
            error.problems.join('|'),
            contains(fragment),
            reason: '应报出：$fragment',
          );
        }
      }
    }

    test('非法 JSON / 错误顶层形状', () {
      expectProblems('{broken', <String>['不是合法 JSON']);
      expectProblems('{"foo": 1}', <String>['索引必须是']);
      expectProblems('{"sources": "nope"}', <String>['索引必须是']);
    });

    test('缺 id / 缺 name / 缺 url / url 非绝对地址', () {
      expectProblems(
        '{"sources": [{"name": "甲", "type": "manga", "version": "1.0.0", '
        '"url": "ftp://x/a.json", "capabilities": ["search"]}]}',
        <String>['缺少 id', 'url 不是可下载的绝对地址'],
      );
      expectProblems(
        '{"sources": [{"id": "a", "type": "manga", "version": "1.0.0", '
        '"capabilities": ["search"]}]}',
        <String>['缺少 name', '缺少 url'],
      );
      expectProblems(
        '{"sources": [{"id": "a", "name": "甲", "type": "manga", '
        '"version": "1.0.0", "url": "notaurl", "capabilities": ["search"]}]}',
        <String>['url 不是可下载的绝对地址'],
      );
    });

    test('version / type / capabilities 未知值', () {
      expectProblems(
        '{"sources": [{"id": "a", "name": "甲", "type": "book", '
        '"version": "1.0", "url": "https://r.example.com/a.json", '
        '"capabilities": ["teleport"]}]}',
        <String>[
          'version 不是 major.minor.patch',
          'type 未知：book',
          '能力未知：teleport',
        ],
      );
    });

    test('缺 capabilities 数组；updatedAt 非 ISO', () {
      expectProblems(
        '{"sources": [{"id": "a", "name": "甲", "type": "manga", '
        '"version": "1.0.0", "url": "https://r.example.com/a.json", '
        '"capabilities": [], "updatedAt": "昨天"}]}',
        <String>['缺少 capabilities 数组', 'updatedAt 不是 ISO 8601'],
      );
    });

    test('重复 id 拒绝（同仓库必须唯一）', () {
      final duplicated =
          '{"sources": ['
          '${jsonEncode(validEntry())}, ${jsonEncode(validEntry())}]}';
      expectProblems(duplicated, <String>['id 重复']);
    });

    test('非对象元素列出位置', () {
      expectProblems('{"sources": [42]}', <String>['第 1 项不是对象']);
    });
  });

  group('版本比较', () {
    test('major/minor/patch 逐级比较；isNewerThan 语义', () {
      expect(
        const CatalogVersion(
          1,
          2,
          3,
        ).isNewerThan(const CatalogVersion(1, 2, 2)),
        isTrue,
      );
      expect(
        const CatalogVersion(
          1,
          3,
          0,
        ).isNewerThan(const CatalogVersion(1, 2, 9)),
        isTrue,
      );
      expect(
        const CatalogVersion(
          2,
          0,
          0,
        ).isNewerThan(const CatalogVersion(1, 9, 9)),
        isTrue,
      );
      expect(
        const CatalogVersion(
          1,
          2,
          3,
        ).isNewerThan(const CatalogVersion(1, 2, 3)),
        isFalse,
      );
      final versions = <CatalogVersion>[
        const CatalogVersion(1, 0, 0),
        const CatalogVersion(0, 9, 0),
        const CatalogVersion(1, 0, 1),
      ]..sort();
      expect(versions.map((version) => version.toString()).toList(), <String>[
        '0.9.0',
        '1.0.0',
        '1.0.1',
      ]);
    });

    test('tryParse 拒绝非三段/负数/非数字', () {
      expect(CatalogVersion.tryParse('1.2'), isNull);
      expect(CatalogVersion.tryParse('1.2.3.4'), isNull);
      expect(CatalogVersion.tryParse('-1.2.3'), isNull);
      expect(CatalogVersion.tryParse('a.b.c'), isNull);
      expect(CatalogVersion.tryParse(' 1.2.3 '), const CatalogVersion(1, 2, 3));
    });
  });
}
