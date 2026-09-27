import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/source_providers.dart';
import '../data/lns/lns_source.dart';

/// 取轻书架来源。
///
/// 轻书架是随包编译的内置适配器，但用户是否停用 / 移除只有注册表知道，
/// 所以页面每次都从注册表快照里取（与远端书架页同一做法）。
Future<LnsSource> loadLnsSource(WidgetRef ref) async {
  final snapshot = await ref.read(sourcesProvider.future);
  final entry = snapshot.entries
      .where((candidate) => candidate.descriptor.id == LnsSource.id)
      .firstOrNull;
  final source = entry?.source;
  if (source is! LnsSource) {
    throw StateError('未找到轻书架来源（可能已被移除或停用）');
  }
  return source;
}
