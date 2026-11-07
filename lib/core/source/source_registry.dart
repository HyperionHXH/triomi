import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import '../models/source_exception.dart';
import 'bangumi_public_client.dart';
import 'bangumi_source.dart';
import 'declarative_source.dart';
import 'host_features.dart';
import 'http_client.dart';
import 'js/js_runtime.dart';
import 'js/js_source.dart';
import 'js/runtime/js_runtime_factory.dart';
import 'kazumi_repository.dart';
import 'kazumi_source.dart';
import 'mihon_source.dart';
import 'rule_schema.dart';
import 'source_api.dart';
import 'source_repository.dart';

/// Fixture browsing is explicit opt-in, including on debug APKs handed to users.
const developmentSourcesEnabled =
    kDebugMode && bool.fromEnvironment('TRIOMI_DEV_FIXTURES');
const developmentSourceIds = <String>{
  'local-fixture',
  'local-fixture-js',
  'local-fixture-anime',
  'local-fixture-novel',
};

/// 一个可用的来源：描述信息 + 执行实现。
class SourceEntry {
  const SourceEntry({
    required SourceDescriptor descriptor,
    required this.source,
    required this.enabled,
    this.ruleText,
    this.repoUrl,
    bool? canRemove,
    this.isRetiredDefault = false,
    // Keep the public descriptor: argument while exposing live JS capabilities.
    // ignore: prefer_initializing_formals
  }) : _descriptor = descriptor,
       // ignore: prefer_initializing_formals
       _canRemove = canRemove;

  final SourceDescriptor _descriptor;
  SourceDescriptor get descriptor => source is JsSource && source.isReady
      ? source.descriptor.copyWith(kind: _descriptor.kind)
      : _descriptor;
  final ContentSource source;
  final bool enabled;
  final String? ruleText;
  final String? repoUrl;
  final bool? _canRemove;

  bool get isBuiltin => descriptor.kind == SourceKind.builtin;
  bool get canRemove => _canRemove ?? (!isBuiltin || ruleText != null);

  /// Application-owned metadata remains resolvable, but is not a plugin.
  bool get isInternal => descriptor.id == SourceRepository.internalMetadataId;

  /// A pristine old AGE engine retained solely for its stored numeric IDs.
  /// It is not a second candidate when the canonical same-site plugin exists.
  final bool isRetiredDefault;
  bool get isManageable => !isInternal && !isRetiredDefault;
  bool get isCustomLegacyAge =>
      descriptor.id == 'age-anime' &&
      !SourceRegistry._isPristineLegacyAge(ruleText);

  bool supports(SourceCapability capability) => descriptor.supports(capability);
}

/// 规则加载失败的记录。
///
/// 坏规则不能让整个来源列表消失——它必须作为一个可见的失败项出现在管理页，
/// 否则用户只会看到「来源不见了」，无从排查。
class SourceFailure {
  const SourceFailure({
    required this.id,
    required this.name,
    required this.message,
    this.lang = '',
    this.type,
    this.nsfw,
    this.canRemove = true,
  });

  final String id;
  final String name;
  final String message;
  final String lang;
  final MediaType? type;
  final bool? nsfw;
  final bool canRemove;
}

/// 一次注册表加载的完整结果。
class SourceRegistrySnapshot {
  const SourceRegistrySnapshot({required this.entries, required this.failures});

  final List<SourceEntry> entries;
  final List<SourceFailure> failures;

  List<SourceEntry> get manageableEntries => [
    for (final entry in entries)
      if (entry.isManageable) entry,
  ];

  List<SourceEntry> get enabledEntries => <SourceEntry>[
    for (final entry in entries)
      if (entry.enabled &&
          (developmentSourcesEnabled ||
              !developmentSourceIds.contains(entry.descriptor.id)))
        entry,
  ];

  /// 具备某能力的已启用来源。
  List<SourceEntry> enabledWith(SourceCapability capability) => <SourceEntry>[
    for (final entry in enabledEntries)
      if (entry.supports(capability)) entry,
  ];
}

/// Disabled scripts expose metadata only; discovering capabilities executes JS.
class _DisabledScriptSource implements ContentSource {
  const _DisabledScriptSource(this.descriptor);

  @override
  final SourceDescriptor descriptor;

  @override
  bool get isReady => false;
}

typedef JsSourceFactory = JsSource Function({
  required SourceRule rule,
  required JsRuntime runtime,
  required SourceHttpClient http,
  Map<String, Object?> Function()? requestOptions,
});

/// 来源注册表：负责「从数据库 / 内置资产里把规则变成可用来源」。
///
/// 双轨来源体系（见 PROJECT_SPEC 4.3）：
/// - 内置适配器（LK / LNS，M4 落地）——随包编译，走原生实现；
/// - 规则来源——声明式 JSON 规则，或 JS 规则（同一份规则文件里的 `script`）。
class SourceRegistry {
  SourceRegistry({
    required this.repository,
    required this.http,
    this.bangumiPublicClient,
    this.builtinAdapters = const <String, ContentSource>{},
    this.defaultDisabledBuiltins = const <String>{},
    this.mihonAdapters = const <MihonSource>[],
    this.metadataFailures = const <SourceFailure>[],
    this.jsRuntimeFactory,
    this.jsRequestOptions,
    this.jsSourceFactory,
    AssetBundle? assetBundle,
  }) : _bundle = assetBundle ?? rootBundle;

  final SourceRepository repository;
  final SourceHttpClient http;
  final BangumiPublicClient? bangumiPublicClient;

  /// 内置适配器（如轻之国度）：随包编译，不走规则文件。
  /// 键为来源 id；对应数据库行的 ruleText 为空。
  final Map<String, ContentSource> builtinAdapters;

  /// 首次播种时**默认停用**的内置来源 id。
  ///
  /// 用于「实现已就位但尚未端到端联调」的来源（如需要账号的轻书架）：
  /// 用户可在来源管理页手动启用，联调通过后从该集合移除。
  final Set<String> defaultDisabledBuiltins;

  /// Executable Mihon sources restored from the Android host status store.
  /// They are deliberately kept outside the rule database because an APK is
  /// not a JSON rule and its enabled state belongs to the native host.
  final List<MihonSource> mihonAdapters;
  final List<SourceFailure> metadataFailures;

  /// JS 规则用的引擎工厂；为 null 时用 flutter_js（Web 上不可用）。
  /// 测试注入替身走这里。
  final JsRuntime Function()? jsRuntimeFactory;

  final Map<String, Object?> Function(String sourceId)? jsRequestOptions;
  final JsSourceFactory? jsSourceFactory;

  final AssetBundle _bundle;
  final Map<String, ({String text, JsSource instance})> _scripts = {};
  Future<String>? _metadataText;

  // Before build 186 Windows checkouts could package CRLF bytes. Normalize only
  // that transport difference; script bytes, JSON spacing and key order stay pinned.
  static bool _isPristineLegacyAge(String? text) =>
      text != null &&
      sha256.convert(utf8.encode(text.replaceAll('\r\n', '\n'))).toString() ==
          'c0adc77c4118399cd9077790840e2133e74517b992e84220c700d931279f0063';

  Future<void> _ensureInternalMetadata() async {
    final text = await (_metadataText ??= _bundle.loadString(
      'assets/rules/bangumi-anime.json',
    ));
    final rule = SourceRule.parseJson(text);
    final descriptor = rule.descriptor;
    final saved = await repository.byId(SourceRepository.internalMetadataId);
    if (saved != null &&
        saved.ruleText == text &&
        saved.enabled &&
        saved.kind == SourceKind.builtin &&
        saved.name == descriptor.name &&
        saved.type == descriptor.type &&
        saved.lang == descriptor.lang &&
        saved.version == descriptor.version &&
        saved.repoUrl == null) {
      return;
    }
    await repository.upsert(
      id: descriptor.id,
      name: descriptor.name,
      type: descriptor.type,
      kind: SourceKind.builtin,
      ruleText: text,
      lang: descriptor.lang,
      version: descriptor.version,
      enabled: true,
    );
  }

  Future<bool> _hasCanonicalAge() async {
    final row = await repository.byId(KazumiRule.idForName('AGE'));
    if (row?.ruleText == null) return false;
    try {
      final rule = KazumiRule.parse(row!.ruleText!, allowDeprecated: true);
      // An edited rule with the same name but another host is not a duplicate.
      return rule.descriptor.id == row.id &&
          rule.descriptor.baseUrl == 'https://www.agedm.io/';
    } on RuleFormatException {
      return false;
    }
  }

  Future<bool> _retireLegacyAge() async {
    if (!await _hasCanonicalAge()) return false;
    final legacy = await repository.byId('age-anime');
    if (legacy == null ||
        legacy.kind != SourceKind.builtin ||
        legacy.name != 'AGE 番剧' ||
        legacy.version != '1.0.1' ||
        legacy.lang != 'zh' ||
        legacy.type != MediaType.anime ||
        legacy.repoUrl != null ||
        !_isPristineLegacyAge(legacy.ruleText)) {
      return false;
    }
    await repository.removeUnreferencedDefault(
      legacy,
      replacementId: KazumiRule.idForName('AGE'),
    );
    return true;
  }

  bool _disposed = false;

  /// Own JS engines for the lifetime of this registry. Refreshes reuse an
  /// unchanged script; replacements/removals cancel only the affected engine.
  void dispose() {
    _disposed = true;
    for (final cached in _scripts.values) {
      cached.instance.dispose();
    }
    _scripts.clear();
  }

  JsSource _script(String id, String text, SourceRule rule) {
    SourceHostFeatures.requireSupported(id, rule.requiresHost);
    if (_disposed) throw StateError('来源注册表已关闭');
    final previous = _scripts[id];
    if (previous?.text == text) return previous!.instance;
    previous?.instance.dispose();
    final source = (jsSourceFactory ?? JsSource.new)(
      rule: rule,
      runtime: (jsRuntimeFactory ?? createFlutterJsRuntime)(),
      http: http,
      requestOptions: jsRequestOptions == null
          ? null
          : () => jsRequestOptions!(id),
    );
    _scripts[id] = (text: text, instance: source);
    return source;
  }

  /// Packaged official Kazumi rules are pinned to KazumiRules
  /// 2967d7babafffa92dbf35fbcb69d0fd964139e63. Stable asset markers preserve
  /// removals; newer packaged bytes never replace an existing installation.
  static const officialKazumiNames = [
    '7sefun',
    'aafun',
    'AGE',
    'akianime',
    'baimao',
    'dalvdm',
    'DM84',
    'ezdmw',
    'giriGiriLove',
    'LMM',
    'mgnacg',
    'moonci',
    'mutefun',
    'MXdm',
    'sorani',
    'TvTFun',
    'xfdmneo',
    'xfdmnext',
  ];

  static List<String> get builtinRuleAssets => <String>[
    'assets/rules/bangumi-anime.json',
    for (final name in officialKazumiNames) 'assets/rules/kazumi-$name.json',
    'assets/rules/mangadex-api-js.json',
    if (developmentSourcesEnabled) ...<String>[
      'assets/rules/local-fixture.json',
      'assets/rules/local-fixture-anime.json',
      'assets/rules/local-fixture-novel.json',
      // JS 规则示例：与 local-fixture.json 解析同一站点，用于对照两种写法。
      'assets/rules/local-fixture-js.json',
    ],
  ];

  Future<SourceRegistrySnapshot> load() async {
    if (_disposed) throw StateError('来源注册表已关闭');
    await _ensureInternalMetadata();
    final canonicalAgeInstalled = await _retireLegacyAge();
    final rows = await repository.all();
    if (_disposed) throw StateError('来源注册表已关闭');
    final ids = <String>{};
    for (final row in rows) {
      if (!row.enabled) continue;
      final text = row.ruleText;
      if (text == null) continue;
      try {
        if (KazumiRule.recognizes(text)) continue;
        if (SourceRule.parseJson(text).isScript) ids.add(row.id);
      } on RuleFormatException {
        // Invalid/replaced rules no longer own their previous JS engine.
      }
    }
    for (final removed
        in _scripts.keys.where((id) => !ids.contains(id)).toList()) {
      _scripts.remove(removed)!.instance.dispose();
    }
    final entries = <SourceEntry>[];
    final failures = <SourceFailure>[...metadataFailures];

    for (final row in rows) {
      final text = row.ruleText;
      if (text == null || text.trim().isEmpty) {
        final adapter = builtinAdapters[row.id];
        if (adapter != null) {
          entries.add(
            SourceEntry(
              descriptor: adapter.descriptor.copyWith(kind: row.kind),
              source: adapter,
              enabled: row.enabled,
              canRemove: false,
            ),
          );
          continue;
        }
        failures.add(
          SourceFailure(
            id: row.id,
            name: row.name,
            lang: row.lang,
            type: row.type,
            canRemove: !builtinAdapters.containsKey(row.id),
            message: '仅有来源信息，尚未安装规则；请从来源目录安装兼容版本，也可移除此记录。书架与下载保留。',
          ),
        );
        continue;
      }
      SourceDescriptor? metadata;
      try {
        if (KazumiRule.recognizes(text)) {
          final rule = KazumiRule.parse(text, allowDeprecated: true);
          metadata = rule.descriptor;
          if (rule.descriptor.id != row.id) {
            throw const RuleFormatException('Kazumi 规则标识与保存的来源不一致');
          }
          entries.add(
            SourceEntry(
              descriptor: rule.descriptor.copyWith(kind: row.kind),
              source: KazumiSource(rule: rule, http: http),
              enabled: row.enabled,
              ruleText: text,
              repoUrl: row.repoUrl,
              canRemove: !builtinAdapters.containsKey(row.id),
            ),
          );
          continue;
        }
        final rule = SourceRule.parseJson(text);
        metadata = rule.descriptor;
        if (rule.isScript) {
          final ContentSource source = row.enabled
              ? _script(row.id, text, rule)
              : _DisabledScriptSource(
                  rule.descriptor.copyWith(
                    capabilities: const <SourceCapability>{},
                  ),
                );
          entries.add(
            SourceEntry(
              descriptor: source.descriptor.copyWith(kind: row.kind),
              source: source,
              enabled: row.enabled,
              ruleText: text,
              isRetiredDefault:
                  canonicalAgeInstalled &&
                  row.id == 'age-anime' &&
                  _isPristineLegacyAge(text),
              repoUrl: row.repoUrl,
              canRemove: !builtinAdapters.containsKey(row.id),
            ),
          );
          continue;
        }
        entries.add(
          SourceEntry(
            descriptor: rule.descriptor.copyWith(kind: row.kind),
            source:
                rule.descriptor.id == 'bangumi-anime' &&
                    rule.baseUrl == 'https://api.bgm.tv'
                ? BangumiSource(
                    rule: rule,
                    http: http,
                    publicClient: bangumiPublicClient,
                  )
                : DeclarativeSource(rule: rule, http: http),
            enabled: row.enabled,
            ruleText: text,
            repoUrl: row.repoUrl,
            canRemove: !builtinAdapters.containsKey(row.id),
          ),
        );
      } on RuleFormatException catch (error) {
        failures.add(
          SourceFailure(
            id: row.id,
            name: row.name,
            message: error.message,
            lang: metadata?.lang ?? row.lang,
            type: row.type,
            nsfw: metadata?.nsfw,
            canRemove: !builtinAdapters.containsKey(row.id),
          ),
        );
      } on SourceException catch (error) {
        failures.add(
          SourceFailure(
            id: row.id,
            name: row.name,
            message: error.userMessage,
            lang: metadata?.lang ?? row.lang,
            type: row.type,
            nsfw: metadata?.nsfw,
            canRemove: !builtinAdapters.containsKey(row.id),
          ),
        );
      } catch (error) {
        failures.add(
          SourceFailure(
            id: row.id,
            name: row.name,
            message: '$error',
            lang: metadata?.lang ?? row.lang,
            type: row.type,
            nsfw: metadata?.nsfw,
            canRemove: !builtinAdapters.containsKey(row.id),
          ),
        );
      }
    }

    for (final source in mihonAdapters) {
      entries.add(
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: source.isReady,
        ),
      );
    }

    return SourceRegistrySnapshot(entries: entries, failures: failures);
  }

  /// 把内置示例规则写进数据库（用户之后可以停用或删除）。
  ///
  /// [alreadySeeded] 记录的是**资产路径**（与 [builtinRuleAssets] 同一口径）：
  /// 返回本次已处理的路径：成功播种、已有来源或已有配置需显式安装的路径。
  /// 无效规则不记成功，下次启动重试。
  Future<Set<String>> seedBuiltins({required Set<String> alreadySeeded}) async {
    final seededNow = <String>{};
    // Older profiles have no tombstones for repository-only removals. Their
    // absence is not installation consent: new packaged sources remain fully
    // available through explicit catalog install/all, rather than resurrecting.
    final existingProfile =
        alreadySeeded.isNotEmpty ||
        (await repository.count(excludeInternal: true)) > 0;
    // Unlike removable playback rules, metadata is a required internal service.
    // Prior seeded markers (including deletions in older builds) cannot disable it.
    await _ensureInternalMetadata();
    const originalKazumiAssets = {
      'assets/rules/kazumi-7sefun.json',
      'assets/rules/kazumi-MXdm.json',
      'assets/rules/kazumi-DM84.json',
    };

    // 内置适配器：只补没播种过的行（ruleText 为空，实现在代码里）。
    for (final adapter in builtinAdapters.values) {
      final marker = 'builtin:${adapter.descriptor.id}';
      if (alreadySeeded.contains(marker)) continue;
      await repository.upsert(
        id: adapter.descriptor.id,
        name: adapter.descriptor.name,
        type: adapter.descriptor.type,
        kind: SourceKind.builtin,
        lang: adapter.descriptor.lang,
        version: adapter.descriptor.version,
        enabled: !defaultDisabledBuiltins.contains(adapter.descriptor.id),
      );
      seededNow.add(marker);
    }

    for (final asset in builtinRuleAssets) {
      if (alreadySeeded.contains(asset)) continue;
      if (existingProfile &&
          asset.startsWith('assets/rules/kazumi-') &&
          !originalKazumiAssets.contains(asset)) {
        seededNow.add(asset);
        continue;
      }
      try {
        final text = await _bundle.loadString(asset);
        final kazumi = KazumiRule.recognizes(text);
        final descriptor = kazumi
            ? KazumiRule.parse(text).descriptor
            : SourceRule.parseJson(text).descriptor;
        // Adding a packaged source must not overwrite a previously installed,
        // edited or disabled source. Upgrades use the catalog CAS installer.
        if (await repository.byId(descriptor.id) != null) {
          seededNow.add(asset);
          continue;
        }
        await repository.upsert(
          id: descriptor.id,
          name: descriptor.name,
          type: descriptor.type,
          kind: kazumi ? SourceKind.plugin : SourceKind.builtin,
          ruleText: text,
          lang: descriptor.lang,
          version: descriptor.version,
          repoUrl: kazumi ? KazumiRepository.defaultRepository : null,
        );
        seededNow.add(asset);
      } on RuleFormatException {
        // 随包的规则写错了属于开发期问题，不应阻塞启动；
        // 不记录该路径，下次启动还会重试（修好后自动出现）。
        continue;
      }
    }
    await _retireLegacyAge();
    return seededNow;
  }

  /// 从文本导入规则；校验通过后落库并返回解析结果。
  Future<SourceDescriptor> importFromText(
    String text, {
    String? repoUrl,
    bool enabled = true,
    bool allowDeprecated = false,
  }) async {
    if (text.trim().isEmpty) {
      throw const RuleFormatException('规则内容为空');
    }
    if (KazumiRule.recognizes(text)) {
      final rule = KazumiRule.parse(text, allowDeprecated: allowDeprecated);
      final old = await repository.byId(rule.descriptor.id);
      if (old != null && old.ruleText != text) {
        throw const RuleFormatException('已有同名 Kazumi 来源，请从番剧规则仓库安全更新');
      }
      await repository.replaceRule(
        expected: old,
        id: rule.descriptor.id,
        name: rule.descriptor.name,
        type: rule.descriptor.type,
        lang: rule.descriptor.lang,
        version: rule.descriptor.version!,
        ruleText: text,
        repoUrl: repoUrl ?? 'manual',
        enabledWhenNew: enabled && !rule.deprecated,
      );
      return rule.descriptor;
    }
    final rule = SourceRule.parseJson(text);
    SourceHostFeatures.requireSupported(rule.descriptor.id, rule.requiresHost);
    if (rule.descriptor.id == SourceRepository.internalMetadataId) {
      throw const RuleFormatException('Bangumi 资料由应用维护，不能导入替换');
    }
    await repository.upsert(
      id: rule.descriptor.id,
      name: rule.descriptor.name,
      type: rule.descriptor.type,
      kind: SourceKind.plugin,
      ruleText: text,
      lang: rule.descriptor.lang,
      version: rule.descriptor.version,
      repoUrl: repoUrl,
      enabled: enabled,
    );
    return rule.descriptor;
  }

  Future<void> setEnabled(String id, {required bool enabled}) async {
    await repository.setEnabled(id, enabled: enabled);
    if (!enabled) _scripts.remove(id)?.instance.dispose();
  }

  Future<void> remove(String id) async {
    if (builtinAdapters.containsKey(id)) {
      throw StateError('内置来源不能移除，可以停用');
    }
    await repository.remove(id);
    _scripts.remove(id)?.instance.dispose();
  }

  /// 把来源异常转换成可直接展示的文案（区分是哪个源出的问题）。
  static String describeError(SourceException error, String sourceName) =>
      '$sourceName：${error.userMessage}';
}
