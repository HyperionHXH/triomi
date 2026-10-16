import 'dart:collection';
import 'dart:convert';

/// A stored snapshot includes the original labels/options, never just indices.
List<Map<String, Object?>> decodeMangaFilters(String json) {
  final decoded = jsonDecode(json);
  final Object? rows;
  if (decoded is Map) {
    if (decoded['version'] != 1) {
      throw const FormatException('保存筛选格式不受支持，请重新选择；原记录已保留');
    }
    rows = decoded['filters'];
  } else {
    rows = decoded; // Existing backups stored the complete FilterList directly.
  }
  if (rows is! List) throw const FormatException('保存筛选格式无效，原记录已保留');
  List<Map<String, Object?>> parseRows(List<Object?> values) => [
    for (final value in values)
      (() {
        if (value is! Map) throw const FormatException('保存筛选条目无效，原记录已保留');
        final row = Map<String, Object?>.from(value);
        if (row['name'] is! String ||
            row['type'] is! String ||
            (row['values'] != null && row['values'] is! List)) {
          throw const FormatException('保存筛选结构无效，原记录已保留');
        }
        if (row['type'] == 'group') {
          if (row['state'] is! List) throw const FormatException('保存筛选分组无效');
          row['state'] = parseRows(row['state'] as List);
        }
        return row;
      })(),
  ];
  return parseRows(rows);
}

List<Map<String, Object?>> copyMangaFilters(List<Map<String, Object?>> rows) =>
    decodeMangaFilters(jsonEncode(rows));

Object? _shape(Map<String, Object?> row) => {
  for (final entry in row.entries)
    if (entry.key != 'state') entry.key: entry.value,
  if (row['type'] == 'group')
    'children': [
      for (final child in row['state'] as List)
        _shape(Map<String, Object?>.from(child as Map)),
    ],
};

Object? _canonical(Object? value) {
  if (value is Map) {
    return SplayTreeMap<String, Object?>.from({
      for (final entry in value.entries)
        '${entry.key}': _canonical(entry.value),
    });
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String mangaFilterFingerprint(List<Map<String, Object?>> filters) =>
    jsonEncode(_canonical(filters));

/// Reject the whole snapshot on shape change; partial/index-based merging can
/// silently turn an old inclusion into a different option after an APK update.
List<Map<String, Object?>> restoreMangaFilters(
  List<Map<String, Object?>> fresh,
  List<Map<String, Object?>> saved,
) {
  if (saved.isEmpty) return copyMangaFilters(fresh);
  if (jsonEncode(_canonical(fresh.map(_shape).toList())) !=
      jsonEncode(_canonical(saved.map(_shape).toList()))) {
    throw const FormatException('来源筛选已改变，请重新选择。已保存搜索及原条件保留。');
  }
  void validate(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      final state = row['state'];
      final values = row['values'] as List? ?? const [];
      switch (row['type']) {
        case 'group':
          if (state is! List) throw const FormatException('筛选分组无效');
          validate([
            for (final child in state) Map<String, Object?>.from(child as Map),
          ]);
        case 'select':
          if (state is! int || state < 0 || state >= values.length) {
            throw const FormatException('筛选选项已失效，请重新选择');
          }
        case 'tri':
          if (state is! int || state < 0 || state > 2) {
            throw const FormatException('包含/排除筛选无效');
          }
        case 'check':
          if (state is! bool) throw const FormatException('勾选筛选无效');
        case 'text':
          if (state is! String) throw const FormatException('文本筛选无效');
        case 'multi':
          if (state is! List || state.any((v) => !values.contains(v))) {
            throw const FormatException('多选筛选已失效，请重新选择');
          }
        case 'sort':
          if (state != null &&
              (state is! Map ||
                  state['index'] is! int ||
                  (state['index'] as int) < 0 ||
                  (state['index'] as int) >= values.length ||
                  state['ascending'] is! bool)) {
            throw const FormatException('排序筛选已失效，请重新选择');
          }
      }
    }
  }

  validate(saved);
  return copyMangaFilters(saved);
}

typedef MangaFilterSummary = ({
  String label,
  List<int> path,
  Object? defaultState,
  String? selectedValue,
});

/// Summaries refer to original tree paths; deleting one never clears siblings.
List<MangaFilterSummary> mangaFilterSummaries(
  List<Map<String, Object?>> applied,
  List<Map<String, Object?>> defaults,
) {
  if (applied.length != defaults.length) return const [];
  final result = <MangaFilterSummary>[];
  void visit(
    List<Map<String, Object?>> rows,
    List<Map<String, Object?>> baseline,
    List<int> path,
    String group,
  ) {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i], original = baseline[i];
      final name = '$group${row['name'] ?? ''}';
      final nextPath = [...path, i];
      final state = row['state'];
      if (row['type'] == 'group') {
        visit(
          [
            for (final child in state as List)
              Map<String, Object?>.from(child as Map),
          ],
          [
            for (final child in original['state'] as List)
              Map<String, Object?>.from(child as Map),
          ],
          nextPath,
          '$name / ',
        );
        continue;
      }
      if (jsonEncode(_canonical(state)) ==
          jsonEncode(_canonical(original['state']))) {
        continue;
      }
      final values = row['values'] as List? ?? const [];
      String? summary;
      switch (row['type']) {
        case 'multi':
          for (final value in state as List) {
            result.add((
              label: '$name：$value',
              path: nextPath,
              defaultState: original['state'],
              selectedValue: '$value',
            ));
          }
          if (state.isEmpty) summary = '未选择';
        case 'check':
          summary = state == true ? '是' : '否';
        case 'tri':
          summary = ['不限', '包含', '排除'][state as int];
        case 'select':
          summary = '${values[state as int]}';
        case 'text':
          summary = '$state';
        case 'sort':
          summary = state is Map
              ? '${values[state['index'] as int]} · ${state['ascending'] == true ? '升序' : '降序'}'
              : '默认排序';
      }
      if (summary != null) {
        result.add((
          label: '$name：$summary',
          path: nextPath,
          defaultState: original['state'],
          selectedValue: null,
        ));
      }
    }
  }

  visit(applied, defaults, const [], '');
  return result;
}
