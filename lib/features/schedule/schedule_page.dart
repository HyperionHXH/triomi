import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/schedule_providers.dart';
import 'season_schedule.dart';

@visibleForTesting
MediaItem scheduleEntryToItem(ScheduleEntry entry) => MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: entry.id,
  type: MediaType.anime,
  title: entry.title,
  url: entry.url ?? 'https://bgm.tv/subject/${entry.id}',
  coverUrl: resolveScheduleCover(entry.coverUrl),
  rating: entry.rating,
);

/// Calendar is also directly addressable without introducing another follows
/// destination; the anime workspace owns the retained three-tab experience.
class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const PageScaffold(title: '时间表', child: SeasonSchedule(embedded: true));
}
