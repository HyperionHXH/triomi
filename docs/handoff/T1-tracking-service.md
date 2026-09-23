# T1 · 追踪服务（Bangumi / AniList 进度上报）

> 对应规格：PROJECT_SPEC 3.2（元数据/追踪）、路线图 M5（「进度上报 Bangumi」）。
> 这是 M5 验收**唯一未达标**的硬指标，优先级最高。
> 目标产出：`lib/features/tracking/` 数据层 + 单测，UI 接线由本机接手。

## 现状（已就位，不要重做）

- DB 表已存在：`lib/core/db/tables.dart` 的 `TrackBinds`（`sourceId, remoteId,
  service, remoteTrackId, syncedAt`，复合主键）。**表结构不用改。**
- 书架状态字段：`library_entries.status`（text，默认 `'doing'`）。
  本项目约定取值：`want / doing / done / paused / dropped`。
- 进度入口：`LibraryRepository.updateProgress({sourceId, remoteId, chapterNumber})`
  （章节号 double）。三个调用点：播放器 / 小说阅读器 / 漫画阅读器。
- 网络层：`SourceHttpClient`（`lib/core/source/http_client.dart`），测试替身
  `test/fixtures/fake_http_client.dart`（支持路由、bytesHandler、uploads 断言）。
- 「我的 → 追踪账号」入口是占位（`profile_page.dart` 的 `_comingSoon`）。

## 范围

### 做
1. `BangumiClient`（REST v0）与 `AniListClient`（GraphQL），共用
   `SourceHttpClient`，错误分类对齐 `SourceErrorType`（401/403→auth、
   404→notFound、429/5xx→server、超时→network）。
2. `TrackingRepository`（TrackBinds 表读写）。
3. `TrackingService`（绑定/解绑/状态映射/进度上报/冲突合并）。
4. 全部单元测试。

### 不做
- 追踪账号页 UI、播放器/阅读器的上报触发接线（后续集成，见文末）。
- OAuth 授权流程（用 personal access token，用户手动粘贴）。

## 实现规格

### 1. BangumiClient — `lib/features/tracking/data/bangumi_client.dart`

Base：`https://api.bgm.tv`；鉴权：`Authorization: Bearer <personal access token>`。
推荐 UA 带联系信息（Bangumi 要求）。

```
GET  /v0/me                                        → { username, id }
GET  /v0/search/subjects/{keyword}?type=2          → 搜索动画条目（分页 limit/offset）
GET  /v0/subjects/{subjectId}                      → 条目详情（name, name_cn, eps）
GET  /v0/users/{username}/collections/{subjectId}  → 收藏状态；404 = 未收藏
POST /v0/users/{username}/collections/{subjectId}  → 创建/更新收藏
     body: { type: int, rate?: int, comment?: string, private?: bool }
PATCH /v0/users/{username}/collections/{subjectId} → 进度
     body: { watched_eps: int, watched_vols?: int }
```

收藏 type 映射：`want=1(想看) doing=3(在看) done=2(看过) paused=4(搁置) dropped=5(抛弃)`。
**注意 Bangumi 的 2=collect(看过)、3=doing(在看)，不要写反**（映射表放常量并加单测）。

### 2. AniListClient — `lib/features/tracking/data/anilist_client.dart`

`POST https://graphql.anilist.co`，`Authorization: Bearer <token>`，
`Content-Type: application/json`。

```graphql
query { Viewer { id name } }
query ($q: String) { Page(perPage: 10) { media(search: $q, type: ANIME) {
  id title { romaji native } episodes } } }
mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int) {
  SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress) {
    id status progress } }
```

status 映射：`want=PLANNING doing=CURRENT done=COMPLETED paused=PAUSED
dropped=DROPPED`。GraphQL 的 `errors` 数组视为业务错误（取 message 抛出）。

### 3. TrackingRepository — `lib/features/tracking/data/tracking_repository.dart`

TrackBinds 表 CRUD：
- `bind(sourceId, remoteId, service, remoteTrackId)`（upsert，写 syncedAt）
- `unbind(sourceId, remoteId, service)` / `unbindAll(sourceId, remoteId)`
- `bindsFor(sourceId, remoteId)` / `allBinds()`
- `markSynced(sourceId, remoteId, service, time)`

### 4. TrackingService — `lib/features/tracking/data/tracking_service.dart`

```dart
class TrackingService {
  /// 凭据（仅 token，用户手动粘贴；存 Preferences，**不落日志**）。
  Future<void> setToken(TrackingServiceKind kind, String token);
  Future<bool> hasToken(TrackingServiceKind kind);
  Future<void> clearToken(TrackingServiceKind kind);

  /// 按标题搜索远端条目（绑定 UI 用）。
  Future<List<TrackCandidate>> search(TrackingServiceKind kind, String title);

  /// 绑定并立刻做一次状态+进度推送。
  Future<void> bind({required MediaItem item, required TrackingServiceKind kind,
      required String remoteTrackId, String status = 'doing', double progress = 0});

  /// 本地进度变化时调用（异步、尽力而为、**绝不抛错打断阅读**）。
  /// 对 item 的全部绑定并行上报；任一失败记入返回值，不阻断其他。
  Future<List<TrackSyncResult>> reportProgress({
    required String sourceId, required String remoteId,
    required double chapterNumber, int? totalEpisodes});

  /// 状态变化时同步收藏状态。
  Future<void> reportStatus({required String sourceId,
      required String remoteId, required String status});
}
```

- `watched_eps = chapterNumber.floor()`（集数从 1 开始，本地第 N 话 = watched_eps N）。
- 冲突策略：上报前读远端 `watched_eps`，**只增不减**（本地 < 远端则跳过推送，
  防止把旧进度覆盖新进度）；Bangumi 404（未收藏）时先 POST 建立收藏再 PATCH。
- token 存 Preferences：键 `tracking.<kind>.token`；**与备份的敏感键过滤
  保持一致**（`backup_service.dart` 的 `_isSensitive` 已含 `token`，无需改）。
- `TrackingServiceKind` 枚举：`bangumi / anilist`（表里的 `service` 值）。

## 测试要求（test/m5c_tracking_test.dart 或 test/t1_test.dart）

1. Bangumi 映射表：status→type 五个值全对（尤其 2/3 不反）；type→status 反向。
2. Bangumi PATCH：上报 watched_eps 取 floor；远端 404 时先 POST 后 PATCH
   （用 FakeHttpClient 路由断言调用顺序与 body）。
3. 只增不减：远端 watched_eps=8、本地 5 → 不发请求；本地 12 → 发 12。
4. AniList mutation 成功与 errors 分支（message 透出）。
5. reportProgress 部分失败不影响其他绑定（一个 401、一个成功）。
6. token 不落日志：FakeHttpClient 收到的 Authorization 头只在请求里，
   交付自查全文无 `print/token`。
7. TrackingRepository 的 upsert / unbindAll / markSynced 往返。

## 验收标准

- `flutter analyze` 零问题；新增测试全绿且全量测试不回归。
- 不引入 UI 代码（tracking/ 下只有 data/ 与领域类型）。
- 无新插件依赖（纯 Dart）。

## 后续集成点（本机接手，dpsk 不用做）

- `TrackingService.reportProgress` 在 `LibraryRepository.updateProgress` 成功后
  由 provider 层触发（三个调用点：player_page / novel_reader_page /
  manga_reader_page，通过 Riverpod 而非侵入仓储）。
- 追踪账号页：绑定/解绑/搜索选择条目。
