import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/source_exception.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_providers.dart';
import '../data/lk/lk_source.dart';

/// 取某个来源的账号域能力（当前只有轻之国度实现）。
///
/// 来源虽然是随包编译的内置适配器，但是否被用户停用 / 移除只有注册表知道，
/// 所以页面每次都从注册表快照里取（与远端书架页同一做法）。
/// 返回能力接口而不是具体类：页面只依赖契约，测试可以注入替身。
Future<AccountProfileProvider> loadAccountSource(
  WidgetRef ref,
  String sourceId,
) async {
  final snapshot = await ref.read(sourcesProvider.future);
  final entry = snapshot.entries
      .where((candidate) => candidate.descriptor.id == sourceId)
      .firstOrNull;
  final source = entry?.source;
  if (source is! AccountProfileProvider) {
    throw StateError('来源 $sourceId 不支持账号功能（可能已被移除或停用）');
  }
  return source;
}

/// 轻之国度来源的账号域能力。
Future<AccountProfileProvider> loadLkAccount(WidgetRef ref) =>
    loadAccountSource(ref, LkSource.id);

/// 错误文案：来源错误用面向用户的说明，其他错误回退到 `toString`。
String describeSourceError(Object error) =>
    error is SourceException ? error.userMessage : '$error';
