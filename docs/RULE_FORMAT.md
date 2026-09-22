# 规则格式说明（声明式来源）

Triomi 的来源规则是一份 JSON 文件，描述「怎么请求、怎么取字段」。
应用不内置任何内容源，规则由使用者自行添加。同一份引擎同时支持 **HTML 站点** 与 **JSON 接口**。

## 1. 最小结构

```json
{
  "id": "my-manga",
  "name": "我的漫画源",
  "type": "manga",
  "lang": "zh",
  "version": "1.0.0",
  "baseUrl": "https://example.com",
  "capabilities": ["search"],
  "search": {
    "url": "/search?q={keyword}&page={page}",
    "list": ".list .item",
    "fields": {
      "remoteId": { "selector": "a", "attr": "href", "regex": "/manga/(\\d+)" },
      "title": "a.title",
      "url": { "selector": "a", "attr": "href", "absolute": true }
    }
  }
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 稳定本地标识（不是站点 ID），导入后不可变更 |
| `name` | ✅ | 展示名 |
| `type` | ✅ | `anime` / `manga` / `novel` |
| `lang` | | 默认 `zh` |
| `version` | | 便于日后判断规则是否需要更新 |
| `baseUrl` | | 与相对地址拼接用；JSON 接口也填 |
| `response` | | `html`（默认）或 `json` |
| `requireLogin` | | 该源是否需要登录（UI 会据此提示） |
| `headers` | | 附加请求头（会与全局 UA 合并） |
| `capabilities` | ✅ | 见下节 |

## 2. 能力声明

`capabilities` 决定 UI 显示哪些功能，且**必须与规则内容一致**（不一致会在导入时被自检拒绝）：

| 能力 | 需要提供的规则 |
|---|---|
| `discover` | `discover.feeds` + `discover.list` |
| `search` | `search.list` |
| `detail` | `detail`（或至少 `search`） |
| `content` | `content` |
| `account` / `remoteShelf` / `progressSync` / `unlock` / `comment` / `reward` | 需登录或付费的站点能力，M4 随内置适配器落地 |

## 3. 请求模板

请求地址与请求体支持以下占位符：

| 占位符 | 含义 |
|---|---|
| `{page}` | 页码（从 1 开始） |
| `{offset}` | `(page - 1) × pageSize`，`pageSize` 默认 20，可用 `pageSize` 覆盖 |
| `{keyword}` | 原始关键词 |
| `{keywordEncoded}` | 关键词的 URL 编码形式 |
| `{urlRaw}` | 详情 / 正文页地址（原样） |
| `{url}` | 同上，但经过 URL 编码（放进参数时用） |
| `{id}` | 作品的源内标识（详情、剧集等二次请求用） |

> 处理顺序是「先替换占位符、再补全相对地址」，所以 `"{urlRaw}"`、`"/v0/subjects/{id}"`
> 这类写法都能正确处理。

## 4. 字段提取

`fields` 的每个值可以是三种写法：

```json
"title": "a.title"                         // 简写：选择器，取文本
"cover": "img.cover@data-src"              // 简写：选择器@属性
"url": {                                   // 完整写法
  "selector": "a",
  "attr": "href",                          // text（默认）| html | outerHtml | 任意属性名
  "regex": "/manga/(\\d+)",                // 命中后进一步提取
  "group": 1,                              // 取第几个捕获组，默认 1
  "trim": true,                            // 默认 true
  "absolute": true                         // 把相对地址补全为绝对地址
}
```

**选择器语法**（HTML 模式）：

- CSS：`.list .item`、`a.title`、`img[data-src]`
- XPath：`//div[@class='item']`、`.//a`（相对当前节点）、`//a/@href`（直接取属性）

> 章节列表这类「在当前页面里再查一层」的场景，用 `.//` 开头的相对选择器。

**列表项的字段**默认在**该项节点内部**查询（相对语义），因此写 `.title` 或 `.//a` 即可。

**约定与兜底**：

- 列表项缺少 `remoteId` 或标题（`title` / `name`）时会被跳过，不会产生脏数据。
- 标题支持 `name` 兜底：`name_cn` 为空时自动用站点原名（Bangumi 规则即依赖此行为）。
- `content.images` 是**数组**，按顺序尝试，第一个取到值的生效 —— 常用于
  `["img@data-original", "img@data-src", "img@src"]` 这类懒加载站点的兜底。
- `content.text` 取到的 HTML 会转成纯文本：保留段落换行、去标签、还原 HTML 实体。
- `locked` 字段为字符串 `"true"` 时标记为付费/锁定章节（应用只标注，不绕过、不缓存、不导出）。

## 5. JSON 接口模式

`"response": "json"` 时：

- `list` 与字段的 `selector` 改用**点路径**：`data`、`images.large`、`data.0.name`
- 字段的 `regex` / `group` / `trim` 仍然生效
- `content.images` 不适用（JSON 接口一般没有图片选择器）

示例（随包分发的 `assets/rules/bangumi-anime.json` 就是这么写的）：

```json
{
  "id": "bangumi-anime",
  "name": "Bangumi 番剧资料",
  "type": "anime",
  "baseUrl": "https://api.bgm.tv",
  "response": "json",
  "headers": { "User-Agent": "Triomi/0.1.0 (https://github.com/HyperionHXH/triomi)" },
  "capabilities": ["search", "detail"],
  "search": {
    "url": "/v0/search/subjects?limit=20&offset={offset}",
    "method": "POST",
    "bodyType": "json",
    "body": "{\"keyword\":\"{keyword}\",\"filter\":{\"type\":[2]}}",
    "list": "data",
    "fields": { "remoteId": "id", "title": "name_cn", "name": "name", "coverUrl": "images.large" }
  },
  "detail": {
    "url": "/v0/subjects/{id}",
    "fields": { "title": "name_cn", "description": "summary" },
    "chapters": {
      "url": "/v0/episodes?subject_id={id}&limit=100",
      "list": "data",
      "fields": { "remoteId": "id", "title": "name_cn", "name": "name", "number": "sort", "releaseDate": "airdate" }
    }
  }
}
```

## 6. 导入与排错

- 入口：发现页 / 我的 →「来源与规则」→ 右上角导入（粘贴文本 / 从剪贴板 / 从 URL 拉取）。
- 导入时会做**结构自检**，报错信息会直接说明原因（例如 `缺少 id`、
  `声明了 content 能力但没有 content 规则`）。
- 规则加载失败的来源**不会静默消失**：它会在来源管理页以红色失败项显示，
  并带上具体原因（便于定位是规则写错还是 JSON 坏了）。
- 应用运行时的解析失败会带上来源名与错误类别（需要登录 / 限流 / 超时 / 解析失败 / 权限 / 不存在），
  聚合搜索时**单个来源失败不影响其它来源**。

## 7. 免责提示

规则只描述如何解析站点结构。请遵守目标站点的服务条款与内容版权要求，
不要批量抓取、分发或商业使用站点内容。
