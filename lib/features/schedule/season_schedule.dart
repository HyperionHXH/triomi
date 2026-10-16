import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/http_client.dart';
import '../../core/source/source_providers.dart';
import '../detail/anime_filter_dialog.dart';
import '../detail/anime_info_repository.dart';
import '../discover/widgets/media_item_card.dart';

class SeasonSchedule extends ConsumerStatefulWidget {
  const SeasonSchedule({super.key});
  @override
  ConsumerState<SeasonSchedule> createState() => _SeasonScheduleState();
}

class _SeasonScheduleState extends ConsumerState<SeasonSchedule> {
  late AnimeFilter _filter = AnimeFilter(
    year: DateTime.now().year,
    quarter: (DateTime.now().month - 1) ~/ 3 + 1,
  );
  final _rows = <Map<Object?, Object?>>[];
  var _epoch = 0, _offset = 0, _weekday = 0;
  bool _busy = false, _more = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy && !reset || !_more && !reset) return;
    final epoch = reset ? ++_epoch : _epoch;
    final filter = _filter;
    setState(() {
      _busy = true;
      _error = null;
      if (reset) {
        _rows.clear();
        _offset = 0;
        _more = true;
      }
    });
    try {
      final response = await ref
          .read(sourceHttpClientProvider)
          .send(
            SourceRequest(
              url:
                  'https://api.bgm.tv/v0/search/subjects?limit=100&offset=$_offset',
              method: 'POST',
              headers: AnimeInfoRepository.headers,
              bodyType: RequestBodyType.json,
              body: jsonEncode(filter.body),
            ),
            sourceId: 'bangumi-anime',
          );
      if (!response.isSuccess) throw StateError('季度资料暂不可用');
      final raw = jsonDecode(response.body) as Map;
      final rows = raw['data'] as List;
      if (!mounted || epoch != _epoch) return;
      setState(() {
        final ids = _rows.map((r) => r['id']).toSet();
        _rows.addAll(
          rows.whereType<Map<Object?, Object?>>().where(
            (r) => r['type'] == 2 && r['nsfw'] != true && ids.add(r['id']),
          ),
        );
        _offset += rows.length;
        _more =
            rows.isNotEmpty &&
            (raw['total'] is num
                ? _offset < (raw['total'] as num)
                : rows.length >= 20);
      });
    } catch (_) {
      if (mounted && epoch == _epoch) setState(() => _error = '历史季暂不可用');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  int _day(Map<Object?, Object?> row) {
    const days = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    for (final field in (row['infobox'] as List? ?? [])) {
      if (field is Map && field['key'] == '放送星期') {
        final index = days.indexOf('${field['value']}');
        if (index >= 0) return index + 1;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .9,
      child: Column(
        children: [
          ListTile(
            title: Text(
              '${_filter.year ?? '全部年代'} · ${_filter.quarter == null ? '全年' : '${_filter.quarter}季度'}时间表',
            ),
            subtitle: const Text('按上游放送星期分类；未提供星期的条目保留为未注明'),
            trailing: IconButton(
              tooltip: '选择历史季',
              icon: const Icon(Icons.date_range),
              onPressed: () async {
                final filter = await showDialog<AnimeFilter>(
                  context: context,
                  builder: (_) => AnimeFilterDialog(initial: _filter),
                );
                if (!mounted || filter == null) return;
                _filter = filter;
                unawaited(_load(reset: true));
              },
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var day = 0; day <= 7; day++)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ChoiceChip(
                      label: Text(
                        day == 0
                            ? '全部'
                            : '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
                      ),
                      selected: day == _weekday,
                      onSelected: (_) => setState(() => _weekday = day),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: MediaItemCollection(
              items: [
                for (final row in _rows)
                  if (_weekday == 0 || _day(row) == _weekday) bangumiItem(row),
              ],
              sourceName: 'Bangumi 历史季',
              preferGrid: true,
              badgeOf: (item) {
                final row = _rows.firstWhere(
                  (r) => '${r['id']}' == item.remoteId,
                );
                final day = _day(row);
                return day == 0
                    ? '星期未注明'
                    : '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}';
              },
              footer: Center(
                child: _busy
                    ? const CircularProgressIndicator()
                    : _error != null
                    ? TextButton(onPressed: _load, child: Text('$_error · 重试'))
                    : _more
                    ? TextButton(
                        onPressed: _load,
                        child: const Text('加载更多本季作品'),
                      )
                    : const Text('本季作品已加载'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
