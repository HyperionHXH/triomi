import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences.dart';
import '../../../core/text/zh_converter.dart';

const bool danmakuFeatureEnabled = true;

/// A validated rule. Regex evaluation happens when the episode/filter changes,
/// never in the animation ticker. The deliberately restricted regex grammar
/// permits one variable repetition and no groups, alternatives or backreferences.
class DanmakuShieldRule {
  const DanmakuShieldRule({
    required this.text,
    this.isRegex = false,
    this.enabled = true,
  });

  static const maxRules = 256;
  static const maxLength = 128;
  static const maxTextLength = 512;
  final String text;
  final bool isRegex;
  final bool enabled;

  DanmakuShieldRule copyWith({String? text, bool? isRegex, bool? enabled}) =>
      DanmakuShieldRule(
        text: text ?? this.text,
        isRegex: isRegex ?? this.isRegex,
        enabled: enabled ?? this.enabled,
      );

  static DanmakuShieldRule parse(String input) {
    final text = input.trim();
    final regex =
        text.length >= 2 && text.startsWith('/') && text.endsWith('/');
    return DanmakuShieldRule(
      text: regex ? text.substring(1, text.length - 1) : text,
      isRegex: regex,
    );
  }

  String? get validationError {
    if (text.trim().isEmpty) return '规则不能为空';
    if (text.length > maxLength) return '规则最多 $maxLength 个字符';
    if (!isRegex) return null;
    var inClass = false;
    var variableRepeats = 0;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == r'\') {
        if (++i >= text.length) return '正则表达式末尾缺少转义字符';
        if ('123456789kgpP'.contains(text[i])) return '不支持反向引用或扩展字符属性';
        continue;
      }
      if (char == '[' && !inClass) {
        inClass = true;
        continue;
      }
      if (char == ']' && inClass) {
        inClass = false;
        continue;
      }
      if (inClass) continue;
      if ('()|'.contains(char)) return '安全正则不支持分组、择一或环视';
      if ('*+?'.contains(char)) variableRepeats++;
      if (char == '{') {
        final end = text.indexOf('}', i + 1);
        if (end < 0) return '重复次数缺少右括号';
        final range = text.substring(i + 1, end).split(',');
        if (range.length > 2) return '重复次数格式无效';
        final min = int.tryParse(range.first);
        final max = range.length == 1 ? min : int.tryParse(range.last);
        if (min == null || max == null || min < 0 || max < min || max > 64) {
          return '重复次数须为 0–64 的有限范围';
        }
        if (min != max) variableRepeats++;
        i = end;
      }
      if (variableRepeats > 1) return '安全正则最多允许一个可变重复项';
    }
    try {
      RegExp(text);
    } on FormatException {
      return '正则表达式无效';
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'text': text,
    'isRegex': isRegex,
    'enabled': enabled,
  };

  static DanmakuShieldRule? fromJson(Object? value) {
    if (value is String) return parse(value);
    if (value is! Map || value['text'] is! String) return null;
    return DanmakuShieldRule(
      text: value['text'] as String,
      isRegex: value['isRegex'] == true,
      enabled: value['enabled'] != false,
    );
  }
}

class _ShieldMatcher {
  _ShieldMatcher(DanmakuSettings settings)
    : keywords = [
        ...settings.blockedWords.where((word) => word.isNotEmpty),
        for (final rule in settings.shieldRules)
          if (rule.enabled && !rule.isRegex && rule.validationError == null)
            rule.text,
      ],
      regexes = [
        for (final rule in settings.shieldRules)
          if (rule.enabled && rule.isRegex && rule.validationError == null)
            RegExp(rule.text),
      ];
  final List<String> keywords;
  final List<RegExp> regexes;

  final Map<String, bool> _results = {};
  bool matches(String text) {
    final cached = _results[text];
    if (cached != null) return cached;
    final matches =
        keywords.any(text.contains) ||
        regexes.any((rule) => rule.hasMatch(text));
    if (_results.length >= 2048) _results.clear();
    _results[text] = matches;
    return matches;
  }
}

/// Display settings shared by the settings page and the live player panel.
/// Existing fontScale/speedScale keys remain readable and writable for backups.
class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = true,
    this.opacity = 0.9,
    this.fontScale = 1,
    this.speedScale = 1,
    this._fontSize,
    this._durationSeconds,
    this.area = 1,
    this.lineHeight = 1.6,
    this.fontWeight = 4,
    this.followVideoRate = true,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.showColor = true,
    this.outline = true,
    this.outlineWidth = 1,
    this.massive = false,
    this.maxActive = 120,
    this.mergeDuplicates = false,
    this.conversion = ZhConversionMode.off,
    this.blockedWords = const <String>[],
    this.blockedUsers = const <String>[],
    this.shieldRules = const <DanmakuShieldRule>[],
  });

  final bool enabled;
  final double opacity;
  final double fontScale;
  final double speedScale;
  final double? _fontSize;
  final double? _durationSeconds;
  double get fontSize => _bounded(_fontSize ?? 16 * fontScale, 10, 48, 16);
  double get durationSeconds =>
      _bounded(_durationSeconds ?? 9 / speedScale, 2, 16, 9);
  final double area;
  final double lineHeight;
  final int fontWeight;
  final bool followVideoRate;
  final bool showScroll;
  final bool showTop;
  final bool showBottom;
  final bool showColor;
  final bool outline;
  final double outlineWidth;
  final bool massive;
  final int maxActive;
  final bool mergeDuplicates;
  final ZhConversionMode conversion;
  final List<String> blockedWords;
  final List<String> blockedUsers;
  final List<DanmakuShieldRule> shieldRules;

  static const duplicateWindowMs = 5000;
  static final _matchers = Expando<_ShieldMatcher>();
  int get scrollDurationMs => (durationSeconds * 1000).round();
  int get staticDurationMs => _durationSeconds == null
      ? (_bounded(4.2 / speedScale, 2, 16, 4.2) * 1000).round()
      : scrollDurationMs;

  DanmakuSettings copyWith({
    bool? enabled,
    double? opacity,
    double? fontScale,
    double? speedScale,
    double? fontSize,
    double? durationSeconds,
    double? area,
    double? lineHeight,
    int? fontWeight,
    bool? followVideoRate,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    bool? showColor,
    bool? outline,
    double? outlineWidth,
    bool? massive,
    int? maxActive,
    bool? mergeDuplicates,
    ZhConversionMode? conversion,
    List<String>? blockedWords,
    List<String>? blockedUsers,
    List<DanmakuShieldRule>? shieldRules,
  }) => DanmakuSettings(
    enabled: enabled ?? this.enabled,
    opacity: _bounded(opacity ?? this.opacity, 0.1, 1, 0.9),
    fontScale: _bounded(fontScale ?? this.fontScale, 0.1, 3, 1),
    speedScale: _bounded(speedScale ?? this.speedScale, 0.5, 2, 1),
    fontSize: fontSize ?? (fontScale == null ? _fontSize : null),
    durationSeconds:
        durationSeconds ?? (speedScale == null ? _durationSeconds : null),
    area: _bounded(area ?? this.area, 0, 1, 1),
    lineHeight: _bounded(lineHeight ?? this.lineHeight, 0, 3, 1.6),
    fontWeight: (fontWeight ?? this.fontWeight).clamp(1, 9).toInt(),
    followVideoRate: followVideoRate ?? this.followVideoRate,
    showScroll: showScroll ?? this.showScroll,
    showTop: showTop ?? this.showTop,
    showBottom: showBottom ?? this.showBottom,
    showColor: showColor ?? this.showColor,
    outline: outline ?? this.outline,
    outlineWidth: _bounded(outlineWidth ?? this.outlineWidth, 0.1, 3, 1),
    massive: massive ?? this.massive,
    maxActive: (maxActive ?? this.maxActive).clamp(20, 300).toInt(),
    mergeDuplicates: mergeDuplicates ?? this.mergeDuplicates,
    conversion: conversion ?? this.conversion,
    blockedWords: List.unmodifiable(blockedWords ?? this.blockedWords),
    blockedUsers: List.unmodifiable(blockedUsers ?? this.blockedUsers),
    shieldRules: List.unmodifiable(
      (shieldRules ?? this.shieldRules).take(DanmakuShieldRule.maxRules),
    ),
  );

  bool filters(String text, {String? user}) {
    if (text.length > DanmakuShieldRule.maxTextLength) return true;
    if (user != null && user.isNotEmpty && blockedUsers.contains(user)) {
      return true;
    }
    final matcher = _matchers[this] ??= _ShieldMatcher(this);
    return matcher.matches(text);
  }

  /// Reset appearance/playback only; all legacy and new block rules survive.
  DanmakuSettings restoreDefaults() => DanmakuSettings(
    blockedWords: List.unmodifiable(blockedWords),
    blockedUsers: List.unmodifiable(blockedUsers),
    shieldRules: List.unmodifiable(shieldRules),
  );

  String exportShieldRules() => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'rules': [
      for (final word in blockedWords) DanmakuShieldRule(text: word).toJson(),
      for (final rule in shieldRules) rule.toJson(),
    ],
  });

  /// JSON list/object or one Kazumi-style keyword /regex/ per line.
  /// Invalid imports are atomic: nothing is changed until every rule is valid.
  DanmakuSettings importShieldRules(String input) {
    if (input.length > 128 * 1024) throw const FormatException('导入内容过大');
    final trimmed = input.trim();
    Object? decoded;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      decoded = jsonDecode(trimmed);
      if (decoded is Map) decoded = decoded['rules'];
      if (decoded is! List) throw const FormatException('缺少规则列表');
    } else {
      decoded = const LineSplitter()
          .convert(input)
          .where((line) => line.trim().isNotEmpty)
          .toList();
    }
    final imported = <DanmakuShieldRule>[];
    for (final value in decoded as List) {
      final rule = DanmakuShieldRule.fromJson(value);
      final error = rule?.validationError;
      if (rule == null || error != null) {
        throw FormatException(error ?? '规则格式无效');
      }
      if (blockedWords.contains(rule.text) && !rule.isRegex) continue;
      if ([
        ...shieldRules,
        ...imported,
      ].any((item) => item.text == rule.text && item.isRegex == rule.isRegex)) {
        continue;
      }
      imported.add(rule);
      if (shieldRules.length + imported.length > DanmakuShieldRule.maxRules) {
        throw const FormatException('最多保存 256 条屏蔽规则');
      }
    }
    return copyWith(shieldRules: [...shieldRules, ...imported]);
  }

  Map<String, Object?> toJson() => {
    'danmaku.enabled': enabled,
    'danmaku.opacity': _bounded(opacity, 0.1, 1, 0.9),
    'danmaku.fontScale': _bounded(fontScale, 0.1, 3, 1),
    'danmaku.speedScale': _bounded(speedScale, 0.5, 2, 1),
    if (_fontSize != null) 'danmaku.fontSize': fontSize,
    if (_durationSeconds != null) 'danmaku.durationSeconds': durationSeconds,
    'danmaku.area': _bounded(area, 0, 1, 1),
    'danmaku.lineHeight': _bounded(lineHeight, 0, 3, 1.6),
    'danmaku.fontWeight': fontWeight.clamp(1, 9),
    'danmaku.followVideoRate': followVideoRate,
    'danmaku.showScroll': showScroll,
    'danmaku.showTop': showTop,
    'danmaku.showBottom': showBottom,
    'danmaku.showColor': showColor,
    'danmaku.outline': outline,
    'danmaku.outlineWidth': _bounded(outlineWidth, 0.1, 3, 1),
    'danmaku.massive': massive,
    'danmaku.maxActive': maxActive.clamp(20, 300),
    'danmaku.mergeDuplicates': mergeDuplicates,
    'danmaku.conversion': conversion.name,
    'danmaku.blockedWords': blockedWords,
    'danmaku.blockedUsers': blockedUsers,
    'danmaku.shieldRules': [for (final rule in shieldRules) rule.toJson()],
  };

  static const _keys = [
    'enabled',
    'opacity',
    'fontScale',
    'speedScale',
    'fontSize',
    'durationSeconds',
    'area',
    'lineHeight',
    'fontWeight',
    'followVideoRate',
    'showScroll',
    'showTop',
    'showBottom',
    'showColor',
    'outline',
    'outlineWidth',
    'massive',
    'maxActive',
    'mergeDuplicates',
    'conversion',
    'blockedWords',
    'blockedUsers',
    'shieldRules',
  ];

  static DanmakuSettings fromJson(Map<String, Object?> json) {
    Object? value(String key) => json['danmaku.$key'];
    double number(String key, double fallback) =>
        value(key) is num ? (value(key) as num).toDouble() : fallback;
    bool flag(String key, bool fallback) =>
        value(key) is bool ? value(key) as bool : fallback;
    List<String> strings(String key) => [
      if (value(key) is List)
        for (final item in value(key) as List)
          if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
    final conversion = ZhConversionMode.values.where(
      (mode) => mode.name == value('conversion'),
    );
    final rawRules = value('shieldRules');
    return DanmakuSettings(
      enabled: flag('enabled', true),
      opacity: number('opacity', 0.9),
      fontScale: _bounded(number('fontScale', 1), 0.1, 3, 1),
      speedScale: _bounded(number('speedScale', 1), 0.5, 2, 1),
      fontSize: value('fontSize') is num ? number('fontSize', 16) : null,
      durationSeconds: value('durationSeconds') is num
          ? number('durationSeconds', 9)
          : null,
      area: number('area', 1),
      lineHeight: number('lineHeight', 1.6),
      fontWeight: _bounded(number('fontWeight', 4), 1, 9, 4).round(),
      followVideoRate: flag('followVideoRate', true),
      showScroll: flag('showScroll', true),
      showTop: flag('showTop', true),
      showBottom: flag('showBottom', true),
      showColor: flag('showColor', true),
      outline: flag('outline', true),
      outlineWidth: number('outlineWidth', 1),
      massive: flag('massive', false),
      maxActive: _bounded(number('maxActive', 120), 20, 300, 120).round(),
      mergeDuplicates: flag('mergeDuplicates', false),
      conversion: conversion.isEmpty ? ZhConversionMode.off : conversion.first,
      blockedWords: strings('blockedWords'),
      blockedUsers: strings('blockedUsers'),
      shieldRules: [
        if (rawRules is List)
          for (final raw in rawRules.take(DanmakuShieldRule.maxRules))
            if (DanmakuShieldRule.fromJson(raw) case final rule?)
              // Preserve unsafe/imported rules disabled and editable, never run them.
              rule.validationError == null
                  ? rule
                  : rule.copyWith(enabled: false),
      ],
    ).copyWith();
  }

  static DanmakuSettings load(Preferences preferences) => fromJson({
    for (final key in _keys)
      'danmaku.$key': preferences.get<Object?>('danmaku.$key'),
  });

  Future<void> save(Preferences preferences) async {
    final values = toJson();
    for (final key in _keys) {
      final fullKey = 'danmaku.$key';
      if (values.containsKey(fullKey)) {
        await preferences.set(fullKey, values[fullKey]);
      } else {
        await preferences.remove(fullKey);
      }
    }
  }

  static double _bounded(
    double value,
    double min,
    double max,
    double fallback,
  ) => value.isFinite ? value.clamp(min, max).toDouble() : fallback;
}

class DanmakuSettingsController extends Notifier<DanmakuSettings> {
  Future<void> _saving = Future<void>.value();

  @override
  DanmakuSettings build() =>
      DanmakuSettings.load(ref.watch(preferencesProvider));

  Future<void> update(DanmakuSettings next) {
    final normalized = next.copyWith();
    state = normalized;
    final preferences = ref.read(preferencesProvider);
    // Keep rapid live slider writes ordered; an earlier failure cannot prevent
    // subsequent user edits from being saved.
    _saving = _saving.then(
      (_) => normalized.save(preferences),
      onError: (Object _, StackTrace _) => normalized.save(preferences),
    );
    return _saving;
  }

  Future<void> restoreDefaults() => update(state.restoreDefaults());
}

final danmakuSettingsProvider =
    NotifierProvider<DanmakuSettingsController, DanmakuSettings>(
      DanmakuSettingsController.new,
    );
