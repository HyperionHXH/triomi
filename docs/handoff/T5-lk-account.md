# T5 · LK（轻之国度）账号域接口层

> 对应规格：2.4 C2（资料/轻币/签到/关注/发布管理/消息中心/评论）。
> 参照实现（必读）：`_refs/mixn/.../core/data/LightNovelRepository.kt`
> （1018 行，含全部请求体构造与响应解析）。
> **本任务只做接口层 + 领域对象 + 单测**；页面由本机接手，联调需 LK 账号。

## 现状

- LK 客户端已落地：`lib/features/novel/data/lk/lk_client.dart`
  （pc-proxy 信封解析、`_pick/_obj/_listOf/_string/_int` 宽松取值族、
  会话 `lk.securityKey`、登录/恢复/榜单/搜索/详情/卷章/正文/书架/进度/解锁）。
- 评论走**另一个 base**（Mixn 里叫 commentApi）：
  `https://api.lightnovel.fun/pc-comment-proxy/`（其余都是
  `https://www.lightnovel.fun/api/pc-proxy/`）。`LkClient` 目前只有一个
  baseUrl，需要扩展成两个。
- `LkSource`（`lk_source.dart`）实现现有能力；账号域通过新能力接口暴露。

## 范围

### 做
1. `LkClient` 扩展账号域方法（信封解析与取值族直接复用）。
2. 账号域领域对象与能力接口（`AccountProfileProvider` 风格的新契约，
   见下）。
3. 单测（FakeHttpClient 路由 + 夹具 JSON）。

### 不做
- 页面 UI（资料页/签到页/消息页/评论列表与编辑器）。
- 图片上传（`api/dynamic/upload-image-v1` 的 multipart）——本期评论只发
  纯文本；上传接口留 TODO 注释即可。

## 接口清单（全部 POST JSON；base 见上）

| 领域 | 路径 | 用途 |
|---|---|---|
| 资料 | `api/bff/my-home-v1` | 个人资料、轻币余额、关注/粉丝数 |
| 签到 | `api/bff/welfare-sign-detail-v1` | 签到状态（七日格子、今日是否已签） |
| 签到 | `api/bff/claim-welfare-sign-v1` | 领取当日签到 |
| 关注 | `api/bff/toggle-user-follow-v1` | 关注/取关用户 |
| 消息 | `api/bff/message-unread-v1` | 各分类未读数（角标） |
| 私信 | `api/bff/dm-conversations-v1` / `dm-messages-v1` / `dm-mark-read-v1` | 私信会话、消息、标读 |
| 通知 | `api/bff/message-mark-read-v1` | 通知标读 |
| 评论 | `api/new-content-read/get-book-comments` | 评论列表（最热/最新、分页、星级） |
| 评论 | `api/discuss/publish-book-comment` | 发表评论（支持 mention UID 数组——Mixn 的 jsonBody 有专门处理，照搬） |
| 评论 | `api/discuss/like-book-comment` | 点赞/取消 |
| 表情 | `api/bff/comment-emoji-list-v1` | 评论可用表情 |
| 书架态 | `api/new-content-read/get-book-library-state` / `toggle-book-shelf` | 站点收藏状态切换 |
| 历史 | `api/bff/history-v1` / `api/new-content-read/save-book-history` / `delete-book-history` | 站点阅读历史 |

**请求体与响应字段以 Mixn 的 LightNovelRepository.kt 为准**（按上面路径
搜对应方法；信封与多候选键风格与 lk_client 一致）。

## 实现规格

1. `LkClient`：base 扩展为
   `LkClient({mainBase = 'https://www.lightnovel.fun/api/pc-proxy/',
   commentBase = 'https://api.lightnovel.fun/pc-comment-proxy/'})`；
   评论域请求走 commentBase。**现有测试里的 baseUrl 注入点不能破坏**
   （m4_test 的路由以路径为准，base 改了要同步更新测试断言）。
2. 领域对象（`lk_account_models.dart`）：`LkProfile / LkSignDetail /
   LkUnreadSummary / LkConversation / LkDmMessage / LkCommentPage / LkComment`。
   评论分页参数对齐 Mixn（sort=hot/latest、page、pageSize）。
3. 能力接口（`source_api.dart` 追加，**不破坏现有实现类**）：
   ```dart
   abstract class AccountProfileProvider implements AccountProvider {
     Future<LkProfile> profile();          // 资料（含余额）
     Future<LkSignDetail> signDetail();    // 签到状态
     Future<void> claimSign();             // 签到
     Future<LkUnreadSummary> unreadMessages();
     Future<LkCommentPage> comments(String bookRemoteId,
         {required String sort, required int page});
     Future<void> publishComment(String bookRemoteId,
         {required String text, List<int> mentionUids = const []});
     Future<void> likeComment(String commentId, {required bool like});
   }
   ```
   类型放 `lk_account_models.dart`（接口签名里用别名 import 或直接放
   source_api 同包——选后者更顺，但保持 source_api 不依赖 features/：
   **把模型类放 `lib/core/models/lk_account.dart`**）。
4. `LkSource implements AccountProfileProvider`。
5. 所有方法**必须带 security_key**（未登录抛 auth 错误，与现有
   `_requireSession` 行为一致）。

## 测试要求（test/t5_test.dart）

1. my-home-v1 解析：余额/昵称/关注粉丝（夹具 JSON，含缺字段降级）。
2. 签到两接口：状态解析（七日格子）、claim 后 streak+1。
3. 评论列表：hot/latest 两排序参数正确发出；分页 pageSize；星级字段；
   mention 数组在 publish body 里是数组不是字符串（Mixn 的坑，必须有断言）。
4. 未登录调用 → auth 错误（消息引导登录）。
5. commentBase 路由：评论请求确实打到 pc-comment-proxy（FakeHttpClient
   记录完整 URL 断言）。
6. 现有 m4_test 不回归（含 baseUrl 注入）。

## 验收标准

- analyze 零问题；测试全绿；无 UI 代码。
- 凭据不落日志；密码/验证码不出现在任何持久化。

## 后续集成点

- 本机：资料页（头像/余额/签到按钮）、消息中心页（分类未读角标）、
  详情页评论 Tab（列表/排序/分页/发表/点赞）；夹具服务补这些端点做 E2E。
