import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/bangumi_public_client.dart';
import '../../core/source/http_client.dart';
import '../../core/storage/preferences.dart';
import '../detail/anime_info_repository.dart';
import '../discover/widgets/media_item_card.dart';
import 'data/schedule_providers.dart';

/// Current and historical seasons share one retained calendar state. Only the
/// upstream broadcast weekday is used; absent weekdays are never invented.
class SeasonSchedule extends ConsumerStatefulWidget {
  const SeasonSchedule({super.key, this.embedded = false});
  final bool embedded;

  @override
  ConsumerState<SeasonSchedule> createState() => _SeasonScheduleState();
}

class _SeasonScheduleState extends ConsumerState<SeasonSchedule> {
  int _year = DateTime.now().year;
  int _quarter = (DateTime.now().month - 1) ~/ 3 + 1;
  final _rows = <Map<String, Object?>>[];
  final _scrollController = ScrollController();
  int _generation = 0, _offset = 0;
  int _weekday = DateTime.now().weekday;
  bool _busy = false, _more = true;
  String? _error, _calendarError;
  SourceRequestCancellation? _owner;
  bool _calendarReady = false;
  ProviderSubscription<BangumiPublicClient>? _publicClient;

  bool get _currentSeason {
    final now = DateTime.now();
    return _year == now.year && _quarter == (now.month - 1) ~/ 3 + 1;
  }

  @override
  void initState() {
    super.initState();
    final saved = ref
        .read(preferencesProvider)
        .get<List<Object?>>('anime.calendar.season');
    if (saved != null && saved.length == 2) {
      final year = saved[0];
      final quarter = saved[1];
      if (year is int &&
          year >= 1900 &&
          year <= 2100 &&
          quarter is int &&
          quarter >= 1 &&
          quarter <= 4) {
        _year = year;
        _quarter = quarter;
      }
    }
    final weekday = ref
        .read(preferencesProvider)
        .get<int>('anime.calendar.weekday');
    if (weekday != null && weekday >= 1 && weekday <= 7) _weekday = weekday;
    _publicClient = ref.listenManual(bangumiPublicClientProvider, (
      previous,
      next,
    ) {
      if (!mounted || identical(previous, next)) return;
      _calendarReady = false;
      unawaited(_load(reset: true, refresh: true));
    });
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _generation++;
    _owner?.cancel();
    _publicClient?.close();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false, bool refresh = false}) async {
    if (_busy && !reset || !_more && !reset) return;
    final generation = reset ? ++_generation : _generation;
    if (reset) _owner?.cancel();
    final owner = _owner = SourceRequestCancellation();
    final year = _year;
    final quarter = _quarter;
    final currentSeason = _currentSeason;
    setState(() {
      _busy = true;
      _error = currentSeason && !refresh ? _calendarError : null;
      if (reset) {
        _offset = 0;
        _more = true;
      }
    });
    bool active() => mounted && !owner.cancelled && generation == _generation;
    var fetchingWeek = false;
    try {
      var offset = reset ? 0 : _offset;
      if (currentSeason) {
        if (!_calendarReady || refresh) {
          fetchingWeek = true;
          if (refresh) ref.invalidate(weeklyScheduleProvider);
          final days = await ref.read(weeklyScheduleProvider.future);
          if (!active()) return;
          setState(() {
            _rows.clear();
            for (final day in days) {
              for (final entry in day.items) {
                _rows.add({
                  'id': entry.id,
                  'type': 2,
                  'name_cn': entry.title,
                  'images': {'large': entry.coverUrl},
                  'date': entry.airDate,
                  'rating': {
                    'score': entry.rating,
                    'rank': entry.rank,
                    'total': entry.votes,
                  },
                  'weekday': {'id': day.weekday},
                });
              }
            }
            _calendarReady = true;
            _calendarError = null;
            _more = false;
          });
          fetchingWeek = false;
        }
        return;
      } else if (reset) {
        setState(() {
          _rows.clear();
          _calendarReady = false;
        });
      }
      var more = true;
      while (more) {
        final page = await owner.run(
          () => ref
              .read(bangumiPublicClientProvider)
              .search(
                filter: AnimePublicFilter(year: year, quarter: quarter),
                offset: offset,
                limit: 100,
              ),
        );
        if (!active()) return;
        if (page.hasMore && page.nextOffset <= offset) {
          throw StateError('季度资料分页未前进，请重试');
        }
        setState(() {
          final ids = _rows.map((row) => '${row['id']}').toSet();
          for (final row in page.rows) {
            if (row['type'] != 2 || row['nsfw'] == true) continue;
            if (ids.add('${row['id']}')) {
              _rows.add(row);
            }
          }
          _offset = page.nextOffset;
          _more = page.hasMore;
        });
        offset = page.nextOffset;
        more = page.hasMore;
      }
    } catch (error) {
      if (active()) {
        setState(() {
          _error = '公开放送资料暂不可用：$error';
          if (fetchingWeek) _calendarError = _error;
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  int _day(Map<String, Object?> row) {
    final weekday = row['weekday'];
    if (weekday is Map && weekday['id'] is num) {
      return (weekday['id'] as num).toInt();
    }
    const days = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    for (final field in (row['infobox'] as List? ?? const [])) {
      if (field is Map && (field['key'] == '放送星期' || field['key'] == '播放星期')) {
        final index = days.indexOf('${field['value']}');
        if (index >= 0) return index + 1;
      }
    }
    return 0;
  }

  void _setSeason(int year, int quarter) {
    if (year < 1900 || year > 2100) return;
    if (year == _year && quarter == _quarter) return;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _year = year;
      _quarter = quarter;
      _rows.clear();
      _calendarReady = false;
      _calendarError = null;
    });
    unawaited(
      ref.read(preferencesProvider).set('anime.calendar.season', [
        _year,
        _quarter,
      ]),
    );
    unawaited(_load(reset: true));
  }

  void _stepSeason(int step) {
    final index = _year * 4 + _quarter - 1 + step;
    _setSeason(index ~/ 4, index % 4 + 1);
  }

  void _setWeekday(int day) {
    // The shared collection retains scroll state across rebuilds. A new day's
    // full list must begin at its first title, not the previous day's tail.
    if (day == _weekday) return;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() => _weekday = day);
    unawaited(ref.read(preferencesProvider).set('anime.calendar.weekday', day));
  }

  @override
  Widget build(BuildContext context) {
    // Retain the weekly provider until the calendar leaves the current season.
    if (_currentSeason) ref.watch(weeklyScheduleProvider);
    final visible = _rows
        .where((row) {
          final day = _day(row);
          // The calendar has seven real weekday buckets only. Do not surface
          // upstream records whose broadcast day is unknown as a fake tab.
          if (day == 0 || day != _weekday) return false;
          return true;
        })
        .toList(growable: false);
    if (_currentSeason) {
      double number(Map<String, Object?> row, String key) {
        final rating = row['rating'];
        return rating is Map ? double.tryParse('${rating[key]}') ?? 0 : 0;
      }

      visible.sort((a, b) => number(b, 'total').compareTo(number(a, 'total')));
    }
    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              IconButton(
                tooltip: '上一季度',
                onPressed: _year == 1900 && _quarter == 1
                    ? null
                    : () => _stepSeason(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '$_year · $_quarter季度',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: '下一季度',
                onPressed: _year == 2100 && _quarter == 4
                    ? null
                    : () => _stepSeason(1),
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                tooltip: '当前季度',
                onPressed: _currentSeason
                    ? null
                    : () {
                        final now = DateTime.now();
                        _setSeason(now.year, (now.month - 1) ~/ 3 + 1);
                      },
                icon: const Icon(Icons.today_outlined),
              ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final scaler = MediaQuery.textScalerOf(context);
            final tabWidth = (scaler.scale(14) * 2 + 20).clamp(48.0, 120.0);
            final scrollable = constraints.maxWidth - 32 < tabWidth * 7;
            final buttons = [
              for (var day = 1; day <= 7; day++)
                SizedBox(
                  width: scrollable
                      ? tabWidth
                      : (constraints.maxWidth - 32) / 7,
                  child: Semantics(
                    selected: day == _weekday,
                    inMutuallyExclusiveGroup: true,
                    label: '星期${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        backgroundColor: day == _weekday
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        foregroundColor: day == _weekday
                            ? Theme.of(context).colorScheme.onSecondaryContainer
                            : null,
                      ),
                      onPressed: () => _setWeekday(day),
                      child: Text(
                        '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
                ),
            ];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: scrollable
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: buttons),
                    )
                  : Row(children: buttons),
            );
          },
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true, refresh: true),
            child: MediaItemCollection(
              controller: _scrollController,
              items: [for (final row in visible) bangumiItem(row)],
              sourceName: 'Bangumi · 公开兼容季度资料',
              preferGrid: true,
              showMetadata: false,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              badgeOf: (item) {
                final row = visible.firstWhere(
                  (row) => '${row['id']}' == item.remoteId,
                );
                final day = _day(row);
                return '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}';
              },
              footer: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _busy
                      ? const CircularProgressIndicator()
                      : _error != null
                      ? TextButton(
                          onPressed: () => _load(reset: true, refresh: true),
                          child: Text('$_error · 重试'),
                        )
                      : Text(
                          visible.isEmpty
                              ? '没有符合条件的作品'
                              : _currentSeason && _calendarReady
                              ? '本周作品已加载'
                              : '本季作品已加载',
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return widget.embedded
        ? body
        : SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .9,
              child: body,
            ),
          );
  }
}
