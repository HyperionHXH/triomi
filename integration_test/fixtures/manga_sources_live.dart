/// Stable public identities, not HTTP responses or image fixtures. Every listing,
/// detail, chapter and decoded page in the live suite comes from the network.
/// Historical references select ordinary works instead of arbitrary trending
/// results; no adult-domain switch, login, quota bypass or paid unlock is used.
class MangaSourceLiveCase {
  const MangaSourceLiveCase({
    required this.id,
    required this.query,
    this.remoteId,
    this.title,
    this.url,
    this.chapterId,
    this.titlePattern,
    this.canonicalRemoteId,
  });

  final String id;
  final String? query;
  final String? remoteId;
  final String? title;
  final String? url;
  final String? chapterId;
  final String? titlePattern;
  final String? canonicalRemoteId;

  String get asset => id == 'mangadex'
      ? 'assets/rules/mangadex-api-js.json'
      : 'assets/rules/$id-js.json';
}

const mangaSourcesLiveCases = <MangaSourceLiveCase>[
  // The old MangaDex record used Berserk. Select an ordinary family comedy
  // instead; resolve its real identity through live search, never a guessed ID.
  MangaSourceLiveCase(
    id: 'mangadex',
    query: 'Yotsuba',
    remoteId: '58be6aa6-06cb-4ca5-bd20-f1392ce451fb',
  ),
  // The old Komiic sample carried a sexual-content warning. This public sample
  // has an empty warnings array in komiic-public-probe.json.
  MangaSourceLiveCase(id: 'komiic', query: '香格里拉', remoteId: '1050'),
  MangaSourceLiveCase(id: 'xkcd', query: '1', remoteId: '1', chapterId: '1'),
  MangaSourceLiveCase(
    id: 'manhuagui',
    query: '鬼灭之刃',
    remoteId: '19430',
    chapterId: '19430/248298',
  ),
  MangaSourceLiveCase(id: 'webtoons-zh', query: '看臉時代', remoteId: '546'),
  MangaSourceLiveCase(
    id: 'bh3',
    query: '逃离长空篇',
    remoteId: '1001',
    chapterId: '1001/1',
  ),
  MangaSourceLiveCase(
    id: 'terrahistoricus',
    query: '循途漫录：大将军，出击！',
    remoteId: 'terra-historicus/7746',
    chapterId: 'terra-historicus/7746/8623',
  ),
  MangaSourceLiveCase(
    id: 'kuaikanmanhua',
    query: '怦然心动',
    remoteId: '766',
    chapterId: '196392',
  ),
  MangaSourceLiveCase(
    id: 'mh1234',
    query: '我的微信连三界',
    remoteId: '13704',
    chapterId: '413578',
  ),
  MangaSourceLiveCase(
    id: 'guazimanhua',
    query: '从姑获鸟开始',
    remoteId: '14109',
    chapterId: '1624326',
  ),
  // No search export: current public search returned 404. Use an observed
  // non-erotic work, not the old runtime sample selected from trending results.
  MangaSourceLiveCase(
    id: 'miaoqu',
    query: null,
    remoteId: 'zhoushuhuizhan',
    title: '咒术回战',
    url: 'https://www.miaoqumh.org/zhoushuhuizhan',
    chapterId: '255393/52916',
  ),
  MangaSourceLiveCase(
    id: 'iqiyi',
    query: '我家侯爷不宠我',
    remoteId: '283300070',
    chapterId: '2454170170',
  ),
  MangaSourceLiveCase(
    id: 'dongmanmanhua',
    query: '如出一辙的女儿',
    remoteId: '1954',
    chapterId: '1954:1',
  ),
  MangaSourceLiveCase(
    id: 'baozimanhuaplus',
    query: '死灵法师',
    remoteId: 'silingfashiwojishitianzai-mantudezhuyuanzhuheiniaoshe',
    canonicalRemoteId:
        'silingfashiwojishitianzai-mantudezhuyuanzhuheiniaoshe_rjogsq',
    chapterId:
        'silingfashiwojishitianzai-mantudezhuyuanzhuheiniaoshe_rjogsq/0_1',
  ),
  MangaSourceLiveCase(
    id: 'baozimhorg',
    query: '武炼巅峰',
    remoteId: 'wuliandianfeng-pikapi',
    chapterId: '12/907630',
  ),
  MangaSourceLiveCase(
    id: 'zaimanhua',
    query: '瓶中女巫',
    remoteId: '84957',
    chapterId: '84957/182458',
  ),
  // This published source is a general magazine catalog, not manga-only.
  MangaSourceLiveCase(
    id: 'zazhimi',
    query: '25ans',
    remoteId: '26492',
    chapterId: '26492',
  ),
];
